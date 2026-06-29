-- Large, repeatable performance benchmark for proxquery.
--
-- Builds a deterministic synthetic corpus whose term distribution mirrors real
-- English text (COCA top-5000 lemmas, weighted by their real frequency) plus a
-- synthetic long tail, indexes it with a plain GIN index, generates a realistic
-- e-discovery-style query list, and times the native extension against the
-- pure-SQL port.
--
-- The vocabulary, query list, and corpus generation live in shared includes
-- (_vocab.sql, _queries.sql, _corpus.sql) so this benchmark and the inspect
-- tool (inspect.sql) always use identical generation logic. Everything is driven
-- by two seeds (`seed` for the corpus, `qseed` for the queries), so a given set
-- of parameters always reproduces the same corpus and the same queries; the
-- query list is independent of corpus size, so it runs against every tier.
--
-- Run from the repo ROOT (the \copy and \i paths are repo-relative):
--   psql -d DB -v target_mb=1024 -v with_pure=0 -f bench/large/large_bench.sql
-- Parameters (all overridable with -v); generation params are documented in the
-- includes (_vocab.sql / _queries.sql / _corpus.sql):
--   seed/qseed, target_mb, tail_words, zipf_s, batch_docs, max_doc_len,
--   n_topics, n_stop, seg_buckets, segment_len  (corpus + topic locality)
--   nqueries, termlo, termhi, dist_min, dist_max, query_topn  (query mix)
--   iters        timed iterations per query (after a warmup)             (3)
--   with_pure    1 = also time the pure-SQL port + parity gate           (1)
--   with_seqscan 1 = also time the index-disabled (seq scan) baseline    (0)
--   pure         path to the pure-SQL port                  (sql/proxquery_pure.sql)

\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;   -- serial: stable timing AND repeatable RNG order
SET jit = off;
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';

\if :{?iters}
\else
  \set iters 3
\endif
\if :{?with_pure}
\else
  \set with_pure 1
\endif
\if :{?with_seqscan}
\else
  \set with_seqscan 0
\endif
\if :{?pure}
\else
  \set pure 'sql/proxquery_pure.sql'
\endif

-- Phase wall-clock markers, so the report shows where the time actually went
-- (corpus build vs searches) — a useful reference on a shared CI runner.
CREATE TEMP TABLE phase_t(name text, ts timestamptz);
INSERT INTO phase_t VALUES ('start', clock_timestamp());

-- Native extension into public (incl. the @~@ operator); pure-SQL port into the
-- proxquery schema. Restore a search_path that sees both.
DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;
\i :pure
SET search_path = public, proxquery, pg_catalog;

-- Vocabulary, query list, corpus (shared with inspect.sql).
\i bench/large/_vocab.sql
\i bench/large/_queries.sql
INSERT INTO phase_t VALUES ('setup (extension + vocab + queries)', clock_timestamp());
\i bench/large/_corpus.sql
INSERT INTO phase_t VALUES ('corpus (generate + GIN)', clock_timestamp());

-- ================================================================= benchmark
-- avg server-side ms over `iters` runs. NO warmup: the corpus is already cache-warm from the
-- build (and the count/indexed probes that run first), and these timings are qualitative — a
-- smoke + parity check, not a perf baseline — so a per-query priming run isn't worth its cost.
-- `q` MUST be a fully-formed query with the DSL string embedded as a LITERAL (callers
-- build it with format(... %L ...)). Plain `EXECUTE q` re-plans the literal on every run
-- with no plan cache, so each run is a custom plan where `ts_prox_search` inlines and its
-- recheck folds — i.e. we time the real index-served plan. Do NOT switch to `EXECUTE ...
-- USING $1` or `PREPARE`: a parameterized/generic plan can't const-fold the query and
-- silently stops the inlining/fold, which would make the timings measure the wrong plan.
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 2);
END $$;

DROP TABLE IF EXISTS results;
CREATE TABLE results(id int, shape text, q text, candidates bigint, matches bigint,
                     ext_op_ms numeric, ext_search_ms numeric, pure_search_ms numeric, disagree bigint,
                     ext_seq_ms numeric);

SET lb.iters       = :iters;
SET lb.with_pure   = :with_pure;
SET lb.with_seqscan = :with_seqscan;

\echo ''
\echo '== running benchmark =='
DO $run$
DECLARE
  it       int  := current_setting('lb.iters')::int;
  do_pure  bool := current_setting('lb.with_pure')::int = 1;
  do_seq   bool := current_setting('lb.with_seqscan')::int = 1;
  r        record;
  cand     bigint; matc bigint; pmatc bigint;
  exop     numeric; exs numeric; pus numeric; dis bigint; seqms numeric;
BEGIN
  FOR r IN SELECT id, shape, q FROM queries ORDER BY id LOOP
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @@ public.ts_prox_query(%L)', r.q) INTO cand;
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q) INTO matc;
    exop := bench_ms(format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q), it);
    seqms := NULL;
    IF do_seq THEN
      -- Same `@~@` query with the index DISABLED: the positional recheck runs over EVERY row
      -- (a full seq scan) — the brute-force baseline the GIN index accelerates, and the timing
      -- counterpart of the index-vs-seq-scan correctness test. Always ONE run (this column is
      -- qualitative — an order-of-magnitude index speedup, not a precise per-query metric), and
      -- not multiplied by `iters`. Off by default (and on the large tier), where a whole-corpus
      -- recheck per query would dominate.
      SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off;
      seqms := bench_ms(format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q), 1);
      SET LOCAL enable_indexscan = on;  SET LOCAL enable_bitmapscan = on;
    END IF;
    IF do_pure THEN
      -- The consolidated `ts_prox_search` is the recommended portable form (it inlines to
      -- the index-selection clause plus a recheck that folds away when the query's skeleton
      -- is exact). ext_search is the apples-to-apples denominator for the pure slowdown
      -- ratio — same form, different engine — so it is only timed alongside the pure port.
      exs  := bench_ms(format('SELECT count(*) FROM corpus WHERE public.ts_prox_search(body_tsv, %L)', r.q), it);
      -- Parity here is a per-query match-COUNT check (cheap): a differing count
      -- proves a differing row set. The exhaustive row-set identity guarantee is
      -- the matrix job's dedicated pure_sql_port_matches_extension test; this is
      -- a perf + smoke run, so we keep the parity probe to one extra pure count.
      EXECUTE format('SELECT count(*) FROM corpus WHERE proxquery.ts_prox_search(body_tsv, %L)', r.q) INTO pmatc;
      pus := bench_ms(format('SELECT count(*) FROM corpus WHERE proxquery.ts_prox_search(body_tsv, %L)', r.q), it);
      dis := abs(matc - pmatc);
    ELSE
      exs := NULL; pus := NULL; dis := NULL;
    END IF;
    INSERT INTO results VALUES (r.id, r.shape, r.q, cand, matc, exop, exs, pus, dis, seqms);
  END LOOP;
END $run$;
INSERT INTO phase_t VALUES ('searches', clock_timestamp());

-- ------------------------------------------------------------------- reports
\echo ''
\echo '== phase timing (wall seconds) =='
SELECT name AS phase,
       round(extract(epoch FROM ts - lag(ts) OVER (ORDER BY ts))::numeric, 1) AS seconds
FROM phase_t
ORDER BY ts
OFFSET 1;   -- drop the 'start' anchor row

\echo ''
\echo '== results: overall (avg ms/query over iters; lower is better) =='
SELECT count(*)                          AS queries,
       sum(candidates)                   AS total_candidates,
       sum(matches)                      AS total_matches,
       round(avg(ext_op_ms), 2)          AS ext_op_avg,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY ext_op_ms)::numeric, 2)  AS ext_op_p50,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ext_op_ms)::numeric, 2)  AS ext_op_p95,
       round(max(ext_op_ms), 2)          AS ext_op_max,
       round(avg(pure_search_ms), 2)     AS pure_avg,
       round(avg(pure_search_ms) / nullif(avg(ext_search_ms), 0), 1) AS slowdown
FROM results;

\echo ''
\echo '== results: by query shape =='
\if :with_seqscan
SELECT shape,
       count(*)                   AS n,
       round(avg(candidates))     AS avg_cand,
       round(avg(matches))        AS avg_match,
       round(avg(ext_op_ms), 2)      AS ext_op_ms,
       round(avg(ext_seq_ms), 2)     AS ext_seq_ms,
       round(avg(ext_seq_ms) / nullif(avg(ext_op_ms), 0), 1) AS index_speedup,
       round(avg(ext_search_ms), 2)  AS ext_search_ms,
       round(avg(pure_search_ms), 2) AS pure_search_ms,
       round(avg(pure_search_ms) / nullif(avg(ext_search_ms), 0), 1) AS slowdown
FROM results
GROUP BY shape
ORDER BY ext_op_ms DESC;
\else
SELECT shape,
       count(*)                   AS n,
       round(avg(candidates))     AS avg_cand,
       round(avg(matches))        AS avg_match,
       round(avg(ext_op_ms), 2)      AS ext_op_ms,
       round(avg(ext_search_ms), 2)  AS ext_search_ms,
       round(avg(pure_search_ms), 2) AS pure_search_ms,
       round(avg(pure_search_ms) / nullif(avg(ext_search_ms), 0), 1) AS slowdown
FROM results
GROUP BY shape
ORDER BY ext_op_ms DESC;
\endif

-- Per-query (term-by-term) breakdown with candidate/match counts, for the collapsed
-- section of the report. `query` is HTML-escaped (&, <, >, |, *) so the OR `|` and the
-- `<~N>` operators survive both the `| `-aligned -> Markdown table parser and GitHub's
-- HTML sanitizer; raw psql shows the entities.
\echo ''
\echo '== results: per query (counts + timings; query HTML-escaped) =='
\if :with_pure
SELECT id, shape,
       replace(replace(replace(replace(replace(q,'&','&amp;'),'<','&lt;'),'>','&gt;'),'|','&#124;'),'*','&#42;') AS query,
       candidates, matches, ext_op_ms, ext_search_ms, pure_search_ms,
       round(pure_search_ms / nullif(ext_search_ms, 0), 1) AS slowdown
FROM results ORDER BY id;
\else
SELECT id, shape,
       replace(replace(replace(replace(replace(q,'&','&amp;'),'<','&lt;'),'>','&gt;'),'|','&#124;'),'*','&#42;') AS query,
       candidates, matches, ext_op_ms
FROM results ORDER BY id;
\endif
\echo ''

-- ------------------------------------------------------------- pushdown plans
-- Plan-shape guards, surfaced in the PR comment, using real queries from the generated
-- mix. (1) A within/pre query via the `@~@` operator must stay GIN-index-served via the
-- selective `a & b` skeleton + a positional recheck — NOT rewritten to the native `<~>`
-- OR-expansion, which is non-selective and the planner mis-estimates into a seq scan.
-- (2) The recommended `ts_prox_search` must inline + use the index, and on a boolean query
-- fold the recheck away entirely (Bitmap Index Scan, no Filter — no per-row re-detoast).
SELECT coalesce((SELECT q FROM queries WHERE shape = 'within' ORDER BY id LIMIT 1),
                'a <~5> b') AS within_q \gset
SELECT coalesce((SELECT q FROM queries WHERE shape IN ('and2','or2','single') ORDER BY id LIMIT 1),
                'a & b') AS bool_q \gset
\echo ''
\echo '== plan: @~@ within is index-served via the a&b skeleton (not a seq scan) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM corpus WHERE body_tsv @~@ :'within_q';
\echo ''
\echo '== plan: ts_prox_search on a boolean query folds the recheck away (Bitmap Index, no Filter) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM corpus WHERE proxquery.ts_prox_search(body_tsv, :'bool_q');

-- Gate the two plan-shape guarantees (selectivity-independent, so they don't flake on the
-- planner's index-vs-seqscan choice): a silent regression must FAIL the run, not just read
-- as slow timings. (1) the `@~@` within must keep its `@~@` positional recheck — losing it
-- means within was rewritten to the non-selective native OR-expansion (the seq-scan
-- pessimization). (2) `ts_prox_search` must inline (no opaque `ts_prox_search(` left in the
-- plan, else it silently seq-scans) and fold the recheck away on a boolean query.
SET lb.within_q = :'within_q';
SET lb.bool_q   = :'bool_q';
DO $plan$
DECLARE
  line text;
  op_keeps_recheck boolean := false;
  search_inlined   boolean := true;
  search_folded    boolean := true;
BEGIN
  FOR line IN EXECUTE format('EXPLAIN SELECT count(*) FROM corpus WHERE body_tsv @~@ %L',
                             current_setting('lb.within_q')) LOOP
    IF line LIKE '%@~@%' THEN op_keeps_recheck := true; END IF;
  END LOOP;
  FOR line IN EXECUTE format('EXPLAIN SELECT count(*) FROM corpus WHERE proxquery.ts_prox_search(body_tsv, %L)',
                             current_setting('lb.bool_q')) LOOP
    IF line LIKE '%ts_prox_search(%' THEN search_inlined := false; END IF;
    IF line LIKE '%ts_prox_recheck%' OR line LIKE '%_prox_recheck%' THEN search_folded := false; END IF;
  END LOOP;
  IF NOT op_keeps_recheck THEN
    RAISE EXCEPTION 'plan guard: @~@ within [%] lost its recheck — within rewritten to the native OR-expansion (seq-scan pessimization)', current_setting('lb.within_q');
  END IF;
  IF NOT search_inlined THEN
    RAISE EXCEPTION 'plan guard: ts_prox_search [%] did not inline — it would silently seq-scan', current_setting('lb.bool_q');
  END IF;
  IF NOT search_folded THEN
    RAISE EXCEPTION 'plan guard: ts_prox_search [%] did not fold the recheck on a boolean query', current_setting('lb.bool_q');
  END IF;
END $plan$;

-- Parity: with the pure port enabled, every query's extension and pure match
-- counts must agree. Reported as a visible row, then gated (timings on a shared
-- runner are noise; correctness is not).
\if :with_pure
\echo ''
\echo '== parity (pure port vs extension; mismatches must be 0) =='
SELECT count(*) AS queries_checked,
       count(*) FILTER (WHERE disagree <> 0) AS mismatches
FROM results;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM results WHERE disagree IS DISTINCT FROM 0;
  IF n > 0 THEN
    RAISE EXCEPTION 'parity mismatch: pure port and extension disagree on % quer(ies)', n;
  END IF;
END $$;
\endif

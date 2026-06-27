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
--   iters       timed iterations per query (after a warmup)       (3)
--   with_pure   1 = also time the pure-SQL port + parity gate     (1)
--   pure        path to the pure-SQL port                         (sql/proxquery_pure.sql)

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
-- avg server-side ms over `iters` runs, after a warmup that also primes caches.
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  EXECUTE q INTO sink;
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 2);
END $$;

DROP TABLE IF EXISTS results;
CREATE TABLE results(id int, shape text, q text, candidates bigint, matches bigint,
                     ext_op_ms numeric, ext_2cl_ms numeric, pure_2cl_ms numeric, disagree bigint);

SET lb.iters     = :iters;
SET lb.with_pure = :with_pure;

\echo ''
\echo '== running benchmark =='
DO $run$
DECLARE
  it       int  := current_setting('lb.iters')::int;
  do_pure  bool := current_setting('lb.with_pure')::int = 1;
  r        record;
  cand     bigint; matc bigint; pmatc bigint;
  exop     numeric; ex2 numeric; pu2 numeric; dis bigint;
BEGIN
  FOR r IN SELECT id, shape, q FROM queries ORDER BY id LOOP
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @@ public.ts_prox_query(%L)', r.q) INTO cand;
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q) INTO matc;
    exop := bench_ms(format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q), it);
    IF do_pure THEN
      -- ext_2cl is the apples-to-apples denominator for the pure slowdown ratio;
      -- it is ~identical to ext_op (the operator IS the two-clause form), so it is
      -- only worth timing when the pure port is also being timed.
      ex2  := bench_ms(format('SELECT count(*) FROM corpus WHERE body_tsv @@ public.ts_prox_query(%L) AND public.ts_prox_match(body_tsv,%L)', r.q, r.q), it);
      -- Parity here is a per-query match-COUNT check (cheap): a differing count
      -- proves a differing row set. The exhaustive row-set identity guarantee is
      -- the matrix job's dedicated pure_sql_port_matches_extension test; this is
      -- a perf + smoke run, so we keep the parity probe to one extra pure count.
      EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv,%L)', r.q, r.q) INTO pmatc;
      pu2 := bench_ms(format('SELECT count(*) FROM corpus WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv,%L)', r.q, r.q), it);
      dis := abs(matc - pmatc);
    ELSE
      ex2 := NULL; pu2 := NULL; dis := NULL;
    END IF;
    INSERT INTO results VALUES (r.id, r.shape, r.q, cand, matc, exop, ex2, pu2, dis);
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
       round(avg(pure_2cl_ms), 2)        AS pure_avg,
       round(avg(pure_2cl_ms) / nullif(avg(ext_2cl_ms), 0), 1) AS slowdown
FROM results;

\echo ''
\echo '== results: by query shape =='
SELECT shape,
       count(*)                   AS n,
       round(avg(candidates))     AS avg_cand,
       round(avg(matches))        AS avg_match,
       round(avg(ext_op_ms), 2)   AS ext_op_ms,
       round(avg(ext_2cl_ms), 2)  AS ext_2cl_ms,
       round(avg(pure_2cl_ms), 2) AS pure_2cl_ms,
       round(avg(pure_2cl_ms) / nullif(avg(ext_2cl_ms), 0), 1) AS slowdown
FROM results
GROUP BY shape
ORDER BY ext_op_ms DESC;

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

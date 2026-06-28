-- Pure-SQL port vs the native extension, head to head on one shared corpus.
--
-- Both implementations are installed into the SAME database over the SAME table
-- and GIN index, so the only variable is the implementation:
--   * native extension  -> public schema     (incl. the @~@ operator)
--   * pure-SQL port      -> proxquery schema  (sql/proxquery_pure.sql)
-- For each query shape we report the candidate count (rows the @@ skeleton
-- selects), the match count, and avg server-side ms for three forms:
--   ext_op_ms      : extension single operator `tsv @~@ q`  (support fn: index + recheck)
--   ext_search_ms  : extension via the consolidated `ts_prox_search(tsv, q)`
--   pure_search_ms : pure-SQL port via the same `ts_prox_search`
--   slowdown       : pure_search_ms / ext_search_ms  (apples-to-apples cost of going binary-free)
-- A per-query parity column (`disagree`) must be 0 — the two implementations
-- must select the identical row set on this corpus.
--
-- Run from the repo root (so the \i path resolves):
--   cargo pgrx run pg17 proxquery < bench/pure_vs_extension.sql
-- or with plain psql (tunable):
--   psql -d DB -v ndocs=50000 -v wlen=40 -v iters=10 -f bench/pure_vs_extension.sql
--
-- Numbers vary by corpus/machine; the SHAPE is the point: the pure port is
-- correct and index-served, but ~roughly an order of magnitude slower per
-- candidate (unnest per call + a re-parse per row vs the binary's O(log L)
-- access and per-scan parse cache).

\set ON_ERROR_STOP on
\timing off
SET max_parallel_workers_per_gather = 0;   -- stable, comparable timing
SET jit = off;

-- defaults (override any with -v on the psql command line)
\if :{?pure}
\else
  \set pure 'sql/proxquery_pure.sql'
\endif
\if :{?ndocs}
\else
  \set ndocs 20000
\endif
\if :{?wlen}
\else
  \set wlen 40
\endif
\if :{?iters}
\else
  \set iters 5
\endif

-- native extension into public (fresh, in case a stale version lingers)
DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;
-- pure-SQL port into the proxquery schema. The file SETs search_path to
-- proxquery; restore a path that sees both schemas (public has @~@).
\i :pure
SET search_path = public, proxquery, pg_catalog;

-- ---- deterministic synthetic corpus ---------------------------------------
-- :ndocs docs of :wlen tokens drawn from a 200-word vocab that includes the
-- terms the queries probe (each specific token lands in ~18% of docs at wlen=40).
DROP TABLE IF EXISTS bench;
CREATE TABLE bench(id serial PRIMARY KEY, body_tsv tsvector);

-- Each token is a random int in [0,199] mapped to a word: buckets 0..6 are the
-- probed terms, the rest are filler `w7..w199` (so each probed term lands in
-- ~18% of docs at wlen=40). The random draw lives in a fenced (`OFFSET 0`)
-- per-(doc,word) subquery so it is evaluated once per row — a non-correlated
-- scalar subquery would be hoisted to a run-once InitPlan and make every doc
-- identical. A CASE map avoids per-word text[] indexing (linear in array length).
SELECT setseed(0.42);
INSERT INTO bench(body_tsv)
SELECT to_tsvector('simple', string_agg(
         CASE r WHEN 0 THEN 'a' WHEN 1 THEN 'b' WHEN 2 THEN 'c'
                WHEN 3 THEN 'email' WHEN 4 THEN 'confidential'
                WHEN 5 THEN 'ssn' WHEN 6 THEN '123456789'
                ELSE 'w' || r END, ' ' ORDER BY w))
FROM (SELECT d, w, floor(random() * 200)::int AS r
      FROM generate_series(1, :ndocs) d, generate_series(1, :wlen) w
      OFFSET 0) g
GROUP BY d;

CREATE INDEX bench_gin ON bench USING gin(body_tsv);
ANALYZE bench;

\echo ''
\echo '== corpus shape =='
SELECT count(*) AS docs,
       round(avg(length(body_tsv))) AS avg_lexemes_per_doc,
       pg_size_pretty(pg_total_relation_size('bench')) AS table_size
FROM bench;

-- ---- timing harness: avg server-side ms over `iters` runs, after a warmup ---
-- `q` MUST embed the DSL string as a LITERAL (callers use format(... %L ...)). Plain
-- `EXECUTE q` re-plans the literal each run with no plan cache, so every run is a custom
-- plan where `ts_prox_search` inlines and its recheck folds — we time the real index-served
-- plan. Do NOT switch to `EXECUTE ... USING $1` / `PREPARE`: a generic plan can't const-fold
-- the query and silently stops the fold, making the timings measure the wrong plan.
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  EXECUTE q INTO sink;                        -- warmup (and prime caches)
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);
END $$;

-- One row of the comparison for a DSL query `q`: counts, three timings, the
-- pure/ext slowdown, and a pure-vs-extension parity check (must be 0). The portable
-- form is the consolidated `ts_prox_search(tsv, q)` (index selection + a recheck that
-- folds away when the skeleton is exact); ext_search is the apples-to-apples denominator.
CREATE OR REPLACE FUNCTION bench_row(q text, iters int)
RETURNS TABLE(candidates bigint, matches bigint,
              ext_op_ms numeric, ext_search_ms numeric, pure_search_ms numeric,
              slowdown numeric, disagree bigint)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SELECT count(*) FROM bench WHERE body_tsv @@ public.ts_prox_query(%L)', q)
    INTO candidates;
  EXECUTE format('SELECT count(*) FROM bench WHERE body_tsv @~@ %L', q)
    INTO matches;
  ext_op_ms      := bench_ms(format('SELECT count(*) FROM bench WHERE body_tsv @~@ %L', q), iters);
  ext_search_ms  := bench_ms(format('SELECT count(*) FROM bench WHERE public.ts_prox_search(body_tsv, %L)', q), iters);
  pure_search_ms := bench_ms(format('SELECT count(*) FROM bench WHERE proxquery.ts_prox_search(body_tsv, %L)', q), iters);
  slowdown       := round(pure_search_ms / nullif(ext_search_ms, 0), 1);
  EXECUTE format($p$
    SELECT count(*) FROM (
      (SELECT id FROM bench WHERE body_tsv @~@ %L
       EXCEPT SELECT id FROM bench WHERE proxquery.ts_prox_search(body_tsv, %L))
      UNION ALL
      (SELECT id FROM bench WHERE proxquery.ts_prox_search(body_tsv, %L)
       EXCEPT SELECT id FROM bench WHERE body_tsv @~@ %L)
    ) d $p$, q, q, q, q)
    INTO disagree;
  RETURN NEXT;
END $$;

\echo ''
\echo '== pure-SQL port vs native extension (avg ms/query; disagree must be 0) =='
CREATE TEMP TABLE bench_results AS
SELECT t.q AS query, r.candidates, r.matches,
       r.ext_op_ms, r.ext_search_ms, r.pure_search_ms, r.slowdown, r.disagree
FROM (VALUES
        ('a & b'),                       -- boolean: ts_prox_search folds the recheck away
        ('a | b'),                       --   "       (skeleton is exact ⇒ no re-detoast)
        ('a <~3> b'),                    -- proximity: recheck does real work (kept)
        ('a <~3> b <~3> c'),
        ('confidential <!~5> email'),
        ('ssn <~3> ##[0-9]{9}##')
     ) t(q),
     LATERAL bench_row(t.q, :iters) r;
SELECT * FROM bench_results ORDER BY query;

-- Parity gate: the pure port and the extension must select identical rows on
-- this corpus. This is what makes the benchmark a real CI test (timings on a
-- shared runner are noise; correctness is not).
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM bench_results WHERE disagree <> 0;
    IF n > 0 THEN
        RAISE EXCEPTION 'parity mismatch: pure port and extension disagree on % quer(ies)', n;
    END IF;
    RAISE NOTICE 'parity: pure port and extension agree on all % queries', (SELECT count(*) FROM bench_results);
END $$;

-- `ts_prox_search` inlines, so the planner sees the `@@ ts_prox_query(q)` clause and uses
-- the GIN index. For a boolean (recheck-droppable) query the recheck folds away entirely —
-- Bitmap Index Scan with NO Filter, no per-row re-detoast.
\echo ''
\echo '== plan: ts_prox_search on a boolean query folds the recheck away (Bitmap Index, no Filter) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM bench WHERE proxquery.ts_prox_search(body_tsv, 'a & b');

-- For a within/pre shape the recheck does real work, so it is kept as the heap Filter over
-- the selective `a & b` presence skeleton — still index-served, never a seq scan.
\echo ''
\echo '== plan: ts_prox_search on a within query keeps the recheck Filter (still index-served) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM bench WHERE proxquery.ts_prox_search(body_tsv, 'a <~3> b');

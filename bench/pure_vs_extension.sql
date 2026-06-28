-- Pure-SQL port vs the native extension, head to head on one shared corpus.
--
-- Both implementations are installed into the SAME database over the SAME table
-- and GIN index, so the only variable is the implementation:
--   * native extension  -> public schema     (incl. the @~@ operator)
--   * pure-SQL port      -> proxquery schema  (sql/proxquery_pure.sql)
-- For each query shape we report the candidate count (rows the @@ skeleton
-- selects), the match count, and avg server-side ms for three forms:
--   ext_op_ms    : extension single operator `tsv @~@ q`  (support fn: index + recheck)
--   ext_2cl_ms   : extension, written as the portable two clauses
--   pure_2cl_ms  : pure-SQL port, the same two clauses
--   slowdown     : pure_2cl_ms / ext_2cl_ms  (the apples-to-apples cost of going binary-free)
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
-- pure/ext slowdown, and a pure-vs-extension parity check (must be 0).
CREATE OR REPLACE FUNCTION bench_row(q text, iters int)
RETURNS TABLE(candidates bigint, matches bigint,
              ext_op_ms numeric, ext_2cl_ms numeric, pure_2cl_ms numeric,
              slowdown numeric, disagree bigint)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SELECT count(*) FROM bench WHERE body_tsv @@ public.ts_prox_query(%L)', q)
    INTO candidates;
  EXECUTE format('SELECT count(*) FROM bench WHERE body_tsv @~@ %L', q)
    INTO matches;
  ext_op_ms   := bench_ms(format('SELECT count(*) FROM bench WHERE body_tsv @~@ %L', q), iters);
  ext_2cl_ms  := bench_ms(format('SELECT count(*) FROM bench WHERE body_tsv @@ public.ts_prox_query(%L) AND public.ts_prox_match(body_tsv,%L)', q, q), iters);
  pure_2cl_ms := bench_ms(format('SELECT count(*) FROM bench WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv,%L)', q, q), iters);
  slowdown    := round(pure_2cl_ms / nullif(ext_2cl_ms, 0), 1);
  EXECUTE format($p$
    SELECT count(*) FROM (
      (SELECT id FROM bench WHERE body_tsv @~@ %L
       EXCEPT SELECT id FROM bench WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv,%L))
      UNION ALL
      (SELECT id FROM bench WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv,%L)
       EXCEPT SELECT id FROM bench WHERE body_tsv @~@ %L)
    ) d $p$, q, q, q, q, q, q)
    INTO disagree;
  RETURN NEXT;
END $$;

\echo ''
\echo '== pure-SQL port vs native extension (avg ms/query; disagree must be 0) =='
CREATE TEMP TABLE bench_results AS
SELECT t.q AS query, r.candidates, r.matches,
       r.ext_op_ms, r.ext_2cl_ms, r.pure_2cl_ms, r.slowdown, r.disagree
FROM (VALUES
        ('a <~3> b'),
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

\echo ''
\echo '== plan: pure two-clause is GIN-index-served (Bitmap Index Scan + recheck Filter) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM bench
WHERE body_tsv @@ proxquery.ts_prox_query('a <~3> b')
  AND proxquery.ts_prox_match(body_tsv, 'a <~3> b');

-- The @~@ operator on a within/pre shape must be served the SAME way: the planner
-- support keeps the selective `a & b` presence skeleton as the Index Cond + the `@~@`
-- positional recheck as the heap Filter. (It must NOT rewrite the clause to the native
-- `<~>` OR-expansion, which is non-selective and the planner mis-estimates into a seq
-- scan — the within pessimization. Only phrase/exact/boolean are rewritten to a bare
-- native `@@` that drops the recheck.) Expect: Bitmap Index Scan on `ts_prox_query(...)`.
\echo ''
\echo '== plan: the @~@ operator (within) is index-served via the a&b skeleton, NOT a seq scan =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM bench WHERE body_tsv @~@ 'a <~3> b';

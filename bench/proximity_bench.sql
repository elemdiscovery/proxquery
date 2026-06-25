-- proxquery vs the unnest baseline, on a synthetic corpus.
--
-- Mirrors the README methodology: ~5k docs of a few hundred lexemes each, GIN
-- index, server-side timing. Proves two things: (1) proxquery and the unnest
-- subquery return the *same* rows, and (2) how much cheaper proxquery's
-- per-candidate test is. Run with:  cargo pgrx run pg17 proxquery < this file
\set ON_ERROR_STOP on
\timing off
SET max_parallel_workers_per_gather = 0;   -- stable, comparable recheck timing

-- Recreate from the freshly-installed script (cargo pgrx run reuses a persistent
-- DB, so a plain CREATE EXTENSION IF NOT EXISTS would keep a stale version).
DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;
-- CASCADE also clears any wrapper function left over from a prior run that
-- depends on the text_record row type.
DROP TABLE IF EXISTS text_record CASCADE;
CREATE TABLE text_record (id serial PRIMARY KEY, body text, text_tsv tsvector);

-- Deterministic synthetic corpus. Each doc is ~300 filler tokens drawn from a
-- 5,000-word vocabulary (so the tsvector carries a few hundred lexemes — the
-- thing `unnest` must materialize). 'confidential' is injected three ways:
--   15%  boilerplate:  "... confidential email"         (adjacent  -> within 5)
--   15%  substantive:  "confidential ... <300 toks> ... email"  (far -> NOT within)
--   10%  no email:     "confidential ..."               (absent    -> NOT within)
--   60%  neither term
SELECT setseed(0.42);
INSERT INTO text_record (body)
SELECT CASE
         WHEN g.r < 0.15 THEN g.filler || ' confidential email'
         WHEN g.r < 0.30 THEN 'confidential ' || g.filler || ' email'
         WHEN g.r < 0.40 THEN 'confidential ' || g.filler
         ELSE g.filler
       END
FROM (
  SELECT (SELECT string_agg('w' || (floor(random() * 5000))::int::text, ' ')
          FROM generate_series(1, 300)) AS filler,
         random() AS r
  FROM generate_series(1, 5000)
) g;

UPDATE text_record SET text_tsv = to_tsvector('simple', body);
CREATE INDEX text_record_tsv_gin ON text_record USING gin (text_tsv);
ANALYZE text_record;

\echo ''
\echo '== corpus shape =='
SELECT count(*)                                              AS docs,
       round(avg(length(text_tsv)))                         AS avg_lexemes_per_doc,
       pg_size_pretty(pg_total_relation_size('text_record'))AS table_size,
       count(*) FILTER (WHERE text_tsv @@ to_tsquery('simple','confidential')) AS confidential_candidates,
       count(*) FILTER (WHERE text_tsv @@ to_tsquery('simple','confidential')
                          AND ts_prox_not_within(text_tsv,'confidential','email',5)) AS not_within_matches
FROM text_record;

-- ---------------------------------------------------------------------------
-- Correctness parity: the proxquery predicate and the unnest subquery must
-- select the identical id set. Symmetric EXCEPT -> must be 0.
-- ---------------------------------------------------------------------------
\echo ''
\echo '== correctness parity (disagreements must be 0) =='
WITH prox AS (
  SELECT id FROM text_record
  WHERE text_tsv @@ to_tsquery('simple','confidential')
    AND ts_prox_not_within(text_tsv,'confidential','email',5)
), base AS (
  SELECT id FROM text_record
  WHERE text_tsv @@ to_tsquery('simple','confidential')
    AND EXISTS (
      SELECT 1 FROM unnest(text_tsv) wa, unnest(wa.positions) ap
      WHERE wa.lexeme = 'confidential'
        AND NOT EXISTS (
          SELECT 1 FROM unnest(text_tsv) wb, unnest(wb.positions) bp
          WHERE wb.lexeme = 'email' AND abs(ap - bp) <= 5))
)
SELECT (SELECT count(*) FROM (SELECT id FROM prox EXCEPT SELECT id FROM base) a)
     + (SELECT count(*) FROM (SELECT id FROM base EXCEPT SELECT id FROM prox) b) AS disagreements;

-- ---------------------------------------------------------------------------
-- Timing harness: average server-side ms over `iters` runs, after a warmup.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  EXECUTE q INTO sink;                       -- warmup (and prime caches)
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 3);
END $$ LANGUAGE plpgsql;

\echo ''
\echo '== not_within: a confidential with no email within 5 (occurrence-level) =='
\echo '(avg ms over 20 runs; subtract the floor for predicate-only cost)'
SELECT 'candidate floor (@@ only)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential')$q$, 20) AS avg_ms
UNION ALL
SELECT 'proxquery' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential')
                     AND ts_prox_not_within(text_tsv,'confidential','email',5)$q$, 20) AS avg_ms
UNION ALL
SELECT 'unnest',
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential')
                     AND EXISTS (
                       SELECT 1 FROM unnest(text_tsv) wa, unnest(wa.positions) ap
                       WHERE wa.lexeme='confidential'
                         AND NOT EXISTS (
                           SELECT 1 FROM unnest(text_tsv) wb, unnest(wb.positions) bp
                           WHERE wb.lexeme='email' AND abs(ap-bp)<=5))$q$, 20) AS avg_ms;

\echo ''
\echo '== within: confidential within 8 of email (either order) =='
\echo '(proxquery ts_prox_within vs the 16-clause native enumeration, avg ms over 20 runs)'
SELECT 'proxquery' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential & email')
                     AND ts_prox_within(text_tsv,'confidential','email',8)$q$, 20) AS avg_ms
UNION ALL
SELECT 'enumeration',
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple',
                     'confidential <1> email | email <1> confidential | confidential <2> email | email <2> confidential | confidential <3> email | email <3> confidential | confidential <4> email | email <4> confidential | confidential <5> email | email <5> confidential | confidential <6> email | email <6> confidential | confidential <7> email | email <7> confidential | confidential <8> email | email <8> confidential')$q$, 20) AS avg_ms;

-- ---------------------------------------------------------------------------
-- proxquery DSL compiler path: one query string drives both clauses.
-- ---------------------------------------------------------------------------
\echo ''
\echo '== compiler path: ts_prox_query + ts_prox_match via the proxsearch() wrapper =='
-- An inlinable SQL wrapper so the planner still uses the GIN index. NOT shipped
-- in the extension; generated per searchable table.
CREATE OR REPLACE FUNCTION proxsearch(q text) RETURNS SETOF text_record AS $$
  SELECT * FROM text_record
  WHERE text_tsv @@ ts_prox_query(q) AND ts_prox_match(text_tsv, q)
$$ LANGUAGE sql STABLE;

\echo '-- parity: proxsearch(compiler) vs hand-written ts_prox_not_within (disagreements must be 0)'
WITH compiler AS (SELECT id FROM proxsearch('confidential <!~5> email')),
     manual AS (
       SELECT id FROM text_record
       WHERE text_tsv @@ to_tsquery('simple','confidential')
         AND ts_prox_not_within(text_tsv,'confidential','email',5))
SELECT (SELECT count(*) FROM (SELECT id FROM compiler EXCEPT SELECT id FROM manual) a)
     + (SELECT count(*) FROM (SELECT id FROM manual EXCEPT SELECT id FROM compiler) b) AS disagreements;

\echo '-- timing: proxsearch(compiler) vs unnest baseline (avg ms over 20 runs)'
SELECT 'proxsearch (compiler)' AS impl,
       bench_ms($q$SELECT count(*) FROM proxsearch('confidential <!~5> email')$q$, 20) AS avg_ms
UNION ALL
SELECT 'unnest',
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential')
                     AND EXISTS (
                       SELECT 1 FROM unnest(text_tsv) wa, unnest(wa.positions) ap
                       WHERE wa.lexeme='confidential'
                         AND NOT EXISTS (
                           SELECT 1 FROM unnest(text_tsv) wb, unnest(wb.positions) bp
                           WHERE wb.lexeme='email' AND abs(ap-bp)<=5))$q$, 20) AS avg_ms;

\echo ''
\echo '== plan: proxsearch() compiler path (expect Bitmap Index Scan + ts_prox_match Filter) =='
EXPLAIN (COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM proxsearch('confidential <!~5> email');

\echo ''
\echo '== plan: proxquery not_within (expect Bitmap Index Scan + recheck Filter) =='
EXPLAIN (ANALYZE, BUFFERS, COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM text_record
WHERE text_tsv @@ to_tsquery('simple','confidential')
  AND ts_prox_not_within(text_tsv,'confidential','email',5);

-- ---------------------------------------------------------------------------
-- The @~@ operator (Milestone 3): one indexable clause, index-served via the
-- planner support function on a *plain* GIN index.
-- ---------------------------------------------------------------------------
\echo ''
\echo '== @~@ operator: single clause =='
\echo '-- parity: text_tsv @~@ q  vs  proxsearch(q) (disagreements must be 0)'
SELECT (SELECT count(*) FROM (
  (SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <!~5> email'
   EXCEPT SELECT id FROM proxsearch('confidential <!~5> email'))
  UNION ALL
  (SELECT id FROM proxsearch('confidential <!~5> email')
   EXCEPT SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <!~5> email')
) d) AS disagreements;

\echo '-- timing: @~@ operator (avg ms over 20 runs)'
SELECT bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @~@ 'confidential <!~5> email'$q$, 20) AS op_ms;

\echo ''
\echo '== plan: text_tsv @~@ q (expect Bitmap Index Scan + ts_prox_match recheck) =='
EXPLAIN (ANALYZE, BUFFERS, COSTS off, TIMING off, SUMMARY off)
SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <!~5> email';

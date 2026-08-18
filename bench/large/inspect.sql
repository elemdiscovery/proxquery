-- Local inspection of the benchmark's generated queries (and, optionally, their
-- hit counts on a small corpus). Uses the SAME shared includes as the benchmark
-- (_vocab.sql / _queries.sql / _corpus.sql), so what you see here is exactly what
-- large_bench.sql runs. Writes two CSVs into bench/reports/ (gitignored) and
-- prints reproducibility fingerprints + coverage.
--
-- Run from the repo ROOT:
--   psql -d DB -f bench/large/inspect.sql
-- Params (-v): nqueries (200), inspect_corpus (1 = also build a corpus and count
-- hits), target_mb (50 — the inspection corpus is small by default), plus any
-- generation param (seed, qseed, tail_words, ...).

\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;
SET jit = off;
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';

\if :{?inspect_corpus}
\else
  \set inspect_corpus 1
\endif
\if :{?target_mb}
\else
  \set target_mb 50
\endif

DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;

\i bench/large/_vocab.sql
\i bench/large/_queries.sql

-- Reproducibility fingerprints. PostgreSQL's setseed()/random() use PG's built-in
-- PRNG (since PG 15), and the samplers use no transcendental functions, so these
-- md5s are identical on every machine/OS for a given PG major version. Run this
-- on two hosts and compare to confirm.
\echo ''
\echo '== fingerprints (identical across machines for a given PG major) =='
SELECT (SELECT md5(string_agg(word, ',' ORDER BY id)) FROM vocab)               AS vocab_fingerprint,
       (SELECT md5(string_agg(id||'|'||shape||'|'||q, E'\n' ORDER BY id))
          FROM queries)                                                          AS query_fingerprint,
       (SELECT count(*) FROM queries)                                            AS nqueries;

\echo ''
\echo '== query shape distribution =='
SELECT shape, count(*) FROM queries GROUP BY shape ORDER BY count(*) DESC, shape;

-- Dump the full query list (id, shape, q) for eyeballing.
\copy (SELECT id, shape, q FROM queries ORDER BY id) TO 'bench/reports/inspect_queries.csv' WITH (FORMAT csv, HEADER true)
\echo 'wrote bench/reports/inspect_queries.csv'

\if :inspect_corpus
\i bench/large/_corpus.sql

-- inspect only needs candidate/match COUNTS (index-independent), so a plain GIN
-- index is enough here — the GIN-vs-RUM comparison lives in large_bench.sql.
-- (_corpus.sql no longer builds an index; each caller picks its own.)
CREATE INDEX corpus_gin ON corpus USING gin(body_tsv);

-- Per-query results: candidate count (the GIN-index skeleton) and match count
-- (the @~@ operator). This is the benchmark's measurement without the timing.
DROP TABLE IF EXISTS qresults;
CREATE TABLE qresults(id int, shape text, q text, candidates bigint, matches bigint);
\echo ''
\echo '== counting candidates + matches per query =='
DO $insp$
DECLARE r record; c bigint; m bigint;
BEGIN
  FOR r IN SELECT id, shape, q FROM queries ORDER BY id LOOP
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @@ public.ts_prox_query(%L)', r.q) INTO c;
    EXECUTE format('SELECT count(*) FROM corpus WHERE body_tsv @~@ %L', r.q) INTO m;
    INSERT INTO qresults VALUES (r.id, r.shape, r.q, c, m);
  END LOOP;
END $insp$;

\copy (SELECT id, shape, q, candidates, matches FROM qresults ORDER BY id) TO 'bench/reports/inspect_results.csv' WITH (FORMAT csv, HEADER true)
\echo 'wrote bench/reports/inspect_results.csv'

\echo ''
\echo '== coverage: do the queries find anything? =='
SELECT count(*) AS queries,
       count(*) FILTER (WHERE candidates > 0) AS have_candidates,
       count(*) FILTER (WHERE matches    > 0) AS have_matches,
       count(*) FILTER (WHERE matches    = 0) AS zero_match
FROM qresults;

\echo ''
\echo '== coverage by shape =='
SELECT shape,
       count(*) AS n,
       count(*) FILTER (WHERE candidates>0) AS w_cand,
       count(*) FILTER (WHERE matches>0)    AS w_match,
       round(avg(candidates)) AS avg_cand,
       round(avg(matches))    AS avg_match,
       max(matches)           AS max_match
FROM qresults
GROUP BY shape
ORDER BY shape;
\endif

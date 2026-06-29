-- Tokenizer overhead: the custom Unicode tokenizer (proxquery_to_tsvector, which
-- SUPERIMPOSES extra lexemes for accents / hyphens / emails) vs stock
-- to_tsvector('simple', …), head to head on ONE shared, deliberately overlap-heavy
-- corpus. The point is a smoke regression check: superimposition makes the prox
-- tsvector carry more lexemes per doc, so confirm the same proximity workload does
-- not get dramatically slower to match.
--
-- Reports, for the SAME query workload on each column: match counts, avg server-side
-- ms, and the prox/simple ratio — plus the corpus lexeme blow-up. Timings on a shared
-- runner are noisy (read the ratio as a smoke signal, not a baseline). Match counts
-- legitimately DIFFER between the two (the tokenizers normalize differently and
-- superimposition changes positions) — this is a perf comparison, not a parity check.
--
--   cargo pgrx run pg17 proxquery < bench/tokenizer_vs_simple.sql
--   psql -d DB -v ndocs=10000 -v wlen=40 -v iters=5 -f bench/tokenizer_vs_simple.sql

\set ON_ERROR_STOP on
\timing off
SET max_parallel_workers_per_gather = 0;   -- stable, comparable timing
SET jit = off;

\if :{?ndocs} \else \set ndocs 20000 \endif
\if :{?wlen}  \else \set wlen 40     \endif
\if :{?iters} \else \set iters 5     \endif

DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;

-- Overlap-heavy corpus: filler + the probed ASCII terms + tokens that SUPERIMPOSE
-- under the custom tokenizer (hyphenated, email, accented), so the prox tsvector
-- carries materially more lexemes per doc than simple's. Body kept as text so both
-- tokenizers see identical input.
DROP TABLE IF EXISTS tbench;
CREATE TABLE tbench(id serial PRIMARY KEY, body text, simple_tsv tsvector, prox_tsv tsvector);

-- Probe terms (alpha/beta/gamma) are chosen NOT to collide with the lexemes the
-- overlap tokens decompose into (a@b.com → a,b,b.com; café-bar → café,cafe,bar;
-- résumé → resume), so term/AND selectivity is identical across the two tokenizers.
SELECT setseed(0.42);
INSERT INTO tbench(body)
SELECT string_agg(
         CASE r WHEN 0 THEN 'alpha' WHEN 1 THEN 'beta' WHEN 2 THEN 'gamma'
                WHEN 3 THEN 'email' WHEN 4 THEN 'confidential'
                WHEN 5 THEN 'café-bar'   -- hyphen + accent superimposition
                WHEN 6 THEN 'a@b.com'    -- email split (full + local + host + label)
                WHEN 7 THEN 'résumé'     -- accent superimposition
                ELSE 'w' || r END, ' ' ORDER BY w)
FROM (SELECT d, w, floor(random() * 50)::int AS r
      FROM generate_series(1, :ndocs) d, generate_series(1, :wlen) w
      OFFSET 0) g
GROUP BY d;

UPDATE tbench SET simple_tsv = to_tsvector('simple', body),
                  prox_tsv   = proxquery_to_tsvector(body, 'prox_icu');
CREATE INDEX tbench_simple_gin ON tbench USING gin(simple_tsv);
CREATE INDEX tbench_prox_gin   ON tbench USING gin(prox_tsv);
ANALYZE tbench;

\echo ''
\echo '== corpus shape (lexeme blow-up from superimposition) =='
SELECT count(*) AS docs,
       round(avg(length(simple_tsv))) AS simple_lex,
       round(avg(length(prox_tsv)))   AS prox_lex,
       round(avg(length(prox_tsv))::numeric / nullif(avg(length(simple_tsv)), 0), 2) AS lex_ratio,
       pg_size_pretty(pg_relation_size('tbench_simple_gin')) AS simple_gin,
       pg_size_pretty(pg_relation_size('tbench_prox_gin'))   AS prox_gin
FROM tbench;

-- avg server-side ms over `iters` runs, NO warmup (the corpus is cache-warm from the build;
-- qualitative timings). Same 2-arg signature as the sibling scripts — report.sh loads them
-- all into one database, so the signatures must match to avoid an overload-ambiguity error.
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);
END $$;

-- One comparison row: simple via `@~@ proxquery('simple', q)`, prox via
-- `@~@ proxquery('prox_icu', q)` — both index-served, both with the recheck.
CREATE OR REPLACE FUNCTION tbench_row(q text, iters int)
RETURNS TABLE(simple_matches bigint, prox_matches bigint,
              simple_ms numeric, prox_ms numeric, ratio numeric)
LANGUAGE plpgsql AS $$
DECLARE sq text := format('SELECT count(*) FROM tbench WHERE simple_tsv @~@ proxquery(''simple'', %L)', q);
        pq text := format('SELECT count(*) FROM tbench WHERE prox_tsv @~@ proxquery(''prox_icu'', %L)', q);
BEGIN
  EXECUTE sq INTO simple_matches;
  EXECUTE pq INTO prox_matches;
  simple_ms := bench_ms(sq, iters);
  prox_ms   := bench_ms(pq, iters);
  ratio     := round(prox_ms / nullif(simple_ms, 0), 2);
  RETURN NEXT;
END $$;

\echo ''
\echo '== tokenizer vs simple (avg ms/query; ratio = prox/simple) =='
\echo '-- term/AND rows have IDENTICAL selectivity (clean per-op cost ratio); proximity'
\echo '-- rows match MORE on prox (superimposition packs hyphen/email/accent forms onto'
\echo '-- one position, so terms sit closer) — read prox_ms next to prox_matches there.'
CREATE TEMP TABLE tbench_results AS
SELECT t.q AS query, r.simple_matches, r.prox_matches, r.simple_ms, r.prox_ms, r.ratio
FROM (VALUES
        ('alpha'),                     -- bare term: identical selectivity → clean cost ratio
        ('alpha & beta'),              -- boolean AND: identical selectivity → clean cost ratio
        ('confidential <!~5> email'),  -- proximity, comparable selectivity
        ('alpha <~3> beta')            -- proximity: prox matches MORE (superimposition)
     ) t(q),
     LATERAL tbench_row(t.q, :iters) r;
SELECT * FROM tbench_results ORDER BY query;

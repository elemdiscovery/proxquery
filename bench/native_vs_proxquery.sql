-- proxquery vs the native-Postgres equivalent, pattern by pattern.
--
-- For each pattern: a parity check (the two forms must return the identical row
-- set) and the average server-side time of each. Run with:
--   cargo pgrx run pg17 proxquery < bench/native_vs_proxquery.sql
--
-- Takeaway shape (measured; numbers vary by corpus/machine):
--   * proxquery wins on concision everywhere.
--   * On speed it clearly wins not_within (occurrence-level; native needs unnest)
--     and big-fan-out regex (native must build a huge vocab OR-group).
--   * For within/pre the native enumeration is index-served and a touch faster —
--     proxquery's gain there is concision, not speed.
--   * For a *selective* wildcard the native vocab OR-group narrows the index
--     better than proxquery's recheck scan (it can use the resolved lexemes as
--     index keys; proxquery can't), so native wins D and even the companion F.
\set ON_ERROR_STOP on
\timing off
SET max_parallel_workers_per_gather = 0;

-- Corpus size knobs (override on the psql command line, e.g. -v ndocs=50000).
-- Bigger ndocs widens proxquery's not_within lead (the unnest baseline is linear
-- in candidates); bigger doclen amplifies the per-candidate win (more lexemes for
-- unnest to materialize). The who-wins-where shape does not change with size.
\if :{?ndocs}
\else
  \set ndocs 5000
\endif
\if :{?doclen}
\else
  \set doclen 250
\endif
\echo 'corpus:' :ndocs 'docs x ~' :doclen 'filler tokens'

DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;
DROP TABLE IF EXISTS text_record CASCADE;
CREATE TABLE text_record (id serial PRIMARY KEY, body text, text_tsv tsvector);

-- Synthetic corpus: ~250 filler tokens/doc, plus controlled injections of
-- confidential/email (near / far / no-email), of suffix words `w<NN>ology`
-- (some adjacent to a confidential, for the companion case), and of 9-digit
-- numbers (for regex).
SELECT setseed(0.42);
INSERT INTO text_record (body)
SELECT
  g.filler
  || CASE WHEN g.r1 < 0.15 THEN ' confidential email'
          WHEN g.r1 < 0.30 THEN ' confidential ' || g.filler2 || ' email'
          WHEN g.r1 < 0.40 THEN ' confidential'
          ELSE '' END
  || CASE WHEN g.r2 < 0.10 THEN ' confidential ' || g.ology  -- ology within 1 of a confidential
          WHEN g.r2 < 0.20 THEN ' ' || g.ology               -- ology far in the filler
          ELSE '' END
  || CASE WHEN g.r3 < 0.10 THEN ' ' || g.digits ELSE '' END
  || CASE WHEN g.r4 < 0.20 THEN ' alpha x beta x gamma' ELSE '' END  -- 3-term cluster
FROM (
  SELECT
    (SELECT string_agg('w' || (floor(random() * 5000))::int::text, ' ') FROM generate_series(1, :doclen)) AS filler,
    (SELECT string_agg('w' || (floor(random() * 5000))::int::text, ' ') FROM generate_series(1, :doclen)) AS filler2,
    'w' || (floor(random() * 100))::int::text || 'ology' AS ology,
    lpad((floor(random() * 1000000000))::bigint::text, 9, '0') AS digits,
    random() AS r1, random() AS r2, random() AS r3, random() AS r4
  FROM generate_series(1, :ndocs)
) g;

UPDATE text_record SET text_tsv = to_tsvector('simple', body);
CREATE INDEX text_record_tsv_gin ON text_record USING gin (text_tsv);
ANALYZE text_record;

-- The "vocabulary" the native wildcard/regex path resolves against.
DROP TABLE IF EXISTS vocab;
CREATE TABLE vocab AS SELECT word FROM ts_stat('SELECT text_tsv FROM text_record');
CREATE INDEX ON vocab (word text_pattern_ops);
ANALYZE vocab;

-- Timing harness and the native helpers (the queries a user would hand-write).
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  EXECUTE q INTO sink;
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 3);
END $$ LANGUAGE plpgsql;

-- within N either order = 2N enumerated phrase clauses
CREATE OR REPLACE FUNCTION within_q(a text, b text, n int) RETURNS tsquery AS $$
  SELECT to_tsquery('simple', string_agg(format('%s <%s> %s | %s <%s> %s', a, k, b, b, k, a), ' | '))
  FROM generate_series(1, n) k;
$$ LANGUAGE sql IMMUTABLE;

-- ordered within N (pre) = N enumerated phrase clauses
CREATE OR REPLACE FUNCTION pre_q(a text, b text, n int) RETURNS tsquery AS $$
  SELECT to_tsquery('simple', string_agg(format('%s <%s> %s', a, k, b), ' | '))
  FROM generate_series(1, n) k;
$$ LANGUAGE sql IMMUTABLE;

-- vocabulary resolution: lexemes matching a LIKE / regex pattern -> OR-group
CREATE OR REPLACE FUNCTION like_q(pat text) RETURNS tsquery AS $$
  SELECT to_tsquery('simple', string_agg(quote_literal(word), ' | ')) FROM vocab WHERE word LIKE pat;
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION regex_q(pat text) RETURNS tsquery AS $$
  SELECT to_tsquery('simple', string_agg(quote_literal(word), ' | ')) FROM vocab WHERE word ~ pat;
$$ LANGUAGE sql STABLE;

\echo ''
\echo '== corpus =='
SELECT count(*) AS docs, round(avg(length(text_tsv))) AS avg_lexemes,
       (SELECT count(*) FROM vocab) AS distinct_lexemes,
       (SELECT count(*) FROM vocab WHERE word LIKE '%ology') AS ology_lexemes,
       (SELECT count(*) FROM vocab WHERE word ~ '^[0-9]{9}$') AS digit_lexemes
FROM text_record;

-- ===========================================================================
\echo ''
\echo '== A. within: confidential within 8 of email, either order =='
\echo '-- proxquery: confidential <~8> email   |   native: 16 enumerated clauses'
WITH p AS (SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <~8> email'),
     n AS (SELECT id FROM text_record WHERE text_tsv @@ within_q('confidential','email',8))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (16-clause)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @@ within_q('confidential','email',8)$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery',
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <~8> email'$q$, 20);

-- ===========================================================================
\echo ''
\echo '== B. pre: confidential before email within 8 =='
\echo '-- proxquery: confidential <-8> email   |   native: 8 enumerated clauses'
WITH p AS (SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <-8> email'),
     n AS (SELECT id FROM text_record WHERE text_tsv @@ pre_q('confidential','email',8))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (8-clause)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @@ pre_q('confidential','email',8)$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery',
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <-8> email'$q$, 20);

-- ===========================================================================
\echo ''
\echo '== C. not_within (occurrence-level): a confidential with no email within 5 =='
\echo '-- proxquery: confidential <!~5> email   |   native: unnest EXISTS/NOT EXISTS'
WITH p AS (SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <!~5> email'),
     n AS (SELECT id FROM text_record
           WHERE text_tsv @@ to_tsquery('simple','confidential')
             AND EXISTS (SELECT 1 FROM unnest(text_tsv) wa, unnest(wa.positions) ap
                         WHERE wa.lexeme='confidential'
                           AND NOT EXISTS (SELECT 1 FROM unnest(text_tsv) wb, unnest(wb.positions) bp
                                           WHERE wb.lexeme='email' AND abs(ap-bp)<=5)))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (unnest)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential')
                     AND EXISTS (SELECT 1 FROM unnest(text_tsv) wa, unnest(wa.positions) ap
                                 WHERE wa.lexeme='confidential'
                                   AND NOT EXISTS (SELECT 1 FROM unnest(text_tsv) wb, unnest(wb.positions) bp
                                                   WHERE wb.lexeme='email' AND abs(ap-bp)<=5))$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery',
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <!~5> email'$q$, 20);

-- ===========================================================================
\echo ''
\echo '== D. suffix wildcard, STANDALONE: any *ology word =='
\echo '-- native: vocab LIKE %ology -> OR-group (index-served)'
\echo '-- proxquery: ts_prox_recheck(*ology) -- no index key, SEQ SCAN (its weak spot)'
WITH p AS (SELECT id FROM text_record WHERE ts_prox_recheck(text_tsv, '*ology')),
     n AS (SELECT id FROM text_record WHERE text_tsv @@ like_q('%ology'))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (vocab OR-group)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @@ like_q('%ology')$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery (seq scan)',
       bench_ms($q$SELECT count(*) FROM text_record WHERE ts_prox_recheck(text_tsv, '*ology')$q$, 5);

-- ===========================================================================
\echo ''
\echo '== E. single-token regex, STANDALONE: a 9-digit number =='
\echo '-- native: vocab ~ ^[0-9]{9}$ -> OR-group (index-served)'
\echo '-- proxquery: ts_prox_recheck(##[0-9]{9}##) -- SEQ SCAN'
WITH p AS (SELECT id FROM text_record WHERE ts_prox_recheck(text_tsv, '##[0-9]{9}##')),
     n AS (SELECT id FROM text_record WHERE text_tsv @@ regex_q('^[0-9]{9}$'))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (vocab OR-group)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @@ regex_q('^[0-9]{9}$')$q$, 5) AS avg_ms
UNION ALL SELECT 'proxquery (seq scan)',
       bench_ms($q$SELECT count(*) FROM text_record WHERE ts_prox_recheck(text_tsv, '##[0-9]{9}##')$q$, 5);

-- ===========================================================================
\echo ''
\echo '== F. wildcard WITH companion: confidential within 5 of any *ology word =='
\echo '-- proxquery: confidential <~5> *ology (index narrows on confidential)'
\echo '-- native: vocab OR-group + candidate AND + unnest proximity'
WITH p AS (SELECT id FROM text_record WHERE text_tsv @~@ 'confidential <~5> *ology'),
     n AS (SELECT id FROM text_record
           WHERE text_tsv @@ to_tsquery('simple','confidential') AND text_tsv @@ like_q('%ology')
             AND EXISTS (SELECT 1 FROM unnest(text_tsv) wc, unnest(wc.positions) cp,
                                     unnest(text_tsv) wo, unnest(wo.positions) op
                         WHERE wc.lexeme='confidential' AND wo.lexeme LIKE '%ology'
                           AND abs(cp-op)<=5))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (vocab + unnest)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ to_tsquery('simple','confidential') AND text_tsv @@ like_q('%ology')
                     AND EXISTS (SELECT 1 FROM unnest(text_tsv) wc, unnest(wc.positions) cp,
                                             unnest(text_tsv) wo, unnest(wo.positions) op
                                 WHERE wc.lexeme='confidential' AND wo.lexeme LIKE '%ology'
                                   AND abs(cp-op)<=5)$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery',
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <~5> *ology'$q$, 5);

-- ===========================================================================
\echo ''
\echo '== G. within at growing N: native 2N-clause (O(N) recheck) vs proxquery (flat) =='
\echo '-- native grows ~linearly with N; proxquery (two-pointer) is independent of N'
SELECT v.n AS within_n,
  (SELECT count(*) FROM text_record WHERE text_tsv @@ within_q('confidential','email',v.n)) AS matches,
  bench_ms(format($f$SELECT count(*) FROM text_record WHERE text_tsv @@ within_q('confidential','email',%s)$f$, v.n), 10) AS native_ms,
  bench_ms(format($f$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'confidential <~%s> email'$f$, v.n), 10) AS proxquery_ms
FROM (VALUES (8), (25), (50)) v(n);

-- ===========================================================================
\echo ''
\echo '== H. chained multi-distance proximity: alpha <~5> beta <~10> gamma =='
\echo '-- proxquery: one chained expression (occurrence-linked: each pair spans a'
\echo '   region, the next term must fall near it)'
\echo '-- native (loose): within(alpha,beta,5) AND within(beta,gamma,10) -- two'
\echo '   enumerations, document-level. Disagreements are 0 in this corpus (one'
\echo '   alpha/beta/gamma per cluster); in general proxquery''s chain is stricter.'
WITH p AS (SELECT id FROM text_record WHERE text_tsv @~@ 'alpha <~5> beta <~10> gamma'),
     n AS (SELECT id FROM text_record
           WHERE text_tsv @@ within_q('alpha','beta',5) AND text_tsv @@ within_q('beta','gamma',10))
SELECT (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM n) a)
     + (SELECT count(*) FROM (SELECT * FROM n EXCEPT SELECT * FROM p) b) AS disagreements;
SELECT 'native (2 enumerations)' AS impl,
       bench_ms($q$SELECT count(*) FROM text_record
                   WHERE text_tsv @@ within_q('alpha','beta',5) AND text_tsv @@ within_q('beta','gamma',10)$q$, 20) AS avg_ms
UNION ALL SELECT 'proxquery (chain)',
       bench_ms($q$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'alpha <~5> beta <~10> gamma'$q$, 20);

\echo '-- same chain at growing gaps: native pays for two enumerations (~6*gap1'
\echo '   clauses); proxquery stays flat across both operators'
SELECT v.n AS gap1, v.n * 2 AS gap2,
  bench_ms(format($f$SELECT count(*) FROM text_record WHERE text_tsv @@ within_q('alpha','beta',%s) AND text_tsv @@ within_q('beta','gamma',%s)$f$, v.n, v.n * 2), 10) AS native_ms,
  bench_ms(format($f$SELECT count(*) FROM text_record WHERE text_tsv @~@ 'alpha <~%s> beta <~%s> gamma'$f$, v.n, v.n * 2), 10) AS proxquery_ms
FROM (VALUES (5), (25), (50)) v(n);

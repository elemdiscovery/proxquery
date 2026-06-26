-- proxquery — self-test (portable, single install)
-- =================================================
-- Verifies ONE installed implementation against the known-good values in the
-- shared corpus (proxquery_cases.sql). It uses only the portable surface (the
-- `ts_prox_*` functions and the two-clause proximity form), so the SAME suite
-- passes against either:
--   * the pure-SQL port:  psql -f sql/proxquery_pure.sql
--   * the native extension installed into the same schema:
--             CREATE SCHEMA proxquery; CREATE EXTENSION proxquery SCHEMA proxquery;
-- Then:   psql -d yourdb -f sql/proxquery_pure_test.sql
--
-- Prints "all N cases passed" on success, or RAISEs with the failing cases.
-- (Cross-implementation parity — extension vs pure port on the same corpus, plus
-- fuzzing — lives in proxquery_diff_test.sql / proxquery_fuzz_test.sql, which run
-- under `cargo pgrx test` where both implementations are present at once.)

SET client_min_messages = notice;
SET search_path = proxquery, pg_catalog;

\ir proxquery_cases.sql
\ir proxquery_match_cases.sql

CREATE OR REPLACE FUNCTION _prox_selftest_eval(expr text) RETURNS text
    LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    EXECUTE 'SELECT (' || expr || ')::text' INTO r;
    RETURN coalesce(r, '<null>');
EXCEPTION WHEN OTHERS THEN RETURN 'ERR';
END $f$;

DO $$
DECLARE r record; fails int := 0; n int := 0;
BEGIN
    FOR r IN SELECT label, _prox_selftest_eval(expr) AS got, expected FROM _prox_cases ORDER BY label LOOP
        n := n + 1;
        IF r.got IS DISTINCT FROM r.expected THEN
            RAISE WARNING 'FAIL %  got=[%]  expected=[%]', r.label, r.got, r.expected;
            fails := fails + 1;
        END IF;
    END LOOP;
    FOR r IN SELECT label,
                    _prox_selftest_eval(format('ts_prox_match(to_tsvector(%L, %L), %L)', 'simple', doc, query)) AS got,
                    expected
             FROM _prox_match ORDER BY label LOOP
        n := n + 1;
        IF r.got IS DISTINCT FROM r.expected THEN
            RAISE WARNING 'FAIL match:%  got=[%]  expected=[%]', r.label, r.got, r.expected;
            fails := fails + 1;
        END IF;
    END LOOP;
    IF fails > 0 THEN
        RAISE EXCEPTION 'proxquery self-test: % of % case(s) FAILED', fails, n;
    END IF;
    RAISE NOTICE 'proxquery self-test: all % cases passed', n;
END $$;

DROP FUNCTION _prox_selftest_eval(text);

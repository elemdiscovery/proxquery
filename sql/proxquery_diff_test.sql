-- proxquery — differential parity test (extension vs pure port)
-- =============================================================
-- Runs every case in the shared corpus (_prox_cases, from proxquery_cases.sql)
-- against BOTH implementations in one session and asserts they agree with each
-- other and with the expected value:
--     ext == expected  AND  pure == expected  AND  ext == pure
-- so the two implementations cannot silently drift. Unlike the golden self-test
-- (proxquery_pure_test.sql), there is no single oracle — each implementation is
-- also the other's oracle.
--
-- Requires, in the same session:
--   * the shared corpus loaded   (\i proxquery_cases.sql)
--   * the native extension       (CREATE EXTENSION proxquery — any schema)
--   * the pure-SQL port          (\i proxquery_pure.sql — schema `proxquery`)

SET client_min_messages = notice;

-- Evaluate `expr`'s ::text result with `sch` first on the search_path, so an
-- unqualified `ts_prox_*` call resolves to that implementation. Any error
-- (including a deliberate one) collapses to 'ERR', matching the golden runner.
CREATE OR REPLACE FUNCTION pg_temp._prox_eval(sch text, expr text) RETURNS text
    LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    PERFORM set_config('search_path', quote_ident(sch) || ', pg_catalog', true);
    EXECUTE 'SELECT (' || expr || ')::text' INTO r;
    RETURN coalesce(r, '<null>');
EXCEPTION WHEN OTHERS THEN RETURN 'ERR';
END $f$;

DO $$
DECLARE
    r record;
    mr record;
    mexpr text;
    pexpr text;
    ext_sch text;
    got_ext text;
    got_pure text;
    got_probe_ext text;
    got_probe_pure text;
    fails int := 0;
    n int := 0;
BEGIN
    SELECT nsp.nspname INTO ext_sch
    FROM pg_extension e JOIN pg_namespace nsp ON nsp.oid = e.extnamespace
    WHERE e.extname = 'proxquery';
    IF ext_sch IS NULL THEN
        RAISE EXCEPTION 'differential test needs the native extension installed (CREATE EXTENSION proxquery)';
    END IF;
    IF ext_sch = 'proxquery' THEN
        RAISE EXCEPTION 'extension shares schema `proxquery` with the pure port; install it elsewhere';
    END IF;

    FOR r IN SELECT label, expr, expected FROM pg_temp._prox_cases ORDER BY label LOOP
        n := n + 1;
        got_ext  := pg_temp._prox_eval(ext_sch, r.expr);
        got_pure := pg_temp._prox_eval('proxquery', r.expr);
        IF got_ext IS DISTINCT FROM r.expected
           OR got_pure IS DISTINCT FROM r.expected
           OR got_ext IS DISTINCT FROM got_pure THEN
            RAISE WARNING 'FAIL %  ext=[%] pure=[%] expected=[%]', r.label, got_ext, got_pure, r.expected;
            fails := fails + 1;
        END IF;
    END LOOP;

    -- Structured match cases (proxquery_match_cases.sql): derive the recheck expr
    -- from the (doc, query) tuple; `format` quotes both robustly.
    FOR mr IN SELECT label, doc, query, expected FROM pg_temp._prox_match ORDER BY label LOOP
        n := n + 1;
        mexpr := format('ts_prox_match(to_tsvector(%L, %L), %L)', 'simple', mr.doc, mr.query);
        got_ext  := pg_temp._prox_eval(ext_sch, mexpr);
        got_pure := pg_temp._prox_eval('proxquery', mexpr);
        IF got_ext IS DISTINCT FROM mr.expected
           OR got_pure IS DISTINCT FROM mr.expected
           OR got_ext IS DISTINCT FROM got_pure THEN
            RAISE WARNING 'FAIL match:%  ext=[%] pure=[%] expected=[%]', mr.label, got_ext, got_pure, mr.expected;
            fails := fails + 1;
        END IF;
    END LOOP;

    -- Config-aware cases (proxquery_config_cases.sql, if loaded): the 3-arg recheck
    -- under each row's config, on both implementations, plus the soundness invariant —
    -- a `true` recheck whose query carries an index key must be selected by the probe
    -- too (recheck ⟹ probe). A bare leading-wildcard glob has no positive key, so
    -- `ts_prox_query` raises ('needs a companion term'); that collapses the probe to
    -- 'ERR' and soundness is skipped for that row (the index isn't used there anyway).
    IF to_regclass('pg_temp._prox_cfg_match') IS NOT NULL THEN
        FOR mr IN SELECT label, cfg, doc, query, expected FROM pg_temp._prox_cfg_match ORDER BY label LOOP
            n := n + 1;
            mexpr := format('ts_prox_match(to_tsvector(%L::regconfig, %L), %L, %L::regconfig)',
                            mr.cfg, mr.doc, mr.query, mr.cfg);
            got_ext  := pg_temp._prox_eval(ext_sch, mexpr);
            got_pure := pg_temp._prox_eval('proxquery', mexpr);
            IF got_ext IS DISTINCT FROM mr.expected
               OR got_pure IS DISTINCT FROM mr.expected
               OR got_ext IS DISTINCT FROM got_pure THEN
                RAISE WARNING 'FAIL cfg:%  ext=[%] pure=[%] expected=[%]', mr.label, got_ext, got_pure, mr.expected;
                fails := fails + 1;
            END IF;
            IF mr.expected = 'true' THEN
                pexpr := format('(to_tsvector(%L::regconfig, %L) @@ ts_prox_query(%L, %L::regconfig))',
                                mr.cfg, mr.doc, mr.query, mr.cfg);
                got_probe_ext  := pg_temp._prox_eval(ext_sch, pexpr);
                got_probe_pure := pg_temp._prox_eval('proxquery', pexpr);
                IF got_probe_ext = 'false' OR got_probe_pure = 'false' THEN
                    RAISE WARNING 'FAIL cfg-soundness:%  recheck=true but probe ext=[%] pure=[%] (recheck ⟹ probe violated)',
                                  mr.label, got_probe_ext, got_probe_pure;
                    fails := fails + 1;
                END IF;
            END IF;
        END LOOP;
    END IF;

    IF fails > 0 THEN
        RAISE EXCEPTION 'proxquery differential test: % of % case(s) FAILED (extension/pure/expected disagree)', fails, n;
    END IF;
    RAISE NOTICE 'proxquery differential test: all % cases agree (extension == pure == expected)', n;
END $$;

DROP FUNCTION pg_temp._prox_eval(text, text);

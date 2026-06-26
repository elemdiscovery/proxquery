-- proxquery — differential fuzz test (extension vs pure port)
-- ==========================================================
-- Generates random documents and random DSL queries (seeded, so a failure is
-- reproducible) and, for each pair, checks two things in one session:
--
--   A. recheck parity     — ext ts_prox_match == pure ts_prox_match
--   B. superset invariant — for EACH implementation, a recheck match implies the
--      index skeleton selects it: NOT (match AND NOT (doc @@ ts_prox_query(q))).
--      When ts_prox_query has no index key it raises (→ 'ERR'); that is the
--      seq-scan path, where the invariant holds trivially, so it is exempt.
--
-- Requires both implementations in the session (native extension + pure-SQL port
-- in schema `proxquery`). Vocabulary is tiny so docs and queries overlap and real
-- matches (not just empty results) are exercised.

SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION pg_temp._prox_eval(sch text, expr text) RETURNS text
    LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    PERFORM set_config('search_path', quote_ident(sch) || ', pg_catalog', true);
    EXECUTE 'SELECT (' || expr || ')::text' INTO r;
    RETURN coalesce(r, '<null>');
EXCEPTION WHEN OTHERS THEN RETURN 'ERR';
END $f$;

-- A random document: 3..10 tokens drawn from a 5-symbol vocabulary.
CREATE OR REPLACE FUNCTION pg_temp._fz_doc() RETURNS text LANGUAGE plpgsql AS $f$
DECLARE k int := 3 + floor(random() * 8)::int; out text := '';
BEGIN
    FOR i IN 1..k LOOP
        out := out || (ARRAY['a','b','c','d','e'])[1 + floor(random() * 5)::int] || ' ';
    END LOOP;
    RETURN trim(out);
END $f$;

-- A random positional leaf: term / prefix / literal / phrase / regex / suffix glob.
-- All forms match a single-character token, so leaves are meaningful, not inert.
CREATE OR REPLACE FUNCTION pg_temp._fz_leaf() RETURNS text LANGUAGE plpgsql AS $f$
DECLARE tok text := (ARRAY['a','b','c','d','e'])[1 + floor(random() * 5)::int];
        tok2 text := (ARRAY['a','b','c','d','e'])[1 + floor(random() * 5)::int];
BEGIN
    RETURN CASE floor(random() * 6)::int
        WHEN 0 THEN tok
        WHEN 1 THEN tok || '*'
        WHEN 2 THEN '''' || tok || ''''
        WHEN 3 THEN '"' || tok || ' ' || tok2 || '"'
        WHEN 4 THEN '##' || tok || '##'
        ELSE '*' || tok
    END;
END $f$;

-- A random query tree, depth-limited. Mixes proximity, boolean and negation so
-- normalization (lifting & / ! out of proximity operands) is exercised too.
CREATE OR REPLACE FUNCTION pg_temp._fz_query(depth int) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE ops text[] := ARRAY['<~1>','<~2>','<-1>','<-2>','<!~1>','<!~2>','<2>','<->'];
        op text;
BEGIN
    IF depth <= 0 OR random() < 0.35 THEN
        RETURN pg_temp._fz_leaf();
    END IF;
    CASE floor(random() * 5)::int
        WHEN 0 THEN
            op := ops[1 + floor(random() * array_length(ops, 1))::int];
            RETURN '(' || pg_temp._fz_query(depth - 1) || ' ' || op || ' ' || pg_temp._fz_query(depth - 1) || ')';
        WHEN 1 THEN
            RETURN '(' || pg_temp._fz_query(depth - 1) || ' & ' || pg_temp._fz_query(depth - 1) || ')';
        WHEN 2 THEN
            RETURN '(' || pg_temp._fz_query(depth - 1) || ' | ' || pg_temp._fz_query(depth - 1) || ')';
        WHEN 3 THEN
            RETURN '!' || pg_temp._fz_query(depth - 1);
        ELSE
            RETURN '(' || pg_temp._fz_query(depth - 1) || ')';
    END CASE;
END $f$;

DO $$
DECLARE
    ext_sch text;
    doc text; q text;
    m_ext text; m_pure text;        -- recheck results
    sel_ext text; sel_pure text;    -- skeleton selection results
    match_expr text; sel_expr text;
    fails int := 0; i int;
    N constant int := 400;
BEGIN
    SELECT nsp.nspname INTO ext_sch
    FROM pg_extension e JOIN pg_namespace nsp ON nsp.oid = e.extnamespace
    WHERE e.extname = 'proxquery';
    IF ext_sch IS NULL THEN
        RAISE EXCEPTION 'fuzz test needs the native extension installed (CREATE EXTENSION proxquery)';
    END IF;

    PERFORM setseed(0.42424242);  -- reproducible run

    FOR i IN 1..N LOOP
        doc := pg_temp._fz_doc();
        q   := pg_temp._fz_query(3);
        match_expr := format('ts_prox_match(to_tsvector(%L, %L), %L)', 'simple', doc, q);
        sel_expr   := format('to_tsvector(%L, %L) @@ ts_prox_query(%L)', 'simple', doc, q);

        m_ext  := pg_temp._prox_eval(ext_sch, match_expr);
        m_pure := pg_temp._prox_eval('proxquery', match_expr);
        sel_ext  := pg_temp._prox_eval(ext_sch, sel_expr);
        sel_pure := pg_temp._prox_eval('proxquery', sel_expr);

        -- A. the two implementations' recheck must agree.
        IF m_ext IS DISTINCT FROM m_pure THEN
            RAISE WARNING 'RECHECK DIVERGENCE  doc=[%]  q=[%]  ext=[%] pure=[%]', doc, q, m_ext, m_pure;
            fails := fails + 1;
            CONTINUE;
        END IF;

        -- B. recheck match ⇒ skeleton selects it (unless the skeleton has no key,
        --    i.e. raised 'ERR' → seq-scan path, exempt). Checked per implementation.
        IF m_ext = 'true' AND sel_ext = 'false' THEN
            RAISE WARNING 'SUPERSET VIOLATION (ext)  doc=[%]  q=[%]', doc, q;
            fails := fails + 1;
        ELSIF m_pure = 'true' AND sel_pure = 'false' THEN
            RAISE WARNING 'SUPERSET VIOLATION (pure)  doc=[%]  q=[%]', doc, q;
            fails := fails + 1;
        END IF;
    END LOOP;

    IF fails > 0 THEN
        RAISE EXCEPTION 'proxquery fuzz: % of % generated case(s) DIVERGED', fails, N;
    END IF;
    RAISE NOTICE 'proxquery fuzz: all % generated cases agree (extension == pure port)', N;
END $$;

DROP FUNCTION pg_temp._fz_query(int);
DROP FUNCTION pg_temp._fz_leaf();
DROP FUNCTION pg_temp._fz_doc();
DROP FUNCTION pg_temp._prox_eval(text, text);

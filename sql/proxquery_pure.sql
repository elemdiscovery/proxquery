-- proxquery — pure-SQL implementation
-- ====================================
--
-- A drop-in, extension-free port of the proxquery Rust extension. Every public
-- function keeps the same name and signature as the compiled extension, so an
-- environment can run this migration on a managed/cloud Postgres (Cloud SQL,
-- RDS, Neon, …) where loading a custom `.so` isn't practical, and later migrate
-- to the native extension transparently.
--
-- Everything is installed into a dedicated `proxquery` schema (helpers and
-- public functions alike), so it never pollutes `public` and tears down with a
-- single `DROP SCHEMA proxquery CASCADE`. The native extension is relocatable,
-- so it installs into the same schema for a transparent migration:
--     CREATE EXTENSION proxquery SCHEMA proxquery;
-- Call the functions schema-qualified (`proxquery.ts_prox_recheck(…)`) or add the
-- schema to your search_path (`SET search_path = public, proxquery;`). Each
-- public function pins its own search_path, so it resolves correctly either way.
--
-- What is the same: the DSL, the skeleton tsquery (`ts_prox_query`), the
-- positional recheck (`ts_prox_recheck`), and the positional predicate functions —
-- all produce identical results to the Rust extension.
--
-- What differs:
--   * No `@~@` operator. The native extension's single indexable operator needs
--     a C planner support function (impossible in SQL). Rather than ship a
--     look-alike `@~@` that silently seq-scans, this port omits it entirely, so
--     proximity queries are written in the form that is actually index-served —
--     the two clauses the support function would otherwise inject:
--         WHERE tsv @@ proxquery.ts_prox_query(q)   -- GIN index selects
--           AND proxquery.ts_prox_recheck(tsv, q)       -- positional recheck
--     or, equivalently, the one inlinable call `proxquery.ts_prox_search(tsv, q)`,
--     which the planner folds back open to those clauses (see `ts_prox_search`).
--     (The native extension keeps `@~@`; after migrating you may switch to it.)
--   * Performance: positions are read with `unnest(tsvector)` (O(all lexemes)
--     per call) instead of the extension's O(log L) binary search, and the
--     query AST is re-parsed per row. Same answers, slower on large corpora —
--     EXCEPT bounded proximity (within/pre/phrase over plain terms, distance ≤ 32),
--     where the recheck is skipped: `ts_prox_recheck` lowers the query to a native
--     `tsquery` matched by Postgres's own C phrase engine (the same rewrite the
--     extension's `@~@` support function performs). This happens automatically in
--     the standard two-clause form — no special syntax — for literal or custom-plan
--     queries; see `ts_prox_recheck` / `ts_prox_query_native` for the parameter caveat.
--
-- Text search configuration: `simple` (literal, lowercased), matching the
-- extension. Internal helpers are prefixed `_prox_`.

CREATE SCHEMA IF NOT EXISTS proxquery;
SET search_path = proxquery, pg_catalog;
SET check_function_bodies = off;

-- ===========================================================================
-- Small utilities
-- ===========================================================================

-- ASCII-only lowercasing, matching the Rust lexer's `to_ascii_lowercase`
-- (Postgres `lower()` would also fold non-ASCII; the stored `simple` lexemes and
-- the query terms must agree, and the extension folds ASCII only on the query side).
CREATE OR REPLACE FUNCTION _prox_alower(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT translate($1, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz') $fn$;

CREATE OR REPLACE FUNCTION _prox_quote_lexeme(lex text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT '''' || replace($1, '''', '''''') || '''' $fn$;

-- The leading literal run of a glob — characters before the first `*` or `?`.
CREATE OR REPLACE FUNCTION _prox_glob_prefix(glob text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT coalesce(substring($1 from '^[^*?]*'), '') $fn$;

-- Convert a `*`/`?` glob to a LIKE pattern (`*`→`%`, `?`→`_`), escaping the LIKE
-- metacharacters that may appear in the glob's literal parts first.
CREATE OR REPLACE FUNCTION _prox_glob_to_like(glob text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$
    SELECT replace(replace(
             replace(replace(replace($1, '\', '\\'), '%', '\%'), '_', '\_'),
           '*', '%'), '?', '_')
$fn$;

CREATE OR REPLACE FUNCTION _prox_is_word_char(c text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT $1 !~ '\s' AND position($1 in '()&|!<>,"''#') = 0 $fn$;

-- Parse a distance: non-empty digits, clamped to [0, 16383] (matches the Rust
-- `parse_distance` / MAX_DISTANCE clamp, including overflow → 16383). `0` is kept
-- (native tsquery `<0>` = same position), not raised to 1.
CREATE OR REPLACE FUNCTION _prox_parse_distance(digits text) RETURNS int
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    IF digits IS NULL OR digits = '' OR digits !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'expected a distance, got `%`', coalesce(digits, '');
    END IF;
    IF length(digits) > 5 THEN
        RETURN 16383;
    END IF;
    RETURN least(greatest(digits::int, 0), 16383);
END
$fn$;

-- ===========================================================================
-- Position accessors  (the building block: read a lexeme's sorted positions)
-- ===========================================================================

-- Sorted positions of `lexeme` (exact, byte-equal match); empty if absent or
-- position-less. Equivalent to the extension's binary-search accessor.
CREATE OR REPLACE FUNCTION ts_prox_positions(v tsvector, needle text) RETURNS int[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
    SELECT coalesce(
        (SELECT u.positions::int[]
         FROM unnest(v) u
         WHERE u.lexeme = needle COLLATE "C"
         LIMIT 1),
        '{}'::int[])
$fn$;

-- Merged, sorted, unique positions over every lexeme beginning with `prefix`
-- (the `appl*` primitive). Empty if nothing matches.
CREATE OR REPLACE FUNCTION ts_prox_positions_prefix(v tsvector, prefix text) RETURNS int[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
    SELECT coalesce(
        (SELECT array_agg(DISTINCT p ORDER BY p)
         FROM (SELECT unnest(u.positions)::int AS p
               FROM unnest(v) u
               WHERE starts_with(u.lexeme, prefix)) s),
        '{}'::int[])
$fn$;

-- Positions of every lexeme matching a `*`/`?` glob (with a leading literal
-- `pfx` used to narrow the scan, matching the extension's prefix fast path).
CREATE OR REPLACE FUNCTION _prox_pos_glob(v tsvector, pfx text, glob text) RETURNS int[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$
    SELECT coalesce(
        (SELECT array_agg(DISTINCT p ORDER BY p)
         FROM (SELECT unnest(u.positions)::int AS p
               FROM unnest(v) u
               WHERE (pfx = '' OR starts_with(u.lexeme, pfx))
                 AND u.lexeme LIKE _prox_glob_to_like(glob)) s),
        '{}'::int[])
$fn$;

-- Positions of every lexeme matching the whole-lexeme-anchored regex.
CREATE OR REPLACE FUNCTION _prox_pos_regex(v tsvector, pattern text) RETURNS int[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$
    SELECT coalesce(
        (SELECT array_agg(DISTINCT p ORDER BY p)
         FROM (SELECT unnest(u.positions)::int AS p
               FROM unnest(v) u
               WHERE (u.lexeme COLLATE "C") ~ ('^(?:' || pattern || ')$')) s),
        '{}'::int[])
$fn$;

-- ===========================================================================
-- Array predicates  (the positional semantics over sorted int[] position lists)
-- ===========================================================================

-- within: some a within n of some b, either order  (∃ |aᵢ − bⱼ| ≤ n).
CREATE OR REPLACE FUNCTION _prox_arr_within(a int[], b int[], n int) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT EXISTS (SELECT 1 FROM unnest(a) x, unnest(b) y WHERE abs(x - y) <= n) $fn$;

-- pre: some a strictly before some b within n  (∃ 0 < bⱼ − aᵢ ≤ n).
CREATE OR REPLACE FUNCTION _prox_arr_pre(a int[], b int[], n int) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT EXISTS (SELECT 1 FROM unnest(a) x, unnest(b) y WHERE y - x > 0 AND y - x <= n) $fn$;

-- not_within: occurrence-level — some a has no qualifying b (true if b absent).
-- ordered ⇒ the forbidden b lies after a, within n; else either side.
CREATE OR REPLACE FUNCTION _prox_arr_not_within(a int[], b int[], n int, ordered boolean) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    IF coalesce(array_length(a, 1), 0) = 0 THEN RETURN false; END IF;
    IF coalesce(array_length(b, 1), 0) = 0 THEN RETURN true; END IF;
    -- Saturation guard: the avoid term reached the position cap (16383), so its
    -- tail collapsed and "near b" can't be trusted. Fail open (matches the Rust
    -- `not_within`).
    IF (SELECT max(y) FROM unnest(b) AS y) = 16383 THEN RETURN true; END IF;
    RETURN EXISTS (
        SELECT 1 FROM unnest(a) x
        WHERE NOT EXISTS (
            SELECT 1 FROM unnest(b) y
            WHERE CASE WHEN ordered THEN (y > x AND y - x <= n)
                       ELSE abs(x - y) <= n END));
END
$fn$;

-- The region a chained within/pre operand composes against: the union of the
-- spans [least(aᵢ,bⱼ) .. greatest(aᵢ,bⱼ)] of every satisfying pair, densified to a
-- sorted position set — so a later operand can attach to a term that falls between
-- a matched pair. Per-pair union (not one global min/max), so two separate matches
-- don't bridge the gap between them. One covering interval per a-position (its
-- qualifying partners are contiguous), then generate_series densifies the union.
CREATE OR REPLACE FUNCTION _prox_within_span(a int[], b int[], n int, ordered boolean) RETURNS int[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$
    SELECT coalesce(array_agg(DISTINCT p ORDER BY p), '{}'::int[])
    FROM (
        SELECT generate_series(lo, hi) AS p
        FROM (
            SELECT least(x, min(y)) AS lo, greatest(x, max(y)) AS hi
            FROM unnest(a) AS x
            JOIN unnest(b) AS y
              ON CASE WHEN ordered THEN (y > x AND y - x <= n)
                      ELSE abs(x - y) <= n END
            GROUP BY x
        ) spans
    ) d
$fn$;

-- ===========================================================================
-- Public positional predicate functions
-- ===========================================================================

CREATE OR REPLACE FUNCTION ts_prox_within(v tsvector, a text, b text, n int) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT _prox_arr_within(ts_prox_positions(v, a), ts_prox_positions(v, b), n) $fn$;

CREATE OR REPLACE FUNCTION ts_prox_pre(v tsvector, a text, b text, n int) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT _prox_arr_pre(ts_prox_positions(v, a), ts_prox_positions(v, b), n) $fn$;

CREATE OR REPLACE FUNCTION ts_prox_not_within(v tsvector, a text, b text, n int) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT _prox_arr_not_within(ts_prox_positions(v, a), ts_prox_positions(v, b), n, false) $fn$;

-- Same-occurrence chain over `terms`, each consecutive pair within its gaps[i].
-- gaps must have exactly one fewer element than terms.
CREATE OR REPLACE FUNCTION ts_prox_chain(v tsvector, terms text[], gaps int[]) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    nterms int := coalesce(array_length(terms, 1), 0);
    ngaps  int := coalesce(array_length(gaps, 1), 0);
    reach  int[];
    cur    int[];
    g      int;
    i      int;
BEGIN
    IF nterms = 0 OR ngaps <> nterms - 1 THEN
        RAISE EXCEPTION 'ts_prox_chain: gaps length must be one less than terms length (got % terms, % gaps)',
            nterms, ngaps;
    END IF;
    reach := ts_prox_positions(v, terms[1]);
    IF coalesce(array_length(reach, 1), 0) = 0 THEN RETURN false; END IF;
    FOR i IN 2 .. nterms LOOP
        g := gaps[i - 1];
        cur := ts_prox_positions(v, terms[i]);
        IF coalesce(array_length(cur, 1), 0) = 0 THEN RETURN false; END IF;
        reach := ARRAY(
            SELECT c FROM unnest(cur) c
            WHERE EXISTS (SELECT 1 FROM unnest(reach) r WHERE abs(r - c) <= g)
            ORDER BY c);
        IF coalesce(array_length(reach, 1), 0) = 0 THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$fn$;

-- ===========================================================================
-- Lexer  (query text -> jsonb array of tokens)
-- ===========================================================================
--
-- Token kinds: lparen rparen and or not | op_phrase{n} op_pre{n} op_within{n}
-- op_notwithin{n,ord} | leaf{node}.  A "leaf" carries a finished AST node
-- (term/prefix/glob/regex/phrase) so the parser's atom cases collapse to one.
--
-- AST node shapes (jsonb):
--   {t:term,   v}                         {t:prefix, v}
--   {t:glob,   g, p}                      {t:regex,  v}
--   {t:phrase, atoms:[atom...], gaps:[]}  (atom = a term/prefix/glob node)
--   {t:and, c:[]}  {t:or, c:[]}  {t:not, x}
--   {t:within,    a, b, n, ord}           {t:notwithin, a, b, n, ord}

-- Classify a standalone word, resolving `*`/`?` wildcards. Yields a
-- term/prefix/glob node (also used as a phrase atom).
CREATE OR REPLACE FUNCTION _prox_word_to_node(word text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    lower text := _prox_alower(word);
    stem  text;
    body  text;
BEGIN
    IF right(lower, 2) = ':*' THEN
        stem := left(lower, length(lower) - 2);
        IF stem <> '' AND stem !~ '[*?]' THEN
            RETURN jsonb_build_object('t', 'prefix', 'v', stem);
        END IF;
    END IF;
    IF lower !~ '[*?]' THEN
        RETURN jsonb_build_object('t', 'term', 'v', lower);
    END IF;
    IF lower = '*' THEN
        RAISE EXCEPTION 'a bare `*` matches everything; give it a literal part';
    END IF;
    body := left(lower, length(lower) - 1);
    IF right(lower, 1) = '*' AND body !~ '[*?]' THEN
        RETURN jsonb_build_object('t', 'prefix', 'v', body);
    END IF;
    RETURN jsonb_build_object('t', 'glob', 'g', lower, 'p', _prox_glob_prefix(lower));
END
$fn$;

-- Collapse a quoted phrase's atoms into a node: single atom → that node; else a
-- phrase node with all-1 gaps (adjacency).
CREATE OR REPLACE FUNCTION _prox_phrase_node(atoms jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    gaps jsonb := '[]'::jsonb;
    k    int;
BEGIN
    IF jsonb_array_length(atoms) = 1 THEN
        RETURN atoms -> 0;
    END IF;
    FOR k IN 1 .. jsonb_array_length(atoms) - 1 LOOP
        gaps := gaps || jsonb_build_array(1);
    END LOOP;
    RETURN jsonb_build_object('t', 'phrase', 'atoms', atoms, 'gaps', gaps);
END
$fn$;

-- Interpret a `<…>` bracket body into a single operator token.
CREATE OR REPLACE FUNCTION _prox_bracket_op(content text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    IF content = '-' THEN
        RETURN jsonb_build_object('k', 'op_phrase', 'n', 1);
    ELSIF left(content, 2) = '!~' THEN
        RETURN jsonb_build_object('k', 'op_notwithin', 'n', _prox_parse_distance(substr(content, 3)), 'ord', false);
    ELSIF left(content, 2) = '!-' THEN
        RETURN jsonb_build_object('k', 'op_notwithin', 'n', _prox_parse_distance(substr(content, 3)), 'ord', true);
    ELSIF left(content, 1) = '!' THEN
        RAISE EXCEPTION 'not-within needs a direction: `<!~N>` (either order) or `<!-N>` (ordered)';
    ELSIF left(content, 1) = '~' THEN
        RETURN jsonb_build_object('k', 'op_within', 'n', _prox_parse_distance(substr(content, 2)));
    ELSIF left(content, 1) = '-' THEN
        RETURN jsonb_build_object('k', 'op_pre', 'n', _prox_parse_distance(substr(content, 2)));
    ELSE
        RETURN jsonb_build_object('k', 'op_phrase', 'n', _prox_parse_distance(content));
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_lex(input text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    chars text[] := regexp_split_to_array(input, '');
    n int := coalesce(array_length(chars, 1), 0);
    i int := 1;
    j int;
    p0 int;
    startp int;
    c text;
    content text;
    phrase text;
    atoms jsonb;
    lexeme text;
    word text;
    toks jsonb := '[]'::jsonb;
BEGIN
    WHILE i <= n LOOP
        c := chars[i];
        IF c ~ '\s' THEN
            i := i + 1;
        ELSIF c = '(' THEN toks := toks || jsonb_build_array(jsonb_build_object('k', 'lparen')); i := i + 1;
        ELSIF c = ')' THEN toks := toks || jsonb_build_array(jsonb_build_object('k', 'rparen')); i := i + 1;
        ELSIF c = '&' THEN toks := toks || jsonb_build_array(jsonb_build_object('k', 'and')); i := i + 1;
        ELSIF c = '|' THEN toks := toks || jsonb_build_array(jsonb_build_object('k', 'or')); i := i + 1;
        ELSIF c = '!' THEN toks := toks || jsonb_build_array(jsonb_build_object('k', 'not')); i := i + 1;
        ELSIF c = '<' THEN
            j := i + 1;
            WHILE j <= n AND chars[j] <> '>' LOOP j := j + 1; END LOOP;
            IF j > n THEN RAISE EXCEPTION 'unterminated `<…>` operator'; END IF;
            content := array_to_string(chars[i + 1 : j - 1], '');
            i := j + 1;
            toks := toks || jsonb_build_array(_prox_bracket_op(content));
        ELSIF c = '"' THEN
            j := i + 1;
            WHILE j <= n AND chars[j] <> '"' LOOP j := j + 1; END LOOP;
            IF j > n THEN RAISE EXCEPTION 'unterminated quoted phrase'; END IF;
            phrase := array_to_string(chars[i + 1 : j - 1], '');
            i := j + 1;
            SELECT coalesce(jsonb_agg(_prox_word_to_node(w) ORDER BY ord), '[]'::jsonb)
              INTO atoms
              FROM (SELECT w, ord FROM unnest(regexp_split_to_array(phrase, '\s+'))
                      WITH ORDINALITY AS t(w, ord) WHERE w <> '') q;
            IF jsonb_array_length(atoms) = 0 THEN RAISE EXCEPTION 'empty quoted phrase'; END IF;
            toks := toks || jsonb_build_array(jsonb_build_object('k', 'leaf', 'node', _prox_phrase_node(atoms)));
        ELSIF c = '''' THEN
            j := i + 1;
            lexeme := '';
            LOOP
                IF j > n THEN RAISE EXCEPTION 'unterminated quoted term'; END IF;
                IF chars[j] = '''' AND j < n AND chars[j + 1] = '''' THEN
                    lexeme := lexeme || ''''; j := j + 2;
                ELSIF chars[j] = '''' THEN
                    j := j + 1; EXIT;
                ELSE
                    lexeme := lexeme || chars[j]; j := j + 1;
                END IF;
            END LOOP;
            IF lexeme = '' THEN RAISE EXCEPTION 'empty quoted term'; END IF;
            i := j;
            toks := toks || jsonb_build_array(jsonb_build_object(
                'k', 'leaf', 'node', jsonb_build_object('t', 'term', 'v', _prox_alower(lexeme))));
        ELSIF c = '#' THEN
            IF i >= n OR chars[i + 1] <> '#' THEN
                RAISE EXCEPTION 'a single `#` is not valid; use `##regex##` or quote it';
            END IF;
            p0 := i + 2;
            j := p0;
            WHILE j + 1 <= n AND NOT (chars[j] = '#' AND chars[j + 1] = '#') LOOP j := j + 1; END LOOP;
            IF j + 1 > n OR NOT (chars[j] = '#' AND chars[j + 1] = '#') THEN
                RAISE EXCEPTION 'unterminated `##regex##`';
            END IF;
            i := j + 2;
            toks := toks || jsonb_build_array(jsonb_build_object(
                'k', 'leaf', 'node', jsonb_build_object('t', 'regex', 'v', array_to_string(chars[p0 : j - 1], ''))));
        ELSE
            startp := i;
            WHILE i <= n AND _prox_is_word_char(chars[i]) LOOP i := i + 1; END LOOP;
            IF i = startp THEN RAISE EXCEPTION 'unexpected character `%`', c; END IF;
            word := array_to_string(chars[startp : i - 1], '');
            toks := toks || jsonb_build_array(jsonb_build_object('k', 'leaf', 'node', _prox_word_to_node(word)));
        END IF;
    END LOOP;
    RETURN toks;
END
$fn$;

-- ===========================================================================
-- Parser  (recursive descent; precedence | < & < proximity < !)
-- ===========================================================================
-- Each parse function returns {node, pos}.

CREATE OR REPLACE FUNCTION _prox_as_atom(node jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT CASE WHEN node ->> 't' IN ('term', 'prefix', 'glob') THEN node ELSE NULL END $fn$;

CREATE OR REPLACE FUNCTION _prox_extend_phrase(cur jsonb, rhs jsonb, gap int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    rhs_atom jsonb := _prox_as_atom(rhs);
    left_atom jsonb;
BEGIN
    IF rhs_atom IS NULL THEN
        RAISE EXCEPTION 'phrase/distance operator (`<->`, `<N>`) needs term operands';
    END IF;
    IF cur ->> 't' = 'phrase' THEN
        RETURN jsonb_build_object('t', 'phrase',
            'atoms', (cur -> 'atoms') || jsonb_build_array(rhs_atom),
            'gaps',  (cur -> 'gaps')  || jsonb_build_array(gap));
    END IF;
    left_atom := _prox_as_atom(cur);
    IF left_atom IS NULL THEN
        RAISE EXCEPTION 'phrase/distance operator (`<->`, `<N>`) needs term operands';
    END IF;
    RETURN jsonb_build_object('t', 'phrase',
        'atoms', jsonb_build_array(left_atom, rhs_atom),
        'gaps',  jsonb_build_array(gap));
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_build_prox(first jsonb, ops jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    cur jsonb := first;
    o jsonb;
    opk text;
    rhs jsonb;
    nn int;
    i int;
BEGIN
    FOR i IN 0 .. jsonb_array_length(ops) - 1 LOOP
        o := ops -> i;
        opk := o ->> 'op';
        rhs := o -> 'rhs';
        nn := (o ->> 'n')::int;
        IF opk = 'phrase' THEN
            cur := _prox_extend_phrase(cur, rhs, nn);
        ELSIF opk = 'pre' THEN
            cur := jsonb_build_object('t', 'within', 'a', cur, 'b', rhs, 'n', nn, 'ord', true);
        ELSIF opk = 'within' THEN
            cur := jsonb_build_object('t', 'within', 'a', cur, 'b', rhs, 'n', nn, 'ord', false);
        ELSIF opk = 'notwithin' THEN
            cur := jsonb_build_object('t', 'notwithin', 'a', cur, 'b', rhs, 'n', nn, 'ord', (o ->> 'ord')::boolean);
        END IF;
    END LOOP;
    RETURN cur;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_p_atom(toks jsonb, pos int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    tk jsonb := toks -> pos;
    k text;
    r jsonb;
    p2 int;
BEGIN
    IF tk IS NULL THEN RAISE EXCEPTION 'unexpected end of query'; END IF;
    k := tk ->> 'k';
    IF k = 'lparen' THEN
        r := _prox_p_or(toks, pos + 1);
        p2 := (r ->> 'pos')::int;
        IF (toks -> p2) ->> 'k' IS DISTINCT FROM 'rparen' THEN
            RAISE EXCEPTION 'expected `)`';
        END IF;
        RETURN jsonb_build_object('node', r -> 'node', 'pos', p2 + 1);
    ELSIF k = 'leaf' THEN
        RETURN jsonb_build_object('node', tk -> 'node', 'pos', pos + 1);
    ELSE
        RAISE EXCEPTION 'unexpected token % (expected a term, phrase, or `(`)', tk::text;
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_p_unary(toks jsonb, pos int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    r jsonb;
BEGIN
    IF (toks -> pos) ->> 'k' = 'not' THEN
        r := _prox_p_unary(toks, pos + 1);
        RETURN jsonb_build_object('node', jsonb_build_object('t', 'not', 'x', r -> 'node'),
                                  'pos', (r ->> 'pos')::int);
    END IF;
    RETURN _prox_p_atom(toks, pos);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_p_prox(toks jsonb, pos int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    r jsonb;
    first jsonb;
    ops jsonb := '[]'::jsonb;
    op jsonb;
    k text;
    p int := pos;
BEGIN
    r := _prox_p_unary(toks, p);
    first := r -> 'node';
    p := (r ->> 'pos')::int;
    LOOP
        k := (toks -> p) ->> 'k';
        IF k = 'op_phrase' THEN
            op := jsonb_build_object('op', 'phrase', 'n', ((toks -> p) ->> 'n')::int);
        ELSIF k = 'op_pre' THEN
            op := jsonb_build_object('op', 'pre', 'n', ((toks -> p) ->> 'n')::int);
        ELSIF k = 'op_within' THEN
            op := jsonb_build_object('op', 'within', 'n', ((toks -> p) ->> 'n')::int);
        ELSIF k = 'op_notwithin' THEN
            op := jsonb_build_object('op', 'notwithin', 'n', ((toks -> p) ->> 'n')::int,
                                     'ord', ((toks -> p) ->> 'ord')::boolean);
        ELSE
            EXIT;
        END IF;
        p := p + 1;
        r := _prox_p_unary(toks, p);
        op := op || jsonb_build_object('rhs', r -> 'node');
        p := (r ->> 'pos')::int;
        ops := ops || jsonb_build_array(op);
    END LOOP;
    RETURN jsonb_build_object('node', _prox_build_prox(first, ops), 'pos', p);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_p_and(toks jsonb, pos int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    r jsonb;
    branches jsonb;
    p int := pos;
BEGIN
    r := _prox_p_prox(toks, p);
    branches := jsonb_build_array(r -> 'node');
    p := (r ->> 'pos')::int;
    WHILE (toks -> p) ->> 'k' = 'and' LOOP
        p := p + 1;
        r := _prox_p_prox(toks, p);
        branches := branches || jsonb_build_array(r -> 'node');
        p := (r ->> 'pos')::int;
    END LOOP;
    RETURN jsonb_build_object(
        'node', CASE WHEN jsonb_array_length(branches) = 1 THEN branches -> 0
                     ELSE jsonb_build_object('t', 'and', 'c', branches) END,
        'pos', p);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_p_or(toks jsonb, pos int) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    r jsonb;
    branches jsonb;
    p int := pos;
BEGIN
    r := _prox_p_and(toks, p);
    branches := jsonb_build_array(r -> 'node');
    p := (r ->> 'pos')::int;
    WHILE (toks -> p) ->> 'k' = 'or' LOOP
        p := p + 1;
        r := _prox_p_and(toks, p);
        branches := branches || jsonb_build_array(r -> 'node');
        p := (r ->> 'pos')::int;
    END LOOP;
    RETURN jsonb_build_object(
        'node', CASE WHEN jsonb_array_length(branches) = 1 THEN branches -> 0
                     ELSE jsonb_build_object('t', 'or', 'c', branches) END,
        'pos', p);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_parse(input text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    toks jsonb := _prox_lex(input);
    r jsonb;
BEGIN
    IF jsonb_array_length(toks) = 0 THEN RAISE EXCEPTION 'empty query'; END IF;
    r := _prox_p_or(toks, 0);
    IF (r ->> 'pos')::int <> jsonb_array_length(toks) THEN
        RAISE EXCEPTION 'unexpected token %', (toks -> (r ->> 'pos')::int)::text;
    END IF;
    RETURN r -> 'node';
END
$fn$;

-- ===========================================================================
-- Normalization  (reject non-positional proximity operands; keep OR/phrase in)
-- ===========================================================================

CREATE OR REPLACE FUNCTION _prox_flatten(is_and boolean, children jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    out jsonb := '[]'::jsonb;
    c jsonb;
BEGIN
    FOR c IN SELECT value FROM jsonb_array_elements(children) WITH ORDINALITY AS t(value, ord) ORDER BY ord LOOP
        IF is_and AND c ->> 't' = 'and' THEN
            out := out || (c -> 'c');
        ELSIF (NOT is_and) AND c ->> 't' = 'or' THEN
            out := out || (c -> 'c');
        ELSE
            out := out || jsonb_build_array(c);
        END IF;
    END LOOP;
    IF jsonb_array_length(out) = 1 THEN
        RETURN out -> 0;
    ELSIF is_and THEN
        RETURN jsonb_build_object('t', 'and', 'c', out);
    ELSE
        RETURN jsonb_build_object('t', 'or', 'c', out);
    END IF;
END
$fn$;

-- A proximity operand must be POSITIONAL (term/prefix/glob/regex/phrase, an OR of those,
-- or a nested proximity). The two non-positional booleans raise — recursively, so an `&`/`!`
-- buried in an OR (`(a | !b) <~N> c`) or a nested proximity (`a <~N> (b <~N> !c)`) is caught
-- here at normalize time, not silently mis-evaluated downstream. Mirrors the extension's
-- `check_positional` / AND_OPERAND_ERR / NOT_OPERAND_ERR.
CREATE OR REPLACE FUNCTION _prox_check_positional(node jsonb) RETURNS void
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE t text := node ->> 't'; child jsonb;
BEGIN
    IF t = 'and' THEN
        RAISE EXCEPTION '`&` (AND) cannot be a proximity operand; write the conjunction explicitly, e.g. `(a <~N> c) & (b <~N> c)`, or a co-occurrence group `(a <~M> b) <~N> c`';
    ELSIF t = 'not' THEN
        RAISE EXCEPTION '`!` (NOT) cannot be a proximity operand; use `!(a <~N> c)` for document-level negation, or `c <!~N> a` for an occurrence of c with no nearby a';
    ELSIF t = 'or' THEN
        FOR child IN SELECT jsonb_array_elements(node -> 'c') LOOP
            PERFORM _prox_check_positional(child);
        END LOOP;
    ELSIF t = 'within' OR t = 'notwithin' THEN
        PERFORM _prox_check_positional(node -> 'a');
        PERFORM _prox_check_positional(node -> 'b');
    END IF;  -- term/exact/prefix/glob/regex/phrase: positional, ok
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_make_within(a jsonb, b jsonb, n int, ordered boolean) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    PERFORM _prox_check_positional(a);
    PERFORM _prox_check_positional(b);
    RETURN jsonb_build_object('t', 'within', 'a', a, 'b', b, 'n', n, 'ord', ordered);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_make_not_within(a jsonb, b jsonb, n int, ordered boolean) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    PERFORM _prox_check_positional(a);
    PERFORM _prox_check_positional(b);
    RETURN jsonb_build_object('t', 'notwithin', 'a', a, 'b', b, 'n', n, 'ord', ordered);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_normalize(node jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := node ->> 't';
BEGIN
    IF t = 'and' THEN
        RETURN _prox_flatten(true, (SELECT jsonb_agg(_prox_normalize(c) ORDER BY ord)
                                    FROM jsonb_array_elements(node -> 'c') WITH ORDINALITY AS t(c, ord)));
    ELSIF t = 'or' THEN
        RETURN _prox_flatten(false, (SELECT jsonb_agg(_prox_normalize(c) ORDER BY ord)
                                     FROM jsonb_array_elements(node -> 'c') WITH ORDINALITY AS t(c, ord)));
    ELSIF t = 'not' THEN
        RETURN jsonb_build_object('t', 'not', 'x', _prox_normalize(node -> 'x'));
    ELSIF t = 'within' THEN
        RETURN _prox_make_within(_prox_normalize(node -> 'a'), _prox_normalize(node -> 'b'),
                                 (node ->> 'n')::int, (node ->> 'ord')::boolean);
    ELSIF t = 'notwithin' THEN
        RETURN _prox_make_not_within(_prox_normalize(node -> 'a'), _prox_normalize(node -> 'b'),
                                     (node ->> 'n')::int, (node ->> 'ord')::boolean);
    ELSE
        RETURN node;
    END IF;
END
$fn$;

-- ===========================================================================
-- Skeleton lowering  ->  lexeme-presence tsquery string  (NULL = no constraint)
-- ===========================================================================

CREATE OR REPLACE FUNCTION _prox_conj(parts text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT CASE WHEN array_length($1, 1) = 1 THEN $1[1]
                 ELSE '(' || array_to_string($1, ' & ') || ')' END $fn$;

CREATE OR REPLACE FUNCTION _prox_optional_conj(parts text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    present text[];
BEGIN
    present := ARRAY(SELECT p FROM unnest(parts) p WHERE p IS NOT NULL);
    IF coalesce(array_length(present, 1), 0) = 0 THEN RETURN NULL; END IF;
    RETURN _prox_conj(present);
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_native_phrase_atom(atom jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := atom ->> 't';
BEGIN
    IF t = 'term' THEN
        RETURN _prox_quote_lexeme(atom ->> 'v');
    ELSIF t = 'prefix' THEN
        RETURN _prox_quote_lexeme(atom ->> 'v') || ':*';
    ELSIF t = 'glob' THEN
        IF (atom ->> 'p') <> '' THEN RETURN _prox_quote_lexeme(atom ->> 'p') || ':*'; ELSE RETURN NULL; END IF;
    END IF;
    RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_phrase_skeleton(atoms jsonb, gaps jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    native text[] := '{}';
    keyed  text[] := '{}';
    allkeyed boolean := true;
    na text;
    a jsonb;
    s text;
    g int;
    op text;
    i int;
BEGIN
    FOR a IN SELECT value FROM jsonb_array_elements(atoms) WITH ORDINALITY AS t(value, ord) ORDER BY ord LOOP
        na := _prox_native_phrase_atom(a);
        native := array_append(native, na);
        IF na IS NULL THEN allkeyed := false; ELSE keyed := array_append(keyed, na); END IF;
    END LOOP;
    IF allkeyed THEN
        s := native[1];
        FOR i IN 2 .. array_length(native, 1) LOOP
            g := (gaps ->> (i - 2))::int;
            IF g = 1 THEN op := '<->'; ELSE op := '<' || g || '>'; END IF;
            s := s || ' ' || op || ' ' || native[i];
        END LOOP;
        RETURN '(' || s || ')';
    ELSE
        IF coalesce(array_length(keyed, 1), 0) = 0 THEN RETURN NULL; END IF;
        RETURN _prox_conj(keyed);
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_skeleton(node jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := node ->> 't';
    present text[];
    parts text[] := '{}';
    c jsonb;
    s text;
BEGIN
    IF t = 'term' THEN
        RETURN _prox_quote_lexeme(node ->> 'v');
    ELSIF t = 'prefix' THEN
        RETURN _prox_quote_lexeme(node ->> 'v') || ':*';
    ELSIF t = 'glob' THEN
        IF (node ->> 'p') <> '' THEN RETURN _prox_quote_lexeme(node ->> 'p') || ':*'; ELSE RETURN NULL; END IF;
    ELSIF t = 'regex' THEN
        RETURN NULL;
    ELSIF t = 'phrase' THEN
        RETURN _prox_phrase_skeleton(node -> 'atoms', node -> 'gaps');
    ELSIF t = 'within' THEN
        RETURN _prox_optional_conj(ARRAY[_prox_skeleton(node -> 'a'), _prox_skeleton(node -> 'b')]);
    ELSIF t = 'notwithin' THEN
        RETURN _prox_skeleton(node -> 'a');
    ELSIF t = 'and' THEN
        present := ARRAY(SELECT _prox_skeleton(value)
                         FROM jsonb_array_elements(node -> 'c') WITH ORDINALITY AS x(value, ord)
                         WHERE _prox_skeleton(value) IS NOT NULL
                         ORDER BY ord);
        IF coalesce(array_length(present, 1), 0) = 0 THEN RETURN NULL; END IF;
        RETURN _prox_conj(present);
    ELSIF t = 'or' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') WITH ORDINALITY AS x(value, ord) ORDER BY ord LOOP
            s := _prox_skeleton(c);
            IF s IS NULL THEN RETURN NULL; END IF;
            parts := array_append(parts, s);
        END LOOP;
        RETURN '(' || array_to_string(parts, ' | ') || ')';
    ELSE  -- not
        RETURN NULL;
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_to_tsquery_string(input text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    s text := _prox_skeleton(_prox_normalize(_prox_parse(input)));
BEGIN
    IF s IS NULL THEN
        RAISE EXCEPTION 'query has no positive term to drive the index; add an AND-ed positive term';
    END IF;
    RETURN s;
END
$fn$;

-- ===========================================================================
-- Regex validation  ->  fail fast on a malformed `##regex##`
-- ===========================================================================

CREATE OR REPLACE FUNCTION _prox_regex_ok(pattern text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
BEGIN
    PERFORM '' ~ ('^(?:' || pattern || ')$');
    RETURN true;
EXCEPTION WHEN invalid_regular_expression THEN
    RETURN false;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_validate_regexes(node jsonb) RETURNS void
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := node ->> 't';
    c jsonb;
BEGIN
    IF t = 'regex' THEN
        IF NOT _prox_regex_ok(node ->> 'v') THEN
            RAISE EXCEPTION 'invalid regex `%`', node ->> 'v';
        END IF;
    ELSIF t IN ('and', 'or') THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            PERFORM _prox_validate_regexes(c);
        END LOOP;
    ELSIF t = 'not' THEN
        PERFORM _prox_validate_regexes(node -> 'x');
    ELSIF t IN ('within', 'notwithin') THEN
        PERFORM _prox_validate_regexes(node -> 'a');
        PERFORM _prox_validate_regexes(node -> 'b');
    END IF;
END
$fn$;

-- ===========================================================================
-- Recheck evaluation  (positional semantics on a tsvector)
-- ===========================================================================

-- END position of each phrase match (last atom's position for a satisfying occurrence). A
-- match's span is [end − Σgaps … end]; `_prox_positions` densifies it, `_prox_occ` pairs it
-- with the start. Atoms are term/prefix/glob nodes, resolved by `_prox_positions`.
CREATE OR REPLACE FUNCTION _prox_phrase_ends(node jsonb, v tsvector) RETURNS int[]
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE atoms jsonb := node -> 'atoms'; gaps jsonb := node -> 'gaps';
        reach int[]; cur int[]; g int; i int;
BEGIN
    reach := _prox_positions(atoms -> 0, v);
    IF coalesce(array_length(reach, 1), 0) = 0 THEN RETURN '{}'; END IF;
    FOR i IN 1 .. jsonb_array_length(atoms) - 1 LOOP
        cur := _prox_positions(atoms -> i, v);
        g := (gaps ->> (i - 1))::int;
        reach := ARRAY(SELECT cc FROM unnest(cur) cc WHERE (cc - g) = ANY(reach) ORDER BY cc);
        IF coalesce(array_length(reach, 1), 0) = 0 THEN RETURN '{}'; END IF;
    END LOOP;
    RETURN reach;
END
$fn$;

-- `b` edge-to-edge within `n` of `a` (overlap ⇒ 0), or — when `ord` — strictly AFTER `a`
-- within `n`. Intervals are (s,e); for point operands this is the plain |Δ| ≤ n / 0 < Δ ≤ n.
CREATE OR REPLACE FUNCTION _prox_iv_near(a_s int, a_e int, b_s int, b_e int, n int, ord boolean) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT CASE WHEN ord THEN b_s > a_e AND b_s - a_e <= n
                 ELSE b_s <= a_e + n AND a_s <= b_e + n END $fn$;

-- Occurrence intervals (s,e) of a proximity operand — ONE per match, NOT densified — so
-- not-within reasons per WHOLE occurrence: a phrase/group is "near" b when ANY part of its span
-- is within n. (within/pre use the densified `_prox_positions` instead.) Mirrors `dsl::occurrences`.
CREATE OR REPLACE FUNCTION _prox_occ(node jsonb, v tsvector) RETURNS TABLE(s int, e int)
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE t text := node ->> 't'; total int; n int; ord boolean; c jsonb; ends int[];
BEGIN
    IF t = 'phrase' THEN
        ends := _prox_phrase_ends(node, v);
        SELECT coalesce(sum(x::int), 0) INTO total FROM jsonb_array_elements_text(node -> 'gaps') AS gg(x);
        RETURN QUERY SELECT u.p - total, u.p FROM unnest(ends) AS u(p);
    ELSIF t = 'or' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            RETURN QUERY SELECT o.s, o.e FROM _prox_occ(c, v) AS o;
        END LOOP;
    ELSIF t = 'within' THEN
        n := (node ->> 'n')::int; ord := (node ->> 'ord')::boolean;
        RETURN QUERY SELECT DISTINCT LEAST(ia.s, ib.s), GREATEST(ia.e, ib.e)
                     FROM _prox_occ(node -> 'a', v) AS ia, _prox_occ(node -> 'b', v) AS ib
                     WHERE _prox_iv_near(ia.s, ia.e, ib.s, ib.e, n, ord);
    ELSIF t = 'notwithin' THEN
        n := (node ->> 'n')::int; ord := (node ->> 'ord')::boolean;
        -- Saturation guard (mirrors the Rust `occurrences`): if any avoid-term
        -- occurrence ends on the position cap (16383), its tail collapsed and
        -- "near b" is untrustworthy — fail open, keeping every a-occurrence.
        IF EXISTS (SELECT 1 FROM _prox_occ(node -> 'b', v) AS ib WHERE ib.e = 16383) THEN
            RETURN QUERY SELECT ia.s, ia.e FROM _prox_occ(node -> 'a', v) AS ia;
        ELSE
            RETURN QUERY SELECT ia.s, ia.e FROM _prox_occ(node -> 'a', v) AS ia
                         WHERE NOT EXISTS (SELECT 1 FROM _prox_occ(node -> 'b', v) AS ib
                                           WHERE _prox_iv_near(ia.s, ia.e, ib.s, ib.e, n, ord));
        END IF;
    ELSE  -- leaf: term / prefix / glob / regex (and/not raise via _prox_positions)
        RETURN QUERY SELECT u.p, u.p FROM unnest(_prox_positions(node, v)) AS u(p);
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_positions(node jsonb, v tsvector) RETURNS int[]
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := node ->> 't';
    atoms jsonb;
    gaps jsonb;
    reach int[];
    cur int[];
    res int[] := '{}';
    g int;
    total int;
    i int;
    c jsonb;
BEGIN
    IF t = 'term' THEN
        RETURN ts_prox_positions(v, node ->> 'v');
    ELSIF t = 'prefix' THEN
        RETURN ts_prox_positions_prefix(v, node ->> 'v');
    ELSIF t = 'glob' THEN
        RETURN _prox_pos_glob(v, node ->> 'p', node ->> 'g');
    ELSIF t = 'regex' THEN
        RETURN _prox_pos_regex(v, node ->> 'v');
    ELSIF t = 'phrase' THEN
        reach := _prox_phrase_ends(node, v);
        IF coalesce(array_length(reach, 1), 0) = 0 THEN RETURN '{}'; END IF;
        -- `reach` holds each match's END position; densify to the whole span [end−Σgaps .. end]
        -- so a phrase proximity operand measures EDGE-TO-EDGE, like a nested group's span.
        SELECT coalesce(sum(x::int), 0) INTO total FROM jsonb_array_elements_text(node -> 'gaps') AS e(x);
        IF total = 0 THEN RETURN reach; END IF;
        RETURN ARRAY(SELECT DISTINCT s FROM unnest(reach) AS u(e), generate_series(u.e - total, u.e) AS s ORDER BY s);
    ELSIF t = 'or' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            res := res || _prox_positions(c, v);
        END LOOP;
        RETURN coalesce((SELECT array_agg(DISTINCT p ORDER BY p) FROM unnest(res) p), '{}'::int[]);
    ELSIF t = 'within' THEN
        RETURN _prox_within_span(_prox_positions(node -> 'a', v), _prox_positions(node -> 'b', v),
                                 (node ->> 'n')::int, (node ->> 'ord')::boolean);
    ELSIF t = 'notwithin' THEN
        -- A not-within as a within-operand contributes its isolated occurrences' spans,
        -- densified (like any other operand), so the outer proximity measures against them.
        RETURN coalesce((SELECT array_agg(DISTINCT p ORDER BY p)
                         FROM _prox_occ(node, v) AS o, generate_series(o.s, o.e) AS p), '{}'::int[]);
    ELSE
        RAISE EXCEPTION 'AND/NOT cannot be a proximity operand (normalization should have rejected it)';
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION _prox_eval(node jsonb, v tsvector) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS
$fn$
DECLARE
    t text := node ->> 't';
    c jsonb;
    pa int[];
    pb int[];
BEGIN
    IF t = 'and' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            IF NOT _prox_eval(c, v) THEN RETURN false; END IF;
        END LOOP;
        RETURN true;
    ELSIF t = 'or' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            IF _prox_eval(c, v) THEN RETURN true; END IF;
        END LOOP;
        RETURN false;
    ELSIF t = 'not' THEN
        RETURN NOT _prox_eval(node -> 'x', v);
    ELSIF t = 'within' THEN
        pa := _prox_positions(node -> 'a', v);
        pb := _prox_positions(node -> 'b', v);
        IF (node ->> 'ord')::boolean THEN
            RETURN _prox_arr_pre(pa, pb, (node ->> 'n')::int);
        ELSE
            RETURN _prox_arr_within(pa, pb, (node ->> 'n')::int);
        END IF;
    ELSIF t = 'notwithin' THEN
        -- Occurrence-level: some WHOLE occurrence of `a` has no `b` within `n` (after it, if
        -- ordered). `_prox_occ` already returns just those isolated occurrences, so any row matches.
        RETURN EXISTS (SELECT 1 FROM _prox_occ(node, v));
    ELSE  -- term / prefix / glob / regex / phrase
        RETURN coalesce(array_length(_prox_positions(node, v), 1), 0) > 0;
    END IF;
END
$fn$;

-- ===========================================================================
-- Public compiler entry points  (names/signatures match the extension)
-- ===========================================================================

-- Parse a DSL string and emit the lexeme-presence skeleton as a
-- `to_tsquery('simple', …)` input string.
CREATE OR REPLACE FUNCTION ts_prox_query_skeleton(query text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
BEGIN
    RETURN _prox_to_tsquery_string(query);
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ts_prox_query: %', SQLERRM;
END
$fn$;

-- One query string → the index-selection tsquery.
CREATE OR REPLACE FUNCTION ts_prox_query(query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT to_tsquery('simple', ts_prox_query_skeleton(query)) $fn$;

-- ===========================================================================
-- Native pushdown  ->  a tsquery whose @@ is EXACTLY the recheck (skips it)
-- ===========================================================================
--
-- Mirror of the extension's native lowering (src/dsl.rs `native`). For the common
-- bounded-proximity shapes the positional test is expressible as a native `tsquery`,
-- evaluated by Postgres's own (C) phrase engine in the GIN `@@` heap recheck — so the
-- slow per-row positional recheck can be SKIPPED entirely (it is most of the port's
-- cost). within/pre lower to an OR over exact gaps:
--   a <~n> b  ≡  OR_{k=0..n} (a <k> b | b <k> a)   (either order, |Δ| ≤ n)
--   a <-n> b  ≡  OR_{k=1..n} (a <k> b)             (ordered, 0 < Δ ≤ n)
-- Only shapes that map EXACTLY are accepted; everything else (glob, regex, not-
-- within, document NOT, nested/phrase proximity operands, or a distance past 32 —
-- the extension's NATIVE_MAX_DISTANCE) returns NULL and keeps the presence skeleton +
-- recheck. The cap bounds the OR-expansion; past it the expansion outweighs the
-- recheck it saves.
--
-- `ts_prox_recheck(v, q)` (below) applies this automatically — it is an INLINEABLE
-- coalesce of `v @@ ts_prox_query_native(q)` over the positional recheck — so the
-- ordinary two-clause form gets the pushdown for free, no special syntax:
--   WHERE tsv @@ proxquery.ts_prox_query(q) AND proxquery.ts_prox_recheck(tsv, q)
-- fast for native shapes, recheck for the rest. The native tsquery is built once for a
-- literal (const-folded) or a custom-plan parameter; a bind parameter that flips to a
-- GENERIC plan re-parses it per row (still correct, still faster than the bare recheck)
-- — inline the query as a literal to avoid that.

-- A lexeme quoted for the native tsquery, or NULL if it can't survive `tsqueryin`
-- verbatim. The native tsquery is built with `::tsquery` (tsqueryin), NOT to_tsquery,
-- so lexemes match the recheck's exact byte lookup with no re-tokenizing/lowercasing.
-- The exception is a backslash: tsqueryin escapes it away (`'a\b'` → lexeme `ab`), so
-- such a term would no longer match the recheck — refuse it (it falls back to recheck).
CREATE OR REPLACE FUNCTION _prox_native_lexeme(v text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT CASE WHEN strpos(v, chr(92)) = 0 THEN _prox_quote_lexeme(v) END $fn$;

-- A proximity operand expressible as a native phrase operand: a keyed atom (term/
-- prefix) or an OR of them. NULL for phrase/glob/regex/nested-proximity operands.
CREATE OR REPLACE FUNCTION _prox_native_operand(node jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE t text := node ->> 't'; parts text[] := '{}'; c jsonb; s text;
BEGIN
    IF t = 'term' THEN
        RETURN _prox_native_lexeme(node ->> 'v');
    ELSIF t = 'prefix' THEN
        RETURN _prox_native_lexeme(node ->> 'v') || ':*';
    ELSIF t = 'or' THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            s := _prox_native_operand(c);
            IF s IS NULL THEN RETURN NULL; END IF;
            parts := array_append(parts, s);
        END LOOP;
        RETURN '(' || array_to_string(parts, ' | ') || ')';
    ELSE
        RETURN NULL;
    END IF;
END
$fn$;

-- A phrase atom's exact native key (term/prefix). A glob is not exact (its index
-- prefix over-matches), so a phrase containing one can't be pushed down.
CREATE OR REPLACE FUNCTION _prox_native_phrase_atom(atom jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT CASE atom ->> 't'
                WHEN 'term'   THEN _prox_native_lexeme(atom ->> 'v')
                WHEN 'prefix' THEN _prox_native_lexeme(atom ->> 'v') || ':*'
                ELSE NULL END $fn$;

-- The native tsquery string for a normalized node, or NULL if not native-expressible.
CREATE OR REPLACE FUNCTION _prox_native(node jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    t text := node ->> 't';
    n int; ord boolean;
    a text; b text; s text; na text;
    atoms jsonb; gaps jsonb;
    parts text[] := '{}'; clauses text[] := '{}';
    c jsonb; i int; k int;
BEGIN
    IF t = 'term' THEN
        RETURN _prox_native_lexeme(node ->> 'v');
    ELSIF t = 'prefix' THEN
        RETURN _prox_native_lexeme(node ->> 'v') || ':*';
    ELSIF t IN ('glob', 'regex', 'not', 'notwithin') THEN
        RETURN NULL;
    ELSIF t = 'phrase' THEN
        atoms := node -> 'atoms';
        gaps := node -> 'gaps';
        FOR i IN 0 .. jsonb_array_length(atoms) - 1 LOOP
            na := _prox_native_phrase_atom(atoms -> i);
            IF na IS NULL THEN RETURN NULL; END IF;
            IF i = 0 THEN
                s := na;
            ELSE
                k := (gaps ->> (i - 1))::int;
                s := s || CASE WHEN k = 1 THEN ' <-> ' ELSE ' <' || k || '> ' END || na;
            END IF;
        END LOOP;
        RETURN '(' || s || ')';
    ELSIF t = 'within' THEN
        n := (node ->> 'n')::int;
        ord := (node ->> 'ord')::boolean;
        IF n > 32 OR (ord AND n < 1) THEN RETURN NULL; END IF;   -- 32 = NATIVE_MAX_DISTANCE
        a := _prox_native_operand(node -> 'a');
        b := _prox_native_operand(node -> 'b');
        IF a IS NULL OR b IS NULL THEN RETURN NULL; END IF;
        IF ord THEN
            FOR k IN 1 .. n LOOP
                clauses := array_append(clauses, a || ' <' || k || '> ' || b);
            END LOOP;
        ELSE
            FOR k IN 0 .. n LOOP
                clauses := array_append(clauses, a || ' <' || k || '> ' || b);
                clauses := array_append(clauses, b || ' <' || k || '> ' || a);
            END LOOP;
        END IF;
        RETURN '(' || array_to_string(clauses, ' | ') || ')';
    ELSIF t IN ('and', 'or') THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            s := _prox_native(c);
            IF s IS NULL THEN RETURN NULL; END IF;
            parts := array_append(parts, s);
        END LOOP;
        RETURN '(' || array_to_string(parts, CASE WHEN t = 'and' THEN ' & ' ELSE ' | ' END) || ')';
    ELSE
        RETURN NULL;
    END IF;
END
$fn$;

-- Public: the native-pushdown tsquery, or NULL when the query isn't native-
-- expressible (then use the two-clause presence + ts_prox_recheck form). Mirrors the
-- extension's ts_prox_query_native. A malformed query yields NULL here (the recheck
-- in the fallback branch surfaces the error), matching the extension.
CREATE OR REPLACE FUNCTION ts_prox_query_native(query text) RETURNS tsquery
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
BEGIN
    -- `::tsquery` (tsqueryin) takes the lexemes VERBATIM, matching the recheck's exact
    -- byte lookup; to_tsquery would re-tokenize / re-lowercase them. NULL ⇒ NULL.
    RETURN _prox_native(_prox_normalize(_prox_parse(query)))::tsquery;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$fn$;

-- ===========================================================================
-- Recheck-droppable form  ->  the skeleton @@ alone is the EXACT match
-- ===========================================================================
--
-- For a query with no proximity/not-within operator (plain boolean / phrase / prefix
-- over terms), the presence skeleton `ts_prox_query(q)` is itself the EXACT answer —
-- the positional recheck removes nothing (avg_cand == avg_match). So the second clause
-- of the two-clause form is pure overhead: a Filter that re-detoasts the (often TOASTed)
-- tsvector on every candidate row. `ts_prox_query_exact(q)` returns a non-NULL tsquery
-- exactly when the recheck is droppable — i.e. native-expressible AND free of within/pre/
-- not-within (whose native form is exact but NON-selective, so it must keep the skeleton
-- + recheck, never drive the index alone). It is the pure-SQL mirror of the extension's
-- `ts_prox_query_exact` / planner `simplify` gate (`dsl::simplify_tsquery_string`).
--
-- Recommended query form — one self-folding template that const-folds to the optimal
-- plan for a LITERAL or custom-plan query (a generic-plan bind parameter keeps the
-- recheck, still correct):
--     WHERE tsv @@ proxquery.ts_prox_query(q)
--       AND (proxquery.ts_prox_query_exact(q) IS NOT NULL OR proxquery.ts_prox_recheck(tsv, q))
-- When exact(q) is non-NULL the planner folds `(true OR recheck)` away (one clause, no
-- re-detoast); otherwise `(false OR recheck)` reduces to the recheck (the two-clause form).

-- Whether the normalized AST contains a within/pre (`within`) or not-within (`notwithin`)
-- node anywhere — the gate for `ts_prox_query_exact`. Mirrors the extension's
-- `dsl::contains_within`. A within/not-within at the top returns true immediately; only
-- and/or/not need to be searched (a within nested under a within is already caught).
CREATE OR REPLACE FUNCTION _prox_has_within(node jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$
    SELECT CASE node ->> 't'
        WHEN 'within'    THEN true
        WHEN 'notwithin' THEN true
        WHEN 'not'       THEN _prox_has_within(node -> 'x')
        WHEN 'and'       THEN EXISTS (SELECT 1 FROM jsonb_array_elements(node -> 'c') AS e(v)
                                      WHERE _prox_has_within(e.v))
        WHEN 'or'        THEN EXISTS (SELECT 1 FROM jsonb_array_elements(node -> 'c') AS e(v)
                                      WHERE _prox_has_within(e.v))
        ELSE false
    END
$fn$;

-- Public: the EXACT-match tsquery when the recheck is droppable (boolean / phrase /
-- prefix), or NULL when the recheck is needed (within/pre/not-within, glob-suffix, regex,
-- document NOT, or a malformed query). Non-NULL ⇒ `tsv @@ ts_prox_query_exact(q)` alone is
-- the full match. Mirrors the extension's `ts_prox_query_exact`.
CREATE OR REPLACE FUNCTION ts_prox_query_exact(query text) RETURNS tsquery
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE node jsonb;
BEGIN
    node := _prox_normalize(_prox_parse(query));
    IF _prox_has_within(node) THEN
        RETURN NULL;                              -- exact but non-selective ⇒ keep recheck
    END IF;
    -- `::tsquery` (tsqueryin), verbatim lexemes — matches the recheck's exact byte lookup.
    RETURN _prox_native(node)::tsquery;           -- NULL for glob-suffix / regex / NOT
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$fn$;

-- The positional recheck: evaluate the DSL's semantics on `v` directly. Internal —
-- the public ts_prox_recheck wraps it with the native-pushdown fast path below. Keeps the
-- `ts_prox_recheck:` error prefix so user-facing errors are unchanged.
CREATE OR REPLACE FUNCTION _prox_recheck(v tsvector, query text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    node jsonb;
BEGIN
    node := _prox_normalize(_prox_parse(query));
    PERFORM _prox_validate_regexes(node);
    RETURN _prox_eval(node, v);
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ts_prox_recheck: %', SQLERRM;
END
$fn$;

-- Public recheck: the partner of ts_prox_query for index selection. An INLINEABLE sql
-- coalesce (LANGUAGE sql, IMMUTABLE, no SET clause, qualified body, no sub-select — all
-- required to inline) so that in `tsv @@ ts_prox_query(q) AND ts_prox_recheck(tsv, q)` the
-- planner splices the body in: for a native-expressible `q` it becomes `tsv @@ <native
-- tsquery>` (Postgres's C phrase engine, no positional recheck); otherwise it reduces to
-- the positional recheck. The index always comes from the explicit ts_prox_query clause,
-- so even if this never inlines the worst case is the recheck, never a seq scan. Same
-- boolean as the recheck — ts_prox_query_native(q) is exactly equivalent, or NULL.
-- NOT marked STRICT on purpose: a strict SQL function whose body uses a nonstrict
-- function (coalesce) is not inlined, and inlining is the whole point. NULL args still
-- yield NULL here because the inner ts_prox_query_native / _prox_recheck are STRICT.
CREATE OR REPLACE FUNCTION ts_prox_recheck(v tsvector, query text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT coalesce(v @@ proxquery.ts_prox_query_native(query),
                     proxquery._prox_recheck(v, query)) $fn$;

-- ===========================================================================
-- Consolidated indexable search  ->  the recommended form in one call
-- ===========================================================================
--
-- `ts_prox_search(v, q)` collapses the recommended index-selection + recheck form into a
-- single call. It is written to INLINE (LANGUAGE sql, IMMUTABLE, NOT strict, no SET clause,
-- fully-qualified body, single SELECT) so the planner splices its body back into the query:
-- the `v @@ ts_prox_query(q)` clause is re-exposed for the plain `gin(tsvector)` index, and
-- for a recheck-droppable (boolean / phrase / prefix) constant query the
-- `(ts_prox_query_exact(q) IS NOT NULL OR …)` const-folds away, dropping the per-row recheck
-- (and its tsvector re-detoast). Exactly equal to — and the same plan as — the explicit form:
--     WHERE proxquery.ts_prox_search(tsv, q)        -- one call; planner folds it open
--   ≡ WHERE tsv @@ proxquery.ts_prox_query(q)
--       AND (proxquery.ts_prox_query_exact(q) IS NOT NULL OR proxquery.ts_prox_recheck(tsv, q))
--
-- CAVEAT — index use rides on that inlining. Should it ever fail to inline (the body gains a
-- SET clause, is marked STRICT, is wrapped where the planner can't see the `@@`, …) it
-- degrades SILENTLY to a sequential scan. The explicit two-clause form keeps `@@` visible in
-- the query text and so can never lose the index; prefer it where robustness beats brevity.
-- (The test suite EXPLAINs ts_prox_search and asserts a Bitmap Index Scan, so a regression
-- here fails loudly rather than silently seq-scanning.) A config-aware column uses the 3-arg
-- `ts_prox_search(tsv, q, cfg)` / `ts_prox_query_exact(q, cfg)` overloads below, which fold
-- the recheck the same way (the cfg-resolved skeleton is exactly the match).
CREATE OR REPLACE FUNCTION ts_prox_search(v tsvector, query text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT v @@ proxquery.ts_prox_query(query)
         AND (proxquery.ts_prox_query_exact(query) IS NOT NULL
              OR proxquery.ts_prox_recheck(v, query)) $fn$;

-- ===========================================================================
-- Config-aware surface (3-arg overloads)
-- ===========================================================================
--
-- The 2-arg forms above are `simple`-only (literal lexemes). The 3-arg forms take
-- a `regconfig` so a column built with any text-search config (stemmed, unaccented,
-- a custom `simple_unaccent`, …) can be matched: each query *term* is resolved
-- through `to_tsvector(cfg, term)` — the same routine that built the column — so the
-- recheck agrees with the column and with the `to_tsquery(cfg, …)` skeleton. Globs
-- and regexes scan the stored lexemes verbatim and stay config-agnostic. These call
-- the SAME Postgres builtins as the native extension, so the two ports stay in parity.

-- Distinct lexemes a term resolves to under `cfg` (its tokens run through the
-- config's dictionaries). Empty for a stopword / a term that tokenizes to nothing.
CREATE OR REPLACE FUNCTION _prox_resolve_lexemes(term text, cfg regconfig) RETURNS text[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT coalesce(array_agg(DISTINCT lexeme), '{}'::text[]) FROM unnest(to_tsvector(cfg, term)) $fn$;

-- Fold a glob's literal runs (the maximal non-`*`/`?` substrings) through `cfg`,
-- leaving the wildcards untouched, so a glob matches the column's normalized lexemes
-- the same way a plain term does — and the same way the `to_tsquery(cfg, 'p':*)`
-- skeleton already folds the glob's prefix on the index side. A run is replaced only
-- when `cfg` resolves it to exactly one lexeme (the common alphabetic/accented case);
-- a run that yields 0 or >1 lexemes (punctuated/host/alphanumeric/stopword) is kept
-- verbatim, mirroring the 0/1/>1 fan-out in the term/prefix branches. The fold can
-- only ever improve matching or leave a run as-is — it never blanks a glob out.
CREATE OR REPLACE FUNCTION _prox_fold_glob(g text, cfg regconfig) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    out text := '';
    m   text[];
    lex text[];
BEGIN
    -- each match is either a literal run (m[1]) or a single wildcard (m[2])
    FOR m IN SELECT regexp_matches(g, '([^*?]+)|([*?])', 'g') LOOP
        IF m[2] IS NOT NULL THEN
            out := out || m[2];                       -- wildcard: unchanged
        ELSE
            lex := _prox_resolve_lexemes(m[1], cfg);  -- = distinct to_tsvector(cfg, run)
            IF array_length(lex, 1) = 1 THEN
                out := out || lex[1];                 -- fold to the column's lexeme form
            ELSE
                out := out || m[1];                   -- 0 or >1 lexemes: keep verbatim
            END IF;
        END IF;
    END LOOP;
    RETURN out;
END
$fn$;

-- Rewrite the parsed AST so every term/prefix is resolved to its config lexeme(s),
-- then evaluate with the unchanged `_prox_eval`. A term → its single lexeme, or an
-- OR of lexemes (stemmer/thesaurus), or an empty OR (stopword ⇒ matches nothing). A
-- prefix → its normalized form (so an accented prefix matches the unaccented stored
-- lexemes, as the skeleton does). A glob's literal runs are folded through `cfg` too
-- (see `_prox_fold_glob`), so wildcard searches inherit the column's character
-- normalization and agree with the folded `to_tsquery(cfg, 'p':*)` index probe; regex
-- is left verbatim (its skeleton emits no key, so there is no probe to disagree with).
-- Phrase atoms are resolved in place when they yield a single lexeme (the common
-- case); a phrase atom carries one lexeme, so multi-lexeme atoms are left as-is.
CREATE OR REPLACE FUNCTION _prox_resolve_ast(node jsonb, cfg regconfig) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    t    text := node ->> 't';
    lex  text[];
    arr  jsonb := '[]'::jsonb;
    atoms jsonb := '[]'::jsonb;
    c    jsonb;
    a    jsonb;
    fg   text;
    i    int;
BEGIN
    IF t = 'term' THEN
        lex := _prox_resolve_lexemes(node ->> 'v', cfg);
        IF coalesce(array_length(lex, 1), 0) = 0 THEN
            RETURN jsonb_build_object('t', 'or', 'c', '[]'::jsonb);     -- stopword ⇒ matches nothing
        ELSIF array_length(lex, 1) = 1 THEN
            RETURN jsonb_build_object('t', 'term', 'v', lex[1]);
        ELSE
            FOR i IN 1 .. array_length(lex, 1) LOOP
                arr := arr || jsonb_build_array(jsonb_build_object('t', 'term', 'v', lex[i]));
            END LOOP;
            RETURN jsonb_build_object('t', 'or', 'c', arr);             -- union of lexeme positions
        END IF;
    ELSIF t = 'prefix' THEN
        lex := _prox_resolve_lexemes(node ->> 'v', cfg);
        IF array_length(lex, 1) = 1 THEN
            RETURN jsonb_build_object('t', 'prefix', 'v', lex[1]);
        ELSE
            RETURN node;                                               -- 0 or >1 ⇒ raw prefix
        END IF;
    ELSIF t = 'glob' THEN
        -- recompute the literal prefix from the FOLDED glob so the starts_with()
        -- scan-narrowing in _prox_pos_glob keys off the folded lexemes too.
        fg := _prox_fold_glob(node ->> 'g', cfg);
        RETURN jsonb_build_object('t', 'glob', 'g', fg, 'p', _prox_glob_prefix(fg));
    ELSIF t = 'regex' THEN
        RETURN node;                                                   -- scan stored lexemes verbatim
    ELSIF t = 'phrase' THEN
        FOR a IN SELECT value FROM jsonb_array_elements(node -> 'atoms') AS x(value) LOOP
            IF a ->> 't' IN ('term', 'prefix') THEN
                lex := _prox_resolve_lexemes(a ->> 'v', cfg);
                IF array_length(lex, 1) = 1 THEN
                    a := jsonb_build_object('t', a ->> 't', 'v', lex[1]);
                END IF;
            ELSIF a ->> 't' = 'glob' THEN
                fg := _prox_fold_glob(a ->> 'g', cfg);                  -- fold phrase globs too
                a := jsonb_build_object('t', 'glob', 'g', fg, 'p', _prox_glob_prefix(fg));
            END IF;
            atoms := atoms || jsonb_build_array(a);
        END LOOP;
        RETURN jsonb_build_object('t', 'phrase', 'atoms', atoms, 'gaps', node -> 'gaps');
    ELSIF t IN ('and', 'or') THEN
        FOR c IN SELECT value FROM jsonb_array_elements(node -> 'c') AS x(value) LOOP
            arr := arr || jsonb_build_array(_prox_resolve_ast(c, cfg));
        END LOOP;
        RETURN jsonb_build_object('t', t, 'c', arr);
    ELSIF t = 'not' THEN
        RETURN jsonb_build_object('t', 'not', 'x', _prox_resolve_ast(node -> 'x', cfg));
    ELSIF t IN ('within', 'notwithin') THEN
        RETURN jsonb_build_object('t', t,
            'a', _prox_resolve_ast(node -> 'a', cfg),
            'b', _prox_resolve_ast(node -> 'b', cfg),
            'n', node -> 'n', 'ord', node -> 'ord');
    ELSE
        RETURN node;
    END IF;
END
$fn$;

-- 3-arg skeleton: lower through the column's config (to_tsquery(cfg, …) normalizes
-- the lexemes exactly as the recheck's to_tsvector(cfg, term) does).
CREATE OR REPLACE FUNCTION ts_prox_query(query text, cfg regconfig) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$ SELECT to_tsquery(cfg, ts_prox_query_skeleton(query)) $fn$;

-- 3-arg recheck: resolve terms through cfg, then evaluate.
CREATE OR REPLACE FUNCTION ts_prox_recheck(v tsvector, query text, cfg regconfig) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE
    node jsonb;
BEGIN
    node := _prox_resolve_ast(_prox_normalize(_prox_parse(query)), cfg);
    PERFORM _prox_validate_regexes(node);
    RETURN _prox_eval(node, v);
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ts_prox_recheck: %', SQLERRM;
END
$fn$;

-- 3-arg recheck-droppable form: the config counterpart of `ts_prox_query_exact(q)`. It is
-- `ts_prox_query(q, cfg)` (the index selection) GATED by droppability — so the index filter
-- and the gate are one and the same logic — or NULL when the recheck is needed. The gate is a
-- droppability witness: resolve each term through `cfg` (via `_prox_resolve_ast`) and try to
-- build the native verbatim tsquery; it succeeds only for a droppable shape whose terms all
-- resolve. We discard that witness and return the selection. NULL when the recheck is needed:
-- within/pre (exact but non-selective ⇒ keep the skeleton + recheck), glob-suffix, regex,
-- document NOT, or a stopword-emptied branch. The selection is a subset of the recheck (a
-- compound's `to_tsquery` phrase ⊆ the recheck's OR-of-parts), so dropping the recheck preserves
-- the two-clause result. Mirrors the extension's 3-arg `ts_prox_query_exact(query, cfg)`;
-- identical NULL-ness AND value to it (the differential suite checks).
CREATE OR REPLACE FUNCTION ts_prox_query_exact(query text, cfg regconfig) RETURNS tsquery
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    SET search_path = proxquery, pg_catalog AS
$fn$
DECLARE node jsonb; witness text;
BEGIN
    node := _prox_resolve_ast(_prox_normalize(_prox_parse(query)), cfg);
    IF _prox_has_within(node) THEN RETURN NULL; END IF;     -- exact but non-selective
    witness := _prox_native(node);                          -- droppability witness (verbatim native)
    IF witness IS NULL THEN RETURN NULL; END IF;            -- glob-suffix / regex / NOT
    PERFORM witness::tsquery;                               -- stopword-emptied '()' raises ⇒ NULL
    RETURN proxquery.ts_prox_query(query, cfg);             -- the index selection, gated
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$fn$;

-- 3-arg consolidated search (config-aware) — the one-call form to use for a column built
-- with a non-`simple` config, in place of the explicit two clauses. Same inlinable shape as
-- the 2-arg `ts_prox_search`, so it index-serves via `@@ ts_prox_query(q, cfg)`, and for a
-- recheck-droppable (boolean / phrase / prefix) constant query the
-- `(ts_prox_query_exact(q, cfg) IS NOT NULL OR …)` const-folds away, dropping the per-row
-- recheck (and its re-detoast) — the resolved-lexeme skeleton is exactly the match.
-- within/pre and the lossy shapes keep the recheck. (A generic-plan bind parameter keeps it
-- too — still correct, just not folded.)
CREATE OR REPLACE FUNCTION ts_prox_search(v tsvector, query text, cfg regconfig) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$fn$ SELECT v @@ proxquery.ts_prox_query(query, cfg)
         AND (proxquery.ts_prox_query_exact(query, cfg) IS NOT NULL
              OR proxquery.ts_prox_recheck(v, query, cfg)) $fn$;

-- NOTE: no `@~@` operator (neither the 2-arg nor the `proxquery(cfg, q)` overload).
-- The native extension's single indexable operator needs a C planner support
-- function that cannot be written in SQL; a SQL-only look-alike would silently
-- seq-scan every query. So proximity queries here are always written as the two
-- index-served clauses (the same plan the operator expands to under the extension):
--     WHERE tsv @@ proxquery.ts_prox_query(q [,cfg]) AND proxquery.ts_prox_recheck(tsv, q [,cfg])
-- For the best plan on boolean / phrase / prefix queries, wrap the recheck so it folds
-- away when unnecessary (see `ts_prox_query_exact` above) — never worse, often far faster:
--     WHERE tsv @@ proxquery.ts_prox_query(q [,cfg])
--       AND (proxquery.ts_prox_query_exact(q [,cfg]) IS NOT NULL
--            OR proxquery.ts_prox_recheck(tsv, q [,cfg]))
-- `ts_prox_search(tsv, q [,cfg])` is that exact form in one inlinable call — the 2-arg
-- (`simple`) and 3-arg (config-aware) overloads both fold the recheck:
--     WHERE proxquery.ts_prox_search(tsv, q [,cfg])

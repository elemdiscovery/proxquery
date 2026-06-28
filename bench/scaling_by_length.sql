-- How the pure-SQL port and the native extension recheck scale with document length.
--
-- This is the focused companion to pure_vs_extension.sql: instead of one corpus
-- and several query shapes, it fixes ONE query (`a <~3> b <~3> c`) and sweeps the
-- document length, so the only thing that changes between rows is how many
-- lexemes the recheck has to wade through per document.
--
-- What it measures, and how it is set up:
--   We time each implementation's per-document *recheck* — the positional evaluation it
--   runs on a candidate row — over a sweep of document lengths. The extension reads
--   positions with a binary search over the tsvector's sorted lexemes (query parsed once
--   per scan); the pure port reads them with `unnest(tsvector)` (sql/proxquery_pure.sql
--   `ts_prox_positions`).
--   The query is CHAINED (`a <~3> b <~3> c`) on purpose: a single bounded proximity
--   (`a <~3> b`) lowers to a native `tsquery`, so the pure port's recheck short-circuits to
--   a C `@@` and never walks `unnest`. A chained proximity is not native-expressible, so
--   both ports run their real positional recheck.
--   The query is embedded as a LITERAL (the recommended form), so it is parsed once per
--   scan rather than re-parsed per row — that re-parse is a fixed per-row cost independent
--   of document length, so it is kept out of the per-document work under test.
--   Detoast is kept out too: once a tsvector grows past ~2 KB it is stored out-of-line in
--   TOAST, so a recheck reading straight from the heap first pays to detoast it — a cost
--   both ports pay equally, large and machine-dependent. To time the recheck and not the
--   storage layer, we load each length's tsvectors into an in-memory array ONCE (detoasting
--   them once) and run the rechecks over that. Same inputs and call count for both ports.
--
-- The table reports avg ms/query for each implementation, their ratio (`slowdown`), and a
-- growth table that normalizes each column to its shortest-length value so the per-column
-- rate is explicit. Numbers vary by machine — read the table and draw your own conclusion.
--
-- A per-length `disagree` column (extension vs pure recheck, over every doc) must
-- be 0 — this is what makes the sweep a real CI test (timings are a smoke signal,
-- correctness is not). Numbers vary by machine; the SHAPE is the point.
--
-- Run from the repo root (so the \i path resolves):
--   cargo pgrx run pg17 proxquery < bench/scaling_by_length.sql
-- or with plain psql (tunable):
--   psql -d DB -v sdocs=4000 -v svocab=20000 -v iters=10 -f bench/scaling_by_length.sql

\set ON_ERROR_STOP on
\timing off
SET max_parallel_workers_per_gather = 0;   -- stable, comparable timing
SET jit = off;

-- defaults (override any with -v on the psql command line)
\if :{?pure}   \else \set pure 'sql/proxquery_pure.sql' \endif
\if :{?sdocs}  \else \set sdocs 2000  \endif
\if :{?svocab} \else \set svocab 20000 \endif
\if :{?iters}  \else \set iters 5     \endif

-- native extension into public (fresh, in case a stale version lingers)
DROP EXTENSION IF EXISTS proxquery CASCADE;
CREATE EXTENSION proxquery;
-- pure-SQL port into the proxquery schema; restore a path that sees both schemas.
\i :pure
SET search_path = public, proxquery, pg_catalog;

-- hand the sweep parameters to the server-side DO block below.
SELECT set_config('sb.docs',  :'sdocs',  false),
       set_config('sb.vocab', :'svocab', false),
       set_config('sb.iters', :'iters',  false);

-- Recheck timer: load the current `scorpus` tsvectors into memory ONCE (so detoast is
-- paid once, not per call), then time `iters` set-based passes of each implementation's
-- recheck over them. The query `q` is embedded as a LITERAL (format %L) so the planner
-- parses it once per pass and const-folds it (the recommended usage), keeping the fixed
-- per-row DSL re-parse out of the measured per-document work. `floor_ms` is the same pass
-- doing only a trivial in-memory touch (length()) — the scan/overhead baseline. Same
-- inputs and call counts for both ports.
CREATE OR REPLACE FUNCTION scale_recheck(
    iters int, q text,
    OUT floor_ms numeric, OUT ext_ms numeric, OUT pure_ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    vs tsvector[]; t0 timestamptz; t1 timestamptz; i int; s bigint;
    ext_sql  text := format('SELECT count(*) FROM unnest($1) AS u(v) WHERE public.ts_prox_recheck(v, %L)', q);
    pure_sql text := format('SELECT count(*) FROM unnest($1) AS u(v) WHERE proxquery.ts_prox_recheck(v, %L)', q);
BEGIN
    EXECUTE 'SELECT array_agg(body_tsv) FROM scorpus' INTO vs;   -- detoast ONCE, into memory
    EXECUTE ext_sql USING vs INTO s;    -- warm (compile + prime caches)
    EXECUTE pure_sql USING vs INTO s;

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP EXECUTE 'SELECT sum(length(v)) FROM unnest($1) AS u(v)' USING vs INTO s; END LOOP;
    t1 := clock_timestamp();
    floor_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 2);

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP EXECUTE ext_sql USING vs INTO s; END LOOP;
    t1 := clock_timestamp();
    ext_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP EXECUTE pure_sql USING vs INTO s; END LOOP;
    t1 := clock_timestamp();
    pure_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);
END $$;

DROP TABLE IF EXISTS scale_results;
CREATE TEMP TABLE scale_results(
  wlen int, lex numeric, docs bigint, matches bigint,
  floor_ms numeric, ext_ms numeric, pure_ms numeric, slowdown numeric, disagree bigint);

-- Sweep the lengths. For each, build a fresh corpus, then time the recheck of the
-- same query (`a <~3> b <~3> c`) against both implementations over the same in-memory
-- tsvectors. No index / ANALYZE: the recheck runs on every doc (that IS the
-- per-candidate cost we are isolating), so an index scan would add nothing but the
-- detoast noise we are deliberately excluding.
DO $run$
DECLARE
  sizes int[] := ARRAY[32, 128, 512, 2048];   -- tokens per doc (64x span)
  ndocs int   := current_setting('sb.docs')::int;
  vocab int   := current_setting('sb.vocab')::int;
  it    int   := current_setting('sb.iters')::int;
  q     text  := 'a <~3> b <~3> c';
  wl    int;
  lex   numeric; ndoc bigint; matc bigint; dis bigint;
  tm    record;
BEGIN
  FOREACH wl IN ARRAY sizes LOOP
    EXECUTE 'DROP TABLE IF EXISTS scorpus';
    EXECUTE 'CREATE TABLE scorpus(id serial PRIMARY KEY, body_tsv tsvector)';
    -- Each doc is the chain's three terms `a b c` (adjacent, so the chain matches),
    -- then wl-3 filler words from a `vocab`-word vocabulary — so the DISTINCT lexeme
    -- count per doc tracks the length, which is exactly what the pure port's `unnest`
    -- recheck has to walk. The random draws live in a fenced (OFFSET 0) subquery so
    -- they are evaluated per token, not hoisted to a run-once InitPlan that would make
    -- every doc identical.
    PERFORM setseed(0.42);
    EXECUTE format($q$
      INSERT INTO scorpus(body_tsv)
      SELECT to_tsvector('simple', 'a b c ' || string_agg(tok, ' '))
      FROM (SELECT d, 'w' || floor(random() * %s)::int AS tok
            FROM generate_series(1, %s) d CROSS JOIN generate_series(1, %s) w
            OFFSET 0) s
      GROUP BY d
    $q$, vocab, ndocs, wl - 3);

    SELECT round(avg(length(body_tsv)), 1), count(*) INTO lex, ndoc FROM scorpus;
    -- matches and parity are correctness checks (untimed): the two rechecks must
    -- return the same boolean for every doc.
    EXECUTE format('SELECT count(*) FILTER (WHERE public.ts_prox_recheck(body_tsv, %L)),'
                || ' count(*) FILTER (WHERE public.ts_prox_recheck(body_tsv, %L)'
                || ' IS DISTINCT FROM proxquery.ts_prox_recheck(body_tsv, %L)) FROM scorpus',
                   q, q, q)
      INTO matc, dis;

    SELECT * INTO tm FROM scale_recheck(it, q);

    INSERT INTO scale_results(wlen, lex, docs, matches, floor_ms, ext_ms, pure_ms, slowdown, disagree)
    VALUES (wl, lex, ndoc, matc, tm.floor_ms, tm.ext_ms, tm.pure_ms,
            round(tm.pure_ms / nullif(tm.ext_ms, 0), 1), dis);
  END LOOP;
  EXECUTE 'DROP TABLE IF EXISTS scorpus';
END
$run$;

\echo ''
\echo '== scaling: pure vs extension recheck by text length (avg ms over all docs; disagree must be 0) =='
\echo '-- one chained, non-native query (a <~3> b <~3> c) rechecked over every doc, timed on'
\echo '-- in-memory tsvectors (detoast excluded), as document length grows.'
SELECT wlen          AS tokens_per_doc,
       round(lex)    AS lexemes_per_doc,
       docs,
       matches,
       ext_ms,
       pure_ms,
       slowdown,
       disagree
FROM scale_results ORDER BY wlen;

\echo ''
\echo '== scaling: growth vs shortest length (each column / its shortest-doc value) =='
\echo '-- each column divided by its shortest-doc value, so the per-column growth rate is explicit.'
WITH base AS (SELECT ext_ms AS e0, pure_ms AS p0 FROM scale_results ORDER BY wlen LIMIT 1)
SELECT r.wlen                                AS tokens_per_doc,
       round(r.ext_ms  / nullif(b.e0, 0), 1) AS ext_growth_x,
       round(r.pure_ms / nullif(b.p0, 0), 1) AS pure_growth_x
FROM scale_results r, base b ORDER BY r.wlen;

-- Parity gate: at every length the two rechecks must agree on every doc. This is
-- what makes the sweep a CI test, not just a timing.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM scale_results WHERE disagree <> 0;
    IF n > 0 THEN
        RAISE EXCEPTION 'parity mismatch: pure port and extension disagree at % length(s)', n;
    END IF;
    RAISE NOTICE 'parity: pure port and extension agree at all % lengths', (SELECT count(*) FROM scale_results);
END $$;

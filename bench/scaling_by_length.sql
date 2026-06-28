-- How the pure-SQL port and the native extension recheck scale with document length.
--
-- This is the focused companion to pure_vs_extension.sql: instead of one corpus
-- and several query shapes, it fixes ONE query (`a <~3> b`) and sweeps the
-- document length, so the only thing that changes between rows is how many
-- lexemes the recheck has to wade through per document.
--
-- What it measures, and why it measures it THIS way:
--   The thing we want to compare is the per-document *recheck* — the positional
--   evaluation each implementation runs on a candidate row:
--     * native extension : positions read with an O(log L) binary search over the
--       tsvector, no per-row query re-parse.
--     * pure-SQL port     : positions read with `unnest(tsvector)` — O(L) in the
--       lexemes per doc (sql/proxquery_pure.sql `ts_prox_positions`) — and the
--       query AST re-parsed (jsonb) on every call.
--   Run as a normal indexed query, that signal is swamped by something both
--   implementations pay equally: once a tsvector grows past ~2 KB it is stored
--   out-of-line in TOAST, so every recheck first pays an O(L) detoast. That
--   detoast floor is large, machine-dependent (a cold/contended runner pays far
--   more for an out-of-line fetch), and identical for both ports — so on a shared
--   CI runner it can dominate the extension's tiny real cost and even invert the
--   comparison. To compare the implementations and not the storage layer, we load
--   each length's tsvectors into memory ONCE (detoast once) and time the recheck
--   functions directly over them. Same inputs, same call count; the only variable
--   left is the recheck algorithm.
--
-- `slowdown` (pure_ms / ext_ms) should climb with length; the growth table that
-- follows normalizes each column to its shortest-length value so the *rate* is
-- explicit — ext_growth stays near flat, pure_growth rises with length.
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

-- Recheck timer: load the current `scorpus` tsvectors into memory ONCE (so the
-- O(L) detoast is paid once, not per call), then time `iters` full passes of each
-- implementation's recheck over them. `floor_ms` is the same pass doing only a
-- trivial in-memory touch (length()) — the loop/overhead baseline the rechecks
-- sit on top of. Inputs and call counts are identical across the two ports.
CREATE OR REPLACE FUNCTION scale_recheck(
    iters int, q text,
    OUT floor_ms numeric, OUT ext_ms numeric, OUT pure_ms numeric)
LANGUAGE plpgsql AS $$
DECLARE vs tsvector[]; v tsvector; t0 timestamptz; t1 timestamptz; i int; s bigint;
BEGIN
    EXECUTE 'SELECT array_agg(body_tsv) FROM scorpus' INTO vs;   -- detoast ONCE, into memory
    -- warm both rechecks (compile cached plans) before timing anything.
    FOREACH v IN ARRAY vs LOOP
        PERFORM public.ts_prox_match(v, q);
        PERFORM proxquery.ts_prox_match(v, q);
    END LOOP;

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP s := 0; FOREACH v IN ARRAY vs LOOP s := s + length(v); END LOOP; END LOOP;
    t1 := clock_timestamp();
    floor_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 2);

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP FOREACH v IN ARRAY vs LOOP PERFORM public.ts_prox_match(v, q); END LOOP; END LOOP;
    t1 := clock_timestamp();
    ext_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);

    t0 := clock_timestamp();
    FOR i IN 1..iters LOOP FOREACH v IN ARRAY vs LOOP PERFORM proxquery.ts_prox_match(v, q); END LOOP; END LOOP;
    t1 := clock_timestamp();
    pure_ms := round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);
END $$;

DROP TABLE IF EXISTS scale_results;
CREATE TEMP TABLE scale_results(
  wlen int, lex numeric, docs bigint, matches bigint,
  floor_ms numeric, ext_ms numeric, pure_ms numeric, slowdown numeric, disagree bigint);

-- Sweep the lengths. For each, build a fresh corpus, then time the recheck of the
-- same query (`a <~3> b`) against both implementations over the same in-memory
-- tsvectors. No index / ANALYZE: the recheck runs on every doc (that IS the
-- per-candidate cost we are isolating), so an index scan would add nothing but the
-- detoast noise we are deliberately excluding.
DO $run$
DECLARE
  sizes int[] := ARRAY[32, 128, 512, 2048];   -- tokens per doc (64x span)
  ndocs int   := current_setting('sb.docs')::int;
  vocab int   := current_setting('sb.vocab')::int;
  it    int   := current_setting('sb.iters')::int;
  q     text  := 'a <~3> b';
  wl    int;
  lex   numeric; ndoc bigint; matc bigint; dis bigint;
  tm    record;
BEGIN
  FOREACH wl IN ARRAY sizes LOOP
    EXECUTE 'DROP TABLE IF EXISTS scorpus';
    EXECUTE 'CREATE TABLE scorpus(id serial PRIMARY KEY, body_tsv tsvector)';
    -- One `a` at a random slot, one `b` 1..8 slots later, the rest filler from a
    -- `vocab`-word vocabulary (so distinct lexemes per doc track the length, which
    -- is what drives the pure port's unnest cost). The random draws live in a
    -- fenced (OFFSET 0) subquery so they are evaluated per row, not hoisted to a
    -- run-once InitPlan that would make every doc identical.
    PERFORM setseed(0.42);
    EXECUTE format($q$
      INSERT INTO scorpus(body_tsv)
      SELECT to_tsvector('simple', string_agg(tok, ' ' ORDER BY w))
      FROM (
        SELECT dq.d, g.w,
               CASE WHEN g.w = dq.pa THEN 'a'
                    WHEN g.w = dq.pb THEN 'b'
                    ELSE 'w' || floor(random() * %s)::int END AS tok
        FROM (SELECT d, pa, pa + 1 + floor(random() * 8)::int AS pb
              FROM (SELECT gd AS d, 1 + floor(random() * (%s - 9))::int AS pa
                    FROM generate_series(1, %s) gd) p0) dq
        CROSS JOIN generate_series(1, %s) g(w)
        OFFSET 0
      ) s
      GROUP BY d
    $q$, vocab, wl, ndocs, wl);

    SELECT round(avg(length(body_tsv)), 1), count(*) INTO lex, ndoc FROM scorpus;
    -- matches and parity are correctness checks (untimed): the two rechecks must
    -- return the same boolean for every doc.
    EXECUTE format('SELECT count(*) FILTER (WHERE public.ts_prox_match(body_tsv, %L)),'
                || ' count(*) FILTER (WHERE public.ts_prox_match(body_tsv, %L)'
                || ' IS DISTINCT FROM proxquery.ts_prox_match(body_tsv, %L)) FROM scorpus',
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
\echo '-- recheck timed on in-memory tsvectors (detoast excluded), so the only variable'
\echo '-- is the algorithm: pure unnest O(L) + AST re-parse vs ext O(log L) binary search.'
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
\echo '-- ext_growth stays near flat (O(log L) lookup); pure_growth rises with length'
\echo '-- (O(L) unnest per recheck) — the pure port scales at a strictly worse rate.'
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

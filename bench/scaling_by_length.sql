-- How the pure-SQL port and the native extension scale with document length.
--
-- This is the focused companion to pure_vs_extension.sql: instead of one corpus
-- and several query shapes, it fixes ONE query (`a <~3> b`) and sweeps the
-- document length, so the only thing that changes between rows is how many
-- lexemes the recheck has to wade through per candidate.
--
-- Why the two implementations diverge with length:
--   * native extension : positions are read with an O(log L) binary search over
--     the tsvector, and the parsed query AST is cached once per scan.
--   * pure-SQL port     : positions are read with `unnest(tsvector)` — O(L) in
--     the number of lexemes per call (sql/proxquery_pure.sql `ts_prox_positions`),
--     and the AST is re-parsed per row. So the per-candidate recheck cost grows
--     ~linearly with document length while the extension's stays ~flat.
--
-- To isolate that effect the corpus holds the CANDIDATE COUNT constant: every doc
-- gets exactly one `a` and one `b` (so `a & b` — the index skeleton — selects all
-- :sdocs docs at every length), with `b` placed 1..8 positions after `a` (so ~3/8
-- of docs actually satisfy `<~3>`, a non-trivial match set for the parity check).
-- The remaining slots are filler drawn from a large vocab, so the distinct-lexeme
-- count per doc tracks the target length. Same candidates, longer text → the only
-- moving part is the per-candidate position lookup.
--
-- `slowdown` (pure_ms / ext_ms) should climb with length; the growth table that
-- follows normalizes each column to its shortest-length value so the *rate* is
-- explicit — ext_growth stays near flat, pure_growth rises with length.
--
-- A per-length `disagree` column (extension vs pure row-set EXCEPT) must be 0 —
-- this is what makes the sweep a real CI test (timings on a shared runner are
-- noise; correctness is not). Numbers vary by machine; the SHAPE is the point.
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

-- avg server-side ms over `iters` runs, after a warmup (same harness as the siblings).
CREATE OR REPLACE FUNCTION bench_ms(q text, iters int) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; t1 timestamptz; i int; sink bigint;
BEGIN
  EXECUTE q INTO sink;                        -- warmup (and prime caches)
  t0 := clock_timestamp();
  FOR i IN 1..iters LOOP EXECUTE q INTO sink; END LOOP;
  t1 := clock_timestamp();
  RETURN round(extract(epoch FROM (t1 - t0)) * 1000.0 / iters, 1);
END $$;

DROP TABLE IF EXISTS scale_results;
CREATE TEMP TABLE scale_results(
  wlen int, lex numeric, candidates bigint, matches bigint,
  ext_ms numeric, pure_ms numeric, slowdown numeric, disagree bigint);

-- Sweep the lengths. For each, build a fresh corpus, time the same query against
-- both implementations, and record the row. The DSL is a constant (`a <~3> b`),
-- so the recheck does the same two position lookups every time — only the lexeme
-- count they scan changes.
DO $run$
DECLARE
  sizes int[] := ARRAY[32, 128, 512, 2048];   -- tokens per doc (64x span)
  ndocs int   := current_setting('sb.docs')::int;
  vocab int   := current_setting('sb.vocab')::int;
  it    int   := current_setting('sb.iters')::int;
  q     text  := 'a <~3> b';
  wl    int;
  lex   numeric; cand bigint; matc bigint; dis bigint;
  ex    numeric; pu numeric;
BEGIN
  FOREACH wl IN ARRAY sizes LOOP
    EXECUTE 'DROP TABLE IF EXISTS scorpus';
    EXECUTE 'CREATE TABLE scorpus(id serial PRIMARY KEY, body_tsv tsvector)';
    -- One `a` at a random slot, one `b` 1..8 slots later, the rest filler from a
    -- `vocab`-word vocabulary (so distinct lexemes per doc track the length). The
    -- random draws live in a fenced (OFFSET 0) subquery so they are evaluated per
    -- row, not hoisted to a run-once InitPlan that would make every doc identical.
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
    EXECUTE 'CREATE INDEX scorpus_gin ON scorpus USING gin(body_tsv)';
    EXECUTE 'ANALYZE scorpus';

    SELECT round(avg(length(body_tsv)), 1) INTO lex FROM scorpus;
    EXECUTE format('SELECT count(*) FROM scorpus WHERE body_tsv @@ public.ts_prox_query(%L)', q) INTO cand;
    EXECUTE format('SELECT count(*) FROM scorpus WHERE body_tsv @~@ %L', q) INTO matc;

    ex := bench_ms(format('SELECT count(*) FROM scorpus WHERE body_tsv @@ public.ts_prox_query(%L) AND public.ts_prox_match(body_tsv, %L)', q, q), it);
    pu := bench_ms(format('SELECT count(*) FROM scorpus WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv, %L)', q, q), it);

    EXECUTE format($p$
      SELECT count(*) FROM (
        (SELECT id FROM scorpus WHERE body_tsv @~@ %L
         EXCEPT SELECT id FROM scorpus WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv, %L))
        UNION ALL
        (SELECT id FROM scorpus WHERE body_tsv @@ proxquery.ts_prox_query(%L) AND proxquery.ts_prox_match(body_tsv, %L)
         EXCEPT SELECT id FROM scorpus WHERE body_tsv @~@ %L)
      ) d $p$, q, q, q, q, q, q)
      INTO dis;

    INSERT INTO scale_results(wlen, lex, candidates, matches, ext_ms, pure_ms, slowdown, disagree)
    VALUES (wl, lex, cand, matc, ex, pu, round(pu / nullif(ex, 0), 1), dis);
  END LOOP;
  EXECUTE 'DROP TABLE IF EXISTS scorpus';
END
$run$;

\echo ''
\echo '== scaling: pure vs extension by text length (avg ms/query; disagree must be 0) =='
\echo '-- candidates is held constant; only lexemes_per_doc grows, so the timing'
\echo '-- delta is purely the per-candidate recheck cost (pure unnest O(L) vs ext O(log L)).'
SELECT wlen          AS tokens_per_doc,
       round(lex)    AS lexemes_per_doc,
       candidates,
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

-- Parity gate: at every length the pure port and the extension must select the
-- identical row set. This is what makes the sweep a CI test, not just a timing.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM scale_results WHERE disagree <> 0;
    IF n > 0 THEN
        RAISE EXCEPTION 'parity mismatch: pure port and extension disagree at % length(s)', n;
    END IF;
    RAISE NOTICE 'parity: pure port and extension agree at all % lengths', (SELECT count(*) FROM scale_results);
END $$;

-- Shared include: build the deterministic e-discovery-style query list.
-- Included by large_bench.sql and inspect.sql. Requires vocab + topic_lut (\i
-- _vocab.sql first). Built with its own seed, before the corpus, so the list is
-- independent of corpus size and identical across tiers.
--
-- Proximity shapes draw their terms from a single shared TOPIC, so they line up
-- with the corpus's topic segments and short-radius windows actually match.
-- Boolean / single / bare-wildcard shapes draw globally by frequency rank.
-- `phraseprox` (a phrase span inside a proximity) and `hardwild` (a suffix/infix/
-- regex term that can't pre-filter the index) are deliberately NON-native: they
-- don't lower to a plain tsquery, so they exercise the real positional/pattern
-- recheck — the regime where the pure port can't use its native fast-path.
--
-- Machine independence: PostgreSQL's setseed()/random() use PG's built-in PRNG
-- (since PG 15), not libc, and the samplers use only multiply/floor (no exp/ln/
-- pow), so the list is identical across machines/OS for a given PG major.
-- (inspect.sh prints a fingerprint you can compare across hosts.)
--
-- Params (\set, with defaults): qseed, nqueries, termlo, termhi, dist_min, dist_max

\if :{?qseed}
\else
  \set qseed 0.137
\endif
\if :{?nqueries}
\else
  \set nqueries 200
\endif
\if :{?termlo}
\else
  \set termlo 30
\endif
\if :{?termhi}
\else
  \set termhi 4000
\endif
\if :{?dist_min}
\else
  \set dist_min 2
\endif
\if :{?dist_max}
\else
  \set dist_max 15
\endif
\if :{?query_topn}
\else
  \set query_topn 8
\endif

-- Global term by frequency rank, skewed toward common words via u*u (median rank
-- ~1/4 of the band). Skips the top stopwords and the rare tail.
CREATE OR REPLACE FUNCTION pick_term(lo int, hi int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE u float8 := random(); k int;
BEGIN
  k := lo + floor((hi - lo) * u * u)::int;
  RETURN (SELECT word FROM vocab WHERE id = k);
END $$;

-- A topic in [1, k]; and `cnt` DISTINCT words (no replacement) drawn from that
-- topic's `topn` most common HEAD words. Restricting to the topic's common, real
-- words keeps a proximity query's terms reliably co-present in the topic's
-- documents (so the query has candidates), while the corpus's topic segments keep
-- them positionally close (so a short window matches).
CREATE OR REPLACE FUNCTION pick_topic(k int) RETURNS int
LANGUAGE sql AS $$ SELECT 1 + floor(random() * k)::int $$;
CREATE OR REPLACE FUNCTION pick_topic_terms(t int, topn int, cnt int) RETURNS text[]
LANGUAGE sql AS $$
  SELECT array_agg(word) FROM (
    SELECT word FROM (
      SELECT word FROM vocab
      WHERE topic = t AND id <= current_setting('lb.head_n')::int
      ORDER BY weight DESC, id LIMIT topn
    ) top
    ORDER BY random() LIMIT cnt                 -- distinct rows => distinct terms
  ) s
$$;

-- `cnt` DISTINCT global terms (no replacement), drawn by frequency rank with the
-- same u*u skew toward common words as pick_term, via rejection on repeats.
CREATE OR REPLACE FUNCTION pick_global_terms(lo int, hi int, cnt int) RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE ids int[] := '{}'; u float8; k int;
BEGIN
  WHILE coalesce(array_length(ids, 1), 0) < cnt LOOP
    u := random();
    k := lo + floor((hi - lo) * u * u)::int;
    IF NOT (k = ANY(ids)) THEN ids := ids || k; END IF;
  END LOOP;
  RETURN (SELECT array_agg(v.word ORDER BY o.ord)
          FROM unnest(ids) WITH ORDINALITY AS o(id, ord)
          JOIN vocab v ON v.id = o.id);
END $$;

-- Proximity distance in [lo, hi]. With topic segments these can be short.
CREATE OR REPLACE FUNCTION pick_dist(lo int, hi int) RETURNS int
LANGUAGE sql AS $$ SELECT lo + floor(random() * (hi - lo + 1))::int FROM (SELECT random() AS r) s $$;

-- Prefix wildcard by truncation: drop 1..3 trailing chars (>= 3-char stem). The
-- COCA head is lemmas (no inflected forms), so a truncating wildcard is how a
-- term catches its variants — e.g. manag* -> manage/manager/management.
CREATE OR REPLACE FUNCTION wild(w text) RETURNS text
LANGUAGE sql AS $$ SELECT substr(w, 1, GREATEST(3, length(w) - (1 + floor(random()*3))::int)) || '*' $$;

-- A NON-indexable / non-native wildcard built from a term, to exercise the recheck's
-- pattern path. Suffix (`*tion`) and regex (`##capac.*##`) can't pre-filter the GIN
-- index at all, infix (`ap*n`) only via its short prefix, and none of the three lower
-- to a native tsquery -- so the pure port can't take its fast-path and runs the full
-- positional/pattern scan. Callers pair it with a plain term that carries the index
-- (e.g. `*tion <~3> study`), per the README's "you need a second term" guidance.
-- The regex is a real `.*` PATTERN, not a metachar-free `##term##` (which would just
-- match the one lexeme `term` -- a term search done the expensive way -- and never
-- exercise the regex engine over multiple forms).
CREATE OR REPLACE FUNCTION hard_wild(w text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r float8 := random(); k int := LEAST(4, GREATEST(2, length(w) - 2));
BEGIN
  IF    r < 0.34 THEN RETURN '*' || right(w, k);                            -- suffix: application -> *tion
  ELSIF r < 0.67 THEN RETURN left(w, 2) || '*' || right(w, 1);             -- infix:  application -> ap*n
  ELSE  RETURN '##' || substr(w, 1, GREATEST(3, length(w) - 3)) || '.*##'; -- regex:  capacity -> ##capac.*##
  END IF;
END $$;

DROP TABLE IF EXISTS queries;
CREATE TABLE queries(id serial PRIMARY KEY, shape text, q text);

SET lb.nqueries   = :nqueries;
SET lb.termlo     = :termlo;
SET lb.termhi     = :termhi;
SET lb.dist_min   = :dist_min;
SET lb.dist_max   = :dist_max;
SET lb.query_topn = :query_topn;
SET lb.n_topics   = :n_topics;      -- exported by _vocab.sql
SET lb.head_n     = :head_n;        -- exported by _vocab.sql

SELECT setseed(:qseed) AS _ \gset
DO $bq$
DECLARE
  nq  int := current_setting('lb.nqueries')::int;
  tl  int := current_setting('lb.termlo')::int;
  th  int := current_setting('lb.termhi')::int;
  dlo int := current_setting('lb.dist_min')::int;
  dhi int := current_setting('lb.dist_max')::int;
  kt  int := current_setting('lb.n_topics')::int;
  tn  int := current_setting('lb.query_topn')::int;
  i int; rr float8; shape text; q text; tk int;
  g text[]; t text[]; n int; n2 int; n3 int;   -- distinct global / topic term sets
BEGIN
  FOR i IN 1..nq LOOP
    rr := random();
    tk := pick_topic(kt);                 -- a shared topic for proximity shapes
    IF    rr < 0.06 THEN shape := 'single';    q := pick_term(tl,th);
    ELSIF rr < 0.16 THEN shape := 'and2';      g := pick_global_terms(tl,th,2); q := g[1]||' & '||g[2];
    ELSIF rr < 0.22 THEN shape := 'and3';      g := pick_global_terms(tl,th,3); q := g[1]||' & '||g[2]||' & '||g[3];
    ELSIF rr < 0.28 THEN shape := 'or2';       g := pick_global_terms(tl,th,2); q := g[1]||' | '||g[2];
    ELSIF rr < 0.40 THEN shape := 'within';    t := pick_topic_terms(tk,tn,2); n := pick_dist(dlo,dhi);
                                               q := t[1]||' <~'||n||'> '||t[2];
    ELSIF rr < 0.46 THEN shape := 'ordered';   t := pick_topic_terms(tk,tn,2); n := pick_dist(dlo,dhi);
                                               q := t[1]||' <-'||n||'> '||t[2];
    ELSIF rr < 0.52 THEN shape := 'phrase';    -- adjacent-word phrase, 2 or 3 distinct words from one topic
                         IF random() < 0.5 THEN t := pick_topic_terms(tk,tn,2); q := '"'||t[1]||' '||t[2]||'"';
                         ELSE t := pick_topic_terms(tk,tn,3); q := '"'||t[1]||' '||t[2]||' '||t[3]||'"'; END IF;
    ELSIF rr < 0.60 THEN shape := 'phraseprox';-- a phrase span as a proximity operand (non-native: no fast-path)
                         t := pick_topic_terms(tk,tn,3); n := pick_dist(dlo,dhi);
                         q := '"'||t[1]||' '||t[2]||'" <~'||n||'> '||t[3];
    ELSIF rr < 0.68 THEN shape := 'chain3';    t := pick_topic_terms(tk,tn,3); n := pick_dist(dlo,dhi); n2 := pick_dist(dlo,dhi);
                                               q := t[1]||' <~'||n||'> '||t[2]||' <~'||n2||'> '||t[3];
    ELSIF rr < 0.74 THEN shape := 'chain4';    t := pick_topic_terms(tk,tn,4); n := pick_dist(dlo,dhi); n2 := pick_dist(dlo,dhi); n3 := pick_dist(dlo,dhi);
                                               q := t[1]||' <~'||n||'> '||t[2]||' <~'||n2||'> '||t[3]||' <~'||n3||'> '||t[4];
    ELSIF rr < 0.80 THEN shape := 'notwithin'; t := pick_topic_terms(tk,tn,2); n := pick_dist(dlo,dhi);
                                               q := t[1]||' <!~'||n||'> '||t[2];
    ELSIF rr < 0.86 THEN shape := 'wildcard';  q := wild(pick_term(tl,th));
    ELSIF rr < 0.92 THEN shape := 'wildprox';  t := pick_topic_terms(tk,tn,2); n := pick_dist(dlo,dhi);
                                               q := t[1]||' <~'||n||'> '||wild(t[2]);
    ELSE                 shape := 'hardwild';  -- non-indexable/non-native term (suffix/infix/regex) on the LEFT;
                         t := pick_topic_terms(tk,tn,2); n := pick_dist(dlo,dhi);  -- t[2] carries the GIN scan
                         q := hard_wild(t[1])||' <~'||n||'> '||t[2];
    END IF;
    INSERT INTO queries(shape, q) VALUES (shape, q);
  END LOOP;
END $bq$;

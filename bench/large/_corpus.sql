-- Shared include: generate the deterministic, topic-segmented corpus (the TABLE
-- only — no index). Callers build their own index, so large_bench.sql can create
-- and compare each index AM (GIN vs RUM) on identical corpus bytes, and inspect.sql
-- can pick whatever index it needs. Included by large_bench.sql and inspect.sql.
-- Requires vocab + topic_lut and the psql vars exported by _vocab.sql (bg_rate,
-- n_topics, seg_buckets). Run from the repo ROOT (the \copy path is repo-relative).
--
-- Each document is a sequence of fixed-length topic SEGMENTS (segment_len tokens).
-- A segment's topic is a deterministic hash of (doc, segment index), so a run of
-- consecutive positions shares a topic and its words cluster locally. Each token
-- is either a background/stopword draw (probability bg_rate) or a content draw
-- from the segment's topic. string_agg is ORDER BY position so tsvector positions
-- follow the segment layout — that is what makes short-radius proximity hit.
--
-- Params (\set, with defaults): seed, target_mb, batch_docs, max_doc_len, segment_len

\if :{?seed}
\else
  \set seed 0.42
\endif
\if :{?target_mb}
\else
  \set target_mb 1024
\endif
\if :{?batch_docs}
\else
  \set batch_docs 2500
\endif
\if :{?max_doc_len}
\else
  \set max_doc_len 16000
\endif
\if :{?segment_len}
\else
  \set segment_len 12
\endif

DROP TABLE IF EXISTS doc_sizes;
CREATE TABLE doc_sizes(lo int, hi int, weight float8);
\copy doc_sizes FROM 'bench/large/doc_sizes.csv' WITH (FORMAT csv, HEADER true)
-- tsvector keeps at most 16383 positions per lexeme; clamp lengths so we never
-- silently drop positions (which would quietly distort proximity on huge docs).
UPDATE doc_sizes SET lo = LEAST(lo, :max_doc_len), hi = LEAST(hi, :max_doc_len);
DELETE FROM doc_sizes WHERE lo >= hi;

CREATE OR REPLACE FUNCTION sample_doc_len() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r float8 := random(); lo_ int; hi_ int;
BEGIN
  SELECT d.lo, d.hi INTO lo_, hi_
  FROM (SELECT lo, hi, sum(weight) OVER (ORDER BY lo) / (SELECT sum(weight) FROM doc_sizes) AS cw
        FROM doc_sizes) d
  WHERE d.cw >= r
  ORDER BY d.cw
  LIMIT 1;
  RETURN lo_ + floor(random() * (hi_ - lo_ + 1))::int;
END $$;

-- topic of segment `seg` in document `doc`: a deterministic integer hash over
-- [1, k]. No random() (so the topic skeleton is independent of RNG ordering) and
-- no PG hash function (so it is stable across PG versions and platforms).
CREATE OR REPLACE FUNCTION seg_topic(doc bigint, seg int, k int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT 1 + (((h # (h >> 13)) % 4294967296) % k)::int
  FROM (SELECT ((((doc << 20) | seg) % 2147483647) * 2654435761) % 4294967296 AS h) s
$$;

DROP TABLE IF EXISTS corpus;
CREATE TABLE corpus(id bigserial PRIMARY KEY, body_tsv tsvector);

SELECT setseed(:seed) AS _ \gset

SET lb.target_mb    = :target_mb;
SET lb.batch_docs   = :batch_docs;
SET lb.segment_len  = :segment_len;
SET lb.n_topics     = :n_topics;
SET lb.seg_buckets  = :seg_buckets;
SET lb.bg_rate      = :bg_rate;

\echo ''
\echo '== generating corpus (topic-segmented) =='
DO $gen$
DECLARE
  target  bigint := current_setting('lb.target_mb')::bigint * 1024 * 1024;
  bdocs   int    := current_setting('lb.batch_docs')::int;
  seglen  int    := current_setting('lb.segment_len')::int;
  ktopics int    := current_setting('lb.n_topics')::int;
  mbuck   int    := current_setting('lb.seg_buckets')::int;
  bgrate  float8 := current_setting('lb.bg_rate')::float8;
  sz      bigint := 0;
  ndocs   bigint := 0;
  batches int    := 0;
BEGIN
  LOOP
    -- One batch: bdocs docs. For each position, decide background vs content,
    -- pick a bucket, and look up the word in the segment's topic. OFFSET 0 fences
    -- the subquery so random() is evaluated once per token (not hoisted).
    INSERT INTO corpus(body_tsv)
    SELECT to_tsvector('simple', string_agg(lut.word, ' ' ORDER BY toks.pos))
    FROM (
      SELECT t.docno, p.pos,
             CASE WHEN random() < bgrate THEN 0
                  ELSE seg_topic(t.docno, (p.pos / seglen), ktopics) END AS topic,
             floor(random() * mbuck)::int AS bucket
      FROM (SELECT gg AS docno, sample_doc_len() AS len
            FROM generate_series(1, bdocs) gg) t,
           LATERAL generate_series(0, t.len - 1) AS p(pos)
      OFFSET 0
    ) toks
    JOIN topic_lut lut ON lut.topic = toks.topic AND lut.bucket = toks.bucket
    GROUP BY toks.docno;

    batches := batches + 1;
    ndocs   := ndocs + bdocs;
    sz := pg_table_size('corpus');
    EXIT WHEN sz >= target;
  END LOOP;
  RAISE NOTICE 'generated % docs in % batches, table=%', ndocs, batches, pg_size_pretty(sz);
END $gen$;

-- Column stats only (no index yet) — index-independent, so it need not be redone
-- per AM when the caller builds GIN/RUM indexes afterwards.
ANALYZE corpus;

\echo ''
\echo '== corpus shape =='
-- Table size only; per-AM index sizes are reported separately by the caller
-- (large_bench.sql's "index size (by am)" section), since the index no longer
-- lives here.
SELECT count(*) AS docs,
       round(avg(length(body_tsv))) AS avg_lexemes,
       pg_size_pretty(pg_table_size('corpus'))          AS table_size
FROM corpus;

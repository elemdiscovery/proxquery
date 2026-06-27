-- Shared include: build the deterministic vocabulary, partition it into topics,
-- and build the per-topic sampling lookup table. Included by large_bench.sql and
-- inspect.sql. Run from the repo ROOT (the \copy path is repo-relative). Uses NO
-- random(), so it consumes no RNG state and is identical on every machine for a
-- given PostgreSQL major version.
--
-- Topic model (for positional locality): the top `n_stop` words are a global
-- BACKGROUND (stopwords, emitted everywhere); every other word is hard-assigned
-- to one of `n_topics` topics, round-robin by frequency rank so topics have
-- balanced mass and each gets a mix of common + rare terms. _corpus.sql emits
-- documents as runs of one topic at a time, so same-topic words cluster within a
-- few positions and short-radius proximity queries (terms drawn from one topic)
-- actually match. Because segment topics are chosen ~uniformly over the balanced
-- partition, the global term-frequency marginal is approximately preserved.
--
-- Params (\set, with defaults): tail_words, zipf_s, n_topics, n_stop, seg_buckets
-- Exports (psql vars via \gset): head_n, vocab_n, n_topics, seg_buckets, bg_rate

\if :{?tail_words}
\else
  \set tail_words 50000
\endif
\if :{?zipf_s}
\else
  \set zipf_s 1.3
\endif
\if :{?n_topics}
\else
  \set n_topics 300
\endif
\if :{?n_stop}
\else
  \set n_stop 150
\endif
\if :{?seg_buckets}
\else
  \set seg_buckets 4096
\endif

-- Real head: clean COCA lemmas (pure lowercase a-z), freq summed across PoS.
-- Synthetic tail: deterministic pseudo-random 5..30 char strings whose weights
-- continue the head's Zipf curve. The long tail of a real collection is mostly
-- junk tokens (ids, codes, OCR noise, foreign words), so random strings are a
-- fair stand-in, and keeping the head real keeps >80% of occurrences real.
DROP TABLE IF EXISTS coca;
CREATE TABLE coca(rank int, lemma text, pos text, freq bigint,
                  permil float8, pcaps float8, pallc float8, rng int, disp float8);
\copy coca FROM 'docs/wordfrequency.info-top-5000.txt' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

CREATE OR REPLACE FUNCTION synth_word(n bigint) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  m   constant bigint := 4294967296;            -- 2^32
  h   bigint := ((n + 1) * 2654435761) % m;     -- Knuth multiplicative hash
  len int;
  i   int;
  out text := '';
BEGIN
  h   := (h # (h >> 13)) % m;                    -- one xorshift mix
  len := 5 + (h % 26)::int;                       -- 5..30 inclusive
  FOR i IN 1..len LOOP
    h   := (h * 1103515245 + 12345) % m;          -- glibc LCG step
    out := out || chr(97 + (h % 26)::int);        -- 'a'..'z'
  END LOOP;
  RETURN out;
END $$;

-- vocab id == frequency rank (1 = most common); used by the query sampler too.
-- topic: 0 for the global background (top n_stop words), else a balanced
-- round-robin partition over n_topics (interleaving by rank keeps masses even).
DROP TABLE IF EXISTS vocab;
CREATE TABLE vocab(id serial PRIMARY KEY, word text, weight float8, topic int);

INSERT INTO vocab(word, weight)
SELECT word, sum(freq)::float8
FROM (SELECT lower(lemma) AS word, freq FROM coca WHERE lower(lemma) ~ '^[a-z]+$') c
GROUP BY word
ORDER BY 2 DESC;

SELECT count(*) AS head_n, min(weight) AS head_min FROM vocab \gset

INSERT INTO vocab(word, weight)
SELECT synth_word(:head_n + g),
       :head_min * power(:head_n::float8 / (:head_n + g), :zipf_s)
FROM generate_series(1, :tail_words) g;

UPDATE vocab SET topic = CASE WHEN id <= :n_stop THEN 0
                              ELSE 1 + ((id - :n_stop - 1) % :n_topics) END;

SELECT count(*) AS vocab_n FROM vocab \gset
-- background's share of total weight == fraction of tokens drawn from background
SELECT round((sum(weight) FILTER (WHERE topic = 0) / sum(weight))::numeric, 4) AS bg_rate
FROM vocab \gset

-- Per-topic inverse-CDF lookup: seg_buckets uniform buckets per topic, each mapped
-- to the topic's word whose cumulative within-topic weight covers it. Sampling a
-- token is a uniform integer draw + a hash join on (topic, bucket).
DROP TABLE IF EXISTS topic_lut;
CREATE TABLE topic_lut AS
SELECT topic, gs AS bucket, r.word
FROM (
  SELECT topic, word,
         floor(cum_lo * :seg_buckets)::int     AS b0,
         floor(cum_hi * :seg_buckets)::int - 1 AS b1
  FROM (SELECT topic, id, word,
               coalesce(lag(cum_hi) OVER (PARTITION BY topic ORDER BY id), 0.0) AS cum_lo,
               cum_hi
        FROM (SELECT topic, id, word,
                     sum(weight) OVER (PARTITION BY topic ORDER BY id)
                       / sum(weight) OVER (PARTITION BY topic) AS cum_hi
              FROM vocab) c) z
) r,
LATERAL generate_series(r.b0, r.b1) gs;
CREATE UNIQUE INDEX topic_lut_pk ON topic_lut(topic, bucket);

\echo ''
\echo '== vocabulary =='
SELECT :vocab_n AS vocab_n, :head_n AS real_words, :tail_words AS synth_words,
       :n_topics AS topics, :bg_rate AS bg_rate,
       (SELECT count(DISTINCT word) FROM topic_lut) AS terms_reachable,
       round((100.0 * (SELECT sum(weight) FROM vocab WHERE id <= :head_n)
                    / (SELECT sum(weight) FROM vocab))::numeric, 1) AS pct_occ_real;

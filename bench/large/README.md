# Large performance benchmark

A manually triggered, **repeatable** performance benchmark that builds a large
synthetic corpus and times the native `@~@` extension against the pure-SQL port.
It complements the small parity benchmark in [`../pure_vs_extension.sql`](../pure_vs_extension.sql):
that one is a fast per-PR smoke + parity gate; this one stress-tests at 100 MiB–2 GiB.

Trigger it from the Actions tab → **large benchmark** (`.github/workflows/benchmark.yml`),
or run it locally (see below). The report is written to `bench/reports/` (gitignored)
and uploaded as a workflow artifact / job summary.

## What it does

Two tiers, both generated from the same seeds so they are directly comparable:

| Tier  | Default size | Implementations            | Gate             |
| ----- | ------------ | -------------------------- | ---------------- |
| small | 100 MiB      | extension **and** pure-SQL | per-query parity |
| large | 1024 MiB     | extension only             | —                |

The pure-SQL port is ~30–60× slower, so running it on a multi-GiB corpus is not
practical; the small tier covers the head-to-head comparison + parity, and the
large tier shows how the extension alone scales.

Each tier's report includes a **phase-timing** table (wall seconds for setup /
corpus generation / searches) so you can see where the run's time actually went,
and writes **raw per-query timings** to `bench/reports/results_{small,large}.csv`
(both uploaded as the workflow artifact). `ext_search_ms` (the extension via the
consolidated `ts_prox_search`, ≈ identical to `ext_op_ms`) is only timed on the small
tier, where it is the denominator of the pure `slowdown` ratio.

## Repeatability

Everything is deterministic given the parameters:

- **Corpus**: `setseed(seed)` then a fixed sequence of `random()` draws. Runs are
  serial (`max_parallel_workers_per_gather = 0`) so the RNG order — and therefore
  the corpus — is reproducible.
- **Queries**: built before the corpus with their own `setseed(qseed)`, so the
  query list is independent of corpus size and identical across tiers.

**Machine independence.** Since PostgreSQL 15, `setseed()`/`random()` use PG's
*built-in* PRNG (xoroshiro128\*\*), not the platform's libc, so the RNG sequence is
identical across machines/OS for a given PG major (the extension targets 16/17/18,
all ≥ 15). The query samplers use only multiply/floor — no `exp`/`ln`/`pow` — so no
libm rounding differences can creep in either. `inspect.sh` prints `vocab` and
`query` md5 fingerprints; run it on two hosts and compare to confirm. (The corpus
generation still uses `power()` for the synthetic-tail Zipf weights, so corpus
bytes are guaranteed identical only on a fixed platform — which CI always is; the
query list is fully platform-independent.)

## How the corpus is built

- **Vocabulary** = a real head + a synthetic tail.
  - *Head*: the clean lowercase lemmas from
    [`docs/wordfrequency.info-top-5000.txt`](../../docs/wordfrequency.info-top-5000.txt)
    (COCA top-5000), weighted by their real corpus frequency. This is public,
    PII-free word-frequency data — no real document text is used.
  - *Tail*: `tail_words` deterministic pseudo-random 5–30 char strings whose
    weights continue the head's Zipf curve. Real collections have a long tail of
    junk tokens (ids, codes, OCR noise, foreign words), so random strings are a
    fair stand-in. The head keeps **>80% of token occurrences real**.
- **Topics (positional locality).** Pure i.i.d. word placement has no local
  structure, so two specific terms are close only by chance and proximity search
  needs huge windows. Instead the vocabulary is partitioned into `n_topics`
  topics (the top `n_stop` words are a global stopword background, present
  everywhere; every other word is hard-assigned round-robin by frequency rank, so
  topics carry balanced mass). A small per-topic sampling table (`topic_lut`)
  gives each topic its own inverse-CDF over a `seg_buckets`-bucket draw + hash
  join. Because topics are a balanced partition chosen ~uniformly per segment, the
  **global term-frequency marginal is approximately preserved** (the Zipf head you
  worked for stays intact).
- **Documents are topic segments.** Each document is generated as a run of
  fixed-length segments (`segment_len` tokens); a segment's topic is a
  deterministic integer hash of `(doc, segment-index)`. Each token is either a
  background draw (probability `bg_rate`, computed as the stopwords' mass share —
  ~0.55, a realistic stopword fraction) or a content draw from the segment's
  topic. `string_agg` is **ordered by position**, so tsvector positions follow the
  segment layout — that is what makes same-topic words land within a few positions
  and lets short-radius proximity match. This is a simplified segmented topic
  model (cf. LDA / a hidden-topic-Markov model); the segment length is the knob
  that maps to the proximity radius.
- **Document lengths** are drawn from [`doc_sizes.csv`](doc_sizes.csv) (see below),
  clamped to 16383 tokens (tsvector's per-lexeme position cap) so positions are
  never silently dropped.
- The corpus is filled in batches until it reaches the target size, then a plain
  `gin(tsvector)` index is built.

## The query workload

`nqueries` queries in a deterministic e-discovery-style mix:

- single term, boolean `AND` (2–3 terms), `OR`
- within-`<~N>`, ordered-`<-N>`, not-within-`<!~N>`
- adjacent-word phrases (`"a b"`, `"a b c"`)
- multi-term proximity chains (`a <~N> b <~N> c`, and 4-term)
- truncation wildcards (`stem*`, and `term <~N> stem*`) — the COCA head is lemmas
  with no inflected forms, so a truncating wildcard is how a term catches variants
- a phrase span as a proximity operand (`"a b" <~N> c`)
- non-indexable / non-native terms — suffix (`*tion`), infix (`f*r`), and a real regex
  pattern (`##capac.*##`, not a metachar-free `##term##` that just matches one lexeme) —
  each paired with a plain term that carries the index (`*tion <~N> b`)

The last two are deliberately NON-native: they don't lower to a plain `tsquery`, so
they exercise the real positional/pattern recheck — the regime where the pure-SQL
port can't take its native fast-path (and where degenerate user queries get costly
for *both* implementations).

**Boolean / single / bare-wildcard** terms are drawn over a global frequency-rank
band (skipping the top stopwords that match everything and the rare tail that
matches nothing). **Proximity** shapes instead draw all their terms from one
shared topic's `query_topn` most common head words — so the terms are reliably
co-present in that topic's documents *and* sit in the same segments. The payoff:
short, natural radii work. At the default `<~2..15>`, `within` matches ~all of its
candidates' co-occurring docs and even 3–4 term chains match reliably (they were
near-empty under i.i.d. placement at any radius). Adjacent-word *phrases* are the
one shape that stays partly sparse — clustering makes words near each other, but
exact adjacency is still uncommon — which is realistic. Tunables:
`n_topics`/`n_stop`/`segment_len` (corpus locality), `dist_min`/`dist_max` and
`query_topn` (queries).

## doc_sizes.csv — swap in your own distribution

A document's length (in **tokens**, ≈ whitespace words) is drawn by picking a
bucket weighted by `weight`, then a length uniformly within `[lo, hi)`:

```csv
lo,hi,weight
10,80,25
80,300,35
...
```

The committed file is a **placeholder** shaped like an email-heavy collection.
Replace the rows with a real distribution — only the shape and relative weights
matter, not their absolute scale.

## Run it locally

Needs a reachable PostgreSQL (libpq env vars) with the extension installed and a
role with CREATEDB. With a cargo-pgrx managed instance:

```sh
cargo pgrx install --no-default-features --features pg17 \
  --pg-config "$(sed -n 's/^pg17 = "\(.*\)"/\1/p' ~/.pgrx/config.toml)"
cargo pgrx start pg17
export PGHOST="$HOME/.pgrx" PGPORT=28817
SMALL_MB=100 LARGE_MB=512 bench/large/run.sh
```

Useful env knobs (see [`run.sh`](run.sh) for the full list): `SMALL_MB`,
`LARGE_MB`, `SMALL_QUERIES`, `LARGE_QUERIES`, `SMALL_ITERS`, `LARGE_ITERS`,
`RUN_LARGE=0` (skip the large tier), `SEED`, `TAIL_WORDS`, `ZIPF_S`.

## Inspect the queries locally

[`inspect.sh`](inspect.sh) regenerates the exact query list the benchmark uses,
prints reproducibility fingerprints, and (by default) builds a small corpus and
counts candidates + matches per query — handy for eyeballing the workload and
confirming the terms hit:

```sh
export PGHOST="$HOME/.pgrx" PGPORT=28817
bench/large/inspect.sh                 # 200 queries + a 50 MiB corpus
INSPECT_CORPUS=0 bench/large/inspect.sh   # just the query list + fingerprints (fast)
```

It writes `bench/reports/inspect_queries.csv` (`id,shape,q`) and, with a corpus,
`bench/reports/inspect_results.csv` (`id,shape,q,candidates,matches`). Knobs:
`NQUERIES`, `INSPECT_MB`, `INSPECT_CORPUS`, `SEED`, `QSEED`, `DIST_MIN`/`DIST_MAX`
(e.g. `DIST_MAX=150 bench/large/inspect.sh` widens proximity to catch more chains).

## Files

- [`large_bench.sql`](large_bench.sql) — the benchmark (sets up both implementations, runs both tiers' timings + parity)
- [`inspect.sql`](inspect.sql) / [`inspect.sh`](inspect.sh) — local query inspection
- [`run.sh`](run.sh) — the two-tier driver that writes the Markdown report
- `_vocab.sql` / `_queries.sql` / `_corpus.sql` — shared generation includes used by both `large_bench.sql` and `inspect.sql`, so they can never drift
- [`doc_sizes.csv`](doc_sizes.csv) — the document-length distribution (swap in your own)

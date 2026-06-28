# proxquery — Unicode tokenizer (user guide)

proxquery ships a custom, Unicode-aware tokenizer for full-text search: it preserves emoji, folds case and accents, and **superimposes** the
forms of hyphenated words, emails, and accented terms onto one position so a search
for any form finds the document. It is an *extension-only* feature, parallel to the
config-aware path documented in [CONFIG_AWARE.md](CONFIG_AWARE.md) (which threads a
stock `regconfig` through `to_tsvector`). Use the tokenizer when you want the custom normalization; use the config-aware path when stock `to_tsvector(cfg, …)`
is enough and you need the pure-SQL port.

The design contract and per-token rules live in
[TOKENIZER_SPEC.md](TOKENIZER_SPEC.md); this is the how-to.

## Quick start

Build the tsvector with a **generated column**, index it with a plain GIN index, and
query it with the same analyzer:

```sql
CREATE TABLE docs (
    id    bigserial PRIMARY KEY,
    body  text,
    tsv   tsvector GENERATED ALWAYS AS (proxquery_to_tsvector(body, 'prox_icu')) STORED
);
CREATE INDEX docs_tsv_gin ON docs USING gin (tsv);

-- index-accelerated proximity search (same @~@ operator as the config-aware path):
SELECT id FROM docs WHERE tsv @~@ proxquery('prox_icu', 'cafe <-> noir');
```

`proxquery_to_tsvector(body, analyzer)` is `IMMUTABLE`, so it works in a `STORED`
generated column and in index expressions. The analyzer name (`'prox_icu'`) **must be
the same** on the column and in every query — that symmetry is what makes a query fold
the same way the column was built.

## Analyzers

A bare preset name picks the segmenter and the case/accent/emoji toggles:

| name | segmenter | case | accents | emoji |
| --- | --- | --- | --- | --- |
| `prox_icu` (default) | ICU (dictionary CJK/Thai) | fold | fold (`café`=`cafe`) | keep |
| `prox_unicode` | unicode-segmentation (per-char CJK) | fold | fold | keep |
| `prox_icu_accent` | ICU | fold | **sensitive** (`café`≠`cafe`) | keep |
| `prox_icu_no_emoji` | ICU | fold | fold | **drop** |

Case is always folded (the query DSL lowercases terms), so case-sensitivity isn't a
preset.

### `:dict` suffix — stemming, stopwords, synonyms

Append `:<dictionary>` to route every lexeme through a Postgres text-search
dictionary (`ts_lexize`):

```sql
-- english stemming + stopword removal:  running / runs / run  all match "run"
… proxquery_to_tsvector(body, 'prox_icu:english_stem') …
SELECT … WHERE tsv @~@ proxquery('prox_icu:english_stem', 'run');

-- compose with any preset and any installed dictionary:
'prox_icu_accent:german_stem'   'prox_unicode:my_synonyms'
```

`<dictionary>` is any `regdictionary` in the database (snowball stemmers, `ispell`,
`thesaurus`, `synonym`, …). Bare presets carry no dictionary and pay nothing.

## What the tokenizer does

- **Case + accent folding (accent-insensitive by default).** The index stores both
  forms — `Café` → `café` and `cafe` at one position — and a **bare** query folds to
  the canonical form, so `cafe` AND `café` both find accented and plain docs alike
  (recall-first). For accent-specific matching, use a **literal** `'café'` (see
  [Literal terms](#literal-terms--exact-matching) below): resolved exactly, it matches
  only the accented spelling (`'CAFÉ'` still folds case). So one superimposed index
  serves both an accent-insensitive search (bare `café`/`cafe`) and an accent-specific
  one (`'café'`) — no reindex. For an index that is fully accent-sensitive on *both*
  sides (smaller, never superimposes), build the column with `prox_icu_accent`.
- **Hyphenated words.** `café-bar` → the compound and each part (`café-bar`, `cafe-bar`,
  `café`, `cafe`, `bar`) all at one position. Searching the compound or any part
  matches, and a neighbor is adjacent to the whole word.
- **Emails.** `a@b.com` → `a@b.com`, `a`, `b.com`, `b` (full + local + host + labels,
  no bare TLD), superimposed.
- **URLs.** `https://x.com/p?q=1` → the full URL + host (`x.com`, `x`); paths/queries
  aren't split.
- **Apostrophes.** `it's` → `it's`, `it`, `its` (full + prefix + stripped); curly `’`
  is normalized to `'`.
- **Emoji** are preserved as their own token (ZWJ families, flags, skin-tone
  sequences stay intact), unless the analyzer drops them.
- **CJK/Thai** word segmentation with the ICU analyzer (dictionary), or per-character
  with `prox_unicode`.
- **Numbers** are kept as-is (`1,000`, `3.14`); no variant superimposition.

Because superimposition packs a hyphenated/email/accented word's forms onto **one**
position, proximity reads naturally across it — e.g. in `send a@b.com now`, `send <-> a`
matches (the email occupies a single slot).

## Querying

The query DSL is the same one the config-aware path uses (terms, `&` `|` `!`,
phrases `"a b"`, `a <-> b` / `a <N> b`, within `a <~N> b`, ordered `a <-N> b`,
not-within `a <!~N> b`, prefixes `appl*`, globs, regex `##…##`). Three equivalent
forms, all index-served:

```sql
-- 1) the operator (recommended)
WHERE tsv @~@ proxquery('prox_icu', 'cafe <-> noir')

-- 2) the explicit two clauses it expands to (GIN probe AND positional recheck)
WHERE tsv @@ ts_prox_query(proxquery('prox_icu','cafe <-> noir'))
  AND proxquery_recheck(tsv, 'cafe <-> noir', 'prox_icu')

-- 3) a bare recheck (seq scan; no index)
WHERE proxquery_recheck(tsv, 'cafe <-> noir', 'prox_icu')
```

`@~@` carries a planner support function that rewrites form (1) into form (2) against
a GIN index, so you normally just write the operator.

### Literal terms — exact matching

A bare term is **accent- and stem-insensitive** — it folds to the index's canonical
form. To match a term *exactly* (preserving accents, skipping stemming), wrap it in
single quotes. Dollar-quoting the query string keeps the inner quotes readable:

```sql
-- bare: accent-insensitive (finds café AND cafe)
WHERE tsv @~@ proxquery('prox_icu', 'cafe')
-- literal: exact (finds only the accented café)
WHERE tsv @~@ proxquery('prox_icu', $$'café'$$)
-- literals compose in proximity, phrases, etc.
WHERE tsv @~@ proxquery('prox_icu', $$'café' <-> noir$$)
```

A literal is case-folded (the DSL lowercases) and NFC/curly-apostrophe normalized, but
**not** accent-folded or stemmed, so it matches only the form the index preserved. A
literal the index folded away finds nothing — e.g. `'running'` under a `:english_stem`
analyzer, whose index stored `run`. (The single quote is also the escape hatch for
terms with special characters, e.g. `'a*b'` searches a literal asterisk; `''` is a
literal quote.)

## Notes & gotchas

- **Symmetry.** The analyzer name must match on the column and in the query. A
  mismatch silently misses (the two sides fold differently).
- **Baked in.** The analyzer is part of the generated-column definition. To change it,
  alter the column and reindex.
- **Extension-only.** This path is not in the pure-SQL port. The default-parser /
  config-aware path ([CONFIG_AWARE.md](CONFIG_AWARE.md)) remains available in both.
- **Two function families.** `ts_prox_*` (`ts_prox_query`, `ts_prox_recheck(tsv, q,
  regconfig)`) is the **stock / regconfig** family — portable, and present in the
  pure-SQL port. `proxquery_*` (`proxquery_to_tsvector`, `proxquery_recheck(tsv, q,
  analyzer)`) is the **custom-tokenizer** family — extension-only. The split is
  deliberate: a function's family tells you whether it works under the pure port. The
  `@~@ proxquery(src, q)` operator is the convenience that dispatches to either (also
  extension-only — the port has no `@~@`).
- **`:dict` immutability.** A dictionary is resolved by name to an OID (cached);
  it's immutable-by-convention like `regconfig` — if you drop and recreate the
  dictionary, reindex.
- **Performance.** The tokenizer matches at essentially the same per-operation cost as
  stock `simple` (see `bench/tokenizer_vs_simple.sql`); the ICU engine adds dictionary
  cost only on CJK/Thai text.

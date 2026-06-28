# proxquery Unicode Tokenizer — Spec (DRAFT)

Status: **draft contract** for the extension-only custom tokenizer. This defines the
`input text → tsvector` behavior we will pin with a golden test corpus before writing
the segmenter. Items marked **OPEN** need a decision; everything else reflects choices
already made (see below).

## Architecture (decided)

- A pgrx **builder function** `proxquery_to_tsvector(body text, analyzer text) → tsvector`
  produces the tsvector directly — *not* a `CREATE TEXT SEARCH PARSER` (a TS parser
  can't superimpose positions: PostgreSQL assigns one position per parser token).
- The **analyzer** is a named config (referenced identically on the index and query
  sides), so the two sides can't drift and it stays `IMMUTABLE` → folds into the GIN
  index condition. Indexed via a `GENERATED ALWAYS AS (proxquery_to_tsvector(body,
  'name')) STORED` column.
- **Extension-only, both sides.** Query atoms resolve through the same tokenizer, which
  pure SQL can't replicate. The default-parser path (`to_tsvector(cfg,…)`) is unchanged
  and stays mirrored across the extension and the pure-SQL port. The matching engine
  (DSL / proximity / `ts_prox_match` / operators) is shared and is **not** forked — it
  reads any tsvector and already handles superimposed positions.

## Pipeline

1. **NFC-normalize** the whole input (composed form), so `é` (U+00E9) and `e`+U+0301
   tokenize identically.
2. **Segment** into logical tokens via UAX #29 word boundaries, through a `Segmenter`
   trait with two backends: `unicode-segmentation` (tiny, per-char CJK) and
   `icu_segmenter` (ICU4X, dictionary CJK/Thai). Chosen per analyzer.
3. **Classify** each segment: word / number / alphanumeric / emoji / structured
   (email, URL/host) / punctuation.
4. **Decompose** structured + compound tokens into sub-lexemes (hyphen, email, URL).
5. **Normalize** each lexeme: always Unicode case-fold; accent-fold per analyzer.
6. **Emit** the tsvector with the position model below.

## Position model (the core idea)

Each **logical token** (a whitespace/boundary-delimited unit) occupies **one position**.
Every lexeme derived from it — the compound, its parts, and folded/accented variants —
is **superimposed at that one position**. This removes the position inflation the stock
PG parser causes for hyphens/compounds, so proximity reads naturally:

```
"send a@b.com now"  →  send:1   {a@b.com, a, b.com, b, …}:2   now:3
```

`send <-> a` matches (a is at position 2, adjacent to send). Punctuation/symbol-only
segments produce no lexeme and **consume no position** (a removed token leaves no gap —
consistent with how proximity should read across dropped punctuation).

## Token rules

| Category | Rule |
|---|---|
| **Words / alphanumeric** | UAX#29 word run → one lexeme. Mixed letter+digit runs (`abc123`, `h2o`) stay whole (WB9/WB10). Underscores treated as word chars (kept). |
| **Numbers / IDs** | Kept **as-is** per UAX#29 (`1,000`, `3.14` whole); **no** variant superimposition (`1000`/`3`/`14` not emitted — common tokens, tiny benefit, real bloat). Digits are word chars so Bates-style IDs (`ABC0001234`) stay one token. |
| **Emoji** | **Preserved** as their own lexemes. ZWJ sequences (family/profession), skin-tone modifiers, and regional-indicator flag pairs are kept **intact** as a single lexeme each. |
| **Case** | **Always Unicode case-folded** (`caseless`), e.g. `Straße`/`STRASSE`→`strasse`. Original case is not preserved as a separate lexeme. |
| **Accents** | Superimpose **both** the case-folded original and the accent-folded form at one position (`Café` → `café` + `cafe`), so one index serves accent-sensitive *and* -insensitive search — the accent analog of hyphen superimposition. Accent-fold is **Latin-scoped** (NFD-strip combining marks + small unaccent-style table for atomics like `ø→o`, `æ→ae`); never strip Arabic/Indic marks. |
| **Hyphenated** | Superimpose compound + parts at one position: `c-d` → `c-d`, `c`, `d`. Each part is then case/accent-normalized like any word. |
| **Emails** | Decompose + superimpose at one position: full address, local part, full host, and host labels **except the TLD**. `a@b.com` → `a@b.com`, `a`, `b.com`, `b`. `john@mail.example.com` → `john@mail.example.com`, `john`, `mail.example.com`, `mail`, `example`. (No bare TLD.) |
| **URLs / hosts** | Superimpose the **full URL + host** only, host decomposed like an email host (labels except TLD). **No** path/query-segment splitting. `https://x.com/p?q=1` → `https://x.com/p?q=1`, `x.com`, `x`. |
| **Apostrophes** | Curly `’` (U+2019) normalized to `'`. Superimpose full token + part-before-apostrophe + apostrophe-removed form: `it's` → `it's`, `it`, `its`; `Paul's` → `paul's`, `paul`, `pauls`. Cheap (apostrophe tokens are rare). Contraction prefixes are mild noise (`don't` → `don`); drop the prefix if undesired. |
| **CJK / Thai** | Engine-dependent: `icu_segmenter` does dictionary word segmentation; `unicode-segmentation` falls to per-character. Selected per analyzer. |
| **Punctuation / symbols** | Dropped; no lexeme, no position. |

## Analyzer config (fields)

Each named analyzer fixes a tuple of these toggles (so the builder stays IMMUTABLE —
usable in a generated column / index expression). The name is referenced identically
on the index and query sides.

- `segmenter`: `unicode` | `icu` (default `icu`).
- `fold_case`: bool (default **true**). Case-*sensitivity* is not currently offered —
  the DSL ASCII-lowercases query terms at parse time, so a case-sensitive analyzer
  couldn't match symmetrically without a DSL change.
- `fold_accents`: bool (default **true**); superimposes both forms (`Café`→`café`+`cafe`).
- `keep_emoji`: bool (default **true**).
- `decompose_emails` / `decompose_urls`: bool (default **true**).
- `stopwords`: list/none (default none — legal review wants common words searchable).
- (later) stemming hook via `ts_lexize` if we want PG dictionaries.

### Built-in named analyzers (the registry, in `AnalyzerKind`)

| Name | segmenter | fold case | fold accents | emoji |
| --- | --- | --- | --- | --- |
| `prox_icu` (default) | icu | ✓ | ✓ (superimpose) | keep |
| `prox_unicode` | unicode-seg | ✓ | ✓ (superimpose) | keep |
| `prox_icu_accent` | icu | ✓ | ✗ (accent-sensitive) | keep |
| `prox_icu_no_emoji` | icu | ✓ | ✓ | drop |

Adding a preset is a one-line entry in `AnalyzerKind::from_name`/`config`. (A
user-extensible registry would need catalog-level support to stay IMMUTABLE, so it's
out of scope; presets are built-in.)

**`:dict` suffix.** Any preset name may carry an optional text-search dictionary:
`<preset>:<dict>` (e.g. `prox_icu:english_stem`, `prox_icu_accent:german_stem`). Each
emitted lexeme is then routed through that `regdictionary` via `ts_lexize` —
`NULL` → keep as-is, `{}` → drop (stop word), else emit the stem/synonym output
(superimposed). The dict name resolves to an OID once per backend (cached). Bare
presets carry no dict and pay nothing (a single `Option` check per lexeme). Case
*sensitivity* is still not offered (the DSL ASCII-lowercases query terms).
Immutable-by-convention, like `regconfig`: drop/recreate the dictionary → reindex.

## Query-side resolution (bare vs literal)

The index superimposes; the query chooses how much of that to use. A query atom
resolves through the **same** analyzer (segmentation, case-fold, dictionary), but:

- A **bare** term (`café`, `café-bar`) resolves to its **canonical** form — case-fold +
  accent-fold + stem, no superimposed variants and no part decomposition. So it folds
  to what the index's folded form is: accent- and stem-insensitive by default (`café`
  and `cafe` both match), and a compound stays whole (`café-bar` → `cafe-bar`, not its
  parts — query a part directly to find the compound).
- A **literal** `'…'` term resolves **exactly** — case-fold + NFC/curly only, *no*
  accent-fold, stem, or decomposition — matching the form the index preserved. This is
  the precision opt-out: `'café'` matches only the accented spelling. A literal the
  index folded away (e.g. `'running'` under `:english_stem`) finds nothing.

One superimposed index thus backs both an accent-insensitive search (bare) and an
accent-specific one (literal) without reindexing. `prox_icu_accent` is the alternative
when the index itself should be accent-sensitive (smaller, never superimposes).

## Decisions (all resolved)

- **Accents:** superimpose both accented + folded (`Café` → `café` + `cafe`).
- **Emails:** drop the bare TLD (full address + local + host + labels-except-TLD).
- **URLs:** full URL + host only (no path/label explosion).
- **Numbers:** kept as-is, no variant superimposition.
- **Apostrophes:** superimpose full + part-before-apostrophe + apostrophe-stripped.

## Test corpus (Phase 1 output)

Extension-only Rust `#[pg_test]`s asserting `proxquery_to_tsvector(input,'analyzer')`
equals an expected tsvector, organized by the categories above, seeded from the
ParadeDB/UAX#29-derived checklist (emoji ZWJ/flags/skin-tone, NFC/NFD equivalence,
mixed-script, emails/URLs, hyphen compounds, decimals/versions, contractions, CJK).
Kept **separate** from the pure-port diff corpus.

# Config-aware proxquery (design sketch — not implemented)

Today proxquery is **`simple`-only**. This sketches what it would take to make it
work against a `tsvector` built with any text-search configuration (`english`,
etc.). It is a design note for later, not a spec of shipped behavior.

## The problem

proxquery matches by *lexeme*. It currently lexifies query terms as `simple`
(literal, lowercased) in **two** places that must agree:

1. **Skeleton** (index selection): `to_tsquery('simple', …)`.
2. **Recheck** (`ts_prox_match`): a literal, lowercased byte lookup of each term in
   the `tsvector`.

If the column was built with, say, `english`, the stored lexemes are stems
(`running` → `run`) and stopwords are dropped. proxquery looks up the literal
`running`, misses, and — because the skeleton's `to_tsquery('simple', …)` selects
**zero candidates** — the query returns nothing before the recheck even runs. The
`<N>` operator is no exception: its distance math is config-independent (positions
count stopwords on any config), but the *terms* inside it are still `simple`.

So the fix is entirely about **lexifying query terms through the column's config**,
consistently on both sides.

## Where the config comes from

A `tsvector` carries no config, so proxquery has to be told which one to use.

- **GUC `proxquery.config`** (regconfig, default `simple`) — the default for the
  `@~@` operator, which is binary (`tsvector @~@ text`) and has no room for a
  third argument.
- **Explicit 3-arg functions** for fine control without the operator sugar:
  `ts_prox_query(text, regconfig)` and `ts_prox_match(tsvector, text, regconfig)`.
  The existing 2-arg forms keep reading the GUC.

The `@~@` path therefore picks up the config from the GUC (`SET proxquery.config =
'english'`), which is session-scoped, not per-query. Per-query control means using
the 3-arg functions directly (and the two-clause form), giving up the single
operator. Document that trade-off.

## Term resolution

Resolve each query term to its lexeme set under the config, **once per query**
(not per document), and cache it on the parsed node:

```
lexemes(term) = distinct lexemes of  to_tsvector(<config>, term)
```

- **1 lexeme** — the normal case (`running` → `run`).
- **≥2 lexemes** — thesaurus/compound dictionaries can emit several. Treat the term
  as the OR of them: union their positions. The existing position-set model already
  does this (same as an OR-group or a prefix), so no new machinery.
- **0 lexemes** — the term is a **stopword** (or tokenizes to nothing). It can't be
  located, so a proximity/phrase over it is meaningless. Reject with a clear error
  (`"the" is a stopword under config "english"`), consistent with the
  reject-and-refine stance elsewhere. (Silently dropping it would desync the
  skeleton and the recheck.)

The skeleton side is easier: just pass the config to `to_tsquery(<config>, …)` —
it already runs each lexeme through the config's dictionaries. (Verify that
single-quoted lexemes in `to_tsquery` are still normalized; they should be.)

## What changes, by piece

| Piece | Today (`simple`) | Config-aware |
|---|---|---|
| skeleton | `to_tsquery('simple', s)` | `to_tsquery(<cfg>, s)` |
| term recheck | literal byte lookup | resolve to lexeme set via `<cfg>`, union positions |
| `@~@` | implicit `simple` | reads `proxquery.config` GUC |
| functions | 2-arg | add 3-arg `(…, regconfig)` overloads |

The **consistency invariant** is the thing to get right: skeleton and recheck must
resolve every term identically (same config, same stopword handling), or recall
breaks (the recheck only ever filters down from what the index returned).

## Hard parts / caveats

- **Phrases + stopwords.** Under `english`, `"the quick fox"` must become
  `quick <2> fox` — the dropped stopword widens the gap, exactly as
  `phraseto_tsquery` accounts for it. proxquery's exact-gap phrase recheck would
  have to reproduce that stopword-offset arithmetic. This is the gnarliest sub-
  problem; the skeleton can lean on `phraseto_tsquery(<cfg>, …)`, but the recheck
  needs the same offsets.
- **Wildcards / regex match stems.** `*ology` and `##…##` scan the *stored*
  lexemes, which under `english` are stems (`biology` may be stored as `biolog`).
  So wildcard/regex semantics are only crisp under `simple`; under a stemming
  config they match stems, not surface forms. Document as best-effort, or restrict
  wildcards/regex to `simple`.
- **Per-row cost.** `ts_prox_match` re-parses (and would re-resolve) the query per
  row. Resolution must be hoisted/cached per query (e.g. a backend-local cache
  keyed by `(query, config)`), or it calls `to_tsvector` per term per row.
- **Operator can't carry per-query config** — see the GUC trade-off above.

## Backward compatibility

Default the GUC to `simple`; the 2-arg functions and current `@~@` behavior are
unchanged. This is purely additive.

## Rough implementation order

1. Register the `proxquery.config` GUC (regconfig, default `simple`).
2. Thread a config (GUC or arg) into `ts_prox_query` / `ts_prox_match`; add 3-arg
   overloads.
3. Skeleton: swap `'simple'` for the config in the `to_tsquery` call.
4. Recheck: a `resolve(term, cfg) -> Vec<lexeme>` (via `to_tsvector(cfg, term)`),
   cached per query; route `Term` lookups through it; error on stopwords.
5. Decide wildcard/regex policy under non-`simple` (best-effort vs `simple`-only).
6. Phrase stopword-offset handling (or restrict phrases to `simple` first).
7. Tests against an `english` column; verify skeleton/recheck parity.

# Why proxquery exists, and what actually needs the binary

This explains the motivation for the extension and draws an honest line between
the parts that are just **concise sugar over native Postgres** and the parts that
genuinely need **compiled code**.

The short version: almost nothing proxquery does is *impossible* in stock
Postgres. The extension exists for **speed**, **concision**, and one thing that
truly cannot be done in SQL — a single indexable operator.

## Motivation

Postgres full-text search matches at the **document** level and ships exactly one
proximity primitive: `a <N> b` — "b is exactly N lexemes after a", ordered and
exact. Everything proximity-shaped has to be built on top of that, and two gaps
show up immediately:

1. **"Within N, either order" must be enumerated.** `a <~N> b` has no native
   operator, so you expand it to `2N` OR-clauses. It works and is index-served,
   but the query grows with N and the recheck re-evaluates all `2N` clauses.

2. **Occurrence-level reasoning isn't expressible in `tsquery` at all.** `tsquery`
   reasons about whole documents. "Find an `a` that is *not* near any `b`, even if
   a *different* `a` is near a `b`" (e.g. `confidential` used in substance, not in
   the email-footer boilerplate) cannot be written as a `tsquery`. The only native
   route is an `unnest`-based positional subquery, which **materializes the entire
   `tsvector`** per candidate just to read two lexemes' positions — fine for a few
   thousand rows, painful for hundreds of thousands.

proxquery's goal is to make this whole grammar **correct, fast, and one clause**:
a `tsquery`-superset DSL and a single `text_tsv @~@ 'q'` operator that is
index-served on a plain GIN index.

## What native Postgres can already do (just verbosely)

Semantically, most of the grammar is reachable in stock Postgres:

| Capability | Native Postgres equivalent |
|---|---|
| boolean, phrase, adjacency, exact distance, prefix | **identical** native `tsquery`: `a & b`, `a \| b`, `!a`, `a <-> b`, `a <N> b`, `appl:*` |
| within N, either order | the `2N`-clause enumeration `(a<1>b)\|(b<1>a)\|…\|(a<N>b)\|(b<N>a)` |
| ordered within N (pre) | the `N`-clause enumeration `(a<1>b)\|…\|(a<N>b)` |
| suffix / infix / single-char wildcard | resolve against a vocabulary (`SELECT lexeme … WHERE lexeme LIKE '%ology'`) → an OR-group `tsquery` |
| single-token regex | same, with `lexeme ~ '^…$'` → OR-group |
| occurrence-level `not within` / same-window | an `unnest`-based `EXISTS … NOT EXISTS` positional subquery |

For the first row, proxquery is **pure sugar** — those operators pass straight
through to `tsquery`. For the rest, the native form is real but costs you
verbosity, a vocabulary scan and fan-out (wildcards/regex), or a full-`tsvector`
materialization per row (occurrence-level predicates).

## What actually requires the compiled binary

Two things genuinely need compiled code; everything else is a speed/concision win.

1. **A single indexable operator (`@~@`) — this one is C-only.** `@~@` is index-
   served via a **planner support function** (`SupportRequestIndexCondition`) that
   rewrites `text_tsv @~@ 'q'` into the index condition `text_tsv @@
   ts_prox_query('q')` plus a recheck. Planner support functions **cannot be written
   in SQL or PL/pgSQL** — they must be compiled. Without the binary you can still
   get the same *result*, but only as the hand-written two-clause form
   (`text_tsv @@ ts_prox_query(q) AND ts_prox_match(text_tsv, q)`), never one
   operator.

2. **Fast position access.** Reading "the positions of lexeme X" in SQL means
   `unnest(tsvector)`, which is `O(all lexemes)` and materializes the whole vector.
   The binary binary-searches the sorted lexeme pool (`O(log L)`) and reads only the
   lexemes it names. That is the ~10× speedup on the occurrence-level predicates —
   the same predicates you *can* write with `unnest`, just far slower.

Everything in between — the proximity predicates, the DSL parser, the wildcard/
regex scan — *could* be expressed in PL/pgSQL over `unnest`, but would be slow and
unpleasant. Compiled, they are cheap.

## Summary

| Part | Native? | What the binary adds |
|---|---|---|
| `& \| ! ( ) " " <-> <N> :*` | yes, identical | nothing — concision only |
| `<~N>` / `<-N>` within / pre | yes, enumerated | concise syntax; flat-in-N recheck overtakes the native `O(N)` enumeration around N≈13 |
| `<!~N>` / `<!-N>` not-within, windows | only via `unnest` | `tsquery` can't express it; ~4–10× faster |
| suffix / infix / `?` / `##regex##` | yes, via vocabulary OR-group | per-document recheck scan, no vocab table |
| `text_tsv @~@ 'q'` (one indexable clause) | no | **the operator itself — needs a C planner support fn** |

## Measured (see `bench/native_vs_proxquery.sql`)

On a 5k-doc corpus, parity is identical row-for-row; the speed picture:

- **Occurrence-level `not_within`**: proxquery ~4× faster (and the lead widens with
  corpus size — the `unnest` baseline is linear in candidates).
- **Large-fan-out regex**: proxquery ~3× faster (the native vocabulary OR-group
  blows up).
- **within / pre**: native's `2N`-clause enumeration has an `O(N)` recheck, while
  proxquery's recheck is **flat in N** (binary-search the positions, two-pointer,
  and the parsed query is cached per scan). They cross around **N≈13** — native
  faster below, proxquery faster above, by larger margins as N grows (and as the
  number of chained proximity operators grows).
- **Selective standalone wildcards**: native's vocab OR-group is index-served and
  wins; proxquery seq-scans (no index key). Pair a wildcard with a companion term.

So: reach for proxquery for occurrence-level proximity, larger-distance or chained
proximity, big-fan-out regex, or the ergonomics of one operator on a plain GIN
index. For small-N proximity or selective wildcards on a small corpus, native
`tsquery` is competitive or better — proxquery's universal edge there is concision.

# proxquery without the binary — the pure-SQL port

[sql/proxquery_pure.sql](../sql/proxquery_pure.sql) is a drop-in, extension-free
implementation of proxquery written entirely in SQL and PL/pgSQL. It exists for
environments where you **can't load a compiled extension** — managed Postgres
like Cloud SQL, RDS, or Azure, where `CREATE EXTENSION proxquery` isn't an
option — and as a stepping stone you can later swap for the native extension
with no query changes.

It is a plain migration file: run it once and you have the whole proxquery surface.

```sh
psql -d your_db -f sql/proxquery_pure.sql
```

## Everything lives in a `proxquery` schema

All objects — the public `ts_prox_*` functions and the `_prox_*` helpers — are
installed into a dedicated **`proxquery` schema**. It never touches `public`,
and it tears down in one line:

```sql
DROP SCHEMA proxquery CASCADE;
```

Call the functions schema-qualified, or add the schema to your `search_path`:

```sql
-- qualified
SELECT proxquery.ts_prox_recheck(body_tsv, 'quick <~3> fox') FROM docs …;

-- or via search_path (then unqualified works everywhere)
SET search_path = public, proxquery;     -- session, or ALTER DATABASE … SET …
```

Each public function pins its own `search_path` internally, so it resolves
correctly **either way** — a qualified call works even when `proxquery` isn't on
the caller's `search_path`.

## Same names, same answers

Every public function keeps the exact name and signature of the compiled
extension, and returns **identical results** (verified — see
[Parity](#parity-with-the-extension)):

| Function | Role |
| --- | --- |
| `ts_prox_query(text) -> tsquery` | index-selection skeleton |
| `ts_prox_recheck(tsvector, text) -> bool` | positional recheck |
| `ts_prox_search(tsvector, text) -> bool` | the index-selection + recheck form, in one inlinable call |
| `ts_prox_query_exact(text) -> tsquery` | exact tsquery when the recheck is droppable, else NULL |
| `ts_prox_query(text, regconfig) -> tsquery` | config-aware skeleton |
| `ts_prox_recheck(tsvector, text, regconfig) -> bool` | config-aware recheck |
| `ts_prox_search(tsvector, text, regconfig) -> bool` | config-aware one-call form (index-served; keeps the recheck) |
| `ts_prox_query_skeleton(text) -> text` | the `to_tsquery` input string |
| `ts_prox_within / ts_prox_pre / ts_prox_not_within(tsvector, a, b, n)` | positional predicates |
| `ts_prox_chain(tsvector, text[], int[])` | same-occurrence chain |
| `ts_prox_positions / ts_prox_positions_prefix(tsvector, text)` | sorted positions |

The DSL is the same superset of `tsquery` documented in the
[README](../README.md) — booleans, phrases, `<-> <N> <~N> <-N> <!~N> <!-N>`,
prefix/suffix/infix/`?` wildcards, `##regex##`, single-quoted literals.

## There is no `@~@` — write the two-clause form

The native extension's headline feature is a single indexable operator,
`tsv @~@ 'q'`. That works because of a **planner support function**, which is
C-only and cannot be written in SQL — so a pure-SQL `@~@` could never use the
index; it would silently seq-scan every query.

Rather than ship that footgun, **the pure port omits `@~@` entirely.** Proximity
queries are written in the form that is actually index-served — the two clauses
the support function would otherwise inject for you:

```sql
CREATE INDEX ON docs USING gin (body_tsv);

SELECT * FROM docs
WHERE body_tsv @@ proxquery.ts_prox_query('quick <~3> fox')   -- Bitmap Index Scan
  AND proxquery.ts_prox_recheck(body_tsv, 'quick <~3> fox');      -- recheck filter
```

The `@@` clause selects candidates on a plain `gin(tsvector)` index (a built-in,
no custom opclass); `ts_prox_recheck` rechecks positions on just those candidates.
That plan is exactly what `@~@` expands to under the extension — same index, same
recheck, same rows.

This composes with everything else like any ordinary predicate. Combined with a
scalar filter, the planner `BitmapAnd`s the GIN and btree indexes:

```sql
SELECT * FROM docs
WHERE body_tsv @@ proxquery.ts_prox_query('quick <~3> fox')
  AND proxquery.ts_prox_recheck(body_tsv, 'quick <~3> fox')
  AND owner_id = 42                                    -- uses its own index, AND-ed in
ORDER BY ts_rank_cd(body_tsv, proxquery.ts_prox_query('quick <~3> fox')) DESC
LIMIT 10;
```

### Drop the recheck when it does nothing

For a **plain boolean / phrase / prefix** query (no `<~N> <-N> <!~N>` proximity), the
`@@ ts_prox_query(q)` skeleton is already the *exact* match — the recheck removes
nothing, yet still runs as a Filter that **re-detoasts the tsvector on every candidate
row** (expensive once the column TOASTs, i.e. long documents). `ts_prox_query_exact(q)`
returns a non-NULL tsquery exactly when the recheck is droppable (NULL for proximity /
not-within / suffix-glob / regex, which genuinely need it), so the recheck can be wrapped
to fold away when redundant. **`ts_prox_search(tsv, q)` is that whole form in one call:**

```sql
SELECT * FROM docs WHERE proxquery.ts_prox_search(body_tsv, q);
```

It is an *inlinable* SQL function, so the planner splices its body back into the query —
re-exposing `@@ ts_prox_query(q)` for the GIN index, then, for a constant (or custom-plan)
`q`, const-folding `ts_prox_query_exact(q)`: a recheck-droppable query collapses to a single
index clause (no Filter, no re-detoast — on par with the extension), everything else reduces
to the ordinary two-clause form. (A generic-plan bind parameter keeps the recheck — still
correct, just not folded.) The native extension exposes the same `ts_prox_search`, so the
query is drop-in portable. It expands to exactly:

```sql
WHERE body_tsv @@ proxquery.ts_prox_query(q)
  AND (proxquery.ts_prox_query_exact(q) IS NOT NULL OR proxquery.ts_prox_recheck(body_tsv, q));
```

**Caveat — index use rides on inlining, so verify it.** The index scan and the recheck
fold both depend on the planner inlining `ts_prox_search` and const-folding the query —
which it does for a **literal or custom-plan** query, but *not*, say, a generic-plan
prepared statement, or a call wrapped where the planner can't see the `@@`. When inlining
is defeated it degrades **silently to a sequential scan** — no error, just slow. So
`EXPLAIN` your real query and confirm the plan is what you think: a `Bitmap Index Scan`
(never a `Seq Scan`), and for a boolean/phrase query no recheck `Filter`.

If it isn't, don't lean on the function — **reproduce its logic in your application.** Ask
once (when you build the query, or cached per distinct query) whether the recheck is
droppable, and emit the matching SQL explicitly so the index is driven by an `@@` clause
that is literally in the query text:

```sql
-- one metadata query decides the form:
SELECT proxquery.ts_prox_query_exact(:q) IS NOT NULL AS recheck_droppable;

-- droppable  → one clause, recheck dropped:
WHERE tsv @@ proxquery.ts_prox_query(:q)
-- otherwise  → the two-clause form:
WHERE tsv @@ proxquery.ts_prox_query(:q) AND proxquery.ts_prox_recheck(tsv, :q)
```

That is exactly what `ts_prox_search` does internally; doing it yourself just moves the
decision to a place the planner can't undo. (The explicit two-clause form alone is always
safe too — it keeps `@@` visible so it can never lose the index — it just leaves the boolean
recheck running.)

## Performance

Same answers, slower — the gap is read amplification, not capability:

- **Position access** is `unnest(tsvector)`, which is `O(all lexemes)` and
  materializes the whole vector per call. The extension binary-searches the
  sorted lexeme pool (`O(log L)`) and reads only the lexemes you name.
- The query AST is **re-parsed per row** in the recheck (the extension caches the
  parse per scan). The `@@` selection narrows candidates first, so the recheck
  only runs on rows the index already matched — keep the `@@` clause selective
  and this stays cheap.

Measured head-to-head over one shared corpus and GIN index
([bench/pure_vs_extension.sql](../bench/pure_vs_extension.sql), 20k docs ~40
lexemes each; same query selects the identical rows in both — `disagree = 0`).
Absolute ms vary by machine; the ratio is the point:

| query | candidates rechecked | extension | pure SQL | slowdown |
| --- | --- | --- | --- | --- |
| `a <~3> b` | 630 | 3.4 ms | 47 ms | ~14× |
| `a <~3> b <~3> c` | 101 | 1.0 ms | 16 ms | ~16× |
| `confidential <!~5> email` | 3652 | 17 ms | 247 ms | ~14× |
| `ssn <~3> ##[0-9]{9}##` | 3552 | 83 ms | 358 ms | ~4× |

So expect **roughly 4–30+× slower**: ~an order of magnitude for term-driven
proximity (the `unnest` + re-parse overhead per candidate), shrinking to ~4×
when a shared cost dominates the recheck — here both implementations run the
identical Postgres regex engine over the candidates. The cost scales with the
number of candidates the `@@` clause lets through, so a selective query stays
cheap; occurrence-level proximity or big-fan-out regex over a large, loosely
selective corpus is where staying extension-free costs the most.

## Query planning

The two-clause form is built so the planner can push the proximity selection
down to the text table's GIN index — and it does. The implementation being
PL/pgSQL doesn't get in the way:

- **`ts_prox_query(q)` constant-folds.** It is `IMMUTABLE`, so for a constant
  query string the planner pre-evaluates it at plan time into a literal `tsquery`
  and uses that as the GIN index condition. (Folding and inlining are different:
  the `SET search_path` on the public functions blocks function *inlining*, not
  *constant-folding*.) For a runtime parameter it is evaluated once per execution
  — still index-usable.
- **`ts_prox_recheck(tsv, q)` is a residual filter.** It references only the
  `tsvector` and a constant, so the planner applies it at the text table's scan,
  after the index narrows candidates. It is recursive, so it would not be inlined
  even as `LANGUAGE sql` — there is nothing inside it to "collapse" into a join,
  and nothing the function language would change.

This holds across the shapes you'd actually write — an inline `WHERE`, an
explicit `JOIN`, or `id IN (SELECT … )` over a dedicated text table. The last
flattens to a (semi-)join and still plans the proximity scan identically:

```
Hash Join  (documents.id = text_documents.id)
  ->  Seq Scan on documents          Filter: status = 'active'     -- outer filter, independent
  ->  Hash
        ->  Bitmap Heap Scan on text_documents
              Filter: ts_prox_recheck(text_tsv, 'a <~2> b')           -- residual recheck
              ->  Bitmap Index Scan on text_documents_text_tsv_idx
                    Index Cond: (text_tsv @@ 'a & b')               -- folded + GIN
```

`id IN (subquery)` is a good shape here: the semi-join returns each outer row
once (no multiplication), and the proximity scan stays self-contained on the
table whose GIN index serves it.

**Selectivity caveat.** The planner has no selectivity estimator for
`ts_prox_recheck`, so it uses a default guess — but the `@@ ts_prox_query(const)`
clause carries real `tsvector` statistics, so the row estimate (and therefore the
join strategy) is anchored by the indexable clause. The join then adapts: a
selective proximity query yields few ids and nested-loop PK lookups on the outer
table; a loose one yields a hash join. (A proper selectivity support function
would be C-only — not available extension-free.)

**If you wrap the search in a function**, make the wrapper a set-returning
`LANGUAGE sql STABLE` single `SELECT` (the `proxsearch(q)` shape) so the planner
inlines it and pushes outer predicates and the index through. A `plpgsql`
set-returning wrapper is an optimization fence — materialized, no pushdown. The
*internal* functions' language is irrelevant to that, and you don't need a
wrapper at all: the inline two-clause `WHERE` is already optimal.

## Migrating to the native extension later

Because the names, semantics, and schema all line up, moving up is mechanical
and transparent — the extension is **relocatable**, so it installs into the same
`proxquery` schema:

```sql
DROP SCHEMA proxquery CASCADE;             -- remove the pure functions
CREATE EXTENSION proxquery SCHEMA proxquery;   -- same names, same schema
```

Every two-clause `… @@ proxquery.ts_prox_query(q) AND proxquery.ts_prox_recheck(…)`
query keeps working **verbatim** — identical plan, now with the faster C position
access. The extension additionally brings the single `@~@` operator, so you may
optionally rewrite those sites to `body_tsv @~@ 'q'` once it's present (purely
ergonomic; same plan).

## What's not here

- **`@~@`** and its planner support function (C-only) — see above. This includes
  the config-carrying `@~@ proxquery(cfg, q)` overload; under the pure port you use
  `ts_prox_search(tsv, q, cfg)` (or the explicit two clauses) instead (next bullet).
- Config-aware lexing **is** here: the 3-arg `ts_prox_query(text, regconfig)`,
  `ts_prox_recheck(tsvector, text, regconfig)`, and `ts_prox_search(tsvector, text,
  regconfig)` overloads match a column built with any text-search config (stemmed,
  unaccented, …), identical to the extension (see [CONFIG_AWARE.md](CONFIG_AWARE.md)).
  The 3-arg `ts_prox_search` is index-served but keeps the recheck — config term
  resolution can fan out, so it doesn't fold the way the `simple` 2-arg form does.
  Only the single operator is missing.

## Parity with the extension

The shared parity corpus lives in [tests/parity_cases.md](../tests/parity_cases.md) —
a human-readable markdown spec of `(input → expected)` cases (boolean predicates,
exact skeleton strings, index selection, recheck, compound operands, grouping
semantics, and malformed-input errors). The differential runner
([sql/proxquery_diff_test.sql](../sql/proxquery_diff_test.sql)) parses it and asserts
every case agrees three ways — **extension == pure port == expected** — using only the
portable surface (the `ts_prox_*` functions and the two-clause form), so neither
implementation can silently drift from the other.

During development the two were also run side-by-side on a live Postgres: the
full curated battery plus ~15,000 randomized DSL queries and ~4,800 randomized
predicate/window/position cases — **zero mismatches**.

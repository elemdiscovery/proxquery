# proxquery

![proxquery](docs/proxquery.png)

A PostgreSQL extension (built with [pgrx](https://github.com/pgcentralfoundation/pgrx)) that adds term-proximity search on top of `tsvector`: "within N words", ordered proximity, occurrence-level "not within N", and phrases. It reads lexeme positions directly out of the `tsvector`, and it plugs into a normal GIN index.

The motivation is to implement query syntax similar to dtSearch and Lucene without also implementing an actual custom index.

## Install

Requires PostgreSQL 16+ (16, 17, and 18 are built and tested).

### Prebuilt binaries (self-managed Postgres)

Every [release](https://github.com/elemdiscovery/proxquery/releases) packages the extension and an installer. Download and run the equivalent of:

```sh
tar xzf proxquery-<version>-pg17-linux-amd64.tar.gz
cd proxquery-<version>-pg17-linux-amd64
./install.sh                 # targets the Postgres on PATH (pg_config)
# or: PG_CONFIG=/path/to/pg_config ./install.sh
```

```sql
CREATE EXTENSION proxquery;
```

The binaries link against the build runner's glibc. If that's an issue in real systems we'll better target this.

### Docker

A Postgres image with proxquery preinstalled:

```sh
docker run --rm -e POSTGRES_PASSWORD=pw ghcr.io/elemdiscovery/proxquery:pg17
```

then `CREATE EXTENSION proxquery;`.

### Pure-SQL port

On managed Postgres [sql/proxquery_pure.sql](sql/proxquery_pure.sql) is a re-implementation using plain SQL with the same function names and identical results, installed into a dedicated `proxquery` schema.

The usage difference is that the `@~@` operator needs a C planner support function, so the pure port does **not** implement it and you need to call two functions for each query to properly use the index.

```sql
SELECT * FROM docs
WHERE body_tsv @@ proxquery.ts_prox_query('quick <~3> fox')   -- GIN index selects
  AND proxquery.ts_prox_match(body_tsv, 'quick <~3> fox');      -- recheck refines
```

The practical difference is that the pure SQL implementation is much, much slower.

If you somehow get the real extension installed later, the migration from the pure SQL implementation to the extension is `DROP SCHEMA proxquery CASCADE; CREATE EXTENSION proxquery SCHEMA proxquery;`. The two-clause queries keep working as-is. See [docs/PURE_SQL.md](docs/PURE_SQL.md) for some AI-babble details.

## Usage

Query a `tsvector` column with the `@~@` operator. The right-hand side is a query string (the DSL below).

```sql
-- a plain GIN index drives candidate selection
CREATE INDEX ON docs USING gin (body_tsv);

-- "quick" within 3 words of "fox", in either order
SELECT * FROM docs WHERE body_tsv @~@ 'quick <~3> fox';

-- a "confidential" with no "email" within 5 words (occurrence-level)
SELECT * FROM docs WHERE body_tsv @~@ 'confidential <!~5> email';
```

The operator `@~@` is using a plain `gin(tsvector)` index. The operator works in two steps: the index selects candidate rows by lexeme, and then the operator rechecks word positions in order to refine the result.

Ranking results isn't a goal of this extension, but `ts_prox_query(q)` returns a real `tsquery`, so the `ts_rank_cd` can be used to get a result, but it won't be particularly meaningful for complex queries.

```sql
SELECT * FROM docs
WHERE body_tsv @~@ 'quick <~3> fox'
ORDER BY ts_rank_cd(body_tsv, ts_prox_query('quick <~3> fox')) DESC
LIMIT 10;
```

## Query operators

The DSL is a superset of `tsquery`. Native `tsquery` syntax works unchanged; the `<…>` proximity operators are the additions.

| Syntax | Meaning |
| --- | --- |
| `a & b` | both terms (AND) |
| `a \| b` | either term (OR) |
| `!a` | term absent (NOT) |
| `( )` | grouping |
| `appl*` | prefix (`:*` works too) |
| `*ology` | suffix |
| `f*r` | infix |
| `te?t` | single character (`?`) |
| `##re##` | regex, whole lexeme |
| `'a b'` | literal term (no operator/wildcard meaning) |
| `"a b c"` | phrase (adjacent words) |
| `a <-> b` | `b` immediately after `a` |
| `a <N> b` | `b` exactly `N` words after `a` |
| `a <~N> b` | within `N` words, either order |
| `a <-N> b` | `a` before `b`, within `N` words |
| `a <!~N> b` | an `a` with no `b` within `N` words |
| `a <!-N> b` | an `a` with no `b` within the next `N` words |

A few comments:

- Proximity operators are read left to right, so `a <~5> b <~5> c` reads as`(a <~5> b) <~5> c`.
- A wildcard that starts with `*`/`?` (`*ology`) and a regex (`##…##`) are matched in the recheck and need a companion term, e.g. `study <~3> *ology` or else you won't be using the index at all.
- A wildcard with a leading literal (`f*r`, `te?t`) uses that as an index prefix.
- Regex matches whole lexemes in the index after splitting and normalization. If you are trying to do complex regex you probably need to do it before indexing on the raw text.
- Real world queries written by users can become really degenerate in this syntax. You might want to discourage complexity on the application side.

## Functions

The `@~@` operator is built on functions, which can also be used directly:

- `ts_prox_within(tsvector, a, b, n)`, `ts_prox_pre(...)`, `ts_prox_not_within(...)`,
  `ts_prox_window(tsvector, text[], int[])` — positional predicates.
- `ts_prox_positions(tsvector, lexeme)` / `ts_prox_positions_prefix(tsvector, prefix)` —
  sorted positions of a lexeme.
- `ts_prox_query(text) -> tsquery` / `ts_prox_match(tsvector, text) -> bool` — the
  compiler behind `@~@` (index selection and recheck).

Notice `ts_prox_window` isn't the same as using the proximity operators in an associative way and is not available via DSL syntax.

The `ts_prox_window`function instead 'chains' the proximity onto each specific lexeme hit rather than onto the spanning phrase formed by the lexemes matched in the earlier query. (If that makes sense I'm sorry.)

Matching uses the `simple` text search configuration (literal, lowercased).

## Development

proxquery is built with [pgrx](https://github.com/pgcentralfoundation/pgrx).

### Prerequisites

- A Rust toolchain (`rustup`; stable is fine).
- `cargo-pgrx`, pinned to the same version as the `pgrx` dependency in
  [Cargo.toml](Cargo.toml) (currently `0.19.1`):

  ```sh
  cargo install --locked cargo-pgrx@0.19.1
  ```

- A PostgreSQL 17 install with its development headers, or let pgrx download and
  build its own (see below).

### First-time setup

`cargo pgrx init` wires up the Postgres instances pgrx manages under `~/.pgrx`.
Either let pgrx build PostgreSQL 17 from source:

```sh
cargo pgrx init --pg17 download
```

or point it at an existing install so it reuses those binaries:

```sh
cargo pgrx init --pg17 $(which pg_config)   # e.g. /opt/homebrew/opt/postgresql@17/bin/pg_config
```

### Run it interactively

Compile the extension, install it into the managed PG17 instance, and drop into a
`psql` session with `proxquery` already created:

```sh
cargo pgrx run pg17
```

```sql
SELECT ts_prox_within(to_tsvector('simple','the quick brown fox'), 'quick', 'fox', 2);
```

`cargo pgrx run` reuses a persistent database, so re-run it after edits to pick up
the freshly built `.so` (the bench scripts `DROP`/`CREATE EXTENSION` to avoid a
stale version).

### Run the tests

Tests live in `#[pg_test]` blocks (see [src/lib.rs](src/lib.rs)) and run inside a
temporary Postgres instance:

```sh
cargo pgrx test pg17        # or: cargo test --features pg_test
```

`pg17` is the local default; CI runs the same suite against `pg16`–`pg18` (see
[Other PostgreSQL versions](#other-postgresql-versions) and
[.github/workflows/test.yml](.github/workflows/test.yml)).

For a quick compile/lint check without spinning up Postgres:

```sh
cargo check
cargo clippy --all-targets
```

### Run the benchmarks

The [bench/](bench/) scripts are plain SQL piped into a `cargo pgrx run` session:

```sh
cargo pgrx run pg17 proxquery < bench/native_vs_proxquery.sql   # proxquery vs native FTS
cargo pgrx run pg17 proxquery < bench/proximity_bench.sql       # proxquery vs the unnest baseline
cargo pgrx run pg17 proxquery < bench/pure_vs_extension.sql     # pure-SQL port vs the extension
```

Corpus size is tunable via psql vars, e.g. `-v ndocs=50000` (see the header
comments in each script). `pure_vs_extension.sql` also loads the pure port from
`sql/proxquery_pure.sql`, so run it from the repo root.

### Install into a system Postgres

To install the built extension into the PostgreSQL on your `PATH` (the one
`pg_config` points to):

```sh
cargo pgrx install --release
```

then `CREATE EXTENSION proxquery;` in that database. To produce a relocatable
directory tree for packaging instead, use `cargo pgrx package`.

### Other PostgreSQL versions

`pg17` is the default for local development. The crate has features for
`pg16`–`pg18`, and CI runs the test suite against each of them
([.github/workflows/test.yml](.github/workflows/test.yml)). Build against another
major version locally by swapping the feature, e.g.:

```sh
cargo pgrx run pg16 --no-default-features --features pg16
```

(Run `cargo pgrx init --pg16 …` first so pgrx knows about that instance.)

## Releasing

Releases are conventional-commit driven. release-plz keeps a Release PR up to
date on `main`; merging it tags `v<x.y.z>` and builds the prebuilt binaries,
while every other commit publishes a rolling `edge` pre-release. Pushing Docker
images to GHCR is a separate manual step. The full flow and the promotion steps
are in [docs/RELEASING.md](docs/RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).

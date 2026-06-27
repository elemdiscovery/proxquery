# proxquery

![proxquery](docs/proxquery.png)

`proxquery` is a PostgreSQL extension that adds the `@~@` operator with a more flexible term-proximity search syntax on top of `tsvector`. Primary usage is for "within N words", ordered proximity, and occurrence-level "not within N" terms. It uses lexeme positions directly from the `tsvector` and a normal GIN index to the extent possible.

The motivation is to implement query syntax similar to dtSearch and Lucene without also implementing an actual custom index. All the usual [tsvector limitations](https://www.postgresql.org/docs/current/textsearch-limitations.html) apply.

There is also a [plain SQL implementation](#pure-sql-port) for when compiled extensions can't be used.

## Install

Requires PostgreSQL 16+ (16, 17, and 18 are built and tested).

### Prebuilt binaries

Each [release](https://github.com/elemdiscovery/proxquery/releases) packages the extension and an installer. Download and run the equivalent of:

```sh
tar xzf proxquery-<version>-pg17-linux-amd64.tar.gz
cd proxquery-<version>-pg17-linux-amd64
./install.sh                 # targets the Postgres on PATH (pg_config)
# or: PG_CONFIG=/path/to/pg_config ./install.sh
```

```sql
CREATE EXTENSION proxquery;
```

### Docker

A Postgres image with proxquery preinstalled:

```sh
docker run --rm -e POSTGRES_PASSWORD=pw ghcr.io/elemdiscovery/proxquery:pg17
```

then `CREATE EXTENSION proxquery;`.

### Pure-SQL port

For managed Postgres, [sql/proxquery_pure.sql](sql/proxquery_pure.sql) is a re-implementation using plain SQL with the same function names and identical results, installed into a dedicated `proxquery` schema.

The usage difference is that the `@~@` operator needs a compiled planner support function, so the pure port does **not** implement it and you need to call two functions for each query to properly use the index.

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

The operator `@~@` is syntax sugar for the compound usage of `ts_prox_query` and `ts_prox_match`. The `ts_prox_query` portion acts on the plain `gin(tsvector)` index and selects candidate rows by lexeme. The `ts_prox_match` then rechecks word positions in order to refine the result.

Ranking results isn't a goal of this extension, but `ts_prox_query(q)` returns a real `tsquery`, so `ts_rank_cd` can be used to get a result. It won't be particularly meaningful for complex queries.

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

- Proximity operators are read left to right, so `a <~5> b <~5> c` reads as `(a <~5> b) <~5> c`.
- Adjacent words have a distance of one, so in `a b c` the `a` and `c` have a distance of two.
- Proximity operators act on the span of the left side term, meaning for `a b c d e f`, the term `(a <~5> f) <~1> c` is a match--the `c` is in between the left side results.
- A wildcard that starts with `*`/`?` (`*ology`) and a regex (`##…##`) can't be pre-filtered so you need a second term in the query such as in `study <~3> *ology` or else you won't be using the index at all.
- A wildcard with a leading literal (`f*r`, `te?t`) uses that prefix as the index filter.
- Regex terms match whole lexemes in the tsvector after splitting and normalization. If you are trying to do complex regex you probably need to do it before indexing on the raw text.
- Real world queries written by users can become really degenerate in this syntax. I suggest discouraging complexity on the application side.

## Functions

The `@~@` operator is built on functions that can also be used directly:

- `ts_prox_within(tsvector, a, b, n)`, `ts_prox_pre(...)`, `ts_prox_not_within(...)`,
  `ts_prox_chain(tsvector, text[], int[])` -- positional predicates.
- `ts_prox_positions(tsvector, lexeme)` / `ts_prox_positions_prefix(tsvector, prefix)` --
  sorted positions of a lexeme.
- `ts_prox_query(text) -> tsquery` / `ts_prox_match(tsvector, text) -> bool` -- the
  compiler behind `@~@` (index selection and recheck).

Notice `ts_prox_chain` isn't the same as using the proximity operators in an associative way and is not available via DSL syntax.

The `ts_prox_chain` function instead 'chains' the proximity onto each specific lexeme hit rather than onto the spanning phrase formed by the lexemes matched in the query evaluation. (If that makes sense I'm sorry.)

Matching uses the `simple` text search configuration.

## Development

`proxquery` is built with [pgrx](https://github.com/pgcentralfoundation/pgrx).

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

### Word Frequency Data

The [docs/wordfrequency.info-top-5000.txt](docs/wordfrequency.info-top-5000.txt) used in testing comes from [www.wordfrequency.info](https://www.wordfrequency.info/samples.asp) and can only be redistributed with attribution.

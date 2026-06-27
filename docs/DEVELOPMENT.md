# Development Notes

`proxquery` is built with [pgrx](https://github.com/pgcentralfoundation/pgrx).

## Prerequisites

- A Rust toolchain (`rustup`; stable is fine).
- `cargo-pgrx`, pinned to the same version as the `pgrx` dependency in
  [Cargo.toml](Cargo.toml) (currently `0.19.1`):

  ```sh
  cargo install --locked cargo-pgrx@0.19.1
  ```

- A PostgreSQL 17 install with its development headers, or let pgrx download and
  build its own (see below).

## First-time setup

`cargo pgrx init` wires up the Postgres instances pgrx manages under `~/.pgrx`.
Either let pgrx build PostgreSQL 17 from source:

```sh
cargo pgrx init --pg17 download
```

or point it at an existing install so it reuses those binaries:

```sh
cargo pgrx init --pg17 $(which pg_config)   # e.g. /opt/homebrew/opt/postgresql@17/bin/pg_config
```

## Run it interactively

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

## Run the tests

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

## Run the benchmarks

The [bench/](bench/) scripts are plain SQL piped into a `cargo pgrx run` session:

```sh
cargo pgrx run pg17 proxquery < bench/native_vs_proxquery.sql   # proxquery vs native FTS
cargo pgrx run pg17 proxquery < bench/proximity_bench.sql       # proxquery vs the unnest baseline
cargo pgrx run pg17 proxquery < bench/pure_vs_extension.sql     # pure-SQL port vs the extension
```

Corpus size is tunable via psql vars, e.g. `-v ndocs=50000` (see the header
comments in each script). `pure_vs_extension.sql` also loads the pure port from
`sql/proxquery_pure.sql`, so run it from the repo root.

## Install into a system Postgres

To install the built extension into the PostgreSQL on your `PATH` (the one
`pg_config` points to):

```sh
cargo pgrx install --release
```

then `CREATE EXTENSION proxquery;` in that database. To produce a relocatable
directory tree for packaging instead, use `cargo pgrx package`.

## Other PostgreSQL versions

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

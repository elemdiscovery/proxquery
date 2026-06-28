# proxquery

![proxquery](docs/proxquery.png)

`proxquery` is a PostgreSQL extension that adds the `@~@` operator with a more flexible term-proximity search syntax on top of `tsvector`. Primary usage is for "within N words", ordered proximity, and occurrence-level "not within N" terms. It uses lexeme positions directly from the `tsvector` and a normal GIN index to the extent possible.

The motivation is to implement query syntax similar to dtSearch and Lucene without also implementing an actual custom index. All the usual [tsvector limitations](https://www.postgresql.org/docs/current/textsearch-limitations.html) apply.

Additionally the extension implements a `proxquery_to_tsvector` alternative to `to_tsvector` that calculates `tsvector` with (debatably) more intuitive positions through lexeme superimposition, with adjustments for accents, emoji, hyphenated words, and CJK.

There is also a [plain SQL implementation](#pure-sql-port) for when compiled extensions can't be used. The port supports the DSL syntax but not the custom `tsvector` builder function.

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

### Pure-SQL port

For managed Postgres, [sql/proxquery_pure.sql](sql/proxquery_pure.sql) is a re-implementation of the DSL using plain SQL with the same function names and identical results, installed into a dedicated `proxquery` schema.

The usage difference is that the `@~@` operator needs a compiled planner support function, so the pure port does **not** implement it and you need to call two functions for each query to properly use the index. The custom `tsvector` building is also not supported.

```sql
SELECT * FROM docs
WHERE body_tsv @@ proxquery.ts_prox_query('quick <~3> fox')   -- GIN index selects
  AND proxquery.ts_prox_match(body_tsv, 'quick <~3> fox');      -- recheck refines
```

The practical difference is that the pure SQL implementation is much, much slower. Based on some [unnecessarily complex benchmarks](https://github.com/elemdiscovery/proxquery/actions/workflows/benchmark.yml) it is more than 20x slower.

The intended usage of the `.sql` file is that you can install it using your usual migration process. Updates (if desired) would be done by full replacement in another migration.

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
| `'café'` | literal term |
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

For additional examples look at the [markdown test files](tests/).

## Text search configuration

By default the `@~@` operator assumes the `simple` config on the `tsvector`. To match another configuration use the `proxquery` function overload of the operator.

```sql
SELECT * FROM docs WHERE body_tsv @~@ proxquery('english', 'running <~3> shoes');

-- or in the pure SQL port
SELECT * FROM docs
WHERE body_tsv @@ proxquery.ts_prox_query('running <~3> shoes', 'english')
  AND proxquery.ts_prox_match(body_tsv, 'running <~3> shoes', 'english');
```

### Custom text search configuration

This kind of custom configuration also works. Use this to remove accents without using the custom extension parser.

```sql
CREATE EXTENSION IF NOT EXISTS unaccent;

DROP TEXT SEARCH CONFIGURATION IF EXISTS simple_unaccent;

CREATE TEXT SEARCH CONFIGURATION simple_unaccent (COPY = simple);

ALTER TEXT SEARCH CONFIGURATION simple_unaccent
    ALTER MAPPING FOR
        asciiword, word, numword,
        asciihword, hword, numhword,
        hword_asciipart, hword_part, hword_numpart
    WITH unaccent, simple;
```

## Extension-only `proxquery_to_tsvector`

`proxquery_to_tsvector(body, analyzer)` builds the `tsvector` with a custom tokenizer instead of a stock config.

You then use `@~@` with `proxquery` and the corresponding tokenizer when searching.

An example of what this allows is searching with and without accents on the same index.

```sql
CREATE TABLE docs (
  id   bigserial PRIMARY KEY,
  body text,
  tsv  tsvector GENERATED ALWAYS AS (proxquery_to_tsvector(body, 'prox_icu')) STORED
);
CREATE INDEX docs_tsv_gin ON docs USING gin (tsv);

INSERT INTO docs (body) VALUES
  ('un café noir, please'),
  ('a plain cafe noir here'),
  ('the café is closed');

-- find "café noir" and "cafe noir"
SELECT id, body FROM docs WHERE tsv @~@ proxquery('prox_icu', 'cafe <-> noir');

-- single quote literal `'café'` for only accented results
SELECT id, body FROM docs WHERE tsv @~@ proxquery('prox_icu', '''café'' <-> noir');
```

The built-in analyzers:

| Analyzer | Notes |
| --- | --- |
| `prox_icu` | default; ICU library segmentation, folds case and accents, keeps emoji |
| `prox_unicode` | Same as default but unicode segmentation (per character CJK) |
| `prox_icu_accent` | accent-sensitive (`café` ≠ `cafe`) |
| `prox_icu_no_emoji` | drops emoji instead of indexing them |

You can combine the custom analyzers with built-in dictionaries, with `:dict`, e.g. `prox_icu:english_stem`.

## Functions

The `@~@` operator is built on functions that can also be used directly:

- `ts_prox_query(text [, regconfig]) -> tsquery` -- uses the gin index.
- `ts_prox_match(tsvector, text [, regconfig]) -> bool` -- rechecks the match based on positions.

The custom tokenizer relies on `proxquery_to_tsvector` and `proxquery_match` which includes a parameter for which analyzer to use.

- `proxquery_to_tsvector(body: text, analyzer: text) -> tsvector` -- builds a `tsvector` with a given analyzer.
- `proxquery_match(tsvector, query: text, analyzer: text) -> bool` -- positional recheck for a given analyzer.

These then use lower level functions that you probably don't need:

- `ts_prox_within(tsvector, a, b, n)`, `ts_prox_pre(...)`, `ts_prox_not_within(...)`,
  `ts_prox_chain(tsvector, text[], int[])` -- positional predicates.
- `ts_prox_positions(tsvector, lexeme)` / `ts_prox_positions_prefix(tsvector, prefix)` --
  sorted positions of a lexeme.

Notice `ts_prox_chain` isn't the same as using the proximity operators in an associative way and is not available via DSL syntax.

The `ts_prox_chain` function instead 'chains' the proximity onto each specific lexeme hit rather than onto the spanning phrase formed by the lexemes matched in the query evaluation. (If that makes sense I'm sorry.)

## Development

For the development workflow, reference: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)

## License

MIT. See [LICENSE](LICENSE).

### Word Frequency Data

The [docs/wordfrequency.info-top-5000.txt](docs/wordfrequency.info-top-5000.txt) used in testing comes from [www.wordfrequency.info](https://www.wordfrequency.info/samples.asp) and can only be redistributed with attribution.

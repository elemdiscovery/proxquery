//! Markdown corpus loaders (test-only).
//!
//! Both test corpora live in human-readable markdown specs of GFM tables (each value
//! cell wrapped in `` ` `` with literal `|` escaped `\|`, so they round-trip exactly):
//!   * `tests/parity_cases.md` — the cross-implementation parity corpus (extension vs
//!     pure-SQL port), loaded by [`load_parity`] into the temp tables the differential
//!     runner (`sql/proxquery_diff_test.sql`) reads.
//!   * `tests/tokenizer_cases.md` — the extension-only tokenizer golden corpus, loaded
//!     by [`load_tokenizer`] into `_prox_tok` for the `tokenizer_corpus` test.
//!
//! Only compiled under the `pg_test` feature (which also pulls in `pulldown-cmark`);
//! never part of a release build.

use pgrx::prelude::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

/// A parsed GFM table: its header cells and its data rows.
struct Table {
    headers: Vec<String>,
    rows: Vec<Vec<String>>,
}

/// Parse every GFM table in `md`. A cell's value is the concatenation of its text and
/// inline-code spans, trimmed — so a backticked cell with an escaped pipe
/// (`` `a \| b` ``) round-trips to `a | b`.
fn parse_tables(md: &str) -> Vec<Table> {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_TABLES);
    let mut tables: Vec<Table> = Vec::new();
    let mut headers: Vec<String> = Vec::new();
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut in_head = false;
    let mut in_cell = false;
    for ev in Parser::new_ext(md, opts) {
        match ev {
            Event::Start(Tag::Table(_)) => {
                headers = Vec::new();
                rows = Vec::new();
            }
            Event::End(TagEnd::Table) => tables.push(Table {
                headers: std::mem::take(&mut headers),
                rows: std::mem::take(&mut rows),
            }),
            Event::Start(Tag::TableHead) => in_head = true,
            Event::End(TagEnd::TableHead) => in_head = false,
            Event::End(TagEnd::TableRow) => {
                if !in_head {
                    rows.push(std::mem::take(&mut row));
                }
            }
            Event::Start(Tag::TableCell) => {
                in_cell = true;
                cell = String::new();
            }
            Event::End(TagEnd::TableCell) => {
                in_cell = false;
                let v = std::mem::take(&mut cell).trim().to_string();
                if in_head {
                    headers.push(v);
                } else {
                    row.push(v);
                }
            }
            Event::Text(t) | Event::Code(t) if in_cell => {
                cell.push_str(&t);
            }
            _ => {}
        }
    }
    tables
}

/// All data rows from every table whose header matches `headers` (the spec splits one
/// logical corpus across several sub-tables, one per commented group).
fn rows_for(tables: &[Table], headers: &[&str]) -> Vec<Vec<String>> {
    tables
        .iter()
        .filter(|t| t.headers.iter().map(String::as_str).eq(headers.iter().copied()))
        .flat_map(|t| t.rows.iter().cloned())
        .collect()
}

/// Dollar-quote a value with a tag absent from the corpus (values may contain `$$`,
/// single quotes, etc., but never `$pq$`).
fn dq(s: &str) -> String {
    format!("$pq${s}$pq$")
}

fn insert_rows(table: &str, rows: &[Vec<String>]) {
    if rows.is_empty() {
        return;
    }
    let values: Vec<String> = rows
        .iter()
        .map(|r| format!("({})", r.iter().map(|c| dq(c)).collect::<Vec<_>>().join(",")))
        .collect();
    Spi::run(&format!("INSERT INTO {table} VALUES {}", values.join(","))).unwrap();
}

/// Load `tests/parity_cases.md` into the temp tables the differential / golden runners
/// read (`_prox_cases`, `_prox_match`, `_prox_cfg_match`). Best-effort builds the
/// `public.simple_unaccent` config; its rows are skipped when contrib `unaccent` is
/// absent (so the corpus still runs on a Postgres without contrib).
pub fn load_parity() {
    let tables = parse_tables(include_str!("../tests/parity_cases.md"));
    let cases = rows_for(&tables, &["label", "expression", "expected"]);
    let matches = rows_for(&tables, &["label", "doc", "query", "expected"]);
    let cfgs = rows_for(&tables, &["label", "config", "doc", "query", "expected"]);

    Spi::run(
        "DROP TABLE IF EXISTS _prox_cases; \
         CREATE TEMP TABLE _prox_cases(label text, expr text, expected text); \
         DROP TABLE IF EXISTS _prox_match; \
         CREATE TEMP TABLE _prox_match(label text, doc text, query text, expected text); \
         DROP TABLE IF EXISTS _prox_cfg_match; \
         CREATE TEMP TABLE _prox_cfg_match(label text, cfg text, doc text, query text, expected text)",
    )
    .unwrap();

    // Best-effort accent-folding config (needs contrib `unaccent`). Schema-qualified so
    // it resolves under either implementation's pinned search_path.
    let unaccent_ok = Spi::run(
        "CREATE EXTENSION IF NOT EXISTS unaccent; \
         DROP TEXT SEARCH CONFIGURATION IF EXISTS public.simple_unaccent; \
         CREATE TEXT SEARCH CONFIGURATION public.simple_unaccent (COPY = pg_catalog.simple); \
         ALTER TEXT SEARCH CONFIGURATION public.simple_unaccent \
           ALTER MAPPING FOR asciiword, word, numword, asciihword, hword, numhword, \
                             hword_asciipart, hword_part, hword_numpart \
           WITH unaccent, simple",
    )
    .is_ok();

    insert_rows("_prox_cases", &cases);
    insert_rows("_prox_match", &matches);
    let cfgs: Vec<Vec<String>> = cfgs
        .into_iter()
        .filter(|r| unaccent_ok || !r[1].starts_with("public.simple_unaccent"))
        .collect();
    insert_rows("_prox_cfg_match", &cfgs);
}

/// Load `tests/tokenizer_cases.md` into `_prox_tok(label, analyzer, input, expected)`
/// for the `tokenizer_corpus` test (which asserts `proxquery_to_tsvector(input,
/// analyzer) = expected::tsvector` per row).
pub fn load_tokenizer() {
    let tables = parse_tables(include_str!("../tests/tokenizer_cases.md"));
    let rows = rows_for(&tables, &["label", "analyzer", "input", "expected"]);
    Spi::run(
        "DROP TABLE IF EXISTS _prox_tok; \
         CREATE TEMP TABLE _prox_tok(label text, analyzer text, input text, expected text)",
    )
    .unwrap();
    insert_rows("_prox_tok", &rows);
}

/// Load `tests/analyzer_cases.md` into `_prox_an(label, analyzer, doc, query, expected)`
/// for the `analyzer_operator_corpus` test (the DSL operator surface under the custom
/// tokenizer, checked via `proxquery_match` and the `@~@` index path).
pub fn load_analyzer_ops() {
    let tables = parse_tables(include_str!("../tests/analyzer_cases.md"));
    let rows = rows_for(&tables, &["label", "analyzer", "doc", "query", "expected"]);
    Spi::run(
        "DROP TABLE IF EXISTS _prox_an; \
         CREATE TEMP TABLE _prox_an(label text, analyzer text, doc text, query text, expected text)",
    )
    .unwrap();
    insert_rows("_prox_an", &rows);
}

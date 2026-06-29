//! proxquery — positional proximity predicates for `tsvector` full-text search.
//!
//! Milestone 1: the position accessor ([`tsvector`]) and the proximity predicates
//! ([`proximity`]), exposed as SQL recheck filters. These pair with a plain GIN
//! `@@` candidate selection today; the proximity query compiler and the single
//! `@~@` operator land in later milestones (see docs/IMPLEMENTATION_PLAN.md).

use pgrx::prelude::*;

#[cfg(any(test, feature = "pg_test"))]
mod corpus;
mod dsl;
mod proximity;
mod support;
mod tokenizer;
mod tsvector;

use pgrx::datum::Internal;
use std::cell::RefCell;
use std::rc::Rc;
use tsvector::TsVector;

::pgrx::pg_module_magic!(name, version);

/// Sorted positions of one lexeme (`int[]`; empty if absent or position-less).
/// The core primitive — a binary search plus one position-array read.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_positions(v: TsVector, lexeme: &str) -> Vec<i32> {
    v.positions(lexeme.as_bytes())
}

/// Merged sorted positions over every lexeme beginning with `prefix` (`appl*`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_positions_prefix(v: TsVector, prefix: &str) -> Vec<i32> {
    v.positions_prefix(prefix.as_bytes())
}

/// Some `a` within `n` of some `b`, either order (`a <~n> b`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_within(v: TsVector, a: &str, b: &str, n: i32) -> bool {
    proximity::within(&v.positions(a.as_bytes()), &v.positions(b.as_bytes()), n)
}

/// Some `a` before some `b` within `n`, ordered (`a <-n> b`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_pre(v: TsVector, a: &str, b: &str, n: i32) -> bool {
    proximity::pre(&v.positions(a.as_bytes()), &v.positions(b.as_bytes()), n)
}

/// Occurrence-level: some `a` with no `b` within `n` (`a <!~n> b`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_not_within(v: TsVector, a: &str, b: &str, n: i32) -> bool {
    proximity::not_within(&v.positions(a.as_bytes()), &v.positions(b.as_bytes()), n, false)
}

/// Same-occurrence chain over `terms`, each consecutive pair within its
/// `gaps[i]`, mutually within the gaps. `gaps` must have exactly one fewer
/// element than `terms`.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_chain(v: TsVector, terms: Vec<String>, gaps: Vec<i32>) -> bool {
    if terms.is_empty() || gaps.len() + 1 != terms.len() {
        error!(
            "ts_prox_chain: gaps length must be one less than terms length (got {} terms, {} gaps)",
            terms.len(),
            gaps.len()
        );
    }
    let positions: Vec<Vec<i32>> = terms.iter().map(|t| v.positions(t.as_bytes())).collect();
    proximity::chain(&positions, &gaps)
}

// --- proxquery DSL compiler (Milestone 2) --------------------------------

/// Parse a proxquery DSL string and emit the lexeme-presence skeleton as a
/// `to_tsquery('simple', …)` input string. Used by the `ts_prox_query` wrapper
/// below; exposed for tests and debugging. Errors on malformed or purely
/// negative queries.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_query_skeleton(query: &str) -> String {
    match dsl::to_tsquery_string(query) {
        Ok(s) => s,
        Err(e) => error!("ts_prox_query: {e}"),
    }
}

// The user-facing compiler entry point: one query string → the index-selection
// tsquery. A thin SQL wrapper so the result is a real `tsquery` (no custom
// return-type boundary needed) and the planner can fold it into an index scan.
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_query(query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT to_tsquery('simple', ts_prox_query_skeleton($1)) $$;
"#,
    name = "ts_prox_query_wrapper",
    requires = [ts_prox_query_skeleton],
);

/// Introspection: the `to_tsquery('simple', …)` input string whose `@@` is EXACTLY
/// the positional recheck for a query that maps cleanly onto native `tsquery` phrase
/// operators (bounded within/pre/phrase over plain terms — see
/// [`dsl::native_tsquery_string`]), or NULL when the query isn't native-expressible.
/// This is the recheck-dropping form the pure-SQL port and `ts_prox_recheck`'s native
/// fast-path use; exposed so one can check whether — and to what — a query pushes down
/// (`SELECT ts_prox_query_native('a <~3> b')`). NOTE: the `@~@` planner support only
/// *rewrites a constant clause* to this for phrase/exact/boolean shapes; `within`/`pre`
/// keep the selective `a & b` skeleton + recheck instead (see
/// [`dsl::simplify_tsquery_string`]), even though they stay native-expressible here.
#[pg_extern(immutable, parallel_safe, strict)]
fn ts_prox_query_native_string(query: &str) -> Option<String> {
    dsl::native_tsquery_string(query)
}

// `tsquery` form of the native skeleton — introspection for the pushdown expansion.
// NULL for a non-native query. `::tsquery` (tsqueryin) takes the lexemes VERBATIM — the
// SAME path the `@~@` C support uses (see `support::index_condition`) and the pure port's
// `ts_prox_query_native`. NOT `to_tsquery`: that re-tokenizes the lexemes, expanding a
// single-quoted literal like `'a-b-c'` into the phrase `'a-b-c' <-> 'a' <-> 'b' <-> 'c'`,
// which both breaks the "@@ is EXACTLY the recheck" contract and diverges from the port.
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_query_native(query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT ts_prox_query_native_string($1)::tsquery $$;
"#,
    name = "ts_prox_query_native_wrapper",
    requires = [ts_prox_query_native_string],
);

/// The recheck-droppable native tsquery, or NULL when the recheck is needed. Unlike
/// [`ts_prox_query_native_string`], this is `None` for `within`/`pre`/`not-within` (whose
/// native form is exact but NON-selective — it must keep the `a & b` skeleton + recheck,
/// never drive the index alone). Non-NULL exactly when `tsv @@ ts_prox_query_exact(q)`
/// alone is the full match: plain boolean / phrase / prefix. Same gate the `@~@` planner
/// `simplify` uses ([`dsl::simplify_tsquery_string`]); exposed so the pure-SQL port's
/// recommended one-clause form stays drop-in-portable to the native extension.
#[pg_extern(immutable, parallel_safe, strict)]
fn ts_prox_query_exact_string(query: &str) -> Option<String> {
    dsl::simplify_tsquery_string(query)
}

// `tsquery` form of the recheck-droppable native query, mirroring the pure port's
// `ts_prox_query_exact`. `::tsquery` (tsqueryin) takes the lexemes VERBATIM, matching the
// recheck's exact byte lookup; NULL (non-droppable / malformed) stays NULL.
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_query_exact(query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT ts_prox_query_exact_string($1)::tsquery $$;
"#,
    name = "ts_prox_query_exact_wrapper",
    requires = [ts_prox_query_exact_string],
);

/// Whether the recheck is droppable for `query` under `cfg` — the gate for the 3-arg
/// `ts_prox_query_exact`. True for boolean / phrase / prefix queries whose every term
/// resolves to ≥1 lexeme under `cfg`; false for within/pre/not-within, glob-suffix,
/// regex, NOT, or a stopword-emptied branch. When true the index selection
/// `ts_prox_query(q, cfg)` is a subset of the recheck, so the recheck folds away.
/// `cfg` arrives as a plain oid (regconfig is binary-coercible).
#[pg_extern(immutable, parallel_safe, strict)]
fn ts_prox_query_exact_cfg_droppable(query: &str, cfg: pgrx::pg_sys::Oid) -> bool {
    dsl::cfg_exact_droppable(query, cfg)
}

// `ts_prox_query_exact(q, cfg)` IS `ts_prox_query(q, cfg)` gated by droppability: the
// recheck-droppable tsquery is the index selection itself (so the filter and the gate are
// identical logic), or NULL when the recheck is needed. The CASE short-circuits, so
// `ts_prox_query` (which raises on a keyless query) is only evaluated for a droppable —
// hence keyed — query.
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_query_exact(query text, cfg regconfig) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT CASE WHEN ts_prox_query_exact_cfg_droppable($1, $2::oid)
                      THEN ts_prox_query($1, $2) END $$;
"#,
    name = "ts_prox_query_exact_cfg_wrapper",
    requires = [ts_prox_query_exact_cfg_droppable, "ts_prox_query_cfg_wrapper"],
);

// Consolidated indexable search: one INLINABLE function = `@@ ts_prox_query(q)` plus the
// recheck-droppable fold — identical to the pure port's `ts_prox_search`, so the recommended
// one-call SQL is drop-in portable across the pure→native migration. NOT `STRICT` (the `OR`
// is nonstrict — a strict SQL function with a nonstrict body is not inlined, and inlining is
// what re-exposes the `@@` to the GIN index). Index use therefore rides on inlining; the test
// suite EXPLAINs it and asserts a Bitmap Index Scan so a regression is loud, not a silent seq
// scan. (Extension users normally just write `@~@`, which the C support fn already optimizes.)
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_search(v tsvector, query text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT v @@ ts_prox_query(query)
              AND (ts_prox_query_exact(query) IS NOT NULL OR ts_prox_recheck(v, query)) $$;
"#,
    name = "ts_prox_search_wrapper",
    requires = ["ts_prox_query_wrapper", "ts_prox_query_exact_wrapper", ts_prox_recheck],
);

// Config-aware skeleton: same presence skeleton, but lowered through the column's
// text-search config (`to_tsquery(cfg, …)` stems/unaccents the lexemes exactly as
// the recheck's `to_tsvector(cfg, term)` does, so selection and recheck agree). The
// skeleton string itself is config-independent — only the wrapping config changes.
pgrx::extension_sql!(
    r#"
CREATE FUNCTION ts_prox_query(query text, cfg regconfig) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT to_tsquery(cfg, ts_prox_query_skeleton($1)) $$;
"#,
    name = "ts_prox_query_cfg_wrapper",
    requires = [ts_prox_query_skeleton],
);

thread_local! {
    // The recheck runs per candidate row with the same constant query string, so
    // re-parsing it each time is pure overhead. Cache the parsed+normalized AST
    // keyed by the string (a scan reuses one entry). The `Rc` lets the hot path
    // be a string compare + refcount bump, and lets us drop the `RefCell` borrow
    // before any `eval`/`error!` — holding it across an ereport (longjmp) would
    // leave the cell permanently borrowed.
    static PROXMATCH_AST: RefCell<Option<(String, Rc<dsl::Node>)>> = const { RefCell::new(None) };
}

/// Parse + normalize `query`, reusing the per-scan AST cache. The `RefCell` borrow
/// is released before any `?`/`error!` (a longjmp across it would leak the borrow).
fn cached_ast(query: &str) -> Result<Rc<dsl::Node>, String> {
    if let Some(node) =
        PROXMATCH_AST.with(|c| c.borrow().as_ref().and_then(|(q, n)| (q == query).then(|| Rc::clone(n))))
    {
        return Ok(node);
    }
    let parsed = dsl::normalize(dsl::parse(query)?)?;
    dsl::validate_regexes(&parsed)?; // a malformed ##regex## fails the query up front
    let parsed = Rc::new(parsed);
    PROXMATCH_AST.with(|c| *c.borrow_mut() = Some((query.to_owned(), Rc::clone(&parsed))));
    Ok(parsed)
}

/// Evaluate the proxquery DSL's positional semantics on `v` — the recheck that
/// pairs with `ts_prox_query` for index selection (`v @@ ts_prox_query(q) AND
/// ts_prox_recheck(v, q)`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_recheck(v: TsVector, query: &str) -> bool {
    let node = match cached_ast(query) {
        Ok(n) => n,
        Err(e) => error!("ts_prox_recheck: {e}"),
    };
    match dsl::eval_match(&node, &v, dsl::Resolver::Literal) {
        Ok(m) => m,
        Err(e) => error!("ts_prox_recheck: {e}"),
    }
}

/// Config-aware recheck: resolve each query *term* through `cfg`
/// (`to_tsvector(cfg, term)`) so it matches a column built with that text-search
/// config (stemmed/unaccented/locale-folded lexemes). The `simple` 2-arg
/// [`ts_prox_recheck`] is the literal-lexeme fast path; this is the explicit-config
/// form behind the 3-arg `ts_prox_recheck(tsvector, text, regconfig)` overload and
/// the `@~@ proxquery(cfg, q)` operator. `cfg` arrives as a plain `oid` (regconfig
/// is binary-coercible); the SQL wrappers do the `regconfig::oid` cast.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_recheck_cfg(v: TsVector, query: &str, cfg: pgrx::pg_sys::Oid) -> bool {
    let node = match cached_ast(query) {
        Ok(n) => n,
        Err(e) => error!("ts_prox_recheck: {e}"),
    };
    match dsl::eval_match(&node, &v, dsl::Resolver::Cfg(cfg)) {
        Ok(m) => m,
        Err(e) => error!("ts_prox_recheck: {e}"),
    }
}

/// Analyzer-aware recheck: resolve each query atom through the named custom Unicode
/// tokenizer so a query matches a column built with `proxquery_to_tsvector(body,
/// analyzer)` — the query side of that symmetry (a query `café` folds to the same
/// superimposed `café`/`cafe` the indexer stored). Extension-only; the pure-SQL port
/// can't run the Rust tokenizer.
#[pg_extern(immutable, parallel_safe)]
fn proxquery_recheck(v: TsVector, query: &str, analyzer: &str) -> bool {
    let kind = match crate::tokenizer::AnalyzerKind::from_name(analyzer) {
        Some(k) => k,
        None => error!("proxquery_recheck: unknown analyzer '{analyzer}'"),
    };
    let node = match cached_ast(query) {
        Ok(n) => n,
        Err(e) => error!("proxquery_recheck: {e}"),
    };
    match dsl::eval_match(&node, &v, dsl::Resolver::Analyzer(kind)) {
        Ok(m) => m,
        Err(e) => error!("proxquery_recheck: {e}"),
    }
}

/// Analyzer-aware index probe: the lexeme-presence tsquery with each term resolved
/// through the analyzer (symmetric with `proxquery_to_tsvector`). Returns the
/// tsquery *text*; the SQL `ts_prox_query(proxquery)` wrapper casts it `::tsquery`
/// (tsqueryin takes the quoted lexemes verbatim — no re-tokenization). The generic
/// `@~@` support fn then injects `tsv @@ ts_prox_query(proxquery)` as the GIN
/// index condition.
#[pg_extern(immutable, parallel_safe, strict)]
fn proxquery_build_query(query: &str, analyzer: &str) -> String {
    let kind = match crate::tokenizer::AnalyzerKind::from_name(analyzer) {
        Some(k) => k,
        None => error!("proxquery_query: unknown analyzer '{analyzer}'"),
    };
    match dsl::analyzer_tsquery_string(query, kind) {
        Ok(s) => s,
        Err(e) => error!("proxquery_query: {e}"),
    }
}

/// True if `src` names a proxquery analyzer (vs a stock `regconfig`) — the dispatch
/// key for the unified `proxquery(src, q)` operand.
#[pg_extern(immutable, parallel_safe, strict)]
fn proxquery_is_analyzer(src: &str) -> bool {
    crate::tokenizer::AnalyzerKind::from_name(src).is_some()
}

// The single-clause surface: `text_tsv @~@ 'a <~5> b'`. For now it is `ts_prox_recheck`
// sugar (a seq-scan recheck); the planner support function below teaches it to use
// the GIN index. The right operand is the DSL string.
pgrx::extension_sql!(
    r#"
CREATE OPERATOR @~@ (
    LEFTARG = tsvector,
    RIGHTARG = text,
    FUNCTION = ts_prox_recheck
);
"#,
    name = "proxmatch_operator",
    requires = [ts_prox_recheck],
);

/// Planner support function for `@~@` / `ts_prox_recheck`. Two requests (see
/// [`support`]): *simplify* rewrites a constant, native-expressible query to a plain
/// `tsvector @@ ts_prox_query_native(q)` (no positional recheck); *index condition*
/// derives the lossy presence skeleton (`tsvector @@ ts_prox_query(q)` + recheck) for
/// everything else, so the operator still uses a plain GIN tsvector index.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_query_support(arg: Internal) -> Internal {
    // "No support" must be a non-NULL datum holding a NULL pointer — returning
    // SQL NULL trips `FunctionCall1Coll`'s "function returned NULL" error.
    let no_support = || Internal::from(Some(pgrx::pg_sys::Datum::null()));
    let node = match arg.unwrap() {
        Some(datum) => datum.cast_mut_ptr::<pgrx::pg_sys::Node>(),
        None => return no_support(),
    };
    // Two requests, dispatched by node type (each guards its own): `simplify` rewrites
    // a native-expressible constant query to a plain `@@` (dropping the recheck);
    // `index_condition` derives the lossy presence skeleton for everything else.
    unsafe { support::simplify(node).or_else(|| support::index_condition(node)) }
        .unwrap_or_else(no_support)
}

// Attach the support fn. Superuser-only, but a trusted extension's install
// script runs privileged, so this works on managed/Neon-style installs too.
pgrx::extension_sql!(
    "ALTER FUNCTION ts_prox_recheck(tsvector, text) SUPPORT ts_prox_query_support;",
    name = "proxmatch_support",
    requires = [ts_prox_recheck, ts_prox_query_support],
);

// --- the @~@ operand: one `proxquery(src, q)` for both regconfig and analyzer ------
//
// The 3-arg `ts_prox_query`/`ts_prox_recheck(…, regconfig)` are the explicit-config
// two-clause form (mirrored by the pure-SQL port). The `@~@` operator can't take a
// third arg, so the normalization SOURCE rides in one typed operand: `proxquery(src, q)`,
// where `src` names EITHER a stock `regconfig` OR a custom analyzer. The operand's
// `ts_prox_query`/`ts_prox_recheck` dispatch on `src` (`proxquery_is_analyzer`): an
// analyzer resolves through the Rust tokenizer, anything else through
// `to_tsvector(src::regconfig, …)`. So `tsv @~@ proxquery('english', q)` and
// `tsv @~@ proxquery('prox_icu', q)` are spelled identically. The generic support fn
// rewrites `tsv @~@ proxquery(...)` to `tsv @@ ts_prox_query(proxquery)` for the GIN
// index (`q` is attr 2, where the support fn's keyless guard reads it).
pgrx::extension_sql!(
    r#"
-- 3-arg recheck: regconfig cast to oid for the internal (regconfig is an oid alias).
CREATE FUNCTION ts_prox_recheck(v tsvector, query text, cfg regconfig) RETURNS bool
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT ts_prox_recheck_cfg($1, $2, $3::oid) $$;

-- 3-arg consolidated search (config-aware): the one-call form for a non-`simple` column,
-- mirroring the pure port's `ts_prox_search(tsv, q, cfg)`. Inlinable (no SET clause), so the
-- `@@ ts_prox_query(q, cfg)` clause drives the index, and for a recheck-droppable (boolean /
-- phrase / prefix) constant query the `(ts_prox_query_exact(q, cfg) IS NOT NULL OR …)`
-- const-folds away, dropping the per-row recheck (and its re-detoast) — the resolved-lexeme
-- skeleton is exactly the match. within/pre and the lossy shapes keep the recheck.
CREATE FUNCTION ts_prox_search(v tsvector, query text, cfg regconfig) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT v @@ ts_prox_query(query, cfg)
              AND (ts_prox_query_exact(query, cfg) IS NOT NULL OR ts_prox_recheck(v, query, cfg)) $$;

-- The typed right operand for @~@: a (source, query) pair. `src` is a regconfig name
-- or a proxquery analyzer name.
CREATE TYPE proxquery AS (src text, q text);

CREATE FUNCTION proxquery(src text, q text) RETURNS proxquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT ROW($1, $2)::proxquery $$;

-- Probe over the operand: an analyzer builds a resolved tsquery (Rust, cast verbatim);
-- a regconfig lowers through to_tsquery. SQL + CASE so it const-folds at plan time and
-- only the taken branch runs (no spurious regconfig cast for an analyzer name).
CREATE FUNCTION ts_prox_query(pq proxquery) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT CASE WHEN proxquery_is_analyzer((pq).src)
                      THEN proxquery_build_query((pq).q, (pq).src)::tsquery
                      ELSE to_tsquery((pq).src::regconfig, ts_prox_query_skeleton((pq).q))
                 END $$;

-- Recheck over the operand. plpgsql (not sql) so the planner does NOT inline the
-- operator into a bare call — inlining would strip the @~@ OpExpr and bypass the
-- support function, losing the index.
CREATE FUNCTION ts_prox_recheck(v tsvector, pq proxquery) RETURNS bool
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ BEGIN
        IF proxquery_is_analyzer(pq.src) THEN
            RETURN proxquery_recheck(v, pq.q, pq.src);
        ELSE
            RETURN ts_prox_recheck_cfg(v, pq.q, pq.src::regconfig::oid);
        END IF;
    END $$;

CREATE OPERATOR @~@ (
    LEFTARG = tsvector,
    RIGHTARG = proxquery,
    FUNCTION = ts_prox_recheck
);

ALTER FUNCTION ts_prox_recheck(tsvector, proxquery) SUPPORT ts_prox_query_support;
"#,
    name = "proxquery_config_aware",
    requires = [
        ts_prox_query_skeleton,
        ts_prox_recheck_cfg,
        ts_prox_query_support,
        proxquery_build_query,
        proxquery_recheck,
        proxquery_is_analyzer,
        "ts_prox_query_cfg_wrapper",
        "ts_prox_query_exact_cfg_wrapper"
    ],
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    fn b(sql: &str) -> bool {
        Spi::get_one::<bool>(sql).unwrap().unwrap()
    }

    fn ints(sql: &str) -> Vec<i32> {
        Spi::get_one::<Vec<i32>>(sql).unwrap().unwrap()
    }

    #[pg_test]
    fn positions_basic_and_prefix() {
        // apple@1 apple@2 orange@3  → two occurrences of apple.
        assert_eq!(
            ints("SELECT ts_prox_positions(to_tsvector('simple','apple apple orange'), 'apple')"),
            vec![1, 2]
        );
        // absent lexeme → empty, not NULL.
        assert!(ints("SELECT ts_prox_positions(to_tsvector('simple','apple'), 'zzz')").is_empty());
        // appl* spans apple@1 + apply@2.
        assert_eq!(
            ints("SELECT ts_prox_positions_prefix(to_tsvector('simple','apple apply orange'), 'appl')"),
            vec![1, 2]
        );
    }

    #[pg_test]
    fn within_either_order() {
        // the@1 quick@2 brown@3 fox@4 → |quick − fox| = 2.
        let v = "to_tsvector('simple','the quick brown fox')";
        assert!(b(&format!("SELECT ts_prox_within({v}, 'quick', 'fox', 2)")));
        assert!(b(&format!("SELECT ts_prox_within({v}, 'fox', 'quick', 2)"))); // symmetric
        assert!(!b(&format!("SELECT ts_prox_within({v}, 'quick', 'fox', 1)")));
    }

    #[pg_test]
    fn pre_is_ordered() {
        // quick@1 brown@2 fox@3.
        let v = "to_tsvector('simple','quick brown fox')";
        assert!(b(&format!("SELECT ts_prox_pre({v}, 'quick', 'fox', 2)")));
        assert!(!b(&format!("SELECT ts_prox_pre({v}, 'fox', 'quick', 2)"))); // wrong order
    }

    #[pg_test]
    fn not_within_is_occurrence_level() {
        // email@1 confidential@2 … confidential@7. One 'confidential' is near
        // 'email', the other (pos 7) is not — the classic boilerplate case.
        let v = "to_tsvector('simple','email confidential foo bar baz qux confidential')";
        // Document-level `confidential AND NOT within(...,3)` would be FALSE here
        // (an email-adjacent confidential exists); the occurrence-level predicate
        // correctly finds the isolated one.
        assert!(b(&format!("SELECT ts_prox_not_within({v}, 'confidential', 'email', 3)")));
        // Within 6 of *every* confidential occurrence ⇒ none isolated.
        assert!(!b(&format!("SELECT ts_prox_not_within({v}, 'confidential', 'email', 6)")));
        // No 'email' at all ⇒ every 'confidential' is isolated.
        let w = "to_tsvector('simple','confidential report only')";
        assert!(b(&format!("SELECT ts_prox_not_within({w}, 'confidential', 'email', 5)")));
    }

    #[pg_test]
    fn not_within_fails_open_at_position_cap() {
        // Past token 16383 a tsvector clamps every position onto the cap (16383),
        // collapsing the tail — so "near b" can't be told from "far from b". The
        // negative operators fail OPEN there: they surface the doc for review
        // rather than asserting an isolation they can't verify.

        // A literal position at the cap round-trips through the accessor.
        assert_eq!(
            ints("SELECT ts_prox_positions($$'email':16383$$::tsvector, 'email')"),
            vec![16383]
        );

        // Avoid term ('email') at the cap, co-located with 'confidential': without
        // the guard this reads as "near" ⇒ not isolated ⇒ false; the guard flips it
        // open. True via the direct predicate and the DSL recheck (both the
        // unordered <!~> and ordered <!-> negations).
        let sat = "$$'confidential':16383 'email':16383$$::tsvector";
        assert!(b(&format!("SELECT ts_prox_not_within({sat}, 'confidential', 'email', 3)")));
        assert!(b(&format!("SELECT ts_prox_recheck({sat}, 'confidential <!~3> email')")));
        assert!(b(&format!("SELECT ts_prox_recheck({sat}, 'confidential <!-3> email')")));

        // Control — no saturation: a genuinely co-located pair is near, so this is
        // NOT the fail-open path and the predicate still returns false.
        let near = "$$'confidential':5 'email':5$$::tsvector";
        assert!(!b(&format!("SELECT ts_prox_not_within({near}, 'confidential', 'email', 3)")));
        assert!(!b(&format!("SELECT ts_prox_recheck({near}, 'confidential <!~3> email')")));

        // Scope — the guard keys off the AVOID term, not the subject. The subject
        // ('confidential') is at the cap but the avoid term ('email') is not, and
        // they're near ⇒ no fail-open, still false.
        let subj = "$$'confidential':16383 'email':16380$$::tsvector";
        assert!(!b(&format!("SELECT ts_prox_not_within({subj}, 'confidential', 'email', 5)")));
    }

    #[pg_test]
    fn chain_pins_same_occurrence() {
        // alpha@1 xx@2 beta@3 yy@4 gamma@5.
        let v = "to_tsvector('simple','alpha xx beta yy gamma')";
        assert!(b(&format!(
            "SELECT ts_prox_chain({v}, ARRAY['alpha','beta','gamma'], ARRAY[2,2])"
        )));
        // Tighten the gaps below the spacing ⇒ no single chain fits.
        assert!(!b(&format!(
            "SELECT ts_prox_chain({v}, ARRAY['alpha','beta','gamma'], ARRAY[1,1])"
        )));
    }

    #[pg_test]
    fn chain_pins_a_single_occurrence_across_the_chain() {
        // alpha@1 beta@2 … beta@9 gamma@10. One beta sits by alpha, another by
        // gamma, but NO single beta is near both — so the alpha→beta→gamma chain
        // cannot complete through one occurrence (occurrence chaining, not span).
        let v = "to_tsvector('simple','alpha beta x x x x x x beta gamma')";
        assert!(!b(&format!("SELECT ts_prox_chain({v}, ARRAY['alpha','beta','gamma'], ARRAY[2,2])")));
        // Document-level "a beta near alpha AND a beta near gamma" WOULD be true
        // here — confirming window is strictly occurrence-pinned, not that.
        assert!(b(&format!("SELECT ts_prox_within({v}, 'beta', 'alpha', 2)"))
            && b(&format!("SELECT ts_prox_within({v}, 'beta', 'gamma', 2)")));
        // A single beta near both ends ⇒ the chain completes through that occurrence.
        let w = "to_tsvector('simple','alpha beta gamma')"; // alpha@1 beta@2 gamma@3
        assert!(b(&format!("SELECT ts_prox_chain({w}, ARRAY['alpha','beta','gamma'], ARRAY[1,1])")));
    }

    #[pg_test]
    fn chain_is_stricter_than_operator_chain() {
        // orange@8 apple@10 banana@12 — apple↔banana and apple↔orange are each
        // within 2, but banana↔orange is 4 apart, so no single strict chain fits.
        let doc = "one two three four five six seven orange nine apple eleven banana";
        let v = format!("to_tsvector('simple','{doc}')");
        // ts_prox_chain demands ONE chain apple→banana→orange; orange isn't within 2
        // of banana ⇒ false.
        assert!(!b(&format!(
            "SELECT ts_prox_chain({v}, ARRAY['apple','banana','orange'], ARRAY[2,2])"
        )));
        // The operator chain composes against the span apple<~2>banana covers
        // ([10..12]), so orange@8 attaches at distance 2 from the apple end ⇒ true —
        // strictly looser than ts_prox_chain.
        assert!(proxmatch(doc, "apple <~2> banana <~2> orange"));
    }

    // --- ts_prox_query skeleton -------------------------------------------
    // Checked by selection semantics (does the skeleton's tsquery select this
    // doc?), which is robust to the exact parenthesization to_tsquery produces.
    fn selects(doc: &str, q: &str) -> bool {
        let (doc, q) = (doc.replace('\'', "''"), q.replace('\'', "''"));
        b(&format!("SELECT to_tsvector('simple','{doc}') @@ ts_prox_query('{q}')"))
    }

    #[pg_test]
    fn skeleton_boolean_and_proximity() {
        assert!(selects("a b", "a <~5> b"));
        assert!(!selects("a", "a <~5> b")); // proximity requires both present
        assert!(selects("a", "a | b"));
        assert!(!selects("c", "a | b"));
        assert!(selects("a c", "(a | b) <~5> c")); // OR distributes into the operand
        assert!(selects("b c", "(a | b) <~5> c"));
        assert!(!selects("a", "(a | b) <~5> c")); // missing c
    }

    #[pg_test]
    fn skeleton_and_lift_not_within_and_negation() {
        // A boolean `&` can't be a proximity operand (it no longer silently distributes);
        // the writer spells out the conjunction, whose skeleton still requires all three.
        assert!(selects("a b c", "(a <~5> c) & (b <~5> c)"));
        assert!(!selects("a c", "(a <~5> c) & (b <~5> c)")); // missing b
        // <!~N> contributes only the companion term; recheck owns the distance.
        assert!(selects("confidential", "confidential <!~5> email"));
        assert!(!selects("email", "confidential <!~5> email"));
        // Document-level NOT is dropped from the skeleton (recheck owns it).
        assert!(selects("foo bar", "foo & !bar"));
        assert!(!selects("baz", "foo & !bar"));
    }

    #[pg_test]
    fn skeleton_phrase_and_prefix() {
        assert!(selects("quick fox", "\"quick fox\"")); // adjacent → native <->
        assert!(!selects("quick brown fox", "\"quick fox\"")); // not adjacent
        assert!(selects("apple", "appl*"));
        assert!(!selects("orange", "appl*"));
    }

    #[pg_test]
    fn backslash_in_literal_term_is_harmless() {
        // A single-quoted DSL term may contain a backslash; it's a literal lexeme
        // byte, not an error. But to_tsvector treats backslash as a token separator,
        // so a normally-built document never holds a backslash lexeme — the term
        // matches nothing, via both the recheck and the full operator.
        let q = "$$'a\\b'$$"; // the DSL term  'a\b'
        assert!(!b(&format!("SELECT ts_prox_recheck(to_tsvector('simple','a b'), {q})")));
        assert!(!b(&format!("SELECT to_tsvector('simple','a b') @~@ {q}")));
        // It still compiles to a valid index skeleton (no error / NULL).
        assert!(b(&format!("SELECT ts_prox_query({q}) IS NOT NULL")));
    }

    #[pg_test]
    fn prefix_colon_star_translates_like_sugar() {
        // Our `appl*` sugar and native tsquery `appl:*` lower to the SAME quoted
        // prefix: the lexeme is single-quoted, the `:*` marker sits outside it.
        fn skel(q: &str) -> String {
            Spi::get_one::<String>(&format!("SELECT ts_prox_query_skeleton('{q}')")).unwrap().unwrap()
        }
        assert_eq!(skel("appl*"), "'appl':*");
        assert_eq!(skel("appl:*"), "'appl':*"); // native form → identical skeleton
    }

    #[pg_test]
    fn prefix_native_form_and_exact_term() {
        // Native tsquery `appl:*` behaves identically to the `appl*` sugar — as a
        // standalone term, via index selection, and as a proximity operand.
        assert!(proxmatch("the apple pie", "appl:*"));
        assert!(selects("the apple pie", "appl:*"));
        assert!(proxmatch("apple pie", "appl:* <~2> pie"));
        // A prefix is INCLUSIVE of the exact term (`starts_with`; a word is its own
        // prefix): `apple*` matches "apple" itself, not only longer words.
        assert!(proxmatch("apple", "apple*")); // exact
        assert!(proxmatch("applesauce", "apple*")); // longer
        assert!(!proxmatch("appl", "apple*")); // shorter than the prefix ⇒ no
        assert!(selects("apple", "apple:*")); // inclusive via index selection too
    }

    #[pg_test]
    fn wildcard_glob_and_quoting() {
        // suffix / infix / single-char, all via the unified glob (recheck scan).
        assert!(proxmatch("this text is confidential", "*ial")); // suffix
        assert!(proxmatch("this text is confidential", "con*ial")); // infix
        assert!(!proxmatch("this text is public", "con*ial"));
        assert!(proxmatch("pick the best test", "te?t")); // ? = one char
        assert!(!proxmatch("pick the best tense", "te?t")); // 'tense' is longer
        // A glob with a leading literal is index-served standalone (prefix key).
        assert!(selects("running tests", "te?t")); // skeleton 'te:*'
        // Suffix glob (no prefix) needs a companion; "study" drives the index.
        assert!(proxfind("the study of biology", "study <~3> *ology"));
        assert!(!proxfind("the study of cats", "study <~3> *ology"));
        // Single-quoted literal: the term is taken verbatim, no wildcard meaning.
        assert!(proxmatch("we love c sharp", "'c'"));
        assert!(!proxmatch("we love rust", "'c'"));
    }

    #[pg_test]
    fn regex_single_token() {
        // ##regex## matches whole lexemes via Postgres's own engine.
        assert!(proxmatch("call me at 123456789 today", "##[0-9]{9}##"));
        assert!(!proxmatch("call me at 12345 today", "##[0-9]{9}##")); // only 5 digits
        // anchored to the whole lexeme; the ? here is regex (optional), not a glob.
        assert!(proxmatch("the colour is nice", "##colou?r##"));
        assert!(proxmatch("the color is nice", "##colou?r##"));
        // companion form — "ssn" drives the index, the regex is rechecked.
        assert!(proxfind("ssn 123456789 here", "ssn <~3> ##[0-9]{9}##"));
        assert!(!proxfind("ssn abc here", "ssn <~3> ##[0-9]{9}##"));
    }

    #[pg_test]
    fn regex_anchoring_is_ours_and_user_anchors_are_harmless() {
        // We wrap every ##regex## as `^(?:pattern)$` (see Regexp::compile), matching
        // the WHOLE lexeme — so a partial pattern never substring-matches a longer
        // lexeme.
        assert!(proxmatch("the colour is nice", "##colou?r##"));
        assert!(!proxmatch("the colourful flag", "##colou?r##")); // 'colourful' ≠ full
        // A user's own ^…$ is redundant but harmless (becomes `^(?:^colou?r$)$`).
        assert!(proxmatch("the colour is nice", "##^colou?r$##"));
        assert!(proxmatch("the colour is nice", "##^colou?r##")); // one-sided anchor too
        assert!(proxmatch("the colour is nice", "##colou?r$##"));
        // The non-capturing group keeps alternation scoped under our anchors, so
        // each branch is still a full-lexeme match.
        assert!(proxmatch("the cat sat", "##cat|dog##"));
        assert!(proxmatch("the dog ran", "##cat|dog##"));
        assert!(!proxmatch("category dogma", "##cat|dog##")); // neither is a whole lexeme
    }


    // --- ts_prox_recheck recheck + full pipeline -----------------------------
    fn proxmatch(doc: &str, q: &str) -> bool {
        let (doc, q) = (doc.replace('\'', "''"), q.replace('\'', "''"));
        b(&format!("SELECT ts_prox_recheck(to_tsvector('simple','{doc}'), '{q}')"))
    }
    // Selection AND recheck together — what the proxsearch()-style wrapper does.
    fn proxfind(doc: &str, q: &str) -> bool {
        let (doc, q) = (doc.replace('\'', "''"), q.replace('\'', "''"));
        b(&format!(
            "SELECT to_tsvector('simple','{doc}') @@ ts_prox_query('{q}') \
                 AND ts_prox_recheck(to_tsvector('simple','{doc}'), '{q}')"
        ))
    }

    #[pg_test]
    fn recheck_within_and_pre() {
        assert!(proxmatch("a x b", "a <~2> b")); // distance 2, either order
        assert!(!proxmatch("a x y b", "a <~2> b")); // distance 3
        assert!(proxmatch("a x y b", "a <~3> b"));
        assert!(proxmatch("a x b", "a <-2> b")); // pre: a before b, within 2
        assert!(!proxmatch("b x a", "a <-2> b")); // wrong order for <-N>
    }

    #[pg_test]
    fn recheck_within_distance_is_position_gap() {
        // a@1 b@2 c@3 → distance is the position gap |a − c| = 2 (the intervening
        // 'b' counts), so within 2 matches; within 1 (adjacency) does not.
        assert!(proxmatch("a b c", "a <~2> c"));
        assert!(proxmatch("a b c", "c <~2> a")); // symmetric: c within 2 of a
        assert!(!proxmatch("a b c", "a <~1> c")); // gap is 2, not 1
        assert!(!proxmatch("a b c", "c <~1> a")); // symmetric the other way too
    }

    #[pg_test]
    fn ts_prox_chain_pins_occurrence_not_span() {
        // Same doc (a@1 2@2 b@3 4@4 5@5 c@6). ts_prox_chain is a per-link chain that
        // carries forward ONE occurrence per term — distinct from the operator
        // chain's span region (it does not test "is b inside the [a..c] span").
        let v = "to_tsvector('simple','a 2 b 4 5 c')";
        // a→b→c places b between by construction (b within 2 of a, c within 3 of b).
        assert!(b(&format!("SELECT ts_prox_chain({v}, ARRAY['a','b','c'], ARRAY[2,3])")));
        // a→c→b tests b only against the carried c@6 (distance 3): gap 1 misses, 3 hits.
        assert!(!b(&format!("SELECT ts_prox_chain({v}, ARRAY['a','c','b'], ARRAY[6,1])")));
        assert!(b(&format!("SELECT ts_prox_chain({v}, ARRAY['a','c','b'], ARRAY[6,3])")));
        // The operator chain instead treats the left side as a SPAN, so b@3 (between
        // a@1 and c@6) attaches at `<~1>` — whereas window must name b in the chain.
        assert!(proxmatch("a 2 b 4 5 c", "(a <~6> c) <~1> b"));
    }

    #[pg_test]
    fn chained_proximity_attaches_term_within_left_side_span() {
        // doc: a@1 2@2 b@3 4@4 5@5 c@6.  `a <~6> c` matches and occupies the SPAN
        // [1..6] (the interval between the matched pair), so a term falling between
        // them attaches even at `<~1>` — b@3 is inside the span (distance 0).
        let d = "a 2 b 4 5 c";
        assert!(proxmatch(d, "(a <~6> c) <~1> b")); // b@3 lies inside the [a@1..c@6] span
        assert!(proxmatch(d, "(c <~6> a) <~1> b")); // inner pair is symmetric
        // Multiple occurrences: the region is the UNION of per-pair spans, NOT a
        // global min/max — a term in the gap between two separate matched pairs does
        // not attach. a@1 c@3 (span [1..3]) … a@10 c@12 (span [10..12]); g@6 is in the gap.
        let d2 = "a x c x x g x x x a x c"; // a@{1,10} c@{3,12} g@6 x@{2,4,5,7,8,9,11}
        assert!(!proxmatch(d2, "(a <~2> c) <~1> g")); // g@6 sits between the clusters
        assert!(proxmatch(d2, "(a <~2> c) <~1> x")); // x@2 is inside the first span [1..3]
    }

    #[pg_test]
    fn within_zero_is_same_position() {
        // Distances clamp to [0, 16383]; `0` is kept (not raised to 1). `<~0>` /
        // `<0>` mean SAME position (distance 0), matching native tsquery `<0>`.
        // Distinct lexemes never share a position, so on normal text `<0>` is false —
        // and crucially it is NOT silently adjacency (which is how it'd behave if 0
        // were clamped to 1): `<0>` on `a b` is false where `<~1>` is true.
        assert!(!proxmatch("a b", "a <~0> b")); // a@1 b@2 ⇒ different positions
        assert!(!proxmatch("a b", "a <0> b")); // <0> ≠ adjacency (would be true if clamped to 1)
        assert!(proxmatch("a b", "a <~1> b")); //   …whereas <~1> does match adjacency
        // …but co-located lexemes (a@1 b@1) DO match `<0>` / `<~0>`.
        let tv = "$$'a':1 'b':1$$::tsvector"; // a and b at the same position
        assert!(b(&format!("SELECT ts_prox_recheck({tv}, 'a <~0> b')")));
        assert!(b(&format!("SELECT ts_prox_recheck({tv}, 'a <0> b')")));
        // matches native tsquery exactly (the `<N> unchanged` promise).
        assert!(b(&format!("SELECT {tv} @@ to_tsquery('simple','a <0> b')")));
        // ordered `<-0>` (strictly before, at distance ≤0) is contradictory ⇒ false.
        assert!(!b(&format!("SELECT ts_prox_recheck({tv}, 'a <-0> b')")));
    }

    #[pg_test]
    fn recheck_native_distance_is_exact() {
        // <N> stays native tsquery: exactly N apart, ordered.
        assert!(proxmatch("a x b", "a <2> b")); // b exactly 2 after a
        assert!(!proxmatch("a x y b", "a <2> b")); // 3 apart ⇒ no
        assert!(proxmatch("a b", "a <-> b")); // adjacency (= <1>)
        // `<->` is exactly `<1>` (both hardcode gap 1, bypassing the distance clamp),
        // and distinct from `<0>` (same position) since the honor-0 change.
        let skel = |q: &str| Spi::get_one::<String>(&format!("SELECT ts_prox_query_skeleton('{q}')")).unwrap().unwrap();
        assert_eq!(skel("a <-> b"), skel("a <1> b")); // identical lowering
        assert_eq!(skel("a <-> b"), "('a' <-> 'b')");
        assert!(proxmatch("a b", "a <1> b")); // adjacent ⇒ true
        assert!(!proxmatch("a x b", "a <1> b")); // exactly 1, so distance 2 ⇒ false
        assert_ne!(skel("a <-> b"), skel("a <0> b")); // <-> is 1, not same-position
    }

    #[pg_test]
    fn recheck_not_within_occurrence_level() {
        // Second 'confidential' (pos 7) is far from the only 'email' (pos 1).
        assert!(proxmatch("email confidential foo bar baz qux confidential", "confidential <!~5> email"));
        // Every 'confidential' sits next to an 'email' ⇒ none isolated.
        assert!(!proxmatch("email confidential confidential email", "confidential <!~5> email"));
    }

    #[pg_test]
    fn recheck_not_within_ordered() {
        // <!-N>: an 'a' with no 'b' in the *next* N positions (b before it is fine).
        // price@1 foo@2 discount@3: discount is 2 after price ⇒ within ⇒ not isolated.
        assert!(!proxmatch("price foo discount", "price <!-5> discount"));
        // discount@1 foo@2 price@3: the only discount is *before* price ⇒ price is
        // isolated under the ordered rule (whereas <!~> would call it near).
        assert!(proxmatch("discount foo price", "price <!-5> discount"));
        assert!(!proxmatch("discount foo price", "price <!~5> discount"));
    }

    #[pg_test]
    fn recheck_not_within_term_shared_with_phrase_operand() {
        // The comparison term ('confidential') is BOTH the left operand and the
        // tail of the right phrase operand. A phrase contributes its END positions,
        // so a 'confidential' that *is* a "privileged and confidential" tail sits
        // within 0 of the phrase (itself) ⇒ never isolated. Only a 'confidential'
        // away from any such run can be — i.e. "a confidential used outside the
        // privilege-claim boilerplate".
        let q = "confidential <!~5> \"privileged and confidential\"";
        // The sole confidential is the phrase tail ⇒ none isolated ⇒ false.
        assert!(!proxmatch("privileged and confidential", q));
        // A second confidential far from the phrase tail (conf@3 vs conf@12) ⇒
        // that one is isolated ⇒ true.
        assert!(proxmatch("privileged and confidential w w w w w w w w confidential", q));
        // …but a standalone confidential within 5 of the phrase tail ⇒ not isolated.
        assert!(!proxmatch("privileged and confidential foo confidential", q));
    }

    #[pg_test]
    fn recheck_and_conjunction_shares_anchor() {
        // A boolean `&` can't be a proximity operand (it raises); the explicit
        // conjunction (a <~2> c) & (b <~2> c) anchors both a and b to the same c.
        assert!(proxmatch("a c b", "(a <~2> c) & (b <~2> c)")); // a@1 c@2 b@3
        assert!(!proxmatch("a w w w w c b", "(a <~2> c) & (b <~2> c)")); // a is 5 from c
    }

    #[pg_test]
    fn recheck_chained_composition() {
        // alpha@1 beta@3 gamma@5 — each link within 2.
        assert!(proxmatch("alpha x beta x gamma", "alpha <~2> beta <~2> gamma"));
        assert!(!proxmatch("alpha x x x beta x x x gamma", "alpha <~2> beta <~2> gamma"));
        // Occurrence-linking (why window() is unnecessary in the DSL): alpha-beta
        // sit together early, a *second* beta sits with gamma far away. A
        // document-level `within(a,b) & within(b,gamma)` would wrongly match;
        // composition does not, because gamma must be near the alpha-beta region.
        assert!(!proxmatch("alpha beta x x x x x x beta gamma", "alpha <~2> beta <~2> gamma"));
    }

    #[pg_test]
    fn full_pipeline_selection_then_recheck() {
        assert!(proxfind("a x b", "a <~2> b")); // selected and within
        assert!(!proxfind("a x y z b", "a <~2> b")); // selected (both present) but recheck removes it
        assert!(!proxfind("a alone", "a <~2> b")); // b absent ⇒ not even selected
    }

    #[pg_test]
    fn operator_at_tilde_at() {
        assert!(b("SELECT to_tsvector('simple','a x b') @~@ 'a <~2> b'"));
        assert!(!b("SELECT to_tsvector('simple','a x y z b') @~@ 'a <~2> b'"));
    }

    #[pg_test]
    fn operator_uses_gin_index() {
        Spi::run("CREATE TEMP TABLE proxtest(id serial, tsv tsvector)").unwrap();
        // 200 docs that match `a <~2> b` (a@1 b@3) plus a distinct trailing token.
        Spi::run(
            "INSERT INTO proxtest(tsv) \
             SELECT to_tsvector('simple','a x b w'||g) FROM generate_series(1,200) g",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON proxtest USING gin(tsv)").unwrap();
        Spi::run("ANALYZE proxtest").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION uses_index(q text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN \
               FOR line IN EXECUTE 'EXPLAIN SELECT count(*) FROM proxtest WHERE tsv @~@ ' \
                 || quote_literal(q) LOOP \
                 IF line LIKE '%Index Cond%' THEN hit := true; END IF; \
               END LOOP; \
               RETURN hit; \
             END $$ LANGUAGE plpgsql",
        )
        .unwrap();
        // The support function must turn @~@ into an index condition.
        assert!(b("SELECT uses_index('a <~2> b')"), "@~@ did not use the GIN index");
        // …and still return the right rows with the index in play.
        let n = Spi::get_one::<i64>("SELECT count(*) FROM proxtest WHERE tsv @~@ 'a <~2> b'")
            .unwrap()
            .unwrap();
        assert_eq!(n, 200);
        // A bare wildcard has no index key — it must seq-scan, not error. (The
        // support function must not inject a failing ts_prox_query for a query that
        // can't drive the index.)
        let m = Spi::get_one::<i64>("SELECT count(*) FROM proxtest WHERE tsv @~@ '*5'")
            .unwrap()
            .unwrap();
        assert!(m > 0, "standalone wildcard via @~@ must work as a seq scan");
    }

    #[pg_test]
    fn operator_index_path_matches_recheck_across_query_types() {
        // @~@ IS `ts_prox_recheck` plus a planner support fn that, under a GIN index,
        // rewrites it to `tsv @@ ts_prox_query(q) AND ts_prox_recheck(tsv, q)`. Driven by
        // the SAME structured corpus as the function tests (the `match` table in the
        // markdown parity spec), this builds one indexed table from the distinct docs and
        // confirms, for every distinct query, that @~@ over the index (a) is actually
        // taken when the query carries an index key and (b) returns exactly the rows the
        // bare recheck does.
        crate::corpus::load_parity();
        Spi::run("CREATE TEMP TABLE docs(id serial primary key, tsv tsvector)").unwrap();
        // Distinct docs, duplicated so the planner clearly prefers the index.
        Spi::run(
            "INSERT INTO docs(tsv) SELECT to_tsvector('simple', d.doc) \
             FROM (SELECT DISTINCT doc FROM _prox_match) d, generate_series(1, 20)",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON docs USING gin(tsv)").unwrap();
        Spi::run("ANALYZE docs").unwrap();
        // For each distinct query: compare @~@ forced through the index against the
        // bare recheck (forced seq scan), and require the index plan for keyed queries.
        // The DO block RAISEs on any divergence, surfacing as a failed Spi call.
        Spi::run(
            "DO $$ \
             DECLARE q text; has_key boolean; s_idx text; s_seq text; line text; plan_hit boolean; \
             BEGIN \
               FOR q IN SELECT DISTINCT query FROM _prox_match ORDER BY query LOOP \
                 BEGIN PERFORM ts_prox_query(q); has_key := true; \
                 EXCEPTION WHEN OTHERS THEN has_key := false; END; \
                 SET LOCAL enable_seqscan = off; SET LOCAL enable_indexscan = on; SET LOCAL enable_bitmapscan = on; \
                 EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM docs WHERE tsv @~@ %L', q) INTO s_idx; \
                 IF has_key THEN \
                   plan_hit := false; \
                   FOR line IN EXECUTE format('EXPLAIN SELECT * FROM docs WHERE tsv @~@ %L', q) LOOP \
                     IF line LIKE '%Index Cond%' THEN plan_hit := true; END IF; \
                   END LOOP; \
                   IF NOT plan_hit THEN RAISE EXCEPTION 'index not used for keyed query: %', q; END IF; \
                 END IF; \
                 SET LOCAL enable_seqscan = on; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off; \
                 EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM docs WHERE ts_prox_recheck(tsv, %L)', q) INTO s_seq; \
                 IF s_idx IS DISTINCT FROM s_seq THEN \
                   RAISE EXCEPTION '@~@ index path % differs from recheck % for query: %', s_idx, s_seq, q; \
                 END IF; \
               END LOOP; \
             END $$",
        )
        .expect("@~@ index path must match the recheck for every query");
    }

    #[pg_test]
    fn proxmatch_ast_cache_is_correct() {
        // The per-row AST cache keys on the query string and caches the *parse*,
        // not the result — so the same query on different docs must re-evaluate,
        // and switching queries must not reuse a stale AST.
        assert!(proxmatch("a x b", "a <~2> b"));
        assert!(!proxmatch("a x y z b", "a <~2> b")); // same query, different doc
        assert!(proxmatch("a x b", "a <~2> b")); // back again
        assert!(proxmatch("p q", "p <~1> q")); // different query → cache replaced
        assert!(!proxmatch("a x b", "p <~1> q"));
    }

    // --- native pushdown (drop the recheck for native-expressible shapes) -

    #[pg_test]
    fn native_skeleton_is_some_only_for_expressible_shapes() {
        // Bounded within/pre/phrase over plain terms, AND/OR-combined → native.
        for q in ["a <~2> b", "a <-3> b", "\"a b\"", "a <2> b", "a <~2> b & c",
                  "(a | b) <~2> c", "appl* <~2> b", "a <~2> appl*"] {
            assert!(b(&format!("SELECT ts_prox_query_native_string('{q}') IS NOT NULL")), "expected native: {q}");
        }
        // Beyond the cap, or shapes whose @@ is not exactly the recheck → fall back.
        for q in ["a <~40> b", "a <!~3> b", "a <!-3> b", "##[0-9]+##", "*ology <~2> a",
                  "a & !b", "(a <~5> b) <~5> c", "a <-0> b"] {
            assert!(b(&format!("SELECT ts_prox_query_native_string('{q}') IS NULL")), "expected fallback: {q}");
        }
    }

    #[pg_test]
    fn native_literal_is_verbatim_across_case_accent_and_punctuation() {
        // Regression for the `ts_prox_query_native` wrapper bug: it fed the verbatim
        // native string through `to_tsquery('simple', …)`, which RE-TOKENIZED the
        // lexemes — expanding a single-quoted literal `'a-b-c'` into the parts-phrase
        // `'a-b-c' <-> 'a' <-> 'b' <-> 'c'` and folding case/accent by locale. The fix
        // casts `::tsquery` (tsqueryin) instead — the SAME verbatim path the `@~@` C
        // support and the pure port use — so the lexemes match the recheck's exact byte
        // lookup. (See also the diff corpus for the cross-port `@@`-value parity.)
        let nat = |q: &str| {
            Spi::get_one::<String>(&format!("SELECT ts_prox_query_native($q${q}$q$)::text"))
                .unwrap()
                .unwrap()
        };
        // Hyphen / apostrophe / multi-part literals stay ONE verbatim lexeme…
        assert_eq!(nat("'a-b-c'"), "'a-b-c'");
        assert_eq!(nat("'a-b-c-d-e-f'"), "'a-b-c-d-e-f'");
        assert_eq!(nat("'it''s'"), "'it''s'");
        // …including as a proximity operand (no part-expansion bleeding in).
        assert_eq!(nat("'a-b-c' <-> z"), "'a-b-c' <-> 'z'");
        // Case / accent: the 2-arg `simple` DSL lexer lowercases ASCII ONLY, and the
        // native form mirrors that EXACTLY — the same lexeme the recheck looks up.
        assert_eq!(nat("'café'"), "'café'"); // already-lower accented: unchanged
        assert_eq!(nat("'Café'"), "'café'"); // ASCII `C`→`c`, accent kept
        assert_eq!(nat("'CAFÉ'"), "'cafÉ'"); // ASCII `CAF`→`caf`; uppercase `É` NOT folded
        assert_eq!(nat("'CAFE'"), "'cafe'"); // pure ASCII fully lowercased
        assert_eq!(nat("'A-B-C'"), "'a-b-c'"); // ASCII-lowercased hyphen literal

        // The restored contract: `@@ ts_prox_query_native` EQUALS the recheck for every
        // one of these literals — so the native path never folds case/accent where the
        // verbatim recheck would not. (`'CAFÉ'`→`cafÉ` misses the stored `café`, matching
        // the recheck; only `'café'`/`'Café'` hit.)
        let doc = "to_tsvector('simple','un café noir')";
        for q in ["'café'", "'Café'", "'CAFÉ'", "'cafe'", "'CAFE'"] {
            let rc = b(&format!("SELECT ts_prox_recheck({doc}, $q${q}$q$)"));
            let nat_at = b(&format!("SELECT {doc} @@ ts_prox_query_native($q${q}$q$)"));
            assert_eq!(rc, nat_at, "native @@ must equal the recheck for literal {q}");
        }

        // End-to-end on a vector holding ONLY the compound lexeme (no split parts — as a
        // `proxquery_to_tsvector` column or a hand-built tsvector would). The literal
        // matches it: recheck, native `@@`, and the `@~@` operator all agree. Pre-fix the
        // `to_tsquery` expansion made the native `@@` MISS (the parts-phrase is absent).
        let v = "$$'a-b-c':1 'fact':2$$::tsvector";
        assert!(b(&format!("SELECT ts_prox_recheck({v}, $q$'a-b-c'$q$)")));
        assert!(b(&format!("SELECT {v} @@ ts_prox_query_native($q$'a-b-c'$q$)")));
        assert!(b(&format!("SELECT {v} @~@ $q$'a-b-c'$q$")));
    }

    #[pg_test]
    fn native_pushdown_drops_recheck_and_falls_back() {
        Spi::run("CREATE TEMP TABLE nt(id serial, tsv tsvector)").unwrap();
        // 200 near (a@1 b@3, Δ2) + 200 far (a@1 b@7, Δ6), plus a distinct trailing token.
        Spi::run("INSERT INTO nt(tsv) SELECT to_tsvector('simple','a x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("INSERT INTO nt(tsv) SELECT to_tsvector('simple','a x x x x x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("CREATE INDEX ON nt USING gin(tsv)").unwrap();
        Spi::run("ANALYZE nt").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        // Does the @~@ plan for `q` contain a line matching `pat`?
        Spi::run(
            "CREATE FUNCTION plan_has(q text, pat text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN FOR line IN EXECUTE 'EXPLAIN SELECT count(*) FROM nt WHERE tsv @~@ ' || quote_literal(q) LOOP \
               IF line LIKE pat THEN hit := true; END IF; END LOOP; RETURN hit; END $$ LANGUAGE plpgsql",
        ).unwrap();

        // Native AND selective (phrase / exact `<N>` / boolean): the `@~@` clause is
        // rewritten to a plain `tsv @@ <tsquery>` (a folded phrase literal), so the GIN
        // index serves it and the positional recheck is gone entirely — no `@~@`, no
        // `ts_prox_recheck`. `a <2> b` is the near docs' exact gap (a@1 b@3) ⇒ 200 rows.
        assert!(b("SELECT plan_has('a <2> b', '%Bitmap Index Scan%')"), "exact <N> must be index-served");
        assert!(!b("SELECT plan_has('a <2> b', '%@~@%')"), "exact <N> must drop the @~@ recheck");
        assert!(!b("SELECT plan_has('a <2> b', '%ts_prox_recheck%')"), "exact <N> must drop the ts_prox_recheck recheck");
        let ph = Spi::get_one::<i64>("SELECT count(*) FROM nt WHERE tsv @~@ 'a <2> b'").unwrap().unwrap();
        let phre = Spi::get_one::<i64>("SELECT count(*) FROM nt WHERE ts_prox_recheck(tsv, 'a <2> b')").unwrap().unwrap();
        assert_eq!(ph, 200);
        assert_eq!(ph, phre);

        // within/pre (`<~N>` / `<-N>`) are native-EXPRESSIBLE, but their native form is an
        // OR over exact gaps — NOT a selective index probe. `simplify` must therefore NOT
        // rewrite the clause to it (that would make the OR-of-phrases the sole index
        // driver, which the planner mis-estimates into a seq scan). within/pre instead
        // keep the selective presence skeleton `tsv @@ ts_prox_query('a <~2> b')` (= a & b)
        // plus the `@~@` positional recheck — index-served and exact. Regression guard for
        // the within seq-scan pessimization.
        assert!(b("SELECT plan_has('a <~2> b', '%Bitmap Index Scan%')"), "within must stay index-served via the skeleton");
        assert!(b("SELECT plan_has('a <~2> b', '%@~@%')"), "within must keep the @~@ recheck (not the native rewrite)");
        assert!(b("SELECT plan_has('a <~2> b', '%ts_prox_query(%')"), "within must drive the index with the a&b skeleton");
        // (`ts_prox_query(` + `@~@` present ⇒ index_condition path; the native rewrite
        // would instead fold to a bare `@@ <const tsquery>` with neither marker.)
        // …and it still returns exactly the recheck's rows (the near docs only).
        let op = Spi::get_one::<i64>("SELECT count(*) FROM nt WHERE tsv @~@ 'a <~2> b'").unwrap().unwrap();
        let re = Spi::get_one::<i64>("SELECT count(*) FROM nt WHERE ts_prox_recheck(tsv, 'a <~2> b')").unwrap().unwrap();
        assert_eq!(op, 200);
        assert_eq!(op, re);

        // Fallback (Δ > 32): identical plan shape to the bounded within above — the `@~@`
        // recheck is kept over the presence skeleton (within never takes the native rewrite).
        assert!(b("SELECT plan_has('a <~40> b', '%@~@%')"), "fallback must keep the @~@ recheck");
        assert!(b("SELECT plan_has('a <~40> b', '%ts_prox_query(%')"), "fallback uses the presence skeleton");
        let op40 = Spi::get_one::<i64>("SELECT count(*) FROM nt WHERE tsv @~@ 'a <~40> b'").unwrap().unwrap();
        assert_eq!(op40, 400); // both near and far are within 40
    }

    #[pg_test]
    fn exact_is_some_only_when_recheck_droppable() {
        // Plain boolean / phrase / exact-`<N>` / prefix → the skeleton @@ IS the match,
        // so the recheck is droppable (exact is non-NULL).
        for q in ["a & b", "a | b", "foo", "\"x y\"", "a <2> b", "appl*",
                  "a & \"x y\" & c", "(a | b) & c"] {
            assert!(b(&format!("SELECT ts_prox_query_exact('{q}') IS NOT NULL")), "expected droppable: {q}");
        }
        // within/pre (native but NON-selective), not-within, suffix-glob, regex, document
        // NOT → the recheck does real work, so exact is NULL (keep the two-clause form).
        for q in ["a <~3> b", "a <-3> b", "a <!~3> b", "a <2> b <~3> c",
                  "*ology", "##[0-9]+##", "a & !b", "study <~3> *ology"] {
            assert!(b(&format!("SELECT ts_prox_query_exact('{q}') IS NULL")), "expected recheck-needed: {q}");
        }
    }

    #[pg_test]
    fn exact_template_folds_recheck_and_stays_correct() {
        // The recommended self-folding form:
        //   tsv @@ ts_prox_query(q) AND (ts_prox_query_exact(q) IS NOT NULL OR ts_prox_recheck(tsv,q))
        // const-folds to one clause (no recheck) for an exact query, two clauses otherwise.
        Spi::run("CREATE TEMP TABLE et(id serial, tsv tsvector)").unwrap();
        Spi::run("INSERT INTO et(tsv) SELECT to_tsvector('simple','a x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("INSERT INTO et(tsv) SELECT to_tsvector('simple','a x x x x x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("CREATE INDEX ON et USING gin(tsv)").unwrap();
        Spi::run("ANALYZE et").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        // Does the self-folding template's plan for `q` contain `pat`?
        Spi::run(
            "CREATE FUNCTION tpl_has(q text, pat text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN FOR line IN EXECUTE \
               'EXPLAIN SELECT count(*) FROM et WHERE tsv @@ ts_prox_query(' || quote_literal(q) || \
               ') AND (ts_prox_query_exact(' || quote_literal(q) || ') IS NOT NULL OR ts_prox_recheck(tsv, ' || quote_literal(q) || '))' \
             LOOP IF line LIKE pat THEN hit := true; END IF; END LOOP; RETURN hit; END $$ LANGUAGE plpgsql",
        ).unwrap();

        // Boolean `a & b`: exact is non-NULL ⇒ `(true OR recheck)` folds the recheck away —
        // index-served, no ts_prox_recheck in the plan at all.
        assert!(b("SELECT tpl_has('a & b', '%Bitmap Index Scan%')"), "boolean must be index-served");
        assert!(!b("SELECT tpl_has('a & b', '%ts_prox_recheck%')"), "boolean must fold the recheck away");
        // within `a <~2> b`: exact is NULL ⇒ `(false OR recheck)` keeps the recheck.
        assert!(b("SELECT tpl_has('a <~2> b', '%ts_prox_recheck%')"), "within must keep the recheck");

        // …and the template returns exactly the plain two-clause form's rows, both shapes.
        let cnt = |sql: &str| Spi::get_one::<i64>(sql).unwrap().unwrap();
        for q in ["a & b", "a <~2> b"] {
            let tmpl = cnt(&format!(
                "SELECT count(*) FROM et WHERE tsv @@ ts_prox_query('{q}') \
                 AND (ts_prox_query_exact('{q}') IS NOT NULL OR ts_prox_recheck(tsv,'{q}'))"
            ));
            let two = cnt(&format!(
                "SELECT count(*) FROM et WHERE tsv @@ ts_prox_query('{q}') AND ts_prox_recheck(tsv,'{q}')"
            ));
            assert_eq!(tmpl, two, "self-folding template must equal the two-clause form for {q}");
        }
    }

    #[pg_test]
    fn ts_prox_search_inlines_and_stays_index_served() {
        // `ts_prox_search(tsv, q)` is the consolidated one-call form. It must INLINE so the
        // planner sees the embedded `@@ ts_prox_query(q)` and uses the GIN index (an inlining
        // failure would silently seq-scan — this test makes that loud), folding the recheck
        // for a boolean query and keeping it for a proximity one.
        Spi::run("CREATE TEMP TABLE st(id serial, tsv tsvector)").unwrap();
        Spi::run("INSERT INTO st(tsv) SELECT to_tsvector('simple','a x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("INSERT INTO st(tsv) SELECT to_tsvector('simple','a x x x x x b w'||g) FROM generate_series(1,200) g").unwrap();
        Spi::run("CREATE INDEX ON st USING gin(tsv)").unwrap();
        Spi::run("ANALYZE st").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION s_plan_has(q text, pat text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN FOR line IN EXECUTE 'EXPLAIN SELECT count(*) FROM st WHERE ts_prox_search(tsv, ' || quote_literal(q) || ')' \
             LOOP IF line LIKE pat THEN hit := true; END IF; END LOOP; RETURN hit; END $$ LANGUAGE plpgsql",
        ).unwrap();

        // Headline guard: inlines + index-served (Bitmap Index Scan), never a seq scan.
        assert!(b("SELECT s_plan_has('a & b', '%Bitmap Index Scan%')"), "ts_prox_search must inline + use the index (boolean)");
        assert!(b("SELECT s_plan_has('a <~2> b', '%Bitmap Index Scan%')"), "ts_prox_search must inline + use the index (within)");
        // Boolean folds the recheck away; within keeps it.
        assert!(!b("SELECT s_plan_has('a & b', '%ts_prox_recheck%')"), "boolean must fold the recheck away");
        assert!(b("SELECT s_plan_has('a <~2> b', '%ts_prox_recheck%')"), "within must keep the recheck");

        // …and returns exactly the explicit two-clause form's rows, across shapes.
        let cnt = |sql: &str| Spi::get_one::<i64>(sql).unwrap().unwrap();
        for q in ["a & b", "a | b", "a <~2> b", "\"a x b\"", "a <2> b"] {
            let one = cnt(&format!("SELECT count(*) FROM st WHERE ts_prox_search(tsv, '{q}')"));
            let two = cnt(&format!("SELECT count(*) FROM st WHERE tsv @@ ts_prox_query('{q}') AND ts_prox_recheck(tsv,'{q}')"));
            assert_eq!(one, two, "ts_prox_search must equal the two-clause form for {q}");
        }
    }

    // --- compound operand combinations -----------------------------------

    #[pg_test]
    fn compound_phrase_in_proximity() {
        // A phrase as a proximity operand; distance is measured from the phrase
        // (its end position). the@1 quick@2 brown@3 fox@4 jumps@5
        assert!(proxmatch("the quick brown fox jumps", "\"quick brown\" <~3> jumps")); // end@3, d=2
        assert!(!proxmatch("the quick brown fox jumps", "\"quick brown\" <~1> jumps")); // d=2 > 1
        // phrases on both sides
        assert!(proxmatch("alpha beta x gamma delta", "\"alpha beta\" <~3> \"gamma delta\""));
        // not_within with a phrase operand (occurrence-level)
        assert!(proxmatch("quick brown z z z z z z email", "\"quick brown\" <!~3> email"));
        assert!(!proxmatch("quick brown email", "\"quick brown\" <!~3> email"));
    }

    #[pg_test]
    fn compound_phrase_with_wildcards() {
        // Wildcards inside a phrase match per-atom: prefix, suffix, infix, and `?`.
        assert!(proxmatch("the apple pie", "\"appl* pie\"")); // prefix
        assert!(!proxmatch("the orange pie", "\"appl* pie\""));
        assert!(proxmatch("the biology class", "\"*ology class\"")); // suffix
        assert!(!proxmatch("the geography class", "\"*ology class\""));
        assert!(proxmatch("the best test class", "\"te?t class\"")); // single char
        assert!(!proxmatch("the best tense class", "\"te?t class\""));
        // Also via the <-> phrase operator, not only the quoted form.
        assert!(proxmatch("the biology class", "*ology <-> class"));
        // A keyless-glob phrase still selects via its keyed atom (drives the index).
        assert!(proxfind("the biology class", "*ology <-> class"));
        assert!(!proxfind("the biology room", "*ology <-> class"));
    }

    #[pg_test]
    fn compound_or_group_operand() {
        // OR-group as a proximity operand (recheck): the position-set union.
        assert!(proxmatch("the cat sat", "(cat | dog) <~2> sat"));
        assert!(proxmatch("the dog sat", "(cat | dog) <~2> sat"));
        assert!(!proxmatch("the bird sat", "(cat | dog) <~2> sat"));
        // …and as the not_within companion.
        assert!(proxmatch("cat z z z z z email", "(cat | dog) <!~2> email"));
    }

    #[pg_test]
    fn compound_nested_with_phrase() {
        // (("a b" within 5 of c) within 10 of d) — nested composition over a phrase.
        let q = "(\"a b\" <~5> c) <~10> d";
        assert!(proxmatch("a b x c z z z z d", q)); // d within range of the region
        assert!(!proxmatch("a b x c z z z z z z z z z z d", q)); // d pushed out (>10)
        // nested chain ending in not_within, with no d at all → region is isolated.
        assert!(proxmatch("a b c", "((a <~5> b) <~10> c) <!~3> d"));
    }

    // --- parenthesization: commutation vs. grouping differences ----------

    #[pg_test]
    fn grouping_commutes_where_symmetric() {
        // `<~N>` is either-order, AND/OR commute, and explicit left-grouping is the
        // default association — so none of these rewrites may change the result.
        for doc in ["a x b", "b x a", "a b c", "x y z", "a only"] {
            assert_eq!(proxmatch(doc, "a <~5> b"), proxmatch(doc, "b <~5> a"));
            assert_eq!(proxmatch(doc, "a & b"), proxmatch(doc, "b & a"));
            assert_eq!(proxmatch(doc, "(a | b) <~5> c"), proxmatch(doc, "(b | a) <~5> c"));
            assert_eq!(proxmatch(doc, "(a <~5> b) <~5> c"), proxmatch(doc, "a <~5> b <~5> c"));
        }
    }

    #[pg_test]
    fn grouping_changes_meaning() {
        // The explicit conjunction (a <~5> c) & (b <~5> c) needs BOTH within 5 of c;
        // a & (b <~5> c) needs only a present AND b within 5 of c. a far from c, b
        // adjacent to c → they differ. (`(a & b) <~5> c` itself raises — a boolean `&`
        // is not a proximity operand; see the `bgErr*` corpus cases.)
        let d = "a z z z z z z z z z z b c"; // a@1 b@12 c@13
        assert!(!proxmatch(d, "(a <~5> c) & (b <~5> c)"));
        assert!(proxmatch(d, "a & (b <~5> c)"));

        // (a | b) <~5> c → (a or b) within 5 of c; a | (b <~5> c) → a present OR ….
        let d = "a z z z z z c"; // a@1 c@7, b absent
        assert!(!proxmatch(d, "(a | b) <~5> c")); // a too far, b absent
        assert!(proxmatch(d, "a | (b <~5> c)")); // a present

        // precedence: `a & b | c` parses as `(a & b) | c`, not `a & (b | c)`.
        let d = "c alone"; // only c present
        assert!(proxmatch(d, "a & b | c"));
        assert!(!proxmatch(d, "a & (b | c)"));

        // pre (<-N>) is ordered → not commutative.
        let d = "a x b"; // a@1 b@3
        assert!(proxmatch(d, "a <-5> b"));
        assert!(!proxmatch(d, "b <-5> a"));

        // not_within (<!~N>) is asymmetric in its operands.
        let d = "a b z z z z z z b"; // a@1 b@2 … b@9
        assert!(!proxmatch(d, "a <!~5> b")); // the one a sits next to a b
        assert!(proxmatch(d, "b <!~5> a")); // b@9 is far from any a
    }

    // --- malformed input fails cleanly (exact, controlled messages) ------

    #[pg_test(error = "ts_prox_query: query has no positive term to drive the index; add an AND-ed positive term")]
    fn err_bare_wildcard_has_no_index_key() {
        // A standalone suffix wildcard can't drive the index → ts_prox_query refuses
        // (so the ts_rank_cd(col, ts_prox_query(q)) recipe surfaces it, not silently).
        Spi::run("SELECT ts_prox_query('*ology')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: a bare `*` matches everything; give it a literal part")]
    fn err_dangling_bare_star() {
        // A hanging bare `*` (`something *`, space-separated) is rejected at parse
        // time — it would match every lexeme. (Attached, `something*` is a normal
        // prefix search; see prefix_native_form_and_exact_term.)
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','something here'), 'something *')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: expected `)`")]
    fn err_unbalanced_parens() {
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','a b'), '(a <~5> b')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: not-within needs a direction: `<!~N>` (either order) or `<!-N>` (ordered)")]
    fn err_not_within_without_direction() {
        // dtSearch-style bare `w/N` and a directionless `<!N>` are both rejected.
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','a b'), 'a <!5> b')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: unexpected end of query")]
    fn err_trailing_operator() {
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','a b'), 'a &')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: invalid regex `[`")]
    fn err_invalid_regex() {
        // A ##regex## that can't compile is a query bug → fail, don't suppress.
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','alpha beta'), '##[##')").unwrap();
    }

    #[pg_test(error = "ts_prox_recheck: invalid regex `[`")]
    fn err_invalid_regex_fails_regardless_of_short_circuit() {
        // Validation is up front, so a malformed regex fails the query even when a
        // sibling branch (`alpha`) would have matched and short-circuited eval.
        Spi::run("SELECT ts_prox_recheck(to_tsvector('simple','alpha beta'), 'alpha | ##[##')").unwrap();
    }

    // --- config-aware surface (3-arg overloads + @~@ proxquery operator) ----

    #[pg_test]
    fn config_aware_english_stemming() {
        // The headline: a SURFACE query term matches the stored STEM under `english`.
        assert!(b("SELECT ts_prox_recheck(to_tsvector('english','the running shoes'),'running <~2> shoes','english')"));
        assert!(b("SELECT ts_prox_recheck(to_tsvector('english','the running shoes'),'run <~2> shoe','english')"));
        // The 2-arg simple path is literal — it does NOT match the stem (unchanged).
        assert!(!b("SELECT ts_prox_recheck(to_tsvector('english','the running shoes'),'running <~2> shoes')"));
        // The skeleton is config-independent; only the wrapping config differs, so the
        // 3-arg selection picks the stemmed lexemes.
        assert_eq!(
            Spi::get_one::<String>("SELECT ts_prox_query('running <~2> shoes','english')::text").unwrap().unwrap(),
            "'run' & 'shoe'"
        );
        assert!(b("SELECT to_tsvector('english','the running shoes') @@ ts_prox_query('running <~2> shoes','english')"));
        assert!(!b("SELECT to_tsvector('english','the walking shoes') @@ ts_prox_query('running <~2> shoes','english')"));
    }

    #[pg_test]
    fn config_aware_operator_proxquery() {
        // `tsv @~@ proxquery(cfg, q)`: the config rides in the typed right operand,
        // keeping one operator symbol.
        assert!(b("SELECT to_tsvector('english','the running shoes') @~@ proxquery('english','running <~2> shoes')"));
        assert!(!b("SELECT to_tsvector('english','the walking shoes') @~@ proxquery('english','running <~2> shoes')"));
        // The plain text operator stays `simple` (unchanged) — literal, no stemming.
        assert!(!b("SELECT to_tsvector('english','the running shoes') @~@ 'running <~2> shoes'"));
    }

    #[pg_test]
    fn config_aware_operator_uses_gin_index() {
        // The typed operator must be index-served too — the support fn injects
        // `tsv @@ ts_prox_query(proxquery)` as the GIN index condition.
        Spi::run("CREATE TEMP TABLE ptc(id serial, tsv tsvector)").unwrap();
        Spi::run(
            "INSERT INTO ptc(tsv) SELECT to_tsvector('english','the running shoes number '||g) \
             FROM generate_series(1,300) g",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON ptc USING gin(tsv)").unwrap();
        Spi::run("ANALYZE ptc").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION uses_index_cfg(cfg text, q text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN \
               FOR line IN EXECUTE 'EXPLAIN SELECT count(*) FROM ptc WHERE tsv @~@ proxquery(' \
                 || quote_literal(cfg) || ', ' || quote_literal(q) || ')' LOOP \
                 IF line LIKE '%Index Cond%ts_prox_query%' THEN hit := true; END IF; \
               END LOOP; \
               RETURN hit; \
             END $$ LANGUAGE plpgsql",
        )
        .unwrap();
        assert!(
            b("SELECT uses_index_cfg('english','running <~2> shoes')"),
            "@~@ proxquery(cfg,q) did not use the GIN index"
        );
        let n = Spi::get_one::<i64>(
            "SELECT count(*) FROM ptc WHERE tsv @~@ proxquery('english','running <~2> shoes')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(n, 300);
    }

    #[pg_test]
    fn ts_prox_search_config_aware() {
        // The 3-arg `ts_prox_search(tsv, q, cfg)` — the one-call form for a non-`simple`
        // column — must inline + drive the GIN index, fold the recheck for a droppable
        // (boolean / phrase / prefix) query and keep it for proximity, and return exactly
        // the explicit cfg two-clause form. Each term resolves through the config, so a
        // fan-out (stemmer/compound) becomes an OR of lexemes, which `@@` matches exactly.
        Spi::run("CREATE TEMP TABLE sct(id serial, tsv tsvector)").unwrap();
        Spi::run("INSERT INTO sct(tsv) SELECT to_tsvector('english','the running shoes number '||g) FROM generate_series(1,300) g").unwrap();
        Spi::run("CREATE INDEX ON sct USING gin(tsv)").unwrap();
        Spi::run("ANALYZE sct").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION s3_plan_has(q text, pat text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN FOR line IN EXECUTE 'EXPLAIN SELECT count(*) FROM sct WHERE ts_prox_search(tsv, ' || quote_literal(q) || ', ''english'')' \
             LOOP IF line LIKE pat THEN hit := true; END IF; END LOOP; RETURN hit; END $$ LANGUAGE plpgsql",
        ).unwrap();

        // Inlines + index-served: the `@@ ts_prox_query(q, cfg)` clause drives the GIN index.
        assert!(b("SELECT s3_plan_has('running <~2> shoes', '%Bitmap Index Scan%')"), "3-arg ts_prox_search must inline + use the index");
        assert!(b("SELECT s3_plan_has('running & shoes', '%Bitmap Index Scan%')"), "3-arg ts_prox_search must inline + use the index (boolean)");
        // Boolean / phrase fold the recheck away (the cfg-resolved skeleton is exactly the
        // match); within keeps it. Same fold the 2-arg `simple` form gets.
        assert!(!b("SELECT s3_plan_has('running & shoes', '%ts_prox_recheck%')"), "cfg boolean must fold the recheck away");
        assert!(!b("SELECT s3_plan_has('\"running shoes\"', '%ts_prox_recheck%')"), "cfg phrase must fold the recheck away");
        assert!(b("SELECT s3_plan_has('running <~2> shoes', '%ts_prox_recheck%')"), "cfg within must keep the recheck");

        // The 3-arg `ts_prox_query_exact(q, cfg)` gate: non-NULL for droppable shapes, NULL
        // for within / glob / regex, and NULL for a stopword-emptied branch (recheck kept).
        assert!(b("SELECT ts_prox_query_exact('running & shoes', 'english') IS NOT NULL"), "cfg boolean is droppable");
        assert!(b("SELECT ts_prox_query_exact('running <~2> shoes', 'english') IS NULL"), "cfg within is not droppable");
        assert!(b("SELECT ts_prox_query_exact('* shoes', 'english') IS NULL OR ts_prox_query_exact('sho*', 'english') IS NOT NULL"), "cfg suffix-glob keeps the recheck");
        assert!(b("SELECT ts_prox_query_exact('the & running', 'english') IS NULL"), "cfg stopword branch keeps the recheck");
        // `@@ ts_prox_query_exact` is the full recheck match for a droppable query.
        assert!(b("SELECT to_tsvector('english','the running shoes') @@ ts_prox_query_exact('running & shoes', 'english')"));

        // Results identical to the explicit cfg two-clause form (english stems running→run, shoes→shoe).
        let cnt = |sql: &str| Spi::get_one::<i64>(sql).unwrap().unwrap();
        for q in ["running & shoes", "\"running shoes\"", "running <~2> shoes", "running <~1> number"] {
            let one = cnt(&format!("SELECT count(*) FROM sct WHERE ts_prox_search(tsv, '{q}', 'english')"));
            let two = cnt(&format!(
                "SELECT count(*) FROM sct WHERE tsv @@ ts_prox_query('{q}', 'english') AND ts_prox_recheck(tsv, '{q}', 'english')"
            ));
            assert_eq!(one, two, "3-arg ts_prox_search must equal the cfg two-clause form for {q}");
        }
    }

    #[pg_test]
    fn config_index_path_matches_seqscan() {
        // #3 (the recheck) must yield identical rows with and without the index — the GIN
        // index is a transparent accelerator, never a result change. For every config + query
        // shape, `idx_seq_ok` compares the recommended indexed form three ways and requires
        // they all agree:
        //   • ts_prox_search(tsv,q,cfg) forced through the index (Bitmap Index Scan),
        //   • the SAME predicate forced through a seq scan (the recheck run on every row),
        //   • the explicit two-clause `@@ ts_prox_query AND ts_prox_recheck` (recheck NEVER
        //     dropped).
        // idx==seq proves the index doesn't change the answer; fold==two-clause proves the
        // recheck-drop is result-preserving (and so the droppability gate is sound). Covers
        // boolean/phrase/prefix (recheck dropped), proximity/ordered/not-within/glob/regex/NOT
        // (recheck kept), and fan-out compounds — all keyed so the index plan is forced.
        Spi::run(
            "CREATE FUNCTION idx_seq_ok(relname text, cfg text, q text) RETURNS text AS $$ \
             DECLARE s_seq text; s_idx text; s_2c text; line text; plan_hit boolean := false; has_key boolean; \
             BEGIN \
               BEGIN PERFORM ts_prox_query(q, cfg::regconfig); has_key := true; EXCEPTION WHEN OTHERS THEN has_key := false; END; \
               SET LOCAL enable_seqscan=off; SET LOCAL enable_indexscan=on; SET LOCAL enable_bitmapscan=on; \
               EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM %I WHERE ts_prox_search(tsv, %L, %L::regconfig)', relname, q, cfg) INTO s_idx; \
               EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM %I WHERE tsv @@ ts_prox_query(%L, %L::regconfig) AND ts_prox_recheck(tsv, %L, %L::regconfig)', relname, q, cfg, q, cfg) INTO s_2c; \
               IF has_key THEN \
                 FOR line IN EXECUTE format('EXPLAIN SELECT * FROM %I WHERE ts_prox_search(tsv, %L, %L::regconfig)', relname, q, cfg) LOOP \
                   IF line LIKE '%Bitmap Index Scan%' OR line LIKE '%Index Scan%' THEN plan_hit := true; END IF; \
                 END LOOP; \
                 IF NOT plan_hit THEN RETURN 'no-index'; END IF; \
               END IF; \
               SET LOCAL enable_seqscan=on; SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; \
               EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM %I WHERE ts_prox_search(tsv, %L, %L::regconfig)', relname, q, cfg) INTO s_seq; \
               IF s_idx IS DISTINCT FROM s_seq THEN RETURN 'idx<>seq idx='||s_idx||' seq='||s_seq; END IF; \
               IF s_idx IS DISTINCT FROM s_2c  THEN RETURN 'fold<>2c fold='||s_idx||' 2c='||s_2c; END IF; \
               RETURN 'ok'; \
             END $$ LANGUAGE plpgsql",
        ).unwrap();

        let ok = |relname: &str, cfg: &str, q: &str| {
            let r = Spi::get_one::<String>(&format!("SELECT idx_seq_ok('{relname}', '{cfg}', $q${q}$q$)"))
                .unwrap()
                .unwrap();
            assert_eq!(r, "ok", "index/seqscan/two-clause disagree for [{cfg}] {q}: {r}");
        };

        // English (built-in stemming). Duplicated rows so the planner prefers the index.
        Spi::run("CREATE TEMP TABLE cidx_e(id serial primary key, tsv tsvector)").unwrap();
        Spi::run(
            "INSERT INTO cidx_e(tsv) SELECT to_tsvector('english', d) FROM unnest(ARRAY[ \
                'the running shoes are here', 'walking shoes and socks', 'running fast number two', \
                'a quiet library corner', 'running shoes number five', 'shoes without any running', \
                'he was running right by the shoes', 'number then running far far far far apart shoes']) \
              AS d, generate_series(1,30)",
        ).unwrap();
        Spi::run("CREATE INDEX ON cidx_e USING gin(tsv)").unwrap();
        Spi::run("ANALYZE cidx_e").unwrap();
        for q in [
            "running & shoes", "running | walking", "\"running shoes\"", "running <~2> shoes",
            "running <-2> shoes", "running <!~3> number", "runn*", "run*ng", "shoes & !walking",
            "shoes & ##r.n##",
        ] {
            ok("cidx_e", "english", q);
        }

        // simple_unaccent (accent folding, no stemming/stopwords) — needs contrib `unaccent`;
        // skipped gracefully when absent so contrib-less CI still passes.
        let unaccent_ok = Spi::run(
            "CREATE EXTENSION IF NOT EXISTS unaccent; \
             DROP TEXT SEARCH CONFIGURATION IF EXISTS cu_cfg; \
             CREATE TEXT SEARCH CONFIGURATION cu_cfg (COPY = simple); \
             ALTER TEXT SEARCH CONFIGURATION cu_cfg ALTER MAPPING FOR \
               asciiword, word, numword, asciihword, hword, numhword, hword_asciipart, hword_part, hword_numpart \
               WITH unaccent, simple",
        )
        .is_ok();
        if unaccent_ok {
            Spi::run("CREATE TEMP TABLE cidx_u(id serial primary key, tsv tsvector)").unwrap();
            Spi::run(
                "INSERT INTO cidx_u(tsv) SELECT to_tsvector('cu_cfg', d) FROM unnest(ARRAY[ \
                    'un café noir', 'le café-bar ferme', 'du thé vert ici', 'cafe sans accent', \
                    'noir comme le café', 'un café-bar parisien', 'bien paré ici', 'le bar ouvert']) \
                  AS d, generate_series(1,30)",
            ).unwrap();
            Spi::run("CREATE INDEX ON cidx_u USING gin(tsv)").unwrap();
            Spi::run("ANALYZE cidx_u").unwrap();
            for q in [
                "cafe & noir", "cafe | noir", "\"café noir\"", "cafe <~2> noir", "café-bar",
                "cafe-bar", "caf?", "caf*", "cafe & !the",
            ] {
                ok("cidx_u", "cu_cfg", q);
            }
        }
    }

    #[pg_test]
    fn tsvector_source_variants() {
        // proxquery operates on a `tsvector`; it must not care HOW that tsvector is obtained.
        // Build the SAME data four ways and confirm every access form (`@~@`, `ts_prox_search`,
        // the explicit two-clause) returns the SAME rows from each:
        //   A. a stored `tsvector` column (the classic manual / trigger-maintained pattern)
        //   B. a `GENERATED ALWAYS AS (to_tsvector(...)) STORED` column
        //   C. a `text` column with a FUNCTIONAL gin index on `to_tsvector(...)` (never stored)
        //   D. a `text` column, tsvector computed on the fly, NO index (seq scan)
        // Smoke-level: identical data ⇒ identical tsvectors ⇒ identical results if it works at
        // all. Also asserts the indexed forms (A/B/C) take a Bitmap Index Scan, confirming the
        // `@~@` support function's index pushdown works for an EXPRESSION index, not just a Var.
        Spi::run(
            "CREATE TEMP TABLE src(id serial primary key, body text); \
             INSERT INTO src(body) SELECT d FROM unnest(ARRAY[ \
                'the quick brown fox', 'a quick red fox', 'lazy brown dog', \
                'quick brown bear', 'the fox is quick', 'quick a b c d fox']) AS d, generate_series(1,20)",
        ).unwrap();
        // A: stored tsvector column. B: generated stored column. C: text + functional index. D: text, no index.
        Spi::run("CREATE TEMP TABLE va AS SELECT id, to_tsvector('simple', body) AS tsv FROM src; \
                  CREATE INDEX ON va USING gin(tsv); ANALYZE va").unwrap();
        Spi::run("CREATE TEMP TABLE vb(id int, body text, \
                    tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED); \
                  INSERT INTO vb(id, body) SELECT id, body FROM src; \
                  CREATE INDEX ON vb USING gin(tsv); ANALYZE vb").unwrap();
        Spi::run("CREATE TEMP TABLE vc AS SELECT id, body FROM src; \
                  CREATE INDEX vc_fx ON vc USING gin(to_tsvector('simple', body)); ANALYZE vc").unwrap();
        Spi::run("CREATE TEMP TABLE vd AS SELECT id, body FROM src; ANALYZE vd").unwrap();

        let ids = |from_where: &str| -> Vec<i32> {
            Spi::get_one::<Vec<i32>>(&format!(
                "SELECT coalesce(array_agg(id ORDER BY id), '{{}}'::int[]) FROM {from_where}"
            )).unwrap().unwrap()
        };

        // The chained 3-`<~>` query CANNOT collapse to an index-only plan (its skeleton is
        // the non-exact `the & quick & brown & fox`), so the second-level recheck is mandatory
        // on every source — for the functional index (C) and the no-index source (D) that means
        // the recheck recomputes `to_tsvector('simple', body)` from the heap text. The droppable
        // shapes (boolean / phrase) cover the index-only collapse path.
        for q in [
            "the <~3> quick <~3> brown <~3> fox", // 3 within-ops: recheck mandatory, can't collapse
            "quick & fox", "quick <~2> fox", "\"quick brown\"", "quick <!~3> fox",
        ] {
            // Ground truth: the stored column via the bare recheck (no index, no @@).
            let want = ids(&format!("va WHERE ts_prox_recheck(tsv, '{q}')"));
            assert!(!want.is_empty(), "test-data sanity: [{q}] should match some rows");
            for f in [
                // A — stored column
                format!("va WHERE tsv @~@ '{q}'"),
                format!("va WHERE ts_prox_search(tsv, '{q}')"),
                format!("va WHERE tsv @@ ts_prox_query('{q}') AND ts_prox_recheck(tsv, '{q}')"),
                // B — generated stored column
                format!("vb WHERE tsv @~@ '{q}'"),
                format!("vb WHERE ts_prox_search(tsv, '{q}')"),
                // C — functional index (tsvector computed by the expression index)
                format!("vc WHERE to_tsvector('simple', body) @~@ '{q}'"),
                format!("vc WHERE ts_prox_search(to_tsvector('simple', body), '{q}')"),
                format!("vc WHERE to_tsvector('simple', body) @@ ts_prox_query('{q}') AND ts_prox_recheck(to_tsvector('simple', body), '{q}')"),
                // D — on the fly, no index
                format!("vd WHERE to_tsvector('simple', body) @~@ '{q}'"),
                format!("vd WHERE ts_prox_search(to_tsvector('simple', body), '{q}')"),
            ] {
                assert_eq!(ids(&f), want, "tsvector source/access form disagreed for [{q}]: {f}");
            }
        }

        // The indexed sources must actually USE the index (Bitmap Index Scan) — including the
        // functional/expression index, which exercises the support fn on a non-Var leftarg.
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION src_plan_has(qry text, pat text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN FOR line IN EXECUTE 'EXPLAIN ' || qry LOOP IF line LIKE pat THEN hit := true; END IF; END LOOP; \
             RETURN hit; END $$ LANGUAGE plpgsql",
        ).unwrap();
        for (tbl, pred) in [
            ("va", "tsv @~@ 'quick <~2> fox'"),
            ("vb", "tsv @~@ 'quick <~2> fox'"),
            ("vc", "to_tsvector('simple', body) @~@ 'quick <~2> fox'"),
        ] {
            assert!(
                b(&format!("SELECT src_plan_has($q$SELECT count(*) FROM {tbl} WHERE {pred}$q$, '%Bitmap Index Scan%')")),
                "{tbl}: @~@ must use the GIN index",
            );
        }
    }

    #[pg_test]
    fn config_aware_user_defined_config() {
        // A user-defined config works exactly like a built-in — proxquery only ever
        // passes the regconfig you name into `to_tsvector`. (Custom config, no contrib
        // dependency: a copy of english under a different name.)
        Spi::run("DROP TEXT SEARCH CONFIGURATION IF EXISTS myeng").unwrap();
        Spi::run("CREATE TEXT SEARCH CONFIGURATION myeng (COPY = english)").unwrap();
        assert!(b("SELECT ts_prox_recheck(to_tsvector('myeng','the running shoes'),'running <~2> shoes','myeng')"));
        assert!(b("SELECT to_tsvector('myeng','the running shoes') @~@ proxquery('myeng','running <~2> shoes')"));
        // Two-clause form selects via the same custom config.
        assert!(b(
            "SELECT to_tsvector('myeng','the running shoes') @@ ts_prox_query('running <~2> shoes','myeng') \
             AND ts_prox_recheck(to_tsvector('myeng','the running shoes'),'running <~2> shoes','myeng')"
        ));
    }

    #[pg_test]
    fn config_aware_glob_casefold() {
        // A glob's literal runs resolve through `cfg` just like a term — here `simple`,
        // whose `to_tsvector` Unicode-lowercases a run the ASCII-only query lexer leaves
        // alone. `*É` folds to `*é` and matches the stored lexeme `café` …
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple','un CAFÉ noir'),'*É','simple')"));
        // … but the accent is PRESERVED (folds case, not accent), so it does not match
        // the unaccented `cafe` — proving the feature is config-driven, not hardcoded.
        assert!(!b("SELECT ts_prox_recheck(to_tsvector('simple','un cafe noir'),'*É','simple')"));
        // The 2-arg `simple` path is unchanged: ASCII-only lower leaves `É`, so no match.
        assert!(!b("SELECT ts_prox_recheck(to_tsvector('simple','un CAFÉ noir'),'*É')"));
        // Verbatim fallback: a run resolving to 0/>1 lexemes (punctuated/alphanumeric)
        // is kept as-is — no empty result, no error, identical to the 2-arg behavior.
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple','x foo.bar baz'),'foo.bar*','simple')"));
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple','an abc123 token'),'abc123*','simple')"));
        // Operator form, leading-literal glob (index-drivable): folds through the cfg.
        assert!(b("SELECT to_tsvector('simple','this is confidential') @~@ proxquery('simple','con*ial')"));
    }

    #[pg_test]
    fn config_aware_glob_unaccent() {
        // The headline: on an accent-folding column, WILDCARD searches strip accents
        // too. Needs contrib `unaccent`; skip cleanly where it isn't installed (some
        // source builds) — the contrib-free `config_aware_glob_casefold` covers the
        // mechanism, and the shared corpus exercises this whenever unaccent is present.
        if !b("SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'unaccent')") {
            return;
        }
        Spi::run("CREATE EXTENSION IF NOT EXISTS unaccent").unwrap();
        Spi::run("DROP TEXT SEARCH CONFIGURATION IF EXISTS simple_unaccent").unwrap();
        Spi::run("CREATE TEXT SEARCH CONFIGURATION simple_unaccent (COPY = simple)").unwrap();
        Spi::run(
            "ALTER TEXT SEARCH CONFIGURATION simple_unaccent \
             ALTER MAPPING FOR asciiword, word, numword, \
                               asciihword, hword, numhword, \
                               hword_asciipart, hword_part, hword_numpart \
             WITH unaccent, simple",
        )
        .unwrap();

        // `?` / suffix / infix wildcards all fold their literal runs to the unaccented
        // lexeme form the column was built with.
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple_unaccent','un café noir'),'caf?','simple_unaccent')"));
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple_unaccent','bien paré ici'),'*ré','simple_unaccent')"));
        // `p` is recomputed from the FOLDED glob (`café*o` → `cafe*o`), so the prefix
        // scan keys off `cafe` and reaches `cafezinho`.
        assert!(b("SELECT ts_prox_recheck(to_tsvector('simple_unaccent','o cafezinho'),'café*o','simple_unaccent')"));
        // Operator form.
        assert!(b("SELECT to_tsvector('simple_unaccent','o cafezinho') @~@ proxquery('simple_unaccent','café*o')"));
        // The SAME query is accent-SENSITIVE on plain `simple` (no match) — the column's
        // config, not the library, decides whether accents are stripped.
        assert!(!b("SELECT ts_prox_recheck(to_tsvector('simple','o cafezinho'),'café*o','simple')"));

        // GIN-index soundness on a folding column: the probe folds the glob prefix
        // (`'cafe':*`) and selects the candidate; the recheck — now folding the same way
        // — confirms it. This is the original silent-miss bug (probe yes, recheck no),
        // closed: every selected row survives the recheck.
        Spi::run("CREATE TEMP TABLE uacc(id serial, tsv tsvector)").unwrap();
        Spi::run(
            "INSERT INTO uacc(tsv) SELECT to_tsvector('simple_unaccent','o cafezinho numero '||g) \
             FROM generate_series(1,300) g",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON uacc USING gin(tsv)").unwrap();
        Spi::run("ANALYZE uacc").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        let n = Spi::get_one::<i64>(
            "SELECT count(*) FROM uacc WHERE tsv @~@ proxquery('simple_unaccent','café*o')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(n, 300, "index-served folded glob dropped rows the recheck accepts");
    }

    #[pg_test]
    fn config_aware_index_unaccent_prox() {
        // Companion to `config_aware_glob_unaccent` (globs) and the inline-tsvector
        // config corpus (which proves recheck⟹probe soundness but never touches an
        // index): this confirms PROXIMITY / PHRASE / alphanumeric queries on an
        // accent-folding column are actually SERVED BY the GIN index under the expanded
        // mapping — the @~@ support fn turns each into an `Index Cond … ts_prox_query`
        // (folded keys like `cafe2`/`mp3`), and the index result equals the bare
        // recheck. Needs contrib `unaccent`; skip cleanly where it isn't installed.
        if !b("SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'unaccent')") {
            return;
        }
        Spi::run("CREATE EXTENSION IF NOT EXISTS unaccent").unwrap();
        Spi::run("DROP TEXT SEARCH CONFIGURATION IF EXISTS simple_unaccent").unwrap();
        Spi::run("CREATE TEXT SEARCH CONFIGURATION simple_unaccent (COPY = simple)").unwrap();
        Spi::run(
            "ALTER TEXT SEARCH CONFIGURATION simple_unaccent \
             ALTER MAPPING FOR asciiword, word, numword, \
                               asciihword, hword, numhword, \
                               hword_asciipart, hword_part, hword_numpart \
             WITH unaccent, simple",
        )
        .unwrap();

        // The three docs that should match (each duplicated 20×) buried in noise, so
        // the planner clearly prefers the index. `café-bar` → `café-bar`:2 `café`:3
        // `bar`:4 (compound + parts at consecutive positions); `café2` → `cafe2`;
        // `mp3-café` → `mp3-cafe`:1 `mp3`:2 `cafe`:3.
        Spi::run("CREATE TEMP TABLE pdocs(id serial primary key, tsv tsvector)").unwrap();
        Spi::run(
            "INSERT INTO pdocs(tsv) SELECT to_tsvector('simple_unaccent', d) \
             FROM unnest(ARRAY['le café-bar ferme','un café2 noir','un mp3-café ok']) d, \
                  generate_series(1, 20)",
        )
        .unwrap();
        Spi::run(
            "INSERT INTO pdocs(tsv) SELECT to_tsvector('simple_unaccent','thé vert numero '||g) \
             FROM generate_series(1, 500) g",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON pdocs USING gin(tsv)").unwrap();
        Spi::run("ANALYZE pdocs").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION uses_index_u(q text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN \
               FOR line IN EXECUTE \
                 'EXPLAIN SELECT count(*) FROM pdocs WHERE tsv @~@ proxquery(''simple_unaccent'', ' \
                 || quote_literal(q) || ')' LOOP \
                 IF line LIKE '%Index Cond%ts_prox_query%' THEN hit := true; END IF; \
               END LOOP; \
               RETURN hit; \
             END $$ LANGUAGE plpgsql",
        )
        .unwrap();

        // Each query: the @~@ plan must be index-driven AND return exactly its 20 rows.
        for (q, want) in [
            ("cafe <-> bar", 20i64),    // hyphenated parts, accent-folded
            ("\"cafe bar ferme\"", 20), // phrase spanning the compound + both parts
            ("cafe2 <-> noir", 20),     // numword folded to `cafe2`
            ("mp3 <-> cafe", 20),       // numhword parts adjacent
        ] {
            assert!(
                b(&format!("SELECT uses_index_u('{q}')")),
                "@~@ did not use the GIN index for `{q}` on simple_unaccent",
            );
            let n = Spi::get_one::<i64>(&format!(
                "SELECT count(*) FROM pdocs WHERE tsv @~@ proxquery('simple_unaccent','{q}')"
            ))
            .unwrap()
            .unwrap();
            assert_eq!(n, want, "wrong row count for `{q}` on simple_unaccent");
        }
    }

    #[pg_test]
    fn superimposed_hyphen_positions_match() {
        // Boundary check for "superimposed" hyphen handling — NOT the start of a parser
        // rewrite. Positions are assigned by `to_tsvector` (one per token the parser
        // emits); the compound and its parts share a position only when a single token
        // yields all three lexemes — a parser/dictionary, index-time decision. proxquery
        // only READS positions and can't superimpose post-hoc. This isolates the two
        // halves of the problem and confirms the MATCHING side is already done: a future
        // superimposing parser/dictionary would need ZERO proxquery changes. The
        // tsvectors are hand-built because no stock config will superimpose today.

        // Default tokenization of `a b c-d` → a:1 b:2 c-d:3 c:4 d:5. The COMPOUND is
        // within <~2> of `a` (distance 2); the bare parts (c@4, d@5) are not — which is
        // why the OR-of-forms query already works via the compound, with no parser work.
        let normal = "$$'a':1 'b':2 'c-d':3 'c':4 'd':5$$::tsvector";
        assert!(b(&format!("SELECT ts_prox_recheck({normal}, $$a <~2> 'c-d'$$)")));
        assert!(!b(&format!("SELECT ts_prox_recheck({normal}, $$a <~2> c$$)")));
        assert!(!b(&format!("SELECT ts_prox_recheck({normal}, $$a <~2> d$$)")));

        // Superimposed: c-d, c, d ALL at position 3 → every form is distance 2 from `a`,
        // so each disjunct hits, not just the compound. This is the only behavior a
        // custom parser would unlock — and it needs no change here.
        let sup = "$$'a':1 'b':2 'c-d':3 'c':3 'd':3$$::tsvector";
        assert!(b(&format!("SELECT ts_prox_recheck({sup}, $$a <~2> 'c-d'$$)")));
        assert!(b(&format!("SELECT ts_prox_recheck({sup}, $$a <~2> c$$)")));
        assert!(b(&format!("SELECT ts_prox_recheck({sup}, $$a <~2> d$$)")));
        assert!(b(&format!("SELECT ts_prox_recheck({sup}, $$a <~2> (c | d | 'c-d')$$)")));
    }

    #[pg_test]
    fn tokenizer_corpus() {
        // Golden corpus for the extension-only Unicode tokenizer (the contract in
        // tests/tokenizer_cases.md): proxquery_to_tsvector(input, analyzer) must equal
        // `expected::tsvector` for each row. DEFERRED holds the categories not yet
        // implemented (structured tailorings, emoji) or engine-dependent (ICU CJK) — it
        // shrinks as later phases land. Kept separate from the pure-port diff corpus
        // (the tokenizer is extension-only).
        crate::corpus::load_tokenizer();
        // NFC normalization: a decomposed `é` (e + U+0301) must tokenize like composed
        // `café`. Its input is a combining codepoint with no readable plain-text form,
        // so it lives here rather than in the markdown corpus.
        assert!(
            b("SELECT proxquery_to_tsvector(U&'cafe\\0301', 'prox_icu') \
               = $$'café':1 'cafe':1$$::tsvector"),
            "tf_nfd: decomposed é must fold like composed café",
        );
        // Unicode edge behaviors with no readable plain-text form (invisible controls /
        // combining marks), pinned here rather than in the markdown corpus (same reason
        // as tf_nfd). `m` is the prox_icu recheck: does the bare query term find the doc?
        let m = |doc: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector({doc}, 'prox_icu'), {q}, 'prox_icu')"
            ))
        };
        // Wins — the canonicalizing fold makes the clean spelling find the exotic text: a
        // leading BOM/ZWNBSP is stripped; Turkish dotted-İ case-folds to i then accent-
        // folds the residual dot away; Arabic harakat and Hebrew niqqud are superimposed
        // (voweled + stripped), so the unpointed spelling matches; stacked combining
        // marks fold to the base letter.
        assert!(m(r"U&'\FEFFword'", "'word'"), "leading BOM is stripped");
        assert!(m(r"U&'\0130stanbul'", "'istanbul'"), "Turkish İ folds to i");
        assert!(m("'مُحَمَّد'", "'محمد'"), "Arabic harakat superimposed (unpointed matches)");
        assert!(m("'שָׁלוֹם'", "'שלום'"), "Hebrew niqqud superimposed (unpointed matches)");
        assert!(m(r"U&'a\0301\0302\0303'", "'a'"), "stacked combining marks fold to base");
        // Invisible formatting / bidi controls are stripped during normalization (Unicode
        // default-ignorables with no textual meaning), so a soft-hyphenated word, a bidi-
        // wrapped word, and a zero-width-split word all match their clean spelling — and a
        // bidi RLO can't smuggle itself into an indexed lexeme (Trojan-source). The
        // semantic joiners ZWJ/ZWNJ and emoji variation selectors are kept (see tj_* /
        // is_ignorable_control), so emoji clusters are untouched.
        assert!(m(r"U&'con\00ADfidential'", "'confidential'"), "soft hyphen stripped");
        assert!(m(r"U&'a\202Eb'", "'ab'"), "bidi RLO stripped");
        assert!(m(r"U&'co\200Bnfidential'", "'confidential'"), "ZWSP stripped, token rejoined");
        // An over-long token (> 2046 bytes) is dropped rather than aborting the whole
        // document (matching stock to_tsvector); the surrounding words survive.
        assert!(
            b("SELECT proxquery_to_tsvector('start ' || repeat('a',3000) || ' end', 'prox_icu') \
               = $$'start':1 'end':3$$::tsvector"),
            "over-long token dropped, neighbors kept",
        );
        const DEFERRED: &[&str] = &[];
        // Every row must at least evaluate without error.
        let total = Spi::get_one::<i64>(
            "SELECT count(*) FROM _prox_tok WHERE proxquery_to_tsvector(input, analyzer) IS NOT NULL",
        )
        .unwrap()
        .unwrap();
        assert!(total > 0, "tokenizer corpus did not load");
        // Non-deferred rows must match their expected tsvector exactly.
        let skip = if DEFERRED.is_empty() {
            String::new()
        } else {
            let list = DEFERRED
                .iter()
                .map(|l| format!("'{l}'"))
                .collect::<Vec<_>>()
                .join(", ");
            format!("label NOT IN ({list}) AND ")
        };
        let q = format!(
            "SELECT coalesce(string_agg(\
                 label || $$  got=$$ || proxquery_to_tsvector(input, analyzer)::text \
                 || $$  want=$$ || expected, E'\\n' ORDER BY label), '') \
             FROM _prox_tok \
             WHERE {skip}proxquery_to_tsvector(input, analyzer) IS DISTINCT FROM expected::tsvector"
        );
        let mism = Spi::get_one::<String>(&q).unwrap().unwrap_or_default();
        assert!(mism.is_empty(), "tokenizer corpus mismatches:\n{mism}");
    }

    #[pg_test]
    fn analyzer_recheck_symmetry() {
        // The query side resolves atoms through the SAME analyzer the column was built
        // with, so a query folds to the indexer's superimposed lexemes. Recheck only
        // (seq scan) — the GIN index path is a later phase.
        let m = |doc: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, 'prox_icu'), \
                 $q${q}$q$, 'prox_icu')"
            ))
        };
        // Headline: `CAFÉ` is stored as superimposed {café, cafe}, so any case/accent
        // spelling finds it — and a miss stays a miss.
        assert!(m("un CAFÉ noir", "cafe"));
        assert!(m("un CAFÉ noir", "café"));
        assert!(m("un CAFÉ noir", "CAFE"));
        assert!(!m("un CAFÉ noir", "the"));
        // Proximity reads through the fold: café@2 <-> noir@3.
        assert!(m("un café noir", "cafe <-> noir"));
        // Hyphen superimposition: every form of café-bar sits at ONE position, so a
        // neighbor is adjacent to any part, and the compound is findable accent-folded.
        assert!(m("le café-bar ferme", "le <-> cafe"));
        assert!(m("le café-bar ferme", "bar <-> ferme"));
        assert!(m("le café-bar ferme", "cafe-bar"));
        assert!(m("le café-bar ferme", "bar"));
        // Email split: parts/host are findable, and a neighbor is adjacent to the
        // whole address (one position).
        assert!(m("mail a@b.com here", "b.com"));
        assert!(m("mail a@b.com here", "a"));
        assert!(m("mail a@b.com here", "mail <-> a"));
        // The prox_unicode analyzer resolves symmetrically too (per-char CJK).
        assert!(b(
            "SELECT proxquery_recheck(proxquery_to_tsvector('中文 文档', 'prox_unicode'), \
             '中', 'prox_unicode')"
        ));
    }

    #[pg_test]
    fn analyzer_index_path() {
        // The analyzer `@~@ proxquery(...)` overload must be GIN-index-served (the
        // probe folds query atoms the same way the column was built) AND agree with the
        // bare `proxquery_recheck` recheck (the recheck⟹probe soundness invariant).
        Spi::run("CREATE TEMP TABLE adocs(id serial primary key, tsv tsvector)").unwrap();
        // Distinct docs duplicated + noise, so the planner prefers the index.
        Spi::run(
            "INSERT INTO adocs(tsv) SELECT proxquery_to_tsvector(d, 'prox_icu') \
             FROM unnest(ARRAY['un CAFÉ noir','le café-bar ferme','mail a@b.com here']) d, \
                  generate_series(1, 20)",
        )
        .unwrap();
        Spi::run(
            "INSERT INTO adocs(tsv) SELECT proxquery_to_tsvector('thé vert numero '||g, 'prox_icu') \
             FROM generate_series(1, 500) g",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON adocs USING gin(tsv)").unwrap();
        Spi::run("ANALYZE adocs").unwrap();
        Spi::run("SET enable_seqscan = off").unwrap();
        Spi::run(
            "CREATE FUNCTION uses_index_a(q text) RETURNS bool AS $$ \
             DECLARE line text; hit bool := false; \
             BEGIN \
               FOR line IN EXECUTE \
                 'EXPLAIN SELECT count(*) FROM adocs WHERE tsv @~@ proxquery(''prox_icu'', ' \
                 || quote_literal(q) || ')' LOOP \
                 IF line LIKE '%Index Cond%ts_prox_query%' THEN hit := true; END IF; \
               END LOOP; \
               RETURN hit; \
             END $$ LANGUAGE plpgsql",
        )
        .unwrap();

        for (q, expect_hits) in [
            ("cafe", true),         // accent-folded term finds CAFÉ (and the café-bar part)
            ("café", true),         // accented spelling folds the same
            ("cafe <-> noir", true), // proximity through the fold
            ("cafe-bar", true),     // hyphen compound, accent-folded
            ("b.com", true),        // email host
            ("mail <-> a", true),   // neighbor adjacent to the (one-position) email
            ("zzz", false),         // genuine miss
        ] {
            // The @~@ plan must be index-driven (probe injected as an Index Cond).
            assert!(
                b(&format!("SELECT uses_index_a('{q}')")),
                "@~@ proxquery did not use the GIN index for `{q}`",
            );
            // @~@ (probe ∩ recheck) must equal the bare recheck (soundness: the probe
            // drops no row the recheck accepts).
            let idx = Spi::get_one::<i64>(&format!(
                "SELECT count(*) FROM adocs WHERE tsv @~@ proxquery('prox_icu','{q}')"
            ))
            .unwrap()
            .unwrap();
            let recheck = Spi::get_one::<i64>(&format!(
                "SELECT count(*) FROM adocs WHERE proxquery_recheck(tsv, '{q}', 'prox_icu')"
            ))
            .unwrap()
            .unwrap();
            assert_eq!(idx, recheck, "@~@ index path disagrees with recheck for `{q}`");
            if expect_hits {
                assert!(idx > 0, "expected hits for `{q}`");
            } else {
                assert_eq!(idx, 0, "expected no hits for `{q}`");
            }
        }
    }

    #[pg_test]
    fn analyzer_toggles() {
        // Each named preset selects a (case, accent, emoji) toggle combination, applied
        // symmetrically on both sides.
        let m = |doc: &str, an: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, '{an}'), \
                 $q${q}$q$, '{an}')"
            ))
        };
        // prox_icu_accent = accent-SENSITIVE (still case-insensitive).
        assert!(m("un café noir", "prox_icu_accent", "café")); // exact accent matches
        assert!(m("un CAFÉ noir", "prox_icu_accent", "café")); // case-insensitive
        assert!(!m("un café noir", "prox_icu_accent", "cafe")); // accent differs → miss
        // …whereas the default prox_icu folds accents (contrast): cafe finds café.
        assert!(m("un café noir", "prox_icu", "cafe"));
        // emoji toggle: the default keeps 😀 findable; prox_icu_no_emoji drops it.
        assert!(m("rapport 😀 final", "prox_icu", "😀"));
        assert!(!m("rapport 😀 final", "prox_icu_no_emoji", "😀"));
        // with the emoji dropped (no position consumed), the flanking words are adjacent.
        assert!(m("rapport 😀 final", "prox_icu_no_emoji", "rapport <-> final"));
    }

    #[pg_test]
    fn analyzer_stemming() {
        // A `:dict` suffix routes each lexeme through a text-search dictionary via
        // ts_lexize — here `english_stem` (stem + English stopwords) — applied
        // symmetrically on both sides. Bare presets are unaffected (no dict, no cost).
        let m = |doc: &str, an: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, '{an}'), \
                 $q${q}$q$, '{an}')"
            ))
        };
        // running / runs stem to run, so `run` (and `running`) find them.
        assert!(m("the running shoes", "prox_icu:english_stem", "run"));
        assert!(m("she runs daily", "prox_icu:english_stem", "run"));
        assert!(m("the running shoes", "prox_icu:english_stem", "running")); // query stems too
        // A literal `'running'` bypasses stemming (exact), so it does NOT match the
        // index that stemmed `running` → `run`.
        assert!(!m("the running shoes", "prox_icu:english_stem", "'running'"));
        // the default prox_icu does NOT stem — `run` ≠ `running`.
        assert!(!m("the running shoes", "prox_icu", "run"));
        assert!(m("the running shoes", "prox_icu", "running"));
    }

    #[pg_test]
    fn analyzer_readme_accent_example() {
        // Runs the README "Extension-only tokenizer" example VERBATIM (generated column +
        // GIN + the @~@ operator) so the doc can't drift: a bare term is accent-
        // insensitive (cafe finds café and cafe), a single-quoted literal is accent-exact.
        Spi::run(
            "CREATE TEMP TABLE docs (\
               id   bigserial PRIMARY KEY, \
               body text, \
               tsv  tsvector GENERATED ALWAYS AS (proxquery_to_tsvector(body, 'prox_icu')) STORED)",
        )
        .unwrap();
        Spi::run("CREATE INDEX docs_tsv_gin ON docs USING gin (tsv)").unwrap();
        Spi::run(
            "INSERT INTO docs (body) VALUES \
               ('un café noir, please'), \
               ('a plain cafe noir here'), \
               ('the café is closed')",
        )
        .unwrap();
        let count = |q: &str| -> i64 {
            Spi::get_one::<i64>(&format!(
                "SELECT count(*) FROM docs WHERE tsv @~@ proxquery('prox_icu', $q${q}$q$)"
            ))
            .unwrap()
            .unwrap()
        };
        let hits = |q: &str, id: i64| -> bool {
            b(&format!(
                "SELECT EXISTS(SELECT 1 FROM docs WHERE id = {id} \
                 AND tsv @~@ proxquery('prox_icu', $q${q}$q$))"
            ))
        };
        // Bare `cafe <-> noir` is accent-insensitive → the accented (1) AND plain (2) docs.
        assert_eq!(count("cafe <-> noir"), 2);
        assert!(hits("cafe <-> noir", 1));
        assert!(hits("cafe <-> noir", 2));
        // Literal `'café' <-> noir` is exact → only the accented doc (1), not plain cafe (2).
        assert_eq!(count("'café' <-> noir"), 1);
        assert!(hits("'café' <-> noir", 1));
        assert!(!hits("'café' <-> noir", 2));
    }

    #[pg_test]
    fn analyzer_generated_column() {
        // The documented usage pattern: a STORED generated column (which REQUIRES the
        // builder to be IMMUTABLE) + a plain GIN index + the @~@ operator. This pins
        // that proxquery_to_tsvector works exactly as the user guide shows.
        Spi::run(
            "CREATE TEMP TABLE gdocs(id serial PRIMARY KEY, body text, \
             tsv tsvector GENERATED ALWAYS AS (proxquery_to_tsvector(body, 'prox_icu')) STORED)",
        )
        .unwrap();
        Spi::run("CREATE INDEX ON gdocs USING gin(tsv)").unwrap();
        Spi::run(
            "INSERT INTO gdocs(body) VALUES \
             ('un CAFÉ noir'), ('le café-bar ferme'), ('mail a@b.com here')",
        )
        .unwrap();
        let hit = |q: &str| -> bool {
            b(&format!(
                "SELECT EXISTS(SELECT 1 FROM gdocs WHERE tsv @~@ proxquery('prox_icu', $q${q}$q$))"
            ))
        };
        assert!(hit("cafe")); // accent-folded term finds CAFÉ (and the café-bar part)
        assert!(hit("b.com")); // email host
        assert!(hit("le <-> cafe")); // neighbor adjacent to the hyphenated word's part
        assert!(!hit("zzz")); // genuine miss
    }

    #[pg_test(error = "proxquery: unknown analyzer 'bogus'")]
    fn analyzer_unknown_name_errors() {
        Spi::run("SELECT proxquery_to_tsvector('x', 'bogus')").unwrap();
    }

    #[pg_test(error = "proxquery: unknown analyzer 'prox_icu:nosuchdict'")]
    fn analyzer_unknown_dict_errors() {
        Spi::run("SELECT proxquery_to_tsvector('x', 'prox_icu:nosuchdict')").unwrap();
    }

    #[pg_test]
    fn analyzer_accent_specificity() {
        // The index stores BOTH `café` and `cafe` (superimposed). Bare query terms are
        // accent-INSENSITIVE (recall-first): they fold to the canonical form, so `cafe`
        // AND `café` both find accented and plain docs alike. A literal `'café'` is the
        // precision escape hatch: resolved EXACTLY, it matches only the accented spelling.
        let m = |doc: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, 'prox_icu'), \
                 $q${q}$q$, 'prox_icu')"
            ))
        };
        // Bare term: accent-insensitive both ways.
        assert!(m("un café noir", "cafe"));
        assert!(m("un cafe noir", "cafe"));
        assert!(m("un café noir", "café"));
        assert!(m("un cafe noir", "café")); // bare café is broad → matches plain cafe too
        // Literal `'café'`: EXACT — matches the accented spelling only.
        assert!(m("un café noir", "'café'"));
        assert!(!m("un cafe noir", "'café'")); // the headline: exact café must NOT match plain cafe
        // `'CAFÉ'` still folds case (the DSL lowercases), just not accents.
        assert!(m("un café noir", "'CAFÉ'"));
        // The literal also composes in proximity: exact café next to noir.
        assert!(m("un café noir", "'café' <-> noir"));
        assert!(!m("un cafe noir", "'café' <-> noir"));
    }

    #[pg_test]
    fn analyzer_superimposition_specificity() {
        // The index stores the compound + parts, but a BARE query resolves to the whole
        // (folded) compound — it does NOT decompose — so the compound stays specific
        // while a sub-form (queried directly) finds the superimposed docs. The
        // apostrophe full-form is reachable as a literal `'…'` (resolved exactly).
        let m = |doc: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, 'prox_icu'), \
                 $q${q}$q$, 'prox_icu')"
            ))
        };
        // hyphen: the compound query is specific; a part finds the compound.
        assert!(m("the café-bar", "cafe-bar")); // accent-folded compound → hyphen doc
        assert!(!m("just a bar", "cafe-bar")); // compound must NOT match a plain part
        assert!(m("the café-bar", "bar")); // a part finds the compound
        assert!(m("just a bar", "bar"));
        // email: the full address is specific; a part finds the address.
        assert!(m("send a@b.com now", "a@b.com"));
        assert!(!m("a quick note", "a@b.com")); // full address must NOT match a stray `a`
        assert!(m("send a@b.com now", "b.com")); // host part finds the address
        // apostrophe: the literal full form `'it''s'` is specific; the stripped/prefix
        // parts (valid bare terms) find it too. (A bare `it's` isn't valid query syntax
        // — `'` is the literal-term delimiter.)
        assert!(m("it's mine", "'it''s'"));
        assert!(!m("the it factor", "'it''s'")); // full form must NOT match a bare `it`
        assert!(m("it's mine", "its")); // stripped form finds the apostrophe doc
        assert!(m("it's mine", "it")); // prefix finds it
        // Segmentation is preserved: a token the index splits without compounding (`/`)
        // still splits on the query side too (would not, if the query skipped segmenting).
        assert!(m("alpha beta", "alpha/beta"));
    }

    #[pg_test]
    fn analyzer_apostrophe_query_forms() {
        // The supported ways to search text containing an apostrophe (`it's going to be
        // alright`) against the custom tokenizer, which superimposes `it's` → it's/it/its
        // at one position. (The shared DSL behavior — a raw `'` is the literal delimiter,
        // so `it's …` is a parse error, and `''` escaping — is covered in both
        // implementations by the SQL corpus: litErr1/litErr2 and litq1–litq3.)
        let m = |doc: &str, q: &str| -> bool {
            b(&format!(
                "SELECT proxquery_recheck(proxquery_to_tsvector($d${doc}$d$, 'prox_icu'), \
                 $q${q}$q$, 'prox_icu')"
            ))
        };
        let doc = "it's going to be alright";
        // 1) Phrase form — inside "…" the apostrophe is an ordinary word char, so the
        //    contraction needs no escaping. Full and partial phrases both match.
        assert!(m(doc, "\"it's going to be alright\""));
        assert!(m(doc, "\"it's going\""));
        assert!(!m(doc, "\"going it's\"")); // order matters in a phrase
        // 2) Literal form — the contraction with the quote DOUBLED, combined with
        //    operators. The literal is exact (matches the stored `it's`).
        assert!(m(doc, "'it''s' & going"));
        assert!(m(doc, "'it''s' <-> going")); // it's@1 immediately before going@2
        assert!(m(doc, "'it''s' <~4> alright")); // it's@1 .. alright@5 → distance 4
        assert!(!m(doc, "'it''s' <~3> alright")); // …so <~3> can't reach
        // 3) Bare parts — the apostrophe-stripped (`its`) and prefix (`it`) forms are
        //    superimposed at the same position, so they find the doc without any quoting.
        assert!(m(doc, "it & going"));
        assert!(m(doc, "its & alright"));
        // 4) Exactness — the literal `'it''s'` must NOT match a doc that only has bare
        //    `it`/`is` (no contraction), while the stripped part still does.
        assert!(!m("it is going to be alright", "'it''s'"));
        assert!(m("it is going to be alright", "it & going"));
        // The curly apostrophe `’` normalizes to `'`, so a literal with a straight quote
        // finds a doc written with the curly one.
        assert!(m("it\u{2019}s fine", "'it''s'"));
    }

    #[pg_test]
    fn analyzer_operator_corpus() {
        // The full DSL operator surface under the custom tokenizer (tests/analyzer_cases.md
        // — OR/NOT/grouping, every distance/proximity op, globs/prefix, regex, phrases),
        // which the parity corpus only covers under the stock cfg/literal resolvers. Two
        // phases: (A) the recheck equals `expected` for every row; (B) per distinct query,
        // the GIN-indexed @~@ returns exactly the rows the bare recheck does (probe
        // soundness) and the plan uses the index whenever the query carries a key.
        crate::corpus::load_analyzer_ops();

        // Phase A — recheck correctness.
        let mism = Spi::get_one::<String>(
            "SELECT coalesce(string_agg(label || $$: got=$$ || got || $$ want=$$ || expected, E'\\n' \
                 ORDER BY label), '') \
             FROM (SELECT label, expected, \
                      proxquery_recheck(proxquery_to_tsvector(doc, analyzer), query, analyzer)::text AS got \
                   FROM _prox_an) s \
             WHERE got IS DISTINCT FROM expected",
        )
        .unwrap()
        .unwrap_or_default();
        assert!(mism.is_empty(), "analyzer recheck != expected:\n{mism}");

        // Phase B — per analyzer, build an indexed table from its distinct docs (duplicated
        // so the planner prefers the index) and, per distinct query, force the index vs a
        // seqscan recheck and compare; require the index plan for keyed queries.
        Spi::run(
            "DO $$ \
             DECLARE a text; q text; has_key bool; n_idx bigint; n_seq bigint; line text; plan_hit bool; \
             BEGIN \
               FOR a IN SELECT DISTINCT analyzer FROM _prox_an ORDER BY 1 LOOP \
                 DROP TABLE IF EXISTS _ai; \
                 CREATE TEMP TABLE _ai(tsv tsvector); \
                 EXECUTE format('INSERT INTO _ai SELECT proxquery_to_tsvector(d.doc, %L) \
                                 FROM (SELECT DISTINCT doc FROM _prox_an WHERE analyzer=%L) d, \
                                      generate_series(1,20)', a, a); \
                 CREATE INDEX ON _ai USING gin(tsv); ANALYZE _ai; \
                 FOR q IN SELECT DISTINCT query FROM _prox_an WHERE analyzer=a ORDER BY 1 LOOP \
                   BEGIN PERFORM ts_prox_query(proxquery(a, q)); has_key := true; \
                   EXCEPTION WHEN OTHERS THEN has_key := false; END; \
                   SET LOCAL enable_seqscan=off; SET LOCAL enable_indexscan=on; SET LOCAL enable_bitmapscan=on; \
                   EXECUTE format('SELECT count(*) FROM _ai WHERE tsv @~@ proxquery(%L,%L)', a, q) INTO n_idx; \
                   IF has_key THEN \
                     plan_hit := false; \
                     FOR line IN EXECUTE format('EXPLAIN SELECT * FROM _ai WHERE tsv @~@ proxquery(%L,%L)', a, q) LOOP \
                       IF line LIKE '%Index Cond%ts_prox_query%' THEN plan_hit := true; END IF; \
                     END LOOP; \
                     IF NOT plan_hit THEN RAISE EXCEPTION 'analyzer % query [%] did not use the index', a, q; END IF; \
                   END IF; \
                   SET LOCAL enable_seqscan=on; SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; \
                   EXECUTE format('SELECT count(*) FROM _ai WHERE proxquery_recheck(tsv, %L, %L)', q, a) INTO n_seq; \
                   IF n_idx IS DISTINCT FROM n_seq THEN \
                     RAISE EXCEPTION 'analyzer % query [%]: index=% recheck=% (soundness)', a, q, n_idx, n_seq; \
                   END IF; \
                 END LOOP; \
               END LOOP; \
               DROP TABLE IF EXISTS _ai; \
             END $$",
        )
        .expect("analyzer @~@ index path must match the recheck for every query");
    }

    // --- pure-SQL port parity ----------------------------------------------
    // The extension-free port (sql/proxquery_pure.sql) must stay behavior-
    // identical to this extension, on every CI Postgres version.
    // The portable corpus is the markdown spec (tests/parity_cases.md), the single
    // source of truth, parsed by `corpus::load_parity`. The differential runner
    // executes every case against BOTH the native extension (schema `public`) and the
    // pure-SQL port (schema `proxquery`) and asserts they agree with each other and
    // with the expected value — so the two implementations can't drift. The fuzz runner
    // does the same on randomly generated query/doc pairs. Both require both
    // implementations in one session (the cargo-pgrx-test environment).
    #[pg_test]
    fn pure_sql_matches_extension_corpus() {
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        // The shared corpus is the markdown spec (tests/parity_cases.md), parsed and
        // loaded into the temp tables the differential runner reads.
        crate::corpus::load_parity();
        Spi::run(include_str!("../sql/proxquery_diff_test.sql")).expect("differential corpus test");
    }

    #[pg_test]
    fn pure_sql_matches_extension_fuzz() {
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        Spi::run(include_str!("../sql/proxquery_fuzz_test.sql")).expect("differential fuzz test");
    }

    // Position saturation (lexemes pinned at the 16383 cap) can't be expressed in
    // the markdown corpus — it builds tsvectors from text — so the differential
    // check for the NOT-within fail-open guard lives here, with crafted tsvectors.
    // Asserts the extension and the pure port agree with each other and the
    // expected value on the same cases as `not_within_fails_open_at_position_cap`.
    #[pg_test]
    fn pure_sql_matches_extension_at_position_cap() {
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        // Discover where the extension lives (the differential runner does the same),
        // rather than assuming `public`.
        let ext = Spi::get_one::<String>(
            "SELECT nsp.nspname::text FROM pg_extension e \
             JOIN pg_namespace nsp ON nsp.oid = e.extnamespace WHERE e.extname = 'proxquery'",
        )
        .unwrap()
        .expect("extension installed");

        // Run `expr` under both implementations and assert both equal `expected`.
        let both = |expr: &str, expected: bool| {
            let e = b(&format!("SELECT {ext}.{expr}"));
            let p = b(&format!("SELECT proxquery.{expr}"));
            assert_eq!(e, expected, "extension disagreed: {expr}");
            assert_eq!(p, expected, "pure port disagreed: {expr}");
        };

        // Avoid term ('email') at the cap, co-located with the subject ⇒ fail open.
        let sat = "$$'confidential':16383 'email':16383$$::tsvector";
        both(&format!("ts_prox_not_within({sat}, 'confidential', 'email', 3)"), true);
        both(&format!("ts_prox_recheck({sat}, 'confidential <!~3> email')"), true);
        both(&format!("ts_prox_recheck({sat}, 'confidential <!-3> email')"), true);

        // No saturation: a genuinely co-located pair is near ⇒ still false.
        let near = "$$'confidential':5 'email':5$$::tsvector";
        both(&format!("ts_prox_not_within({near}, 'confidential', 'email', 3)"), false);
        both(&format!("ts_prox_recheck({near}, 'confidential <!~3> email')"), false);

        // Scope: subject at the cap but avoid term not ⇒ no fail open ⇒ still false.
        let subj = "$$'confidential':16383 'email':16380$$::tsvector";
        both(&format!("ts_prox_not_within({subj}, 'confidential', 'email', 5)"), false);
    }

    // Smoke test: every ```sql block in README.md must run without error, so a renamed
    // function or broken syntax the README still references fails CI loudly. Results are NOT
    // checked here — examples with expected output (e.g. the café/cafe rows) are asserted in
    // their own dedicated tests. The README is written for reading, not running, so the test
    // absorbs three setup assumptions: (1) `CREATE EXTENSION proxquery` is already installed →
    // skip that block; (2) the early examples query a `docs(body_tsv)` table the README never
    // shows creating, and the analyzer section later recreates `docs` with its own schema →
    // seed a `docs(body_tsv)` fixture and DROP it before a `CREATE TABLE docs`; (3) the
    // custom-config example needs the `unaccent` contrib → skip it when it isn't available.
    #[pg_test]
    fn readme_examples_run_without_error() {
        // The pure-SQL port (schema `proxquery`) backs the `proxquery.ts_prox_search`
        // examples; the extension (schema `public`) backs `@~@` / `proxquery(...)` /
        // `proxquery_to_tsvector`. Put both on the search_path.
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        Spi::run("SET search_path = public, proxquery, pg_catalog").unwrap();
        Spi::run("CREATE TABLE docs(id bigserial, body_tsv tsvector)").unwrap();
        let has_unaccent = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_available_extensions WHERE name = 'unaccent'",
        )
        .unwrap()
        .unwrap_or(0)
            > 0;

        let readme = include_str!("../README.md");
        let (mut total, mut ran, mut in_sql) = (0, 0, false);
        let mut buf = String::new();
        for line in readme.lines() {
            if in_sql {
                if line.trim_start().starts_with("```") {
                    in_sql = false;
                    let block = buf.trim().to_string();
                    total += 1;
                    if block.is_empty() || block.starts_with("CREATE EXTENSION proxquery") {
                        continue; // already installed in the test
                    }
                    if block.contains("unaccent") && !has_unaccent {
                        continue; // contrib not available here
                    }
                    // the analyzer section recreates `docs` with its own schema — drop the fixture first
                    let sql = if block.contains("CREATE TABLE docs") {
                        format!("DROP TABLE IF EXISTS docs CASCADE;\n{block}")
                    } else {
                        block.clone()
                    };
                    Spi::run(&sql).unwrap_or_else(|e| {
                        panic!("README sql block #{total} failed: {e:?}\n--- block ---\n{block}\n-------------")
                    });
                    ran += 1;
                } else {
                    buf.push_str(line);
                    buf.push('\n');
                }
            } else if line.trim_start().starts_with("```sql") {
                in_sql = true;
                buf.clear();
            }
        }
        assert!(ran >= 4, "expected to run the README's sql examples; ran {ran} of {total} blocks");
    }
}

/// Required by `cargo pgrx test`.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}

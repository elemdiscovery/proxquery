//! proxquery — positional proximity predicates for `tsvector` full-text search.
//!
//! Milestone 1: the position accessor ([`tsvector`]) and the proximity predicates
//! ([`proximity`]), exposed as SQL recheck filters. These pair with a plain GIN
//! `@@` candidate selection today; the proximity query compiler and the single
//! `@~@` operator land in later milestones (see docs/IMPLEMENTATION_PLAN.md).

use pgrx::prelude::*;

mod dsl;
mod proximity;
mod support;
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
    let parsed = dsl::normalize(dsl::parse(query)?);
    dsl::validate_regexes(&parsed)?; // a malformed ##regex## fails the query up front
    let parsed = Rc::new(parsed);
    PROXMATCH_AST.with(|c| *c.borrow_mut() = Some((query.to_owned(), Rc::clone(&parsed))));
    Ok(parsed)
}

/// Evaluate the proxquery DSL's positional semantics on `v` — the recheck that
/// pairs with `ts_prox_query` for index selection (`v @@ ts_prox_query(q) AND
/// ts_prox_match(v, q)`).
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_match(v: TsVector, query: &str) -> bool {
    let node = match cached_ast(query) {
        Ok(n) => n,
        Err(e) => error!("ts_prox_match: {e}"),
    };
    match dsl::eval_match(&node, &v, None) {
        Ok(m) => m,
        Err(e) => error!("ts_prox_match: {e}"),
    }
}

/// Config-aware recheck: resolve each query *term* through `cfg`
/// (`to_tsvector(cfg, term)`) so it matches a column built with that text-search
/// config (stemmed/unaccented/locale-folded lexemes). The `simple` 2-arg
/// [`ts_prox_match`] is the literal-lexeme fast path; this is the explicit-config
/// form behind the 3-arg `ts_prox_match(tsvector, text, regconfig)` overload and
/// the `@~@ proxquery(cfg, q)` operator. `cfg` arrives as a plain `oid` (regconfig
/// is binary-coercible); the SQL wrappers do the `regconfig::oid` cast.
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_match_cfg(v: TsVector, query: &str, cfg: pgrx::pg_sys::Oid) -> bool {
    let node = match cached_ast(query) {
        Ok(n) => n,
        Err(e) => error!("ts_prox_match: {e}"),
    };
    match dsl::eval_match(&node, &v, Some(cfg)) {
        Ok(m) => m,
        Err(e) => error!("ts_prox_match: {e}"),
    }
}

// The single-clause surface: `text_tsv @~@ 'a <~5> b'`. For now it is `ts_prox_match`
// sugar (a seq-scan recheck); the planner support function below teaches it to use
// the GIN index. The right operand is the DSL string.
pgrx::extension_sql!(
    r#"
CREATE OPERATOR @~@ (
    LEFTARG = tsvector,
    RIGHTARG = text,
    FUNCTION = ts_prox_match
);
"#,
    name = "proxmatch_operator",
    requires = [ts_prox_match],
);

/// Planner support function for `@~@` / `ts_prox_match` — derives an index
/// condition (`tsvector @@ ts_prox_query(q)`, lossy) so the operator uses a plain
/// GIN tsvector index. See [`support`].
#[pg_extern(immutable, parallel_safe)]
fn ts_prox_query_support(arg: Internal) -> Internal {
    // "No support" must be a non-NULL datum holding a NULL pointer — returning
    // SQL NULL trips `FunctionCall1Coll`'s "function returned NULL" error.
    let no_support = || Internal::from(Some(pgrx::pg_sys::Datum::null()));
    let node = match arg.unwrap() {
        Some(datum) => datum.cast_mut_ptr::<pgrx::pg_sys::Node>(),
        None => return no_support(),
    };
    unsafe { support::index_condition(node) }.unwrap_or_else(no_support)
}

// Attach the support fn. Superuser-only, but a trusted extension's install
// script runs privileged, so this works on managed/Neon-style installs too.
pgrx::extension_sql!(
    "ALTER FUNCTION ts_prox_match(tsvector, text) SUPPORT ts_prox_query_support;",
    name = "proxmatch_support",
    requires = [ts_prox_match, ts_prox_query_support],
);

// --- config-aware surface: 3-arg overloads + the @~@ proxquery(cfg, q) operator ---
//
// The 3-arg `ts_prox_query`/`ts_prox_match` are the explicit-config two-clause form
// (always index-served, like the 2-arg). The `@~@` operator can't take a third arg,
// so the config rides in a typed right operand: `tsv @~@ proxquery(cfg, q)`. A second
// `@~@` over the `proxquery` composite keeps one operator symbol; its support fn
// (shared with the 2-arg) rewrites it to `tsv @@ ts_prox_query(proxquery)` for the GIN
// index. `simple`-config callers keep using the plain `text` operator unchanged.
pgrx::extension_sql!(
    r#"
-- 3-arg recheck: regconfig cast to oid for the internal (regconfig is an oid alias).
CREATE FUNCTION ts_prox_match(v tsvector, query text, cfg regconfig) RETURNS bool
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT ts_prox_match_cfg($1, $2, $3::oid) $$;

-- The typed right operand for @~@: a (config, query) pair.
CREATE TYPE proxquery AS (cfg regconfig, q text);

CREATE FUNCTION proxquery(cfg regconfig, q text) RETURNS proxquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT ROW($1, $2)::proxquery $$;

-- Skeleton + recheck over the typed operand. The support fn injects
-- `ts_prox_query(proxquery)` as the GIN index condition, deconstructing the pair
-- inside this IMMUTABLE function (so it constant-folds at plan time).
CREATE FUNCTION ts_prox_query(pq proxquery) RETURNS tsquery
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT to_tsquery(($1).cfg, ts_prox_query_skeleton(($1).q)) $$;

-- plpgsql (not sql) so the planner does NOT inline the operator into a bare
-- ts_prox_match_cfg() call — inlining would strip the @~@ OpExpr and bypass the
-- support function, losing the index. (The 2-arg text operator stays indexable for
-- the same reason: its function is a non-inlinable C function.)
CREATE FUNCTION ts_prox_match(v tsvector, pq proxquery) RETURNS bool
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ BEGIN RETURN ts_prox_match_cfg(v, pq.q, pq.cfg::oid); END $$;

CREATE OPERATOR @~@ (
    LEFTARG = tsvector,
    RIGHTARG = proxquery,
    FUNCTION = ts_prox_match
);

ALTER FUNCTION ts_prox_match(tsvector, proxquery) SUPPORT ts_prox_query_support;
"#,
    name = "proxquery_config_aware",
    requires = [ts_prox_query_skeleton, ts_prox_match_cfg, ts_prox_query_support],
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
        // (a & b) <~5> c lifts AND out → all three lexemes required.
        assert!(selects("a b c", "(a & b) <~5> c"));
        assert!(!selects("a c", "(a & b) <~5> c")); // missing b
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
        assert!(!b(&format!("SELECT ts_prox_match(to_tsvector('simple','a b'), {q})")));
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


    // --- ts_prox_match recheck + full pipeline -----------------------------
    fn proxmatch(doc: &str, q: &str) -> bool {
        let (doc, q) = (doc.replace('\'', "''"), q.replace('\'', "''"));
        b(&format!("SELECT ts_prox_match(to_tsvector('simple','{doc}'), '{q}')"))
    }
    // Selection AND recheck together — what the proxsearch()-style wrapper does.
    fn proxfind(doc: &str, q: &str) -> bool {
        let (doc, q) = (doc.replace('\'', "''"), q.replace('\'', "''"));
        b(&format!(
            "SELECT to_tsvector('simple','{doc}') @@ ts_prox_query('{q}') \
                 AND ts_prox_match(to_tsvector('simple','{doc}'), '{q}')"
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
        assert!(b(&format!("SELECT ts_prox_match({tv}, 'a <~0> b')")));
        assert!(b(&format!("SELECT ts_prox_match({tv}, 'a <0> b')")));
        // matches native tsquery exactly (the `<N> unchanged` promise).
        assert!(b(&format!("SELECT {tv} @@ to_tsquery('simple','a <0> b')")));
        // ordered `<-0>` (strictly before, at distance ≤0) is contradictory ⇒ false.
        assert!(!b(&format!("SELECT ts_prox_match({tv}, 'a <-0> b')")));
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
    fn recheck_and_lift_shares_anchor() {
        // (a & b) <~2> c ⇒ both a and b within 2 of c.
        assert!(proxmatch("a c b", "(a & b) <~2> c")); // a@1 c@2 b@3
        assert!(!proxmatch("a w w w w c b", "(a & b) <~2> c")); // a is 5 from c
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
                 IF line LIKE '%Index Cond%ts_prox_query%' THEN hit := true; END IF; \
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
        // @~@ IS `ts_prox_match` plus a planner support fn that, under a GIN index,
        // rewrites it to `tsv @@ ts_prox_query(q) AND ts_prox_match(tsv, q)`. Driven by
        // the SAME structured corpus as the function tests (proxquery_match_cases.sql),
        // this builds one indexed table from the distinct docs and confirms, for every
        // distinct query, that @~@ over the index (a) is actually taken when the query
        // carries an index key and (b) returns exactly the rows the bare recheck does.
        Spi::run(include_str!("../sql/proxquery_match_cases.sql")).expect("load match corpus");
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
                     IF line LIKE '%Index Cond%ts_prox_query%' THEN plan_hit := true; END IF; \
                   END LOOP; \
                   IF NOT plan_hit THEN RAISE EXCEPTION 'index not used for keyed query: %', q; END IF; \
                 END IF; \
                 SET LOCAL enable_seqscan = on; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off; \
                 EXECUTE format('SELECT coalesce(array_agg(id ORDER BY id), ''{}''::int[])::text FROM docs WHERE ts_prox_match(tsv, %L)', q) INTO s_seq; \
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
        // (a & b) <~5> c lifts the AND → BOTH within 5 of c; a & (b <~5> c) → a
        // present AND (b within 5 of c). a far from c, b adjacent to c → they differ.
        let d = "a z z z z z z z z z z b c"; // a@1 b@12 c@13
        assert!(!proxmatch(d, "(a & b) <~5> c"));
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

    #[pg_test(error = "ts_prox_match: a bare `*` matches everything; give it a literal part")]
    fn err_dangling_bare_star() {
        // A hanging bare `*` (`something *`, space-separated) is rejected at parse
        // time — it would match every lexeme. (Attached, `something*` is a normal
        // prefix search; see prefix_native_form_and_exact_term.)
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','something here'), 'something *')").unwrap();
    }

    #[pg_test(error = "ts_prox_match: expected `)`")]
    fn err_unbalanced_parens() {
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','a b'), '(a <~5> b')").unwrap();
    }

    #[pg_test(error = "ts_prox_match: not-within needs a direction: `<!~N>` (either order) or `<!-N>` (ordered)")]
    fn err_not_within_without_direction() {
        // dtSearch-style bare `w/N` and a directionless `<!N>` are both rejected.
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','a b'), 'a <!5> b')").unwrap();
    }

    #[pg_test(error = "ts_prox_match: unexpected end of query")]
    fn err_trailing_operator() {
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','a b'), 'a &')").unwrap();
    }

    #[pg_test(error = "ts_prox_match: invalid regex `[`")]
    fn err_invalid_regex() {
        // A ##regex## that can't compile is a query bug → fail, don't suppress.
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','alpha beta'), '##[##')").unwrap();
    }

    #[pg_test(error = "ts_prox_match: invalid regex `[`")]
    fn err_invalid_regex_fails_regardless_of_short_circuit() {
        // Validation is up front, so a malformed regex fails the query even when a
        // sibling branch (`alpha`) would have matched and short-circuited eval.
        Spi::run("SELECT ts_prox_match(to_tsvector('simple','alpha beta'), 'alpha | ##[##')").unwrap();
    }

    // --- config-aware surface (3-arg overloads + @~@ proxquery operator) ----

    #[pg_test]
    fn config_aware_english_stemming() {
        // The headline: a SURFACE query term matches the stored STEM under `english`.
        assert!(b("SELECT ts_prox_match(to_tsvector('english','the running shoes'),'running <~2> shoes','english')"));
        assert!(b("SELECT ts_prox_match(to_tsvector('english','the running shoes'),'run <~2> shoe','english')"));
        // The 2-arg simple path is literal — it does NOT match the stem (unchanged).
        assert!(!b("SELECT ts_prox_match(to_tsvector('english','the running shoes'),'running <~2> shoes')"));
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
                 || quote_literal(cfg) || '::regconfig, ' || quote_literal(q) || ')' LOOP \
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
    fn config_aware_user_defined_config() {
        // A user-defined config works exactly like a built-in — proxquery only ever
        // passes the regconfig you name into `to_tsvector`. (Custom config, no contrib
        // dependency: a copy of english under a different name.)
        Spi::run("DROP TEXT SEARCH CONFIGURATION IF EXISTS myeng").unwrap();
        Spi::run("CREATE TEXT SEARCH CONFIGURATION myeng (COPY = english)").unwrap();
        assert!(b("SELECT ts_prox_match(to_tsvector('myeng','the running shoes'),'running <~2> shoes','myeng')"));
        assert!(b("SELECT to_tsvector('myeng','the running shoes') @~@ proxquery('myeng','running <~2> shoes')"));
        // Two-clause form selects via the same custom config.
        assert!(b(
            "SELECT to_tsvector('myeng','the running shoes') @@ ts_prox_query('running <~2> shoes','myeng') \
             AND ts_prox_match(to_tsvector('myeng','the running shoes'),'running <~2> shoes','myeng')"
        ));
    }

    // --- pure-SQL port parity ----------------------------------------------
    // The extension-free port (sql/proxquery_pure.sql) must stay behavior-
    // identical to this extension, on every CI Postgres version.
    // The portable corpus (sql/proxquery_cases.sql) is the single source of truth.
    // The differential runner executes every case against BOTH the native extension
    // (schema `public`) and the pure-SQL port (schema `proxquery`) and asserts they
    // agree with each other and with the expected value — so the two implementations
    // can't drift. The fuzz runner does the same on randomly generated query/doc
    // pairs. Both require both implementations in one session (the cargo-pgrx-test
    // environment); the psql-standalone golden check lives in proxquery_pure_test.sql.
    #[pg_test]
    fn pure_sql_matches_extension_corpus() {
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        Spi::run(include_str!("../sql/proxquery_cases.sql")).expect("load shared corpus");
        Spi::run(include_str!("../sql/proxquery_match_cases.sql")).expect("load match corpus");
        Spi::run(include_str!("../sql/proxquery_diff_test.sql")).expect("differential corpus test");
    }

    #[pg_test]
    fn pure_sql_matches_extension_fuzz() {
        Spi::run(include_str!("../sql/proxquery_pure.sql")).expect("load pure-SQL port");
        Spi::run(include_str!("../sql/proxquery_fuzz_test.sql")).expect("differential fuzz test");
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

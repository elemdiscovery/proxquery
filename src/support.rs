//! Planner support for the `@~@` operator — makes it index-served on a *plain*
//! `gin(tsvector)` index, with no custom operator class.
//!
//! When the planner considers `tsvector @~@ 'q'` against a GIN tsvector index, it
//! asks `ts_prox_match`'s support function for usable index conditions
//! ([`pg_sys::SupportRequestIndexCondition`]). We hand back
//! `tsvector @@ ts_prox_query('q')` — the lexeme-presence skeleton, reusing
//! `ts_prox_query` so a runtime-parameter query works too — and mark it **lossy**,
//! so the original `@~@` stays as the positional recheck filter. The result is
//! identical to the hand-written two-clause form, but as one clause.
//!
//! Pure CPU at plan time (no I/O, shmem, or background workers) — Neon-safe.

use core::ptr;
use pgrx::datum::{FromDatum, Internal};
use pgrx::pg_sys;

/// Build the index condition list for a `SupportRequestIndexCondition`, or `None`
/// if this request isn't one we can help with (the planner then falls back to the
/// `@~@` recheck as a plain filter).
///
/// # Safety
/// `node` must be the `Node *` the planner passed to the support function.
pub unsafe fn index_condition(node: *mut pg_sys::Node) -> Option<Internal> {
    if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_SupportRequestIndexCondition {
        return None;
    }
    let req = node.cast::<pg_sys::SupportRequestIndexCondition>();

    // The clause is `tsvector @~@ text` (OpExpr) or `ts_prox_match(tsvector, text)`
    // (FuncExpr) — both carry the two operands in `args`.
    let clause = (*req).node;
    if clause.is_null() {
        return None;
    }
    let args = match (*clause).type_ {
        pg_sys::NodeTag::T_OpExpr => (*clause.cast::<pg_sys::OpExpr>()).args,
        pg_sys::NodeTag::T_FuncExpr => (*clause.cast::<pg_sys::FuncExpr>()).args,
        _ => return None,
    };
    if args.is_null() || (*args).length != 2 {
        return None;
    }

    // `indexarg` is the indexed (tsvector) operand; the other is the DSL text.
    let indexarg = (*req).indexarg;
    if indexarg != 0 && indexarg != 1 {
        return None;
    }
    let indexed = pg_sys::list_nth(args, indexarg).cast::<pg_sys::Node>();
    let query = pg_sys::list_nth(args, 1 - indexarg).cast::<pg_sys::Node>();

    // If the query is a constant with no positive index term — a bare wildcard,
    // regex, or pure negation — offer no index condition. Otherwise we'd inject
    // `@@ ts_prox_query(const)`, which the planner folds and which *errors* for such
    // queries; instead let the `@~@` / `ts_prox_match` filter handle it (seq scan).
    if !query.is_null() && (*query).type_ == pg_sys::NodeTag::T_Const {
        let c = query.cast::<pg_sys::Const>();
        if (*c).consttype == pg_sys::TEXTOID && !(*c).constisnull {
            if let Some(s) = String::from_datum((*c).constvalue, false) {
                if crate::dsl::to_tsquery_string(&s).is_err() {
                    return None;
                }
            }
        }
    }

    // The index must expose `tsvector @@ tsquery` (GIN tsvector_ops, strategy 1).
    let at_at =
        pg_sys::get_opfamily_member((*req).opfamily, pg_sys::TSVECTOROID, pg_sys::TSQUERYOID, 1);
    if at_at == pg_sys::InvalidOid {
        return None;
    }

    // ts_prox_query(text) -> tsquery, resolved via the active search_path.
    let names = pg_sys::stringToQualifiedNameList(c"ts_prox_query".as_ptr(), ptr::null_mut());
    let argtypes = [pg_sys::TEXTOID];
    let proxquery_fn = pg_sys::LookupFuncName(names, 1, argtypes.as_ptr(), true);
    if proxquery_fn == pg_sys::InvalidOid {
        return None;
    }

    // Build  `indexed @@ ts_prox_query(query)`.
    let func_args = pg_sys::lappend(ptr::null_mut(), query.cast());
    let funcexpr = pg_sys::makeFuncExpr(
        proxquery_fn,
        pg_sys::TSQUERYOID,
        func_args,
        pg_sys::InvalidOid,
        pg_sys::InvalidOid,
        pg_sys::CoercionForm::COERCE_EXPLICIT_CALL,
    );
    let opclause = pg_sys::make_opclause(
        at_at,
        pg_sys::BOOLOID,
        false,
        indexed.cast::<pg_sys::Expr>(),
        funcexpr.cast::<pg_sys::Expr>(),
        pg_sys::InvalidOid,
        pg_sys::InvalidOid,
    );

    // Lossy: the index condition is a superset, so keep `@~@` as the recheck.
    (*req).lossy = true;

    let result = pg_sys::lappend(ptr::null_mut(), opclause.cast());
    Some(Internal::from(Some(pg_sys::Datum::from(result))))
}

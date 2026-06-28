//! Planner support for the `@~@` operator — makes it index-served on a *plain*
//! `gin(tsvector)` index, with no custom operator class. Two requests:
//!
//! * **simplify** ([`pg_sys::SupportRequestSimplify`], [`simplify`]) — when the query
//!   is a constant that maps EXACTLY onto a native `tsquery` AND that native form is the
//!   selective index probe (phrase, exact `<N>`, boolean — NOT `within`/`pre`, whose
//!   OR-expansion would seq-scan; see [`crate::dsl::simplify_tsquery_string`]), rewrite
//!   the whole clause to a plain `tsvector @@ ts_prox_query_native('q')`. Postgres's own
//!   (C) phrase engine then evaluates it in the GIN `@@` heap recheck, so the custom
//!   positional recheck is dropped entirely (one detoast, not two).
//! * **index condition** ([`pg_sys::SupportRequestIndexCondition`], [`index_condition`])
//!   — for everything else, hand back `tsvector @@ ts_prox_query('q')` (the lexeme-
//!   presence skeleton) marked **lossy**, so the original `@~@` stays as the positional
//!   recheck filter. Identical to the hand-written two-clause form, but as one clause.
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
    // The DSL string comes from the `text` operand or the `proxquery` composite's `q`.
    if let Some(s) = const_dsl(query) {
        if crate::dsl::to_tsquery_string(&s).is_err() {
            return None;
        }
    }

    // The index must expose `tsvector @@ tsquery` (GIN tsvector_ops, strategy 1).
    let at_at =
        pg_sys::get_opfamily_member((*req).opfamily, pg_sys::TSVECTOROID, pg_sys::TSQUERYOID, 1);
    if at_at == pg_sys::InvalidOid {
        return None;
    }

    // `ts_prox_query` overloaded on the right operand's type: `ts_prox_query(text)`
    // for the plain `@~@`, `ts_prox_query(proxquery)` for the config-carrying one.
    // Passing the operand node straight through lets one code path serve both.
    // (Native-expressible constant queries never reach here — they were rewritten to
    // a plain `tsv @@ <native tsquery>` by the simplify path before index matching.)
    let qtype = pg_sys::exprType(query);
    let names = pg_sys::stringToQualifiedNameList(c"ts_prox_query".as_ptr(), ptr::null_mut());
    let argtypes = [qtype];
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

/// `SupportRequestSimplify` for `@~@` / `ts_prox_match`: when the (constant, plain-
/// `text`) query maps EXACTLY onto a native `tsquery` whose `@@` is ALSO the selective
/// index probe (phrase / exact `<N>` / boolean — see
/// [`crate::dsl::simplify_tsquery_string`]), rewrite the whole clause to a plain
/// `tsvector @@ ts_prox_query_native(query)`. That `@@` is GIN-indexable and carries
/// its own (AM-level) exact recheck, so the custom positional recheck is gone
/// entirely — and the rewrite is equivalent everywhere, seq scan included. Returns
/// `None` (no rewrite) otherwise: runtime parameters, the `proxquery` (cfg/analyzer)
/// operand, `within`/`pre` (whose OR-expansion would lose the `a & b` index driver and
/// seq-scan), and queries that aren't fully native-expressible — all keep the presence
/// skeleton + recheck via [`index_condition`].
///
/// # Safety
/// `node` must be the `Node *` the planner passed to the support function.
pub unsafe fn simplify(node: *mut pg_sys::Node) -> Option<Internal> {
    if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_SupportRequestSimplify {
        return None;
    }
    let fcall = (*node.cast::<pg_sys::SupportRequestSimplify>()).fcall;
    if fcall.is_null() {
        return None;
    }
    // `@~@` / `ts_prox_match(tsvector, text)`: arg 0 is the tsvector, arg 1 the query.
    let args = (*fcall).args;
    if args.is_null() || (*args).length != 2 {
        return None;
    }
    let indexed = pg_sys::list_nth(args, 0).cast::<pg_sys::Node>();
    let query = pg_sys::list_nth(args, 1).cast::<pg_sys::Node>();

    // Only the plain literal path, and only a constant query that is fully native-
    // expressible. (The cfg/analyzer `proxquery` operand is not TEXT; a runtime
    // parameter carries no constant DSL to expand.)
    if pg_sys::exprType(query) != pg_sys::TEXTOID {
        return None;
    }
    let s = const_dsl(query)?;
    // Bail unless the query is safely rewritable: native-expressible AND free of
    // within/pre (whose OR-expansion, as the sole index driver, would seq-scan — see
    // `simplify_tsquery_string`). Those fall through to `index_condition` instead.
    let native_str = crate::dsl::simplify_tsquery_string(&s)?;

    let at_at = pg_sys::OpernameGetOprid(
        pg_sys::stringToQualifiedNameList(c"@@".as_ptr(), ptr::null_mut()),
        pg_sys::TSVECTOROID,
        pg_sys::TSQUERYOID,
    );
    if at_at == pg_sys::InvalidOid {
        return None;
    }

    // Parse the native query to a tsquery NOW (plan time) and inject it as a `Const`,
    // so the `@@` recheck evaluates a literal tsquery per row — not the DSL re-parse a
    // funcexpr would force on every heap tuple. Use `tsqueryin` (the type's input
    // function), NOT `to_tsquery`: the lexemes must be taken VERBATIM to match the
    // recheck's exact byte lookup; `to_tsquery` would re-tokenize / re-lowercase them.
    let (mut typinput, mut typioparam) = (pg_sys::InvalidOid, pg_sys::InvalidOid);
    pg_sys::getTypeInputInfo(pg_sys::TSQUERYOID, &mut typinput, &mut typioparam);
    // A mutable, NUL-terminated buffer: input functions may scribble on the cstring.
    let mut buf: Vec<u8> = native_str.into_bytes();
    buf.push(0);
    let tsq = pg_sys::OidInputFunctionCall(
        typinput,
        buf.as_mut_ptr() as *mut core::ffi::c_char,
        typioparam,
        -1,
    );
    let tsq_const =
        pg_sys::makeConst(pg_sys::TSQUERYOID, -1, pg_sys::InvalidOid, -1, tsq, false, false);
    let opclause = pg_sys::make_opclause(
        at_at,
        pg_sys::BOOLOID,
        false,
        indexed.cast::<pg_sys::Expr>(),
        tsq_const.cast::<pg_sys::Expr>(),
        pg_sys::InvalidOid,
        pg_sys::InvalidOid,
    );
    // make_opclause leaves opfuncid unset; fill it so the rewritten node is complete.
    (*opclause.cast::<pg_sys::OpExpr>()).opfuncid = pg_sys::get_opcode(at_at);

    Some(Internal::from(Some(pg_sys::Datum::from(opclause))))
}

/// The DSL query string carried by a *constant* right operand — the `text` itself,
/// or the `q` field of a folded `proxquery` composite. `None` for a non-constant
/// (runtime parameter) or anything we can't read, which simply skips the keyless
/// guard above (the operator still works; it just doesn't get the early-out).
///
/// # Safety
/// `query` must be a planner expression node (or null).
unsafe fn const_dsl(query: *mut pg_sys::Node) -> Option<String> {
    if query.is_null() || (*query).type_ != pg_sys::NodeTag::T_Const {
        return None;
    }
    let c = query.cast::<pg_sys::Const>();
    if (*c).constisnull {
        return None;
    }
    if (*c).consttype == pg_sys::TEXTOID {
        return String::from_datum((*c).constvalue, false);
    }
    // The `proxquery` composite (the only other @~@ right operand): attr 2 is `q text`.
    if pg_sys::type_is_rowtype((*c).consttype) {
        let tup = (*c).constvalue.cast_mut_ptr::<pg_sys::HeapTupleHeaderData>();
        let mut isnull = false;
        let qd = pg_sys::GetAttributeByNum(tup, 2, &mut isnull);
        if isnull {
            return None;
        }
        return String::from_datum(qd, false);
    }
    None
}

//! Direct positional access into a `tsvector` varlena.
//!
//! pgrx 0.19 ships no `tsvector` wrapper, so we define a thin [`TsVector`] newtype
//! over the detoasted `*mut pg_sys::TSVectorData` and walk it by hand. The layout
//! is the phrase-search-era tsvector (PostgreSQL 12+, unchanged through 18):
//!
//! ```text
//! int32 vl_len_                  varlena header
//! int32 size                     number of lexemes (WordEntry entries)
//! WordEntry entries[size]        { haspos:1, len:11, pos:20 }, sorted by lexeme
//! <lexeme pool>                  `size` lexeme strings, not NUL-terminated
//! <position data>                per haspos entry: uint16 npos; WordEntryPos[npos]
//! ```
//!
//! `entry.pos` is the byte offset from the end of the entry array (`STRPTR`) to the
//! lexeme; positions for a haspos entry sit at `STRPTR + SHORTALIGN(pos + len)`.
//! Because lexemes are sorted (memcmp order), lookup is a binary search — `O(log L)`
//! — and we read only the position array of the lexeme(s) we name, never the whole
//! vector. That fast accessor is the entire reason this extension exists.

use pgrx::callconv::{Arg, ArgAbi};
use pgrx::datum::FromDatum;
use pgrx::nullable::Nullable;
use pgrx::pg_sys;
use pgrx::pgrx_sql_entity_graph::metadata::{
    ArgumentError, ReturnsError, ReturnsRef, SqlMappingRef, SqlTranslatable, TypeOrigin,
};

/// A detoasted `tsvector`, borrowed for the duration of a single function call.
#[repr(transparent)]
pub struct TsVector(*mut pg_sys::TSVectorData);

/// `WEP_GETPOS` — the low 14 bits of a `WordEntryPos` hold the position; the top 2
/// hold the weight, which proximity ignores.
const WEP_POS_MASK: u16 = 0x3fff;

/// `SHORTALIGN` — round up to a 2-byte boundary (position data is `uint16`-aligned).
#[inline]
fn shortalign(x: usize) -> usize {
    (x + 1) & !1usize
}

// ---------------------------------------------------------------------------
// pgrx boundary: how a SQL `tsvector` argument becomes a `TsVector` in Rust.
// FromDatum detoasts; ArgAbi (hand-rolled, since pgrx's `argue_from_datum!`
// covers only its own built-in types) delegates straight back to FromDatum;
// SqlTranslatable maps the Rust type to the SQL `tsvector`.
// ---------------------------------------------------------------------------

impl FromDatum for TsVector {
    unsafe fn from_polymorphic_datum(
        datum: pg_sys::Datum,
        is_null: bool,
        _typoid: pg_sys::Oid,
    ) -> Option<Self> {
        if is_null {
            return None;
        }
        // pg_detoast_datum returns the original pointer when the datum is already
        // a plain (uncompressed, un-toasted) varlena, or a palloc'd copy in the
        // current memory context otherwise — valid for the call. We only read it.
        let detoasted = pg_sys::pg_detoast_datum(datum.cast_mut_ptr::<pg_sys::varlena>());
        Some(TsVector(detoasted.cast::<pg_sys::TSVectorData>()))
    }
}

unsafe impl<'fcx> ArgAbi<'fcx> for TsVector {
    unsafe fn unbox_arg_unchecked(arg: Arg<'_, 'fcx>) -> Self {
        unsafe {
            arg.unbox_arg_using_from_datum()
                .expect("tsvector argument must not be NULL")
        }
    }

    unsafe fn unbox_nullable_arg(arg: Arg<'_, 'fcx>) -> Nullable<Self> {
        unsafe { arg.unbox_arg_using_from_datum().into() }
    }
}

unsafe impl SqlTranslatable for TsVector {
    const TYPE_IDENT: &'static str = pgrx::pgrx_resolved_type!(TsVector);
    const TYPE_ORIGIN: TypeOrigin = TypeOrigin::External;
    const ARGUMENT_SQL: Result<SqlMappingRef, ArgumentError> =
        Ok(SqlMappingRef::literal("tsvector"));
    const RETURN_SQL: Result<ReturnsRef, ReturnsError> =
        Ok(ReturnsRef::One(SqlMappingRef::literal("tsvector")));
}

// ---------------------------------------------------------------------------
// The accessor itself.
// ---------------------------------------------------------------------------

impl TsVector {
    #[inline]
    fn header(&self) -> &pg_sys::TSVectorData {
        unsafe { &*self.0 }
    }

    #[inline]
    fn size(&self) -> usize {
        self.header().size as usize
    }

    /// `(entries pointer, lexeme/position pool base)`.
    #[inline]
    unsafe fn parts(&self) -> (*const pg_sys::WordEntry, *const u8) {
        let entries = self.header().entries.as_ptr();
        let strptr = entries.add(self.size()) as *const u8; // STRPTR = &entries[size]
        (entries, strptr)
    }

    /// Bytes of lexeme `i` (not NUL-terminated).
    #[inline]
    unsafe fn lexeme(
        &self,
        entries: *const pg_sys::WordEntry,
        strptr: *const u8,
        i: usize,
    ) -> &[u8] {
        let e = &*entries.add(i);
        std::slice::from_raw_parts(strptr.add(e.pos() as usize), e.len() as usize)
    }

    /// Append entry `i`'s positions (already sorted ascending) to `out`.
    #[inline]
    unsafe fn push_entry_positions(
        &self,
        strptr: *const u8,
        e: &pg_sys::WordEntry,
        out: &mut Vec<i32>,
    ) {
        if e.haspos() == 0 {
            return; // present but position-less (e.g. a stripped tsvector)
        }
        let base = strptr.add(shortalign(e.pos() as usize + e.len() as usize)) as *const u16;
        let npos = base.read_unaligned() as usize;
        let positions = base.add(1); // WordEntryPos[] follows the npos u16
        out.reserve(npos);
        for k in 0..npos {
            out.push((positions.add(k).read_unaligned() & WEP_POS_MASK) as i32);
        }
    }

    /// Binary-search the sorted lexeme pool for an exact match; entry index if present.
    fn bsearch(&self, needle: &[u8]) -> Option<usize> {
        let n = self.size();
        if n == 0 {
            return None;
        }
        unsafe {
            let (entries, strptr) = self.parts();
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                // slice `cmp` is byte-lexicographic with shorter-is-less, matching
                // Postgres' tsCompareString (memcmp then length).
                match self.lexeme(entries, strptr, mid).cmp(needle) {
                    std::cmp::Ordering::Less => lo = mid + 1,
                    std::cmp::Ordering::Greater => hi = mid,
                    std::cmp::Ordering::Equal => return Some(mid),
                }
            }
            None
        }
    }

    /// Every lexeme in the pool, in stored (sorted) order. Used to enumerate the
    /// lexemes of a freshly built `to_tsvector(cfg, term)` during config-aware term
    /// resolution — those vectors are tiny (one term's tokens), so the copy is cheap.
    pub fn all_lexemes(&self) -> Vec<Vec<u8>> {
        let n = self.size();
        let mut out = Vec::with_capacity(n);
        if n == 0 {
            return out;
        }
        unsafe {
            let (entries, strptr) = self.parts();
            for i in 0..n {
                out.push(self.lexeme(entries, strptr, i).to_vec());
            }
        }
        out
    }

    /// Sorted positions of `lexeme` — empty if it is absent or carries no positions.
    pub fn positions(&self, lexeme: &[u8]) -> Vec<i32> {
        let mut out = Vec::new();
        if let Some(i) = self.bsearch(lexeme) {
            unsafe {
                let (entries, strptr) = self.parts();
                self.push_entry_positions(strptr, &*entries.add(i), &mut out);
            }
        }
        out
    }

    /// Merged, sorted positions over every lexeme beginning with `prefix` — the
    /// contiguous run in the sorted pool. This is the `appl*` primitive: one lower
    /// bound plus a forward scan, no vocabulary table. Empty if nothing matches.
    pub fn positions_prefix(&self, prefix: &[u8]) -> Vec<i32> {
        let mut out = Vec::new();
        let n = self.size();
        if n == 0 {
            return out;
        }
        unsafe {
            let (entries, strptr) = self.parts();
            // Lower bound: first entry whose lexeme ≥ prefix.
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                if self.lexeme(entries, strptr, mid) < prefix {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            let mut i = lo;
            while i < n {
                if !self.lexeme(entries, strptr, i).starts_with(prefix) {
                    break;
                }
                self.push_entry_positions(strptr, &*entries.add(i), &mut out);
                i += 1;
            }
        }
        // Distinct lexemes can't truly share a token position, but sort+dedup keeps
        // the contract (sorted, unique) robust regardless.
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Merged, sorted positions of every lexeme accepted by `pred`. When `prefix`
    /// is non-empty, only the contiguous prefix range of the sorted pool is
    /// scanned (the fast path — a glob/regex with a leading literal); otherwise
    /// the whole pool (`O(L)`, bounded per document). The basis for glob and regex
    /// matching: this document's own lexemes are the vocabulary, no vocab table.
    pub fn positions_matching(&self, prefix: &[u8], pred: impl Fn(&[u8]) -> bool) -> Vec<i32> {
        let mut out = Vec::new();
        let n = self.size();
        if n == 0 {
            return out;
        }
        unsafe {
            let (entries, strptr) = self.parts();
            let mut i = if prefix.is_empty() {
                0
            } else {
                let (mut lo, mut hi) = (0usize, n);
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    if self.lexeme(entries, strptr, mid) < prefix {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                lo
            };
            while i < n {
                let lex = self.lexeme(entries, strptr, i);
                if !prefix.is_empty() && !lex.starts_with(prefix) {
                    break; // past the prefix range
                }
                if pred(lex) {
                    self.push_entry_positions(strptr, &*entries.add(i), &mut out);
                }
                i += 1;
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }
}

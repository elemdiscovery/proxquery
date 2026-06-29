//! Pure positional proximity predicates over sorted, 1-based position arrays.
//!
//! Every function takes already-sorted `&[i32]` position lists (as produced by
//! [`crate::tsvector::TsVector::positions`]) and runs as a bounded two-pointer or
//! binary search — no allocation, no full-vector scan, short-circuiting. Distances
//! are absolute lexeme gaps: adjacent tokens differ by 1, so within-`N` means `|Δ| ≤ N`.

/// The largest position a `tsvector` can store. Positions live in a 14-bit field,
/// so Postgres clamps anything past token 16383 onto it (`LIMITPOS`), and so does
/// our accessor (`WEP_POS_MASK`). A position list whose maximum entry is `MAX_POS`
/// therefore has a *collapsed tail* — distinct tail tokens are indistinguishable,
/// which makes negative proximity untrustworthy; see [`not_within`].
pub const MAX_POS: i32 = 0x3fff;

/// `within` — some `a` within `n` of some `b`, either order: `∃ i,j. |aᵢ − bⱼ| ≤ n`.
///
/// Two-pointer merge of the two sorted runs; `O(|a| + |b|)`.
pub fn within(a: &[i32], b: &[i32], n: i32) -> bool {
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if (a[i] - b[j]).abs() <= n {
            return true;
        }
        if a[i] < b[j] {
            i += 1;
        } else {
            j += 1;
        }
    }
    false
}

/// `pre` — some `a` strictly before some `b` within `n`: `∃ i,j. 0 < bⱼ − aᵢ ≤ n`.
///
/// For each `a` we only need the nearest `b` that follows it; `j` advances
/// monotonically because `a` is sorted ascending. `O(|a| + |b|)`.
pub fn pre(a: &[i32], b: &[i32], n: i32) -> bool {
    let mut j = 0;
    for &ai in a {
        while j < b.len() && b[j] <= ai {
            j += 1;
        }
        if j < b.len() && b[j] - ai <= n {
            return true;
        }
    }
    false
}

/// `not_within` — occurrence-level: some `a` has *no* `b` within `n` (true also when
/// `b` is absent entirely). This is the predicate `a & !within` cannot express,
/// because it reasons per-occurrence rather than per-document. `ordered` restricts
/// the forbidden `b` to those *after* `a` (the `<!-N>` variant); otherwise either
/// side counts (`<!~N>`).
///
/// For each `a`, binary-search `b` for the nearest qualifying neighbour;
/// `O(|a| · log|b|)`, short-circuiting on the first isolated `a`.
///
/// Saturation guard: when the avoid term `b` reaches the position cap (its tail
/// collapsed onto [`MAX_POS`]), "near `b`" can no longer be told from "far from
/// `b`", so this fails *open* — it reports the match for review rather than
/// silently asserting an isolation it can't verify.
pub fn not_within(a: &[i32], b: &[i32], n: i32, ordered: bool) -> bool {
    if a.is_empty() {
        return false;
    }
    if b.is_empty() {
        return true;
    }
    // `b` is sorted ascending, so its last element is its maximum.
    if b[b.len() - 1] == MAX_POS {
        return true;
    }
    for &ai in a {
        let isolated = if ordered {
            // No `b` in `(ai, ai + n]`.
            let idx = b.partition_point(|&x| x <= ai); // first b strictly after ai
            !(idx < b.len() && b[idx] - ai <= n)
        } else {
            let idx = b.partition_point(|&x| x < ai);
            let mut nearest = i32::MAX;
            if idx < b.len() {
                nearest = nearest.min(b[idx] - ai); // b[idx] ≥ ai ⇒ ≥ 0
            }
            if idx > 0 {
                nearest = nearest.min(ai - b[idx - 1]); // ≥ 0
            }
            nearest > n
        };
        if isolated {
            return true;
        }
    }
    false
}

/// `chain` — same-occurrence chain: positions `p₀ … p_k` exist, each consecutive
/// pair drawn from `terms[i]`, `terms[i+1]` with `|pᵢ − pᵢ₊₁| ≤ gaps[i]`
/// (either order). `gaps.len()` must be `terms.len() − 1`.
///
/// This is the predicate that the AND-of-pairwise translation (`within(a,b) &
/// within(b,c)`) cannot express, because it pins the *same* middle occurrence:
/// `reach` carries forward only the positions of `terms[i]` actually reachable
/// from the previous term, so `terms[i+1]` must be near one of *those*.
pub fn chain(terms: &[Vec<i32>], gaps: &[i32]) -> bool {
    if terms.is_empty() || terms.iter().any(|t| t.is_empty()) {
        return false;
    }
    if terms.len() == 1 {
        return true;
    }
    // Positions of the current term reachable through the chain so far. Stays
    // sorted: `cur` is sorted and we push qualifying entries in order.
    let mut reach: Vec<i32> = terms[0].clone();
    for i in 1..terms.len() {
        let g = gaps[i - 1];
        let cur = &terms[i];
        let mut next: Vec<i32> = Vec::with_capacity(cur.len());
        for &c in cur {
            let idx = reach.partition_point(|&x| x < c);
            let near = (idx < reach.len() && reach[idx] - c <= g)
                || (idx > 0 && c - reach[idx - 1] <= g);
            if near {
                next.push(c);
            }
        }
        if next.is_empty() {
            return false;
        }
        reach = next;
    }
    true
}

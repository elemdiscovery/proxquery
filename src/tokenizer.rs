//! Custom Unicode tokenizer — builds a `tsvector` directly (extension-only).
//!
//! See docs/TOKENIZER_SPEC.md. This is the additive, EXTENSION-ONLY path: the
//! default-parser path (`to_tsvector(cfg,…)`) is unchanged and stays mirrored in
//! the pure-SQL port. The matching engine reads whatever tsvector it is given, so
//! nothing downstream changes.
//!
//! Phase 2a implements the core pipeline — NFC-normalize → UAX#29 segment →
//! case-fold → accent-fold (superimpose both) → emit with positions. The
//! structured tailorings (hyphen / email / URL / apostrophe), emoji preservation,
//! and the ICU segmenter backend land in later phases (see the golden corpus in
//! tests/tokenizer_cases.md).
//!
//! The Rust function returns the canonical tsvector *text*; a thin SQL wrapper
//! casts it to `tsvector` (pgrx 0.19 has no tsvector return ABI, and a generated
//! column / `@@` index works identically off the cast).

use caseless::default_case_fold_str;
use icu_segmenter::WordSegmenter;
use pgrx::datum::IntoDatum;
use pgrx::direct_function_call;
use pgrx::pg_sys::Oid;
use pgrx::prelude::*;
use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::HashMap;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::{is_nfkc_quick, IsNormalized, UnicodeNormalization};
use unicode_properties::UnicodeEmoji;
use unicode_segmentation::UnicodeSegmentation;

/// Which UAX#29 segmenter backs an analyzer.
#[derive(Clone, Copy)]
enum Segmenter {
    /// `unicode-segmentation` crate — pure UAX#29 (per-character CJK).
    Unicode,
    /// ICU4X dictionary segmentation (CJK/Thai word boundaries).
    Icu,
}

/// A resolved analyzer config — the toggles a named preset selects, plus an optional
/// text-search dictionary applied per lexeme (stemming / stopwords / synonyms).
struct Analyzer {
    segmenter: Segmenter,
    fold_case: bool,
    fold_accents: bool,
    keep_emoji: bool,
    stem_dict: Option<Oid>,
}

/// The base preset (engine + fold/emoji toggles), before any `:dict` suffix.
#[derive(Clone, Copy)]
enum Base {
    Icu,
    Unicode,
    IcuAccent,
    IcuNoEmoji,
}

/// A Copy handle naming an analyzer — referenced identically on the index and query
/// sides (via `proxquery_to_tsvector` and the query-side resolver in `dsl::Resolver`)
/// so the two can't drift. The name is `<base>[:<dict>]`: a fixed base preset plus an
/// optional text-search dictionary. Fixed presets + an OID keep the builder IMMUTABLE
/// (usable in a generated column / index expression).
#[derive(Clone, Copy)]
pub struct AnalyzerKind {
    base: Base,
    /// `regdictionary` OID from a `:dict` suffix; None for a bare preset (no cost).
    stem_dict: Option<Oid>,
}

impl AnalyzerKind {
    /// Parse `<base>[:<dict>]`. Bare presets:
    ///   prox_icu (default), prox_unicode, prox_icu_accent (accent-sensitive),
    ///   prox_icu_no_emoji. A `:dict` suffix (e.g. `prox_icu:english_stem`) routes each
    ///   lexeme through that dictionary via `ts_lexize` (stem/stopword/synonym).
    pub fn from_name(name: &str) -> Option<Self> {
        let (base_name, dict_name) = match name.split_once(':') {
            Some((b, d)) => (b.trim(), Some(d.trim())),
            None => (name, None),
        };
        let base = match base_name {
            "prox_icu" => Base::Icu,
            "prox_unicode" => Base::Unicode,
            "prox_icu_accent" => Base::IcuAccent,
            "prox_icu_no_emoji" => Base::IcuNoEmoji,
            _ => return None,
        };
        let stem_dict = match dict_name {
            None => None,
            Some(d) => Some(resolve_dict_oid(d)?), // unknown dict → whole name unresolved
        };
        Some(AnalyzerKind { base, stem_dict })
    }

    fn config(self) -> Analyzer {
        let (segmenter, fold_case, fold_accents, keep_emoji) = match self.base {
            Base::Icu => (Segmenter::Icu, true, true, true),
            Base::Unicode => (Segmenter::Unicode, true, true, true),
            Base::IcuAccent => (Segmenter::Icu, true, false, true),
            Base::IcuNoEmoji => (Segmenter::Icu, true, true, false),
        };
        Analyzer { segmenter, fold_case, fold_accents, keep_emoji, stem_dict: self.stem_dict }
    }

    /// Hashable identity for the query-side resolve cache (base preset + dict OID).
    pub fn cache_key(self) -> (u8, Option<Oid>) {
        (self.base as u8, self.stem_dict)
    }

    /// Distinct, sorted lexemes a BARE query atom resolves to. Same segmentation as the
    /// index, with the canonicalizing transforms (case-fold, accent-fold, stem) but no
    /// superimposed variants or part decomposition — so it folds to the index's
    /// canonical form: the unaccented and accented spellings both match (accent- and
    /// stem-insensitive by default). Segmentation is preserved, so a token the index
    /// splits without compounding (e.g. `a/b`) splits here too.
    pub fn lexemes(self, term: &str) -> Vec<Vec<u8>> {
        let mut v: Vec<Vec<u8>> = tokenize(term, &self.config(), true)
            .into_iter()
            .map(|(lex, _)| lex.into_bytes())
            .collect();
        v.sort_unstable();
        v.dedup();
        v
    }

    /// Lexemes a LITERAL `'…'` query term resolves to: case-folded only (NFC + curly
    /// apostrophe normalized), with NO accent-fold, stemming, or decomposition — so it
    /// matches the index's exact preserved form (`'café'` finds only `café`). The
    /// precision escape hatch over the accent/stem-insensitive bare default.
    pub fn lexemes_exact(self, term: &str) -> Vec<Vec<u8>> {
        let a = self.config();
        let normalized: String = term
            .nfc()
            .filter(|&c| !is_ignorable_control(c))
            .collect::<String>()
            .replace(&APOSTROPHES[..], "'");
        let cased = if a.fold_case {
            default_case_fold_str(&normalized)
        } else {
            normalized
        };
        vec![cased.into_bytes()]
    }
}

/// Resolve a text-search dictionary name to its OID, cached per backend. Returns None
/// if no such dictionary exists. (Immutable-by-convention, like `regconfig`: drop and
/// recreate the dictionary and you must reindex.)
fn resolve_dict_oid(name: &str) -> Option<Oid> {
    thread_local! {
        static CACHE: RefCell<HashMap<String, Option<Oid>>> = RefCell::new(HashMap::new());
    }
    if let Some(hit) = CACHE.with(|c| c.borrow().get(name).copied()) {
        return hit;
    }
    let result = std::ffi::CString::new(name).ok().and_then(|cname| unsafe {
        let names = pgrx::pg_sys::stringToQualifiedNameList(cname.as_ptr(), core::ptr::null_mut());
        let oid = pgrx::pg_sys::get_ts_dict_oid(names, true); // missing_ok
        (oid != pgrx::pg_sys::InvalidOid).then_some(oid)
    });
    CACHE.with(|c| c.borrow_mut().insert(name.to_owned(), result));
    result
}

/// Run a token through a text-search dictionary via `ts_lexize`. `None` = the dict did
/// not recognize it (keep as-is); `Some([])` = stop word (drop); `Some(lexemes)` =
/// stem/synonym output.
fn ts_lexize(dict: Oid, token: &str) -> Option<Vec<String>> {
    unsafe {
        direct_function_call::<Vec<String>>(
            pgrx::pg_sys::ts_lexize,
            &[dict.into_datum(), token.into_datum()],
        )
    }
}

/// Atomic letters NFD can't decompose, plus a few ligatures, folded to ASCII.
/// Inputs are already case-folded, so only lowercase forms are needed.
fn atomic_fold(c: char) -> Option<&'static str> {
    Some(match c {
        'ø' => "o",
        'æ' => "ae",
        'œ' => "oe",
        'ð' => "d",
        'þ' => "th",
        'ł' => "l",
        'đ' => "d",
        'ħ' => "h",
        'ı' => "i",
        'ŧ' => "t",
        'ﬁ' => "fi",
        'ﬂ' => "fl",
        'ﬀ' => "ff",
        _ => return None,
    })
}

/// Compatibility-fold (NFKC) a lexeme so fullwidth / half-width / Roman-numeral / etc.
/// spellings collapse to their canonical equivalent (`ＡＢＣ`→`abc`, `Ⅻ`→`xii`). Quick-check
/// gated: a lexeme already in NFKC — all ASCII, ordinary letters, CJK — does no
/// decomposition work, so the cost falls only on tokens that actually carry a
/// compatibility character. Does NOT fold non-ASCII digits or confusables (not
/// compatibility-equivalent under Unicode).
fn compat_fold(s: &str) -> Cow<'_, str> {
    match is_nfkc_quick(s.chars()) {
        IsNormalized::Yes => Cow::Borrowed(s), // common case: no allocation
        _ => Cow::Owned(s.nfkc().collect()),
    }
}

/// Strip diacritics: NFD-decompose, drop combining marks, fold remaining atomics.
/// Latin-scoped by construction — combining marks essential to Arabic/Indic are
/// the only thing dropped, and only base letters that have an ASCII fold change.
fn accent_fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.nfd() {
        if is_combining_mark(c) {
            continue;
        }
        match atomic_fold(c) {
            Some(rep) => out.push_str(rep),
            None => out.push(c),
        }
    }
    out
}

/// Invisible formatting / bidi controls that carry no textual meaning — stripped
/// during normalization so they neither split a word nor hide it from a clean-spelling
/// query (a soft-hyphenated `con­fidential`, a bidi-wrapped word, a zero-width-split
/// word). Deliberately EXCLUDES the semantic joiners ZWJ (U+200D) / ZWNJ (U+200C),
/// which bind emoji clusters and drive Indic/Arabic shaping, and the emoji variation
/// selectors (U+FE00–FE0F), so emoji and shaped scripts are untouched.
fn is_ignorable_control(c: char) -> bool {
    matches!(c,
        '\u{00AD}'                  // soft hyphen
        | '\u{200B}'                // zero width space
        | '\u{200E}' | '\u{200F}'   // LRM, RLM
        | '\u{202A}'..='\u{202E}'   // LRE, RLE, PDF, LRO, RLO
        | '\u{2060}'                // word joiner
        | '\u{2066}'..='\u{2069}'   // LRI, RLI, FSI, PDI
        | '\u{FEFF}'                // ZWNBSP / BOM
    )
}

/// Apostrophe-like code points folded to a straight `'` before tokenization, so a curly or
/// modifier-letter apostrophe shares the straight form's tailoring (`it's`→`it`,`its`):
/// right/left single quote and the modifier-letter apostrophe.
const APOSTROPHES: [char; 3] = ['\u{2019}', '\u{2018}', '\u{02BC}'];

/// Postgres caps a tsvector lexeme at 2046 bytes (`tsvectorin` raises beyond it). Over-long
/// tokens are dropped rather than allowed to abort the whole document.
const MAX_LEXEME_BYTES: usize = 2046;

/// A segment is emitted iff it carries at least one alphanumeric char (words,
/// numbers, alnum IDs, CJK ideographs). Pure punctuation/whitespace is dropped
/// and consumes no position. (Emoji preservation is a later phase.)
fn is_word_like(seg: &str) -> bool {
    seg.chars().any(char::is_alphanumeric)
}

/// A real emoji cluster (kept as its own lexeme): a UAX#29 word-bound segment carrying a
/// char that DEFAULTS to emoji presentation (`Emoji_Presentation=Yes` — 🎂, 👍, flag
/// regional indicators, skin-tone bases; ZWJ sequences come grouped) or an explicit emoji
/// variation selector (VS16, U+FE0F). EXCLUDES text-default symbols that merely have
/// `Emoji=Yes` (™ © ® ▪ ◼): those fall through to punctuation, so they drop and take NO
/// position — a `Foo™ Bar` phrase stays adjacent.
fn is_emoji(seg: &str) -> bool {
    use unicode_properties::EmojiStatus::*;
    seg.chars().any(|c| {
        c == '\u{FE0F}'
            || matches!(
                c.emoji_status(),
                EmojiPresentation
                    | EmojiPresentationAndModifierBase
                    | EmojiPresentationAndEmojiComponent
                    | EmojiPresentationAndModifierAndEmojiComponent
            )
    })
}

/// Emit one normalized lexeme at `pos`, routed through the analyzer's dictionary when
/// one is set: keep as-is if unrecognized, drop if a stop word, else emit the
/// stem/synonym output (all superimposed at `pos`). With no dict (the default) this is
/// a single `Option` check — zero added cost.
fn emit_lexeme(out: &mut Vec<(String, i32)>, lex: &str, pos: i32, a: &Analyzer) {
    // An over-long lexeme would make the `::tsvector` cast raise and abort the whole
    // document; drop it instead (stock `to_tsvector` likewise ignores over-long words).
    if lex.len() > MAX_LEXEME_BYTES {
        return;
    }
    match a.stem_dict {
        None => out.push((lex.to_string(), pos)),
        Some(dict) => match ts_lexize(dict, lex) {
            None => out.push((lex.to_string(), pos)),
            Some(stems) => {
                for s in stems {
                    out.push((s, pos));
                }
            }
        },
    }
}

/// Emit one sub-lexeme at `pos`. The INDEX side superimposes the case-folded form AND
/// its accent-folded variant; the BARE query side emits just the canonical (accent-
/// folded) form, so an unaccented OR accented query matches the index's folded form
/// (accent-insensitive by default). Literal `'…'` query terms bypass this entirely
/// (see `AnalyzerKind::lexemes_exact`). Case-fold and the `emit_lexeme` dictionary
/// apply on both sides — they canonicalize, not expand.
fn emit_sub(out: &mut Vec<(String, i32)>, raw: &str, pos: i32, a: &Analyzer, query: bool) {
    let cased = if a.fold_case {
        default_case_fold_str(raw)
    } else {
        raw.to_string()
    };
    // The canonical form both sides reduce to: accent-fold (when folding) THEN
    // compatibility-fold (NFKC). The query emits ONLY this canonical; the index
    // superimposes it alongside the less-folded forms, so an ASCII spelling and its
    // fullwidth/Roman-numeral/ligature equivalent collapse to one matchable lexeme.
    let accented = if a.fold_accents { accent_fold(&cased) } else { cased.clone() };
    let canonical = compat_fold(&accented);
    if query {
        emit_lexeme(out, &canonical, pos, a);
    } else {
        emit_lexeme(out, &cased, pos, a);
        if accented != cased {
            emit_lexeme(out, &accented, pos, a);
        }
        if canonical.as_ref() != accented && canonical.as_ref() != cased {
            emit_lexeme(out, &canonical, pos, a);
        }
    }
}

/// A host-shaped segment (dotted, e.g. `b.com`) — the RHS of an email.
fn is_host_like(seg: &str) -> bool {
    seg.contains('.') && is_word_like(seg)
}

/// A bare (scheme-less) hostname token like `google.com` / `www.example.com`: dotted, ≥2
/// labels of hostname chars (alnum or `-`), last label a 2–24 letter TLD. Decomposed like
/// an email host (labels except the TLD superimposed) so `google` finds `google.com`.
/// Excludes non-host dotted tokens — `a.b.c` (1-char last label), `version2.0` (digit last
/// label), `it's.going` (apostrophe), `3.14` (digit last label).
fn is_bare_host(seg: &str) -> bool {
    if !seg.contains('.') {
        return false; // fast path: the vast majority of word tokens, no allocation
    }
    let (mut count, mut last) = (0usize, "");
    for label in seg.split('.') {
        if label.is_empty() || !label.chars().all(|c| c.is_alphanumeric() || c == '-') {
            return false;
        }
        count += 1;
        last = label;
    }
    let n = last.chars().count();
    count >= 2 && (2..=24).contains(&n) && last.chars().all(char::is_alphabetic)
}

/// A host's labels except the final TLD: `b.com` → [`b`]; `mail.example.com` →
/// [`mail`, `example`]. Empty for a bare single label.
fn host_labels_except_tld(host: &str) -> Vec<&str> {
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() <= 1 {
        Vec::new()
    } else {
        labels[..labels.len() - 1].to_vec()
    }
}

/// Break a text region into boundary-delimited pieces (words AND the separators
/// between them — `-`, `@`, spaces — which the email/hyphen tailorings rely on).
/// Both backends follow UAX#29 for Latin/punctuation; ICU additionally groups
/// CJK/Thai runs into dictionary words instead of one piece per character.
fn segment(region: &str, seg: Segmenter) -> Vec<&str> {
    match seg {
        Segmenter::Unicode => region.split_word_bounds().collect(),
        Segmenter::Icu => {
            // `new_auto` returns a borrowed view over static compiled data (cheap);
            // it isn't Sync, so we don't cache it in a static.
            let segmenter = WordSegmenter::new_auto(Default::default());
            let mut out = Vec::new();
            let mut prev = 0usize;
            for bp in segmenter.segment_str(region) {
                if bp > prev {
                    out.push(&region[prev..bp]);
                    prev = bp;
                }
            }
            out
        }
    }
}

/// Tokenize a region of text known to contain no URLs, appending lexemes to
/// `out` and advancing `pos`. URLs are pulled out by `tokenize` first, because
/// UAX#29 shatters them into many segments.
fn tokenize_region(region: &str, a: &Analyzer, out: &mut Vec<(String, i32)>, pos: &mut i32, query: bool) {
    let segs: Vec<&str> = segment(region, a.segmenter);
    let mut i = 0;
    while i < segs.len() {
        let seg = segs[i];
        if !is_word_like(seg) {
            // Emoji are preserved verbatim as their own lexeme (no case/accent fold)
            // when the analyzer keeps them; other punctuation/symbols are dropped and
            // consume no position.
            if a.keep_emoji && is_emoji(seg) {
                *pos += 1;
                out.push((seg.to_string(), *pos));
            }
            i += 1;
            continue;
        }
        // Email: word `@` host. The index superimposes full + local + host + host
        // labels at one position; the query keeps just the full address (specific).
        if i + 2 < segs.len() && segs[i + 1] == "@" && is_host_like(segs[i + 2]) {
            let (local, host) = (seg, segs[i + 2]);
            *pos += 1;
            emit_sub(out, &format!("{local}@{host}"), *pos, a, query);
            if !query {
                emit_sub(out, local, *pos, a, query);
                emit_sub(out, host, *pos, a, query);
                for label in host_labels_except_tld(host) {
                    emit_sub(out, label, *pos, a, query);
                }
            }
            i += 3;
            continue;
        }
        // Hyphen or ampersand run: word (SEP word)+ with SEP ∈ {`-`, `&`}. UAX#29 breaks on
        // these connectors, so we re-join the run and superimpose compound + parts + the
        // connector-removed concatenation. The query keeps just the compound. NB `-` is a
        // DSL word char so `a-b-c` stays one query term, but `&` is the AND operator — a
        // bare `R&D` *query* lexes as `R & D`, so the unit is reached via the literal
        // `'R&D'` (→ the `r&d` compound) or the concatenation `RD`.
        if i + 2 < segs.len() && matches!(segs[i + 1], "-" | "&") && is_word_like(segs[i + 2]) {
            i = emit_joined_run(out, &segs, i, segs[i + 1], a, query, pos);
            continue;
        }
        // Plain word. On the index side a scheme-less host superimposes its labels except
        // the TLD (`google.com`→`google`), and an apostrophe-bearing word emits the part
        // before the apostrophe and the apostrophe-stripped form (`Paul's`→`paul`,`pauls`);
        // the query keeps just the word.
        *pos += 1;
        emit_sub(out, seg, *pos, a, query);
        if !query {
            if is_bare_host(seg) {
                for label in host_labels_except_tld(seg) {
                    emit_sub(out, label, *pos, a, query);
                }
            } else if seg.contains('\'') {
                if let Some(idx) = seg.find('\'') {
                    if idx > 0 {
                        emit_sub(out, &seg[..idx], *pos, a, query);
                    }
                }
                emit_sub(out, &seg.replace('\'', ""), *pos, a, query);
            }
        }
        i += 1;
    }
}

/// Emit a connector-joined run `word (SEP word)+` — the hyphen and `&` tailorings. The
/// index side superimposes the compound, each part, and the connector-removed
/// concatenation at one position (`co-operate`→`cooperate`+parts; `R&D`→`r&d`,`r`,`d`,`rd`);
/// the query side keeps only the compound. `sep` is the one-char connector segment
/// (`"-"` / `"&"`). Returns the segment index just past the run.
fn emit_joined_run(
    out: &mut Vec<(String, i32)>,
    segs: &[&str],
    i: usize,
    sep: &str,
    a: &Analyzer,
    query: bool,
    pos: &mut i32,
) -> usize {
    let sep_char = sep.chars().next().unwrap();
    let mut whole = String::from(segs[i]);
    let mut parts = vec![segs[i]];
    let mut j = i + 1;
    while j + 1 < segs.len() && segs[j] == sep && is_word_like(segs[j + 1]) {
        whole.push(sep_char);
        whole.push_str(segs[j + 1]);
        parts.push(segs[j + 1]);
        j += 2;
    }
    *pos += 1;
    emit_sub(out, &whole, *pos, a, query);
    if !query {
        for part in &parts {
            emit_sub(out, part, *pos, a, query);
        }
        emit_sub(out, &whole.replace(sep_char, ""), *pos, a, query);
    }
    j
}

/// First byte index of an `http://`/`https://` URL not glued to a preceding word.
fn find_url_start(s: &str) -> Option<usize> {
    let mut from = 0;
    while let Some(rel) = s[from..].find("http") {
        let idx = from + rel;
        let tail = &s[idx..];
        let at_boundary =
            idx == 0 || !s[..idx].chars().next_back().is_some_and(char::is_alphanumeric);
        if at_boundary && (tail.starts_with("http://") || tail.starts_with("https://")) {
            return Some(idx);
        }
        from = idx + 4;
    }
    None
}

/// Host of a `scheme://host[/...]` URL — text after `://` up to the first
/// `/`, `?`, or `#`.
fn url_host(url: &str) -> Option<&str> {
    let after = url.split("://").nth(1)?;
    let end = after.find(['/', '?', '#']).unwrap_or(after.len());
    let host = &after[..end];
    (!host.is_empty()).then_some(host)
}

/// Emit a URL at one position. The index superimposes full URL + host + host labels;
/// the query keeps just the full URL (specific).
fn emit_url(url: &str, a: &Analyzer, out: &mut Vec<(String, i32)>, pos: &mut i32, query: bool) {
    *pos += 1;
    emit_sub(out, url, *pos, a, query);
    if !query {
        if let Some(host) = url_host(url) {
            emit_sub(out, host, *pos, a, query);
            for label in host_labels_except_tld(host) {
                emit_sub(out, label, *pos, a, query);
            }
        }
    }
}

/// Core: text → `(lexeme, position)` pairs. Pure Rust, unit-testable without PG.
/// URLs are extracted first (UAX#29 shatters them); intervening text runs through
/// `tokenize_region`. Each logical token occupies one position. `query` selects the
/// INDEX side (superimpose compound/parts/accent variants) vs the QUERY side (segment
/// + canonicalize the same way, but emit only each token's exact form).
fn tokenize(input: &str, a: &Analyzer, query: bool) -> Vec<(String, i32)> {
    // NFC so composed/decomposed accents agree; drop invisible formatting/bidi controls
    // (so they don't split or hide a word); fold apostrophe variants to straight.
    let normalized: String = input
        .nfc()
        .filter(|&c| !is_ignorable_control(c))
        .collect::<String>()
        .replace(&APOSTROPHES[..], "'");
    let mut out: Vec<(String, i32)> = Vec::new();
    let mut pos: i32 = 0;
    let mut rest = normalized.as_str();
    while let Some(start) = find_url_start(rest) {
        tokenize_region(&rest[..start], a, &mut out, &mut pos, query);
        let url_end = rest[start..]
            .find(char::is_whitespace)
            .map_or(rest.len(), |w| start + w);
        emit_url(&rest[start..url_end], a, &mut out, &mut pos, query);
        rest = &rest[url_end..];
    }
    tokenize_region(rest, a, &mut out, &mut pos, query);
    out
}

/// Quote a lexeme for tsvector text input: wrap in single quotes, escaping
/// backslash and single-quote.
fn quote_lexeme(lex: &str) -> String {
    let escaped = lex.replace('\\', "\\\\").replace('\'', "''");
    format!("'{escaped}'")
}

/// Canonical `tsvector` text for the `(lexeme, pos)` pairs. The SQL-side
/// `::tsvector` cast (tsvectorin) sorts lexemes and merges/dedups positions, so
/// the order here is irrelevant.
fn build_text(pairs: &[(String, i32)]) -> String {
    pairs
        .iter()
        .map(|(lex, pos)| format!("{}:{}", quote_lexeme(lex), pos))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Build the canonical `tsvector` text for `input` under the named `analyzer`.
/// The SQL wrapper `proxquery_to_tsvector(text, text)` casts it to `tsvector`.
#[pg_extern(immutable, parallel_safe, strict)]
fn proxquery_build_tsvector(input: &str, analyzer: &str) -> String {
    match AnalyzerKind::from_name(analyzer) {
        Some(k) => build_text(&tokenize(input, &k.config(), false)),
        None => error!("proxquery: unknown analyzer '{analyzer}'"),
    }
}

extension_sql!(
    r#"
CREATE FUNCTION proxquery_to_tsvector(text, text) RETURNS tsvector
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$ SELECT proxquery_build_tsvector($1, $2)::tsvector $$;
"#,
    name = "proxquery_to_tsvector_wrapper",
    requires = [proxquery_build_tsvector],
);

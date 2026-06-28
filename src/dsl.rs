//! The proxquery query DSL — a Postgres-natural superset of `tsquery`.
//!
//! We do **not** implement a separate proximity-operator surface syntax; we
//! expose the equivalent capabilities through operators a Postgres FTS user
//! already recognizes, so a translator from another surface is straightforward
//! to write on top (we don't ship one). One grammar, two lowerings (the
//! README's Layer 1): parse → a
//! lexeme-presence [`skeleton`] `tsquery` that drives the GIN index, and an
//! [`eval_match`] positional recheck.
//!
//! ## Operators
//!
//! Native `tsquery`, unchanged: `&` `|` `!` `( )`, `"a b c"` / `a <-> b`
//! (adjacency), `a <N> b` (ordered, **exactly** N apart), `appl:*` / `appl*`.
//!
//! Added — one bracket, modifiers compose: `~` = either-order, `-` = ordered
//! (a before b), `!` = negated (occurrence-level):
//!
//! | | either order | ordered (a→b) |
//! |---|---|---|
//! | within | `a <~N> b` | `a <-N> b` |
//! | not within | `a <!~N> b` | `a <!-N> b` |
//!
//! Precedence (tsquery's own): `|` < `&` < proximity < `!`. Proximity operators
//! are **left-associative composition** — each pair yields the *span* it covers
//! (the union of `[min..max]` over satisfying pairs), and the next operand is
//! tested against that span, so multi-term proximity (`a <~5> b <~5> c`) stays
//! occurrence-linked and a term falling *between* a matched pair can attach.
//!
//! ## Compound-proximity operand rules (normalization)
//!
//! A proximity operand may only be *positional* (term / prefix / phrase / an OR
//! of those / a nested proximity). `&` and `!` are **lifted out**, because
//! `(a & b)` at one position is ~always false and `!` is not a phrase operand:
//!
//! - `(a & b) <~N> c` → `(a <~N> c) & (b <~N> c)`  (distribute, lift AND)
//! - `(!a)    <~N> b` → `!(a <~N> b)`              (lift NOT above)
//! - `(a | b) <~N> c` → kept: OR distributes into the position-set union
//! - `"a b"   <~N> c` → kept: the phrase's positions are its end positions

/// A phrase/distance element. A phrase matches per-atom on position sets, so an
/// atom may be a wildcard (`"*ology class"`): the glob contributes the positions
/// of every lexeme it matches, and adjacency is checked against that set.
#[derive(Debug, Clone, PartialEq)]
pub enum Atom {
    Term(String),
    /// A literal `'…'` term — resolved exactly (no accent-fold/stem), see [`Node::Exact`].
    Exact(String),
    Prefix(String),
    Glob { glob: String, prefix: String },
}

/// The query AST. After [`normalize`], `&`/`|`/`!` appear only at/above the
/// boolean layer (with `Or` also allowed as a positional operand), and every
/// proximity operand is positional.
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Term(String),
    /// A literal `'…'` term. Resolved EXACTLY — case-folded only, no accent-fold,
    /// stemming, or decomposition — so it matches the index's preserved form. The
    /// precision opt-out from the accent/stem-insensitive bare term.
    Exact(String),
    Prefix(String),
    /// A `*`/`?` glob (`*ology`, `f*r`, `te?t`). `glob` is the lowercased pattern;
    /// `prefix` is its leading literal run (empty if it starts with a wildcard).
    /// Scanned per-document; a non-empty `prefix` is its index key and fast path.
    Glob { glob: String, prefix: String },
    /// `##…##` — a regex matched against whole lexemes via Postgres's own engine.
    /// Recheck-only (no index key), so it needs a companion term.
    Regex(String),
    /// Ordered, **exact**-gap sequence: native `"a b"`, `a <-> b`, `a <N> b`.
    /// `gaps[i]` is the exact distance from `atoms[i]` to `atoms[i+1]`.
    Phrase { atoms: Vec<Atom>, gaps: Vec<i32> },
    And(Vec<Node>),
    Or(Vec<Node>),
    Not(Box<Node>),
    /// `<~N>` (either order) or, when `ordered`, `<-N>` (a before b). Both ≤N.
    Within { a: Box<Node>, b: Box<Node>, n: i32, ordered: bool },
    /// `<!~N>` (either order) or, when `ordered`, `<!-N>` (no b after a within N).
    /// Occurrence-level: some `a` with no qualifying `b`.
    NotWithin { a: Box<Node>, b: Box<Node>, n: i32, ordered: bool },
}

const MAX_DISTANCE: i32 = 16383;

fn parse_distance(digits: &str) -> Result<i32, String> {
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("expected a distance, got `{digits}`"));
    }
    // Clamp to [0, MAX]. `0` is kept (not raised to 1): native tsquery `<0>` means
    // "same position", and the proximity ops follow suit (`within(·,0)` = same
    // position; `pre(·,0)` is unsatisfiable). Overflow saturates to MAX.
    Ok(digits.parse::<i32>().unwrap_or(MAX_DISTANCE).clamp(0, MAX_DISTANCE))
}

// ===========================================================================
// Lexer
// ===========================================================================

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    LParen,
    RParen,
    And,                   // &
    Or,                    // |
    Not,                   // !
    PhraseOp(i32),         // <-> => 1, <N> => N   (ordered, exact)
    PreOp(i32),            // <-N>                 (ordered, within)
    WithinOp(i32),         // <~N>                 (either order, within)
    NotWithinOp(i32, bool), // <!~N> (false) / <!-N> (true)
    Term(String),
    Exact(String),         // 'single quoted' literal term
    Prefix(String),
    Glob(String, String),  // glob pattern, leading literal prefix
    Regex(String),         // ##...##
    Phrase(Vec<Atom>),     // "double quoted"
}

fn is_glob_char(c: char) -> bool {
    c == '*' || c == '?'
}

/// Leading literal run of a glob — the characters before the first `*` or `?`.
fn glob_prefix(glob: &str) -> String {
    glob.chars().take_while(|&c| !is_glob_char(c)).collect()
}

/// Classify a standalone word, resolving `*`/`?` wildcards. `appl*` / `appl:*`
/// stay a fast prefix; anything else with a wildcard becomes a glob.
fn word_to_tok(word: &str) -> Result<Tok, String> {
    let lower = word.to_ascii_lowercase();
    if let Some(stem) = lower.strip_suffix(":*") {
        if !stem.is_empty() && !stem.contains(is_glob_char) {
            return Ok(Tok::Prefix(stem.to_string()));
        }
    }
    if !lower.contains(is_glob_char) {
        return Ok(Tok::Term(lower));
    }
    if lower == "*" {
        return Err("a bare `*` matches everything; give it a literal part".into());
    }
    // `appl*` — a single trailing `*` and nothing else special — is the fast path.
    // `strip_suffix` is char-safe; a byte-index slice (`lower[..len-1]`) would panic on
    // a glob ending in a multibyte char (e.g. `café*` once folded, or `*é`).
    if let Some(body) = lower.strip_suffix('*') {
        if !body.contains(is_glob_char) {
            return Ok(Tok::Prefix(body.to_string()));
        }
    }
    let prefix = glob_prefix(&lower);
    Ok(Tok::Glob(lower, prefix))
}

/// Classify a phrase word, reusing the standalone-word rules so a phrase atom can
/// be a term, a prefix (`appl*`), or a glob (`*ology`, `te?t`). A `##regex##` can't
/// appear here — phrases split on whitespace and a regex may contain spaces.
fn word_atom(word: &str) -> Result<Atom, String> {
    Ok(match word_to_tok(word)? {
        Tok::Term(t) => Atom::Term(t),
        Tok::Prefix(p) => Atom::Prefix(p),
        Tok::Glob(glob, prefix) => Atom::Glob { glob, prefix },
        _ => unreachable!("word_to_tok yields only Term/Prefix/Glob"),
    })
}

fn is_word_char(c: char) -> bool {
    !c.is_whitespace() && !matches!(c, '(' | ')' | '&' | '|' | '!' | '<' | '>' | ',' | '"' | '\'' | '#')
}

fn bracket_op(content: &str) -> Result<Tok, String> {
    if content == "-" {
        Ok(Tok::PhraseOp(1)) // <->
    } else if let Some(rest) = content.strip_prefix("!~") {
        Ok(Tok::NotWithinOp(parse_distance(rest)?, false))
    } else if let Some(rest) = content.strip_prefix("!-") {
        Ok(Tok::NotWithinOp(parse_distance(rest)?, true))
    } else if content.starts_with('!') {
        Err("not-within needs a direction: `<!~N>` (either order) or `<!-N>` (ordered)".into())
    } else if let Some(rest) = content.strip_prefix('~') {
        Ok(Tok::WithinOp(parse_distance(rest)?))
    } else if let Some(rest) = content.strip_prefix('-') {
        Ok(Tok::PreOp(parse_distance(rest)?))
    } else {
        Ok(Tok::PhraseOp(parse_distance(content)?))
    }
}

fn lex(input: &str) -> Result<Vec<Tok>, String> {
    let chars: Vec<char> = input.chars().collect();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
        } else if c == '(' {
            toks.push(Tok::LParen);
            i += 1;
        } else if c == ')' {
            toks.push(Tok::RParen);
            i += 1;
        } else if c == '&' {
            toks.push(Tok::And);
            i += 1;
        } else if c == '|' {
            toks.push(Tok::Or);
            i += 1;
        } else if c == '!' {
            toks.push(Tok::Not);
            i += 1;
        } else if c == '<' {
            let start = i + 1;
            let mut j = start;
            while j < chars.len() && chars[j] != '>' {
                j += 1;
            }
            if j >= chars.len() {
                return Err("unterminated `<…>` operator".into());
            }
            let content: String = chars[start..j].iter().collect();
            i = j + 1;
            toks.push(bracket_op(&content)?);
        } else if c == '"' {
            i += 1;
            let start = i;
            while i < chars.len() && chars[i] != '"' {
                i += 1;
            }
            if i >= chars.len() {
                return Err("unterminated quoted phrase".into());
            }
            let phrase: String = chars[start..i].iter().collect();
            i += 1;
            let atoms = phrase.split_whitespace().map(word_atom).collect::<Result<Vec<Atom>, _>>()?;
            if atoms.is_empty() {
                return Err("empty quoted phrase".into());
            }
            toks.push(Tok::Phrase(atoms));
        } else if c == '\'' {
            // A single-quoted literal term: no operator or wildcard meaning, with
            // '' for a literal quote. The escape hatch for terms with special chars.
            i += 1;
            let mut lexeme = String::new();
            loop {
                match chars.get(i) {
                    None => return Err("unterminated quoted term".into()),
                    Some('\'') if chars.get(i + 1) == Some(&'\'') => {
                        lexeme.push('\'');
                        i += 2;
                    }
                    Some('\'') => {
                        i += 1;
                        break;
                    }
                    Some(&ch) => {
                        lexeme.push(ch);
                        i += 1;
                    }
                }
            }
            if lexeme.is_empty() {
                return Err("empty quoted term".into());
            }
            toks.push(Tok::Exact(lexeme.to_ascii_lowercase()));
        } else if c == '#' {
            // ##regex## — everything between the delimiters is the regex verbatim.
            if chars.get(i + 1) != Some(&'#') {
                return Err("a single `#` is not valid; use `##regex##` or quote it".into());
            }
            i += 2;
            let start = i;
            while i + 1 < chars.len() && !(chars[i] == '#' && chars[i + 1] == '#') {
                i += 1;
            }
            if i + 1 >= chars.len() || !(chars[i] == '#' && chars[i + 1] == '#') {
                return Err("unterminated `##regex##`".into());
            }
            let pattern: String = chars[start..i].iter().collect();
            i += 2;
            toks.push(Tok::Regex(pattern));
        } else {
            let start = i;
            while i < chars.len() && is_word_char(chars[i]) {
                i += 1;
            }
            if i == start {
                return Err(format!("unexpected character `{c}`"));
            }
            toks.push(word_to_tok(&chars[start..i].iter().collect::<String>())?);
        }
    }
    Ok(toks)
}

// ===========================================================================
// Parser  (recursive descent; precedence | < & < proximity < !)
// ===========================================================================

enum ProxOp {
    Phrase(i32),
    Pre(i32),
    Within(i32),
    NotWithin(i32, bool),
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }

    fn bump(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.pos).cloned();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn parse(&mut self) -> Result<Node, String> {
        if self.toks.is_empty() {
            return Err("empty query".into());
        }
        let node = self.parse_or()?;
        if self.pos != self.toks.len() {
            return Err(format!("unexpected token {:?}", self.toks[self.pos]));
        }
        Ok(node)
    }

    fn parse_or(&mut self) -> Result<Node, String> {
        let mut branches = vec![self.parse_and()?];
        while matches!(self.peek(), Some(Tok::Or)) {
            self.bump();
            branches.push(self.parse_and()?);
        }
        Ok(if branches.len() == 1 { branches.pop().unwrap() } else { Node::Or(branches) })
    }

    fn parse_and(&mut self) -> Result<Node, String> {
        let mut branches = vec![self.parse_prox()?];
        while matches!(self.peek(), Some(Tok::And)) {
            self.bump();
            branches.push(self.parse_prox()?);
        }
        Ok(if branches.len() == 1 { branches.pop().unwrap() } else { Node::And(branches) })
    }

    fn parse_prox(&mut self) -> Result<Node, String> {
        let first = self.parse_unary()?;
        let mut ops = Vec::new();
        loop {
            let op = match self.peek() {
                Some(&Tok::PhraseOp(n)) => ProxOp::Phrase(n),
                Some(&Tok::PreOp(n)) => ProxOp::Pre(n),
                Some(&Tok::WithinOp(n)) => ProxOp::Within(n),
                Some(&Tok::NotWithinOp(n, ord)) => ProxOp::NotWithin(n, ord),
                _ => break,
            };
            self.bump();
            ops.push((op, self.parse_unary()?));
        }
        build_prox(first, ops)
    }

    fn parse_unary(&mut self) -> Result<Node, String> {
        if matches!(self.peek(), Some(Tok::Not)) {
            self.bump();
            Ok(Node::Not(Box::new(self.parse_unary()?)))
        } else {
            self.parse_atom()
        }
    }

    fn parse_atom(&mut self) -> Result<Node, String> {
        match self.bump() {
            Some(Tok::LParen) => {
                let inner = self.parse_or()?;
                match self.bump() {
                    Some(Tok::RParen) => Ok(inner),
                    _ => Err("expected `)`".into()),
                }
            }
            Some(Tok::Term(t)) => Ok(Node::Term(t)),
            Some(Tok::Exact(t)) => Ok(Node::Exact(t)),
            Some(Tok::Prefix(p)) => Ok(Node::Prefix(p)),
            Some(Tok::Glob(glob, prefix)) => Ok(Node::Glob { glob, prefix }),
            Some(Tok::Regex(pattern)) => Ok(Node::Regex(pattern)),
            Some(Tok::Phrase(atoms)) => Ok(phrase_node(atoms)),
            Some(t) => Err(format!("unexpected token {t:?} (expected a term, phrase, or `(`)")),
            None => Err("unexpected end of query".into()),
        }
    }
}

fn phrase_node(atoms: Vec<Atom>) -> Node {
    if atoms.len() == 1 {
        return match atoms.into_iter().next().unwrap() {
            Atom::Term(t) => Node::Term(t),
            Atom::Exact(t) => Node::Exact(t),
            Atom::Prefix(p) => Node::Prefix(p),
            Atom::Glob { glob, prefix } => Node::Glob { glob, prefix },
        };
    }
    let gaps = vec![1; atoms.len() - 1];
    Node::Phrase { atoms, gaps }
}

fn as_atom(node: &Node) -> Option<Atom> {
    match node {
        Node::Term(t) => Some(Atom::Term(t.clone())),
        Node::Exact(t) => Some(Atom::Exact(t.clone())),
        Node::Prefix(p) => Some(Atom::Prefix(p.clone())),
        Node::Glob { glob, prefix } => Some(Atom::Glob { glob: glob.clone(), prefix: prefix.clone() }),
        _ => None,
    }
}

/// Fold a left-associative proximity chain. Phrase/distance operators extend a
/// contiguous [`Node::Phrase`] (atom operands only); the rest wrap the running
/// node so the next operand is tested against its position region.
fn build_prox(first: Node, ops: Vec<(ProxOp, Node)>) -> Result<Node, String> {
    let mut current = first;
    for (op, rhs) in ops {
        current = match op {
            ProxOp::Phrase(gap) => extend_phrase(current, rhs, gap)?,
            ProxOp::Pre(n) => Node::Within { a: Box::new(current), b: Box::new(rhs), n, ordered: true },
            ProxOp::Within(n) => Node::Within { a: Box::new(current), b: Box::new(rhs), n, ordered: false },
            ProxOp::NotWithin(n, ordered) => {
                Node::NotWithin { a: Box::new(current), b: Box::new(rhs), n, ordered }
            }
        };
    }
    Ok(current)
}

fn extend_phrase(current: Node, rhs: Node, gap: i32) -> Result<Node, String> {
    const ERR: &str = "phrase/distance operator (`<->`, `<N>`) needs term operands";
    let rhs_atom = as_atom(&rhs).ok_or(ERR)?;
    match current {
        Node::Phrase { mut atoms, mut gaps } => {
            atoms.push(rhs_atom);
            gaps.push(gap);
            Ok(Node::Phrase { atoms, gaps })
        }
        other => {
            let left = as_atom(&other).ok_or(ERR)?;
            Ok(Node::Phrase { atoms: vec![left, rhs_atom], gaps: vec![gap] })
        }
    }
}

pub fn parse(input: &str) -> Result<Node, String> {
    let toks = lex(input)?;
    Parser { toks, pos: 0 }.parse()
}

// ===========================================================================
// Normalization  (lift AND/NOT out of proximity operands; keep OR/phrase in)
// ===========================================================================

pub fn normalize(node: Node) -> Node {
    match node {
        Node::And(v) => flatten(true, v.into_iter().map(normalize).collect()),
        Node::Or(v) => flatten(false, v.into_iter().map(normalize).collect()),
        Node::Not(x) => Node::Not(Box::new(normalize(*x))),
        Node::Within { a, b, n, ordered } => make_within(normalize(*a), normalize(*b), n, ordered),
        Node::NotWithin { a, b, n, ordered } => make_not_within(normalize(*a), normalize(*b), n, ordered),
        leaf => leaf,
    }
}

fn make_within(a: Node, b: Node, n: i32, ordered: bool) -> Node {
    match a {
        Node::And(xs) => flatten(true, xs.into_iter().map(|x| make_within(x, b.clone(), n, ordered)).collect()),
        Node::Not(x) => Node::Not(Box::new(make_within(*x, b, n, ordered))),
        _ => match b {
            Node::And(ys) => flatten(true, ys.into_iter().map(|y| make_within(a.clone(), y, n, ordered)).collect()),
            Node::Not(y) => Node::Not(Box::new(make_within(a, *y, n, ordered))),
            _ => Node::Within { a: Box::new(a), b: Box::new(b), n, ordered },
        },
    }
}

fn make_not_within(a: Node, b: Node, n: i32, ordered: bool) -> Node {
    match a {
        Node::And(xs) => flatten(true, xs.into_iter().map(|x| make_not_within(x, b.clone(), n, ordered)).collect()),
        Node::Not(x) => Node::Not(Box::new(make_not_within(*x, b, n, ordered))),
        _ => match b {
            Node::And(ys) => flatten(true, ys.into_iter().map(|y| make_not_within(a.clone(), y, n, ordered)).collect()),
            Node::Not(y) => Node::Not(Box::new(make_not_within(a, *y, n, ordered))),
            _ => Node::NotWithin { a: Box::new(a), b: Box::new(b), n, ordered },
        },
    }
}

fn flatten(is_and: bool, children: Vec<Node>) -> Node {
    let mut out = Vec::with_capacity(children.len());
    for c in children {
        match (is_and, c) {
            (true, Node::And(inner)) | (false, Node::Or(inner)) => out.extend(inner),
            (_, other) => out.push(other),
        }
    }
    if out.len() == 1 {
        out.pop().unwrap()
    } else if is_and {
        Node::And(out)
    } else {
        Node::Or(out)
    }
}

// ===========================================================================
// Skeleton lowering  ->  lexeme-presence tsquery string
// ===========================================================================

/// Lower to a `to_tsquery('simple', …)` input string for index selection.
/// `None` means the subtree imposes no positive constraint (a pure negation, or
/// an OR with an unconstrained branch) — left entirely to the recheck.
pub fn skeleton(node: &Node) -> Result<Option<String>, String> {
    Ok(match node {
        Node::Term(t) => Some(quote_lexeme(t)),
        Node::Exact(t) => Some(quote_lexeme(t)),
        Node::Prefix(p) => Some(format!("{}:*", quote_lexeme(p))),
        // A glob with a leading literal is index-served via that prefix; one that
        // starts with a wildcard carries no key and needs a companion term.
        Node::Glob { prefix, .. } => (!prefix.is_empty()).then(|| format!("{}:*", quote_lexeme(prefix))),
        Node::Regex(_) => None, // recheck-only, no index key
        Node::Phrase { atoms, gaps } => phrase_skeleton(atoms, gaps),
        Node::Within { a, b, .. } => optional_conj(&[skeleton(a)?, skeleton(b)?]),
        Node::NotWithin { a, .. } => skeleton(a)?, // companion term, if it carries a key
        Node::And(v) => {
            let present: Vec<String> = v.iter().filter_map(|c| skeleton(c).transpose()).collect::<Result<_, _>>()?;
            if present.is_empty() { None } else { Some(conj(&present)) }
        }
        Node::Or(v) => {
            let mut parts = Vec::with_capacity(v.len());
            for c in v {
                match skeleton(c)? {
                    Some(s) => parts.push(s),
                    None => return Ok(None), // an unconstrained branch ⇒ whole OR unconstrained
                }
            }
            Some(format!("({})", parts.join(" | ")))
        }
        Node::Not(_) => None, // negation is the recheck's job
    })
}

/// Conjoin the operands that carry a key; `None` if none do (e.g. a proximity of
/// two suffix wildcards — the index can't narrow it, so it needs a companion).
fn optional_conj(parts: &[Option<String>]) -> Option<String> {
    let present: Vec<String> = parts.iter().flatten().cloned().collect();
    (!present.is_empty()).then(|| conj(&present))
}

/// Native phrase skeleton when every atom has an index key; otherwise the
/// conjunction of the atoms that do (a keyless-wildcard atom carries none, so the
/// recheck enforces adjacency and the wildcard). `None` if no atom carries a key.
fn phrase_skeleton(atoms: &[Atom], gaps: &[i32]) -> Option<String> {
    if let Some(native) = atoms.iter().map(native_phrase_atom).collect::<Option<Vec<_>>>() {
        let mut s = native[0].clone();
        for (atom, &g) in native[1..].iter().zip(gaps) {
            let op = if g == 1 { "<->".to_string() } else { format!("<{g}>") };
            s = format!("{s} {op} {atom}");
        }
        Some(format!("({s})"))
    } else {
        let keyed: Vec<String> = atoms.iter().filter_map(native_phrase_atom).collect();
        (!keyed.is_empty()).then(|| conj(&keyed))
    }
}

/// A phrase atom's index key, or `None` for a leading-wildcard glob (no key).
fn native_phrase_atom(atom: &Atom) -> Option<String> {
    match atom {
        Atom::Term(t) => Some(quote_lexeme(t)),
        Atom::Exact(t) => Some(quote_lexeme(t)),
        Atom::Prefix(p) => Some(format!("{}:*", quote_lexeme(p))),
        Atom::Glob { prefix, .. } => (!prefix.is_empty()).then(|| format!("{}:*", quote_lexeme(prefix))),
    }
}

fn conj(parts: &[String]) -> String {
    if parts.len() == 1 {
        parts[0].clone()
    } else {
        format!("({})", parts.join(" & "))
    }
}

fn quote_lexeme(lex: &str) -> String {
    format!("'{}'", lex.replace('\'', "''"))
}

pub fn to_tsquery_string(input: &str) -> Result<String, String> {
    let node = normalize(parse(input)?);
    skeleton(&node)?.ok_or_else(|| {
        "query has no positive term to drive the index; add an AND-ed positive term".to_string()
    })
}

// ===========================================================================
// Native pushdown  ->  a tsquery whose `@@` is EXACTLY the recheck (drops it)
// ===========================================================================
//
// For the common bounded-proximity shapes the positional test can be expressed as
// a native `tsquery` and evaluated by Postgres's own (fast, C) phrase engine in the
// GIN `@@` heap recheck — so the custom `ts_prox_recheck` recheck is dropped entirely
// (the planner support fn marks the index condition non-lossy). within/pre lower to
// an OR over exact gaps, which is exactly the proximity predicate:
//   a <~n> b  ≡  OR_{k=0..n} (a <k> b | b <k> a)   (either order, |Δ| ≤ n)
//   a <-n> b  ≡  OR_{k=1..n} (a <k> b)             (ordered, 0 < Δ ≤ n)
// Only shapes that map EXACTLY are accepted; everything else (glob, regex,
// not-within, document NOT, nested/phrase proximity operands, or a distance past
// `NATIVE_MAX_DISTANCE`) returns None and keeps the presence-skeleton + recheck.
//
// This is `simple`-only (the literal 2-arg path): the cfg/analyzer operands resolve
// terms through dictionaries and stay on the skeleton+recheck path.

/// Distance past which `within`/`pre` are NOT pushed down. The OR-expansion is
/// `2·(n+1)` (either order) / `n` (ordered) phrase clauses, so this caps the query
/// size; past it the expansion's per-row cost outweighs the detoast it saves (the
/// recheck cost is flat in `n`). Benchmarked crossover is ~60 even on long TOASTed
/// docs, so 32 keeps a clear margin while covering realistic proximity distances.
/// Must be a compile-time constant (not a GUC): the wrapper functions stay IMMUTABLE
/// so the planner can const-fold them into the index condition.
pub const NATIVE_MAX_DISTANCE: i32 = 32;

/// A `tsquery` input string (for `tsqueryin` / `::tsquery`, *not* `to_tsquery` — the
/// lexemes are verbatim, matching the recheck's exact byte lookup) whose `@@` is
/// exactly equivalent to the positional recheck, or `None` when the query isn't fully
/// native-expressible within [`NATIVE_MAX_DISTANCE`] (the caller then keeps the
/// presence + recheck path).
pub fn native_tsquery_string(input: &str) -> Option<String> {
    native(&normalize(parse(input).ok()?))
}

/// The native tsquery string for the `@~@` operator's `simplify` rewrite: like
/// [`native_tsquery_string`], but `None` for any query containing a `within`/`pre`
/// (`<~N>` / `<-N>`) node. Those ARE native-expressible — and the pure-SQL port and the
/// `@@ ts_prox_query_native` recheck still use that expansion — but `simplify` must NOT
/// rewrite the whole `@~@` clause to it. The expansion is an OR over exact gaps
/// (`2·(n+1)` / `n` phrase clauses); as the *sole* index driver it replaces the
/// selective `a & b` presence skeleton, and the planner mis-estimates the OR-of-phrases
/// into a sequential scan over the whole table. Declining here keeps within/pre on the
/// [`crate::support::index_condition`] path — the `a & b` skeleton drives the GIN index
/// and a cheap positional recheck filters it, the same fast plan as the portable
/// two-clause form. The rewrite is kept only where it is an unambiguous win: phrase,
/// exact `<N>`, and boolean, whose native form IS the selective skeleton (just with the
/// recheck dropped, since its `@@` is the index probe).
pub fn simplify_tsquery_string(input: &str) -> Option<String> {
    let node = normalize(parse(input).ok()?);
    if contains_within(&node) {
        return None;
    }
    native(&node)
}

/// Whether the normalized AST contains a `within`/`pre` (`Node::Within`) node anywhere —
/// the gate for [`simplify_tsquery_string`]. `not within` already lowers to `None` in
/// [`native`], so it needs no separate guard here.
fn contains_within(node: &Node) -> bool {
    match node {
        Node::Within { .. } => true,
        Node::NotWithin { a, b, .. } => contains_within(a) || contains_within(b),
        Node::And(v) | Node::Or(v) => v.iter().any(contains_within),
        Node::Not(x) => contains_within(x),
        _ => false,
    }
}

/// A lexeme quoted for the native tsquery, or `None` if it can't survive `tsqueryin`
/// verbatim. The native tsquery is built with `tsqueryin` (not `to_tsquery`) so the
/// lexemes match the recheck's exact byte lookup with no re-tokenizing or dictionary
/// re-lowercasing. The one exception is a backslash: `tsqueryin` escapes it away
/// (`'a\b'` → lexeme `ab`), so such a term would no longer match the recheck — refuse
/// it (it falls back to the presence skeleton + recheck, which is correct).
fn native_lexeme(t: &str) -> Option<String> {
    (!t.contains('\\')).then(|| quote_lexeme(t))
}

/// A proximity operand expressible as a native phrase operand: a single keyed atom
/// (term/exact/prefix) or an OR of them. `None` for phrase / glob / regex / nested
/// proximity operands (whose `@@` is not exactly the recheck).
fn native_operand(node: &Node) -> Option<String> {
    match node {
        Node::Term(t) | Node::Exact(t) => native_lexeme(t),
        Node::Prefix(p) => Some(format!("{}:*", native_lexeme(p)?)),
        Node::Or(children) => {
            let parts = children.iter().map(native_operand).collect::<Option<Vec<_>>>()?;
            Some(format!("({})", parts.join(" | ")))
        }
        _ => None,
    }
}

/// A phrase atom's exact native key (term/exact/prefix). A glob is *not* exact (the
/// index prefix over-matches), so a phrase containing one can't be pushed down.
fn native_phrase_atom_exact(atom: &Atom) -> Option<String> {
    match atom {
        Atom::Term(t) | Atom::Exact(t) => native_lexeme(t),
        Atom::Prefix(p) => Some(format!("{}:*", native_lexeme(p)?)),
        Atom::Glob { .. } => None,
    }
}

fn native(node: &Node) -> Option<String> {
    match node {
        Node::Term(t) | Node::Exact(t) => native_lexeme(t),
        Node::Prefix(p) => Some(format!("{}:*", native_lexeme(p)?)),
        // Not exactly index-expressible — keep the recheck.
        Node::Glob { .. } | Node::Regex(_) | Node::Not(_) | Node::NotWithin { .. } => None,
        Node::Phrase { atoms, gaps } => {
            let keyed = atoms.iter().map(native_phrase_atom_exact).collect::<Option<Vec<_>>>()?;
            let mut s = keyed[0].clone();
            for (atom, &g) in keyed[1..].iter().zip(gaps) {
                let op = if g == 1 { "<->".to_string() } else { format!("<{g}>") };
                s = format!("{s} {op} {atom}");
            }
            Some(format!("({s})"))
        }
        Node::Within { a, b, n, ordered } => {
            let n = *n;
            // Ordered <-0> is unsatisfiable (0 < Δ ≤ 0); let the recheck return false.
            if n > NATIVE_MAX_DISTANCE || (*ordered && n < 1) {
                return None;
            }
            let (a, b) = (native_operand(a)?, native_operand(b)?);
            let mut clauses = Vec::new();
            if *ordered {
                for k in 1..=n {
                    clauses.push(format!("{a} <{k}> {b}"));
                }
            } else {
                for k in 0..=n {
                    clauses.push(format!("{a} <{k}> {b}"));
                    clauses.push(format!("{b} <{k}> {a}"));
                }
            }
            Some(format!("({})", clauses.join(" | ")))
        }
        Node::And(v) => {
            let parts = v.iter().map(native).collect::<Option<Vec<_>>>()?;
            Some(format!("({})", parts.join(" & ")))
        }
        Node::Or(v) => {
            let parts = v.iter().map(native).collect::<Option<Vec<_>>>()?;
            Some(format!("({})", parts.join(" | ")))
        }
    }
}

// ===========================================================================
// Config-resolved exact pushdown  ->  drop the recheck for a config-aware column
// ===========================================================================
//
// `native()` above is `simple`-only: it quotes the LITERAL query lexemes verbatim, so
// its `@@` is exactly the literal recheck. The config-aware (3-arg) path resolves each
// term through the column's text-search config (`to_tsvector(cfg, term)`). This builder
// is used purely as a DROPPABILITY WITNESS: it succeeds (returns `Some`) exactly when a
// recheck-droppable query (plain boolean / phrase / prefix, no within/pre/not-within,
// glob, regex, NOT) has every term resolve to ≥1 lexeme. Its string is the OR-of-resolved
// lexemes (a fan-out term — a stemmer/thesaurus, or a parser-split compound like
// `cafe-bar` under `simple_unaccent` — becomes the OR of its parts), which equals the
// recheck; but the public `ts_prox_query_exact` does NOT return it — it returns the index
// SELECTION `to_tsquery(cfg, skeleton)` (= `ts_prox_query`), so the index filter and the
// gate are identical logic. The selection is a subset of the recheck (a compound's
// `to_tsquery` phrase ⊆ the OR), so dropping the recheck preserves the two-clause result.
// within/pre decline (exact but non-selective: they keep the selective skeleton +
// recheck, the same gate as `simplify_tsquery_string`). Mirrors the pure port's
// `_prox_native(_prox_resolve_ast(node, cfg))` gated by `_prox_has_within`.
//
// Resolver-generic in shape, but only `Resolver::Cfg` is wired (`Resolver::Literal`
// goes through `native()`; an analyzer `Exact` would need `lexemes_exact`).

/// A term's config-resolved lexeme(s) as a quoted tsquery fragment — a single lexeme or
/// an OR of them (the recheck unions their positions, so OR is exact). `None` when it
/// resolves to nothing (a stopword: the branch then keeps the recheck) or to a lexeme
/// that can't survive `tsqueryin` verbatim (a backslash — see [`native_lexeme`]).
fn native_resolved_term(r: Resolver, term: &str) -> Option<String> {
    let lexemes = resolve_lexemes(r, term);
    if lexemes.is_empty() {
        return None;
    }
    let parts: Vec<String> = lexemes
        .iter()
        .map(|l| std::str::from_utf8(l).ok().and_then(native_lexeme))
        .collect::<Option<_>>()?;
    Some(if parts.len() == 1 { parts[0].clone() } else { format!("({})", parts.join(" | ")) })
}

/// A prefix's config-folded lexeme as a `:*` key (the prefix run normalized through the
/// config, mirroring the `to_tsquery(cfg, 'p':*)` the skeleton selects on; raw when the
/// config yields 0 or >1 lexemes). `None` for a backslash lexeme.
fn native_resolved_prefix(r: Resolver, p: &str) -> Option<String> {
    let pfx = prefix_norm(r, p);
    Some(format!("{}:*", native_lexeme(std::str::from_utf8(&pfx).ok()?)?))
}

/// A phrase atom resolved through `r`: its single config lexeme, or — for a multi-lexeme
/// / stopword atom — the atom's literal text verbatim (left unresolved, matching the
/// pure port; the recheck makes both ports agree on the resulting empty match). `None`
/// for a glob atom (no exact key) or a backslash lexeme.
fn native_resolved_atom(r: Resolver, atom: &Atom) -> Option<String> {
    match atom {
        Atom::Term(t) | Atom::Exact(t) => match resolve_lexemes(r, t).as_slice() {
            [one] => std::str::from_utf8(one).ok().and_then(native_lexeme),
            _ => native_lexeme(t),
        },
        Atom::Prefix(p) => native_resolved_prefix(r, p),
        Atom::Glob { .. } => None,
    }
}

/// Config counterpart of [`native`]: the recheck-droppable tsquery with leaves resolved
/// through `r`, or `None` to keep the recheck. `@@` of the result is EXACTLY the config
/// recheck for the shapes it accepts (boolean / phrase / prefix); within/pre, glob,
/// regex, not-within and document NOT decline.
fn native_resolved(node: &Node, r: Resolver) -> Option<String> {
    match node {
        Node::Term(t) | Node::Exact(t) => native_resolved_term(r, t),
        Node::Prefix(p) => native_resolved_prefix(r, p),
        Node::Glob { .. } | Node::Regex(_) | Node::Not(_) | Node::NotWithin { .. } | Node::Within { .. } => {
            None
        }
        Node::Phrase { atoms, gaps } => {
            let keyed = atoms.iter().map(|a| native_resolved_atom(r, a)).collect::<Option<Vec<_>>>()?;
            let mut s = keyed[0].clone();
            for (atom, &g) in keyed[1..].iter().zip(gaps) {
                let op = if g == 1 { "<->".to_string() } else { format!("<{g}>") };
                s = format!("{s} {op} {atom}");
            }
            Some(format!("({s})"))
        }
        Node::And(v) => {
            let parts = v.iter().map(|c| native_resolved(c, r)).collect::<Option<Vec<_>>>()?;
            Some(format!("({})", parts.join(" & ")))
        }
        Node::Or(v) => {
            let parts = v.iter().map(|c| native_resolved(c, r)).collect::<Option<Vec<_>>>()?;
            Some(format!("({})", parts.join(" | ")))
        }
    }
}

/// Whether the query is recheck-droppable under `cfg` — the gate for the 3-arg
/// `ts_prox_query_exact`. True exactly when [`native_resolved`] can build a verbatim
/// tsquery: a droppable shape (boolean / phrase / prefix; no within/pre/not-within,
/// glob, regex, NOT) where every term resolves to ≥1 lexeme. In that case the cfg index
/// selection `to_tsquery(cfg, skeleton)` is a *subset* of the recheck (a compound's
/// `to_tsquery` phrase ⊆ the recheck's OR-of-parts), so `@@ selection AND recheck`
/// collapses to `@@ selection` and the recheck folds away. The public function then
/// returns that **selection** (identical to `ts_prox_query`), NOT the OR witness — so the
/// index filter and the droppability gate are one and the same logic.
pub fn cfg_exact_droppable(input: &str, cfg: pg_sys::Oid) -> bool {
    match parse(input) {
        Ok(node) => native_resolved(&normalize(node), Resolver::Cfg(cfg)).is_some(),
        Err(_) => false,
    }
}

// --- analyzer probe: a skeleton with leaves resolved through the analyzer --------
//
// The cfg path lets `to_tsquery(cfg, skeleton)` resolve raw terms, but there is no
// `to_tsquery(analyzer, …)`. So the analyzer skeleton resolves each leaf to the
// analyzer's lexemes itself and quotes them, producing a complete tsquery string
// that `tsqueryin` (`::tsquery`) takes verbatim — no re-tokenization, so a lexeme
// like `cafe-bar` survives intact. Structure mirrors `skeleton`; only leaves differ.

/// A term's analyzer lexemes as a quoted tsquery fragment (OR'd if several — a doc
/// that stored *any* one must be index-selected, the soundness contract). `None`
/// when the term resolves to nothing.
fn resolved_term(kind: AnalyzerKind, term: &str) -> Option<String> {
    let quoted: Vec<String> = resolve_lexemes(Resolver::Analyzer(kind), term)
        .iter()
        .filter_map(|l| std::str::from_utf8(l).ok().map(quote_lexeme))
        .collect();
    match quoted.as_slice() {
        [] => None,
        [one] => Some(one.clone()),
        _ => Some(format!("({})", quoted.join(" | "))),
    }
}

/// A literal `'…'` term's exact analyzer lexeme(s), quoted (no accent-fold/stem).
fn resolved_exact(kind: AnalyzerKind, term: &str) -> Option<String> {
    let quoted: Vec<String> = kind
        .lexemes_exact(term)
        .iter()
        .filter_map(|l| std::str::from_utf8(l).ok().map(quote_lexeme))
        .collect();
    match quoted.as_slice() {
        [] => None,
        [one] => Some(one.clone()),
        _ => Some(format!("({})", quoted.join(" | "))),
    }
}

/// A prefix/glob literal folded to its single analyzer lexeme, or raw when the
/// analyzer yields 0 or >1 lexemes (the same 0/1/>1 fan-out as the cfg path).
fn fold_prefix(kind: AnalyzerKind, p: &str) -> String {
    match resolve_lexemes(Resolver::Analyzer(kind), p).as_slice() {
        [one] => String::from_utf8(one.clone()).unwrap_or_else(|_| p.to_owned()),
        _ => p.to_owned(),
    }
}

fn resolved_atom(kind: AnalyzerKind, atom: &Atom) -> Option<String> {
    match atom {
        Atom::Term(t) => resolved_term(kind, t),
        Atom::Exact(t) => resolved_exact(kind, t),
        Atom::Prefix(p) => Some(format!("{}:*", quote_lexeme(&fold_prefix(kind, p)))),
        Atom::Glob { prefix, .. } => {
            (!prefix.is_empty()).then(|| format!("{}:*", quote_lexeme(&fold_prefix(kind, prefix))))
        }
    }
}

/// Analyzer counterpart of [`skeleton`]: same lowering, leaves resolved + quoted.
fn analyzer_skeleton(node: &Node, kind: AnalyzerKind) -> Result<Option<String>, String> {
    Ok(match node {
        Node::Term(t) => resolved_term(kind, t),
        Node::Exact(t) => resolved_exact(kind, t),
        Node::Prefix(p) => Some(format!("{}:*", quote_lexeme(&fold_prefix(kind, p)))),
        Node::Glob { prefix, .. } => {
            (!prefix.is_empty()).then(|| format!("{}:*", quote_lexeme(&fold_prefix(kind, prefix))))
        }
        Node::Regex(_) => None,
        // Sound conjunction of resolved atoms — the recheck enforces adjacency.
        Node::Phrase { atoms, .. } => {
            let parts: Vec<String> = atoms.iter().filter_map(|a| resolved_atom(kind, a)).collect();
            (!parts.is_empty()).then(|| conj(&parts))
        }
        Node::Within { a, b, .. } => {
            optional_conj(&[analyzer_skeleton(a, kind)?, analyzer_skeleton(b, kind)?])
        }
        Node::NotWithin { a, .. } => analyzer_skeleton(a, kind)?,
        Node::And(v) => {
            let present: Vec<String> = v
                .iter()
                .filter_map(|c| analyzer_skeleton(c, kind).transpose())
                .collect::<Result<_, _>>()?;
            if present.is_empty() {
                None
            } else {
                Some(conj(&present))
            }
        }
        Node::Or(v) => {
            let mut parts = Vec::with_capacity(v.len());
            for c in v {
                match analyzer_skeleton(c, kind)? {
                    Some(s) => parts.push(s),
                    None => return Ok(None),
                }
            }
            Some(format!("({})", parts.join(" | ")))
        }
        Node::Not(_) => None,
    })
}

/// Analyzer-resolved tsquery string for index selection (cast `::tsquery` verbatim).
/// Errors on a keyless query, same contract as [`to_tsquery_string`].
pub fn analyzer_tsquery_string(input: &str, kind: AnalyzerKind) -> Result<String, String> {
    let node = normalize(parse(input)?);
    analyzer_skeleton(&node, kind)?.ok_or_else(|| {
        "query has no positive term to drive the index; add an AND-ed positive term".to_string()
    })
}

// ===========================================================================
// Regex validation  ->  fail fast & consistently on a malformed `##regex##`
// ===========================================================================

/// Probe every `##regex##` in the query so a malformed pattern fails the whole
/// query up front — consistently, regardless of short-circuiting or which
/// documents get scanned — rather than erroring mid-scan or being silently
/// skipped. The offending pattern is named in the error; the recheck can then
/// assume any regex it sees compiles.
pub fn validate_regexes(node: &Node) -> Result<(), String> {
    match node {
        Node::Regex(pattern) if !regex_compiles(pattern) => Err(format!("invalid regex `{pattern}`")),
        Node::And(v) | Node::Or(v) => v.iter().try_for_each(validate_regexes),
        Node::Not(x) => validate_regexes(x),
        Node::Within { a, b, .. } | Node::NotWithin { a, b, .. } => {
            validate_regexes(a)?;
            validate_regexes(b)
        }
        _ => Ok(()),
    }
}

/// Does `pattern` compile? Postgres compiles lazily and `ereport`s on a bad
/// pattern; probe once under a catch scoped to *only* the invalid-regex error (so
/// a statement cancel etc. still propagates) and report it cleanly ourselves —
/// our message is stable across major versions, unlike Postgres's own text.
fn regex_compiles(pattern: &str) -> bool {
    let re = unsafe { Regexp::compile(pattern) };
    pgrx::PgTryBuilder::new(|| {
        unsafe { re.is_match(b"") };
        true
    })
    .catch_when(pgrx::PgSqlErrorCode::ERRCODE_INVALID_REGULAR_EXPRESSION, |_| false)
    .execute()
}

// ===========================================================================
// Recheck evaluation  ->  bool  (the positional semantics on a tsvector)
// ===========================================================================
//
// Every *positional* node evaluates to the sorted set of positions where it
// occurs ([`positions`]); a proximity composes by testing the next operand
// against that set. The boolean layer ([`eval_match`]) answers true/false using
// the predicates in [`crate::proximity`].

use crate::proximity;
use crate::tokenizer::AnalyzerKind;
use crate::tsvector::TsVector;
use pgrx::datum::FromDatum;
use pgrx::pg_sys;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// How a query atom's literal text is resolved to lexeme(s) before matching — the
/// query side of the index/query symmetry, threaded through the whole evaluator.
#[derive(Clone, Copy)]
pub enum Resolver {
    /// 2-arg fast path: match the atom as a verbatim (ASCII-lowered) lexeme.
    Literal,
    /// Config-aware: resolve through `to_tsvector(cfg, term)`.
    Cfg(pg_sys::Oid),
    /// Custom Unicode tokenizer: resolve through the named analyzer, symmetric with
    /// `proxquery_to_tsvector`.
    Analyzer(AnalyzerKind),
}

// --- config-aware term resolution -----------------------------------------
//
// A query term matches by *lexeme*. Under a non-`simple` text-search config the
// stored lexemes are normalized (stemmed, unaccented, lowercased by locale, …),
// so a query term must be run through the SAME config to find them. We resolve
// `term -> lexeme(s)` via `to_tsvector(cfg, term)` — the exact routine that built
// the column — so the recheck agrees with the column, and with the
// `to_tsquery(cfg, …)` skeleton, by construction. `cfg = None` is the historical
// `simple` fast path (literal byte lookup), kept byte-identical for the 2-arg API.

/// OID of `pg_catalog.to_tsvector(regconfig, text)`, looked up once (builtin, stable
/// for the backend).
fn to_tsvector_oid() -> pg_sys::Oid {
    use std::sync::OnceLock;
    static OID: OnceLock<pg_sys::Oid> = OnceLock::new();
    *OID.get_or_init(|| unsafe {
        let names =
            pg_sys::stringToQualifiedNameList(c"pg_catalog.to_tsvector".as_ptr(), core::ptr::null_mut());
        let argtypes = [pg_sys::REGCONFIGOID, pg_sys::TEXTOID];
        pg_sys::LookupFuncName(names, 2, argtypes.as_ptr(), false)
    })
}

/// Cache of a term's resolved lexemes (`Rc` so the hot path clones a refcount, not
/// the Vec). Nested `resolver -> term -> lexemes` so a cache hit looks the term up by
/// `&str` (no per-row `String` allocation); the owned key is built only on a miss.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum CacheKey {
    Cfg(pg_sys::Oid),
    Analyzer(u8, Option<pg_sys::Oid>),
}

type ResolveCache = HashMap<CacheKey, HashMap<String, Rc<Vec<Vec<u8>>>>>;

thread_local! {
    // Resolution is per-row in the recheck but `(resolver, term)` repeats across rows
    // of a scan, so memoize. Bounded by the query vocabulary.
    static RESOLVE_CACHE: RefCell<ResolveCache> = RefCell::new(HashMap::new());
}

/// Distinct lexemes a term resolves to under `r` — through the config's dictionaries
/// (`to_tsvector(cfg, term)`) or the custom analyzer. Empty when the term is a
/// stopword / tokenizes to nothing. Not meaningful on the literal path.
fn resolve_lexemes(r: Resolver, term: &str) -> Rc<Vec<Vec<u8>>> {
    let key = match r {
        Resolver::Cfg(oid) => CacheKey::Cfg(oid),
        Resolver::Analyzer(k) => {
            let (base, dict) = k.cache_key();
            CacheKey::Analyzer(base, dict)
        }
        Resolver::Literal => return Rc::new(Vec::new()),
    };
    if let Some(hit) =
        RESOLVE_CACHE.with(|m| m.borrow().get(&key).and_then(|inner| inner.get(term)).cloned())
    {
        return hit;
    }
    let lexemes = match r {
        Resolver::Cfg(cfg) => unsafe {
            let text = pg_sys::cstring_to_text_with_len(
                term.as_ptr() as *const core::ffi::c_char,
                term.len() as i32,
            );
            let datum = pg_sys::OidFunctionCall2Coll(
                to_tsvector_oid(),
                pg_sys::InvalidOid,
                pg_sys::Datum::from(cfg),
                pg_sys::Datum::from(text),
            );
            match TsVector::from_polymorphic_datum(datum, false, pg_sys::TSVECTOROID) {
                Some(tsv) => tsv.all_lexemes(),
                None => Vec::new(),
            }
        },
        Resolver::Analyzer(k) => k.lexemes(term),
        Resolver::Literal => Vec::new(),
    };
    let rc = Rc::new(lexemes);
    RESOLVE_CACHE
        .with(|m| m.borrow_mut().entry(key).or_default().insert(term.to_owned(), Rc::clone(&rc)));
    rc
}

/// Union of a tsvector's positions over a set of lexemes (an OR of co-located forms —
/// a stemmer/thesaurus/analyzer may emit several).
fn positions_union(v: &TsVector, lexemes: &[Vec<u8>]) -> Vec<i32> {
    match lexemes {
        [] => Vec::new(),
        [one] => v.positions(one),
        many => {
            let mut all = Vec::new();
            for l in many {
                all.extend(v.positions(l));
            }
            all.sort_unstable();
            all.dedup();
            all
        }
    }
}

/// Positions of a (bare) term resolved under `r` — its canonical lexeme(s).
fn term_positions(r: Resolver, term: &str, v: &TsVector) -> Vec<i32> {
    positions_union(v, &resolve_lexemes(r, term))
}

/// Positions of a LITERAL `'…'` term. Under an analyzer it resolves EXACTLY (no
/// accent-fold/stem), so it matches the index's preserved form; under cfg/literal it
/// is the normal term resolution (those paths don't superimpose, so there's nothing
/// to be exact about).
fn exact_positions(r: Resolver, term: &str, v: &TsVector) -> Vec<i32> {
    match r {
        Resolver::Analyzer(k) => positions_union(v, &k.lexemes_exact(term)),
        Resolver::Cfg(_) => term_positions(r, term, v),
        Resolver::Literal => v.positions(term.as_bytes()),
    }
}

/// The prefix to scan for a `Prefix` node under `cfg` — the prefix text normalized
/// through the config (so an accented prefix matches the unaccented stored lexemes,
/// matching what `to_tsquery(cfg, 'p':*)` selects). Falls back to the raw prefix when
/// the config yields zero or several lexemes.
fn prefix_norm(r: Resolver, p: &str) -> Vec<u8> {
    let lexemes = resolve_lexemes(r, p);
    match lexemes.as_slice() {
        [one] => one.clone(),
        _ => p.as_bytes().to_vec(),
    }
}

/// Fold one literal glob run through `cfg`: its single resolved lexeme, or the run
/// verbatim when `cfg` yields 0 or >1 lexemes (the same 0/1/>1 fan-out as terms).
fn fold_run(r: Resolver, run: &str) -> String {
    match resolve_lexemes(r, run).as_slice() {
        [one] => String::from_utf8(one.clone()).unwrap_or_else(|_| run.to_owned()),
        _ => run.to_owned(),
    }
}

/// Fold a glob's literal runs (maximal non-`*`/`?` substrings) through `cfg`, leaving
/// the wildcards untouched, so a wildcard search inherits the column's character
/// normalization and agrees with the folded `to_tsquery(cfg, 'p':*)` index probe.
/// Mirrors the pure port's `_prox_fold_glob`. Returns the folded pattern and its
/// recomputed leading prefix (so the `positions_matching` scan-narrowing keys off the
/// folded lexemes too).
fn fold_glob(r: Resolver, glob: &str) -> (String, String) {
    let mut out = String::new();
    let mut run = String::new();
    for ch in glob.chars() {
        if is_glob_char(ch) {
            if !run.is_empty() {
                out.push_str(&fold_run(r, &run));
                run.clear();
            }
            out.push(ch);
        } else {
            run.push(ch);
        }
    }
    if !run.is_empty() {
        out.push_str(&fold_run(r, &run));
    }
    let prefix = glob_prefix(&out);
    (out, prefix)
}

/// Positions of a glob, resolving its literal runs through `cfg` when one is given
/// (config-aware recheck) or scanning the stored lexemes verbatim otherwise (the
/// `simple` 2-arg fast path).
fn glob_positions(r: Resolver, glob: &str, prefix: &str, v: &TsVector) -> Vec<i32> {
    match r {
        Resolver::Literal => v.positions_matching(prefix.as_bytes(), |lex| glob_match(glob, lex)),
        _ => {
            let (fg, fp) = fold_glob(r, glob);
            v.positions_matching(fp.as_bytes(), |lex| glob_match(&fg, lex))
        }
    }
}

pub fn eval_match(node: &Node, v: &TsVector, r: Resolver) -> Result<bool, String> {
    Ok(match node {
        Node::And(children) => {
            for c in children {
                if !eval_match(c, v, r)? {
                    return Ok(false);
                }
            }
            true
        }
        Node::Or(children) => {
            for c in children {
                if eval_match(c, v, r)? {
                    return Ok(true);
                }
            }
            false
        }
        Node::Not(x) => !eval_match(x, v, r)?,
        Node::Within { a, b, n, ordered } => {
            let (pa, pb) = (positions(a, v, r)?, positions(b, v, r)?);
            if *ordered {
                proximity::pre(&pa, &pb, *n)
            } else {
                proximity::within(&pa, &pb, *n)
            }
        }
        Node::NotWithin { a, b, n, ordered } => {
            proximity::not_within(&positions(a, v, r)?, &positions(b, v, r)?, *n, *ordered)
        }
        Node::Term(_)
        | Node::Exact(_)
        | Node::Prefix(_)
        | Node::Glob { .. }
        | Node::Regex(_)
        | Node::Phrase { .. } => !positions(node, v, r)?.is_empty(),
    })
}

fn positions(node: &Node, v: &TsVector, r: Resolver) -> Result<Vec<i32>, String> {
    Ok(match node {
        // Term/Prefix/Glob resolve through the config or analyzer (unless literal), so
        // a wildcard search folds like the column was built; regex stays verbatim (its
        // skeleton emits no index key, so there is no probe to keep it consistent with).
        Node::Term(t) => match r {
            Resolver::Literal => v.positions(t.as_bytes()),
            _ => term_positions(r, t, v),
        },
        Node::Exact(t) => exact_positions(r, t, v),
        Node::Prefix(p) => match r {
            Resolver::Literal => v.positions_prefix(p.as_bytes()),
            _ => v.positions_prefix(&prefix_norm(r, p)),
        },
        Node::Glob { glob, prefix } => glob_positions(r, glob, prefix, v),
        Node::Regex(pattern) => {
            // Patterns are validated up front (see `validate_regexes`), so by the
            // time the recheck runs the regex is known to compile.
            let re = unsafe { Regexp::compile(pattern) };
            v.positions_matching(b"", |lex| unsafe { re.is_match(lex) })
        }
        Node::Phrase { atoms, gaps } => phrase_positions(atoms, gaps, v, r),
        Node::Or(children) => {
            let mut all = Vec::new();
            for c in children {
                all.extend(positions(c, v, r)?);
            }
            all.sort_unstable();
            all.dedup();
            all
        }
        Node::Within { a, b, n, ordered } => {
            within_span(&positions(a, v, r)?, &positions(b, v, r)?, *n, *ordered)
        }
        Node::NotWithin { a, b, n, ordered } => {
            not_within_participants(&positions(a, v, r)?, &positions(b, v, r)?, *n, *ordered)
        }
        Node::And(_) | Node::Not(_) => {
            return Err("AND/NOT cannot be a proximity operand (normalization should have lifted it)".into())
        }
    })
}

/// OID of `pg_catalog.textregexeq` (the function behind `text ~ text`), looked up
/// once. It is a builtin, so its OID is stable for the life of the backend.
fn textregexeq_oid() -> pg_sys::Oid {
    use std::sync::OnceLock;
    static OID: OnceLock<pg_sys::Oid> = OnceLock::new();
    *OID.get_or_init(|| unsafe {
        let names =
            pg_sys::stringToQualifiedNameList(c"pg_catalog.textregexeq".as_ptr(), core::ptr::null_mut());
        let argtypes = [pg_sys::TEXTOID, pg_sys::TEXTOID];
        pg_sys::LookupFuncName(names, 2, argtypes.as_ptr(), false)
    })
}

/// Whole-lexeme regex matching via Postgres's own engine (the function behind
/// `~`) — no extra dependency, and the dialect matches `~`. The compiled regex is
/// cached by Postgres across calls; we anchor the pattern to the entire lexeme
/// and match under the C collation (byte semantics, deterministic).
struct Regexp {
    oid: pg_sys::Oid,
    anchored: pg_sys::Datum,
}

impl Regexp {
    /// # Safety
    /// Must run inside a Postgres memory context (it palloc's the pattern text).
    unsafe fn compile(pattern: &str) -> Self {
        let anchored = format!("^(?:{pattern})$");
        let text = pg_sys::cstring_to_text_with_len(
            anchored.as_ptr() as *const core::ffi::c_char,
            anchored.len() as i32,
        );
        Regexp { oid: textregexeq_oid(), anchored: pg_sys::Datum::from(text) }
    }

    /// # Safety
    /// `lexeme` is read for the duration of the call only.
    unsafe fn is_match(&self, lexeme: &[u8]) -> bool {
        let lex = pg_sys::cstring_to_text_with_len(
            lexeme.as_ptr() as *const core::ffi::c_char,
            lexeme.len() as i32,
        );
        let matched = pg_sys::OidFunctionCall2Coll(
            self.oid,
            pg_sys::C_COLLATION_OID,
            pg_sys::Datum::from(lex),
            self.anchored,
        );
        bool::from_datum(matched, false).unwrap_or(false)
    }
}

/// Match a `*`/`?` glob against a lexeme (`?` = one char, `*` = any run), on chars.
fn glob_match(pattern: &str, lexeme: &[u8]) -> bool {
    let text = match std::str::from_utf8(lexeme) {
        Ok(t) => t,
        Err(_) => return false,
    };
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    let (mut star, mut mark) = (None, 0usize); // last `*` in pattern, and its match point
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn atom_positions(a: &Atom, v: &TsVector, r: Resolver) -> Vec<i32> {
    match a {
        Atom::Term(t) => match r {
            Resolver::Literal => v.positions(t.as_bytes()),
            _ => term_positions(r, t, v),
        },
        Atom::Exact(t) => exact_positions(r, t, v),
        Atom::Prefix(p) => match r {
            Resolver::Literal => v.positions_prefix(p.as_bytes()),
            _ => v.positions_prefix(&prefix_norm(r, p)),
        },
        Atom::Glob { glob, prefix } => glob_positions(r, glob, prefix, v),
    }
}

/// End positions of an exact-gap sequence: `atoms[i+1]` exactly `gaps[i]` after `atoms[i]`.
fn phrase_positions(atoms: &[Atom], gaps: &[i32], v: &TsVector, r: Resolver) -> Vec<i32> {
    let mut reach = atom_positions(&atoms[0], v, r);
    for (atom, &g) in atoms[1..].iter().zip(gaps) {
        let cur = atom_positions(atom, v, r);
        reach = cur.into_iter().filter(|&c| reach.binary_search(&(c - g)).is_ok()).collect();
        if reach.is_empty() {
            break;
        }
    }
    reach
}

/// Is there a partner for `p` in `others` satisfying the (possibly ordered)
/// distance `n`? `p_is_left` only matters when `ordered`.
fn has_partner(p: i32, others: &[i32], n: i32, ordered: bool, p_is_left: bool) -> bool {
    if others.is_empty() {
        return false;
    }
    if !ordered {
        let idx = others.partition_point(|&x| x < p);
        (idx < others.len() && others[idx] - p <= n) || (idx > 0 && p - others[idx - 1] <= n)
    } else if p_is_left {
        let idx = others.partition_point(|&x| x <= p);
        idx < others.len() && others[idx] - p <= n
    } else {
        let idx = others.partition_point(|&x| x < p);
        idx > 0 && p - others[idx - 1] <= n
    }
}

/// The region a `within`/`pre` contributes when it is itself a proximity operand:
/// the union of the spans `[min(aᵢ,bⱼ) … max(aᵢ,bⱼ)]` of every satisfying pair,
/// densified to a sorted position set. This lets the next operand attach to a term
/// that falls *between* a matched pair; taking the per-pair union (not one global
/// min/max) keeps two separate matches from bridging the gap between them.
/// Positions are capped at `MAX_DISTANCE`, so the densified set is bounded.
fn within_span(a: &[i32], b: &[i32], n: i32, ordered: bool) -> Vec<i32> {
    // One covering interval per `a` position that has a qualifying partner. All of a
    // position's qualifying partners are contiguous in sorted `b`, so the leftmost
    // and rightmost of them (with the position itself) bound its interval. The same
    // `[min(pa,b[first]) … max(pa,b[last−1])]` formula serves both orders, since for
    // the ordered case every qualifying `b` is `> pa`.
    let mut intervals: Vec<(i32, i32)> = Vec::new();
    for &pa in a {
        let (first, last) = if ordered {
            (b.partition_point(|&x| x <= pa), b.partition_point(|&x| x <= pa + n)) // (pa, pa+n]
        } else {
            (b.partition_point(|&x| x < pa - n), b.partition_point(|&x| x <= pa + n)) // [pa−n, pa+n]
        };
        if first < last {
            intervals.push((pa.min(b[first]), pa.max(b[last - 1])));
        }
    }
    densify_union(intervals)
}

/// Merge inclusive intervals and expand to a sorted, unique position list. Merging
/// before expanding bounds the output to the (capped) position range.
fn densify_union(mut intervals: Vec<(i32, i32)>) -> Vec<i32> {
    if intervals.is_empty() {
        return Vec::new();
    }
    intervals.sort_unstable();
    let mut out = Vec::new();
    let (mut lo, mut hi) = intervals[0];
    for &(l, h) in &intervals[1..] {
        if l <= hi + 1 {
            hi = hi.max(h);
        } else {
            out.extend(lo..=hi);
            (lo, hi) = (l, h);
        }
    }
    out.extend(lo..=hi);
    out
}

/// The isolated `a` positions — those with no qualifying `b` (the occurrences a
/// nested not-within contributes).
fn not_within_participants(a: &[i32], b: &[i32], n: i32, ordered: bool) -> Vec<i32> {
    a.iter().copied().filter(|&pa| !has_partner(pa, b, n, ordered, true)).collect()
}

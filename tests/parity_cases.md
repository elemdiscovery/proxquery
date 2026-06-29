# proxquery parity corpus

The shared test corpus that BOTH implementations — the native extension and the
pure-SQL port (`sql/proxquery_pure.sql`) — must agree on. The corpus runner
(`tokenizer`-independent) parses this file's tables and, for every case, asserts
`extension == pure port == expected` (see the `pure_sql_matches_extension_corpus`
`#[pg_test]` and `sql/proxquery_diff_test.sql`). It is the single source of truth:
edit cases here, not in SQL.

Conventions: each value is wrapped in `` ` `` (so `*`, `<~N>`, `&` aren't
interpreted as markdown); a literal `|` inside a value is escaped as `\|`. An
`expected` of `ERR` means the expression must raise; `<null>` means SQL NULL.

## Expression cases

Portable `ts_prox_*` expressions evaluated as `(<expression>)::text` under each
implementation (skeletons, positions, predicates, `@@` selection, errors, and
literal-tsvector cases).

| label | expression | expected |
| --- | --- | --- |
| `err1` | ` ts_prox_query('*ology') ` | `ERR` |
| `err2` | ` ts_prox_recheck(to_tsvector('simple','a b'),'(a <~5> b') ` | `ERR` |
| `err3` | ` ts_prox_recheck(to_tsvector('simple','a b'),'a <!5> b') ` | `ERR` |
| `err4` | ` ts_prox_recheck(to_tsvector('simple','a b'),'a &') ` | `ERR` |
| `err5` | ` ts_prox_recheck(to_tsvector('simple','alpha beta'),'##[##') ` | `ERR` |
| `err6` | ` ts_prox_recheck(to_tsvector('simple','alpha beta'),'alpha \| ##[##') ` | `ERR` |
| `err7` | ` ts_prox_query('!foo') ` | `ERR` |
| `err8` | ` ts_prox_recheck(to_tsvector('simple','a b'),'') ` | `ERR` |
| `bst1` | ` ts_prox_recheck(to_tsvector('simple','something here'),'something *') ` | `ERR` |

single quote is the literal-term delimiter: a raw apostrophe (`it's`) opens a literal that never closes, and `''` is an empty literal — both must raise.

| label | expression | expected |
| --- | --- | --- |
| `litErr1` | ` ts_prox_recheck(to_tsvector('simple','a b'), $$it's here$$) ` | `ERR` |
| `litErr2` | ` ts_prox_query($$''$$) ` | `ERR` |

a distance must be a non-empty run of digits. Anything else — embedded space, trailing junk, a sign, or empty — raises on BOTH implementations (no silent coercion to a default distance). `<-N>` stays the legitimate ordered operator; only a malformed body errors.

| label | expression | expected |
| --- | --- | --- |
| `dbad1` | ` ts_prox_query('a <5x> b') ` | `ERR` |
| `dbad2` | ` ts_prox_query('a < 5> b') ` | `ERR` |
| `dbad3` | ` ts_prox_query('a <~-5> b') ` | `ERR` |
| `dbad4` | ` ts_prox_query('a <> b') ` | `ERR` |
| `dbad5` | ` ts_prox_query('a <~> b') ` | `ERR` |

a proximity operand must be POSITIONAL — something with positions to measure against (a term/prefix/glob/regex/phrase, an OR of those, or a nested proximity that resolves to a span). The two non-positional booleans both raise, on either side, on both implementations, on every proximity operator (`<~N>`, `<-N>`, `<!~N>`, and the exact `<N>`/`<->`): • `&` (AND) — we do NOT silently distribute `(a & b) <~N> c` into `(a <~N> c) & (b <~N> c)` (two *independent* neighborhoods, rarely intended; over an exact op it forces one position, ~always false). • `!` (NOT) — "a is absent" has no position; lifting `(!a) <~N> c` to `!(a <~N> c)` silently flips ∃ to ¬∃, and the natural reading is the occurrence-level `c <!~N> a` (a *different* answer). The check is RECURSIVE, so an `&`/`!` buried in an OR (`bgErr9`/`notErr4`) or in a nested proximity (`notErr3`) is caught at normalize time too, not mis-evaluated downstream. `|` (OR) by contrast IS positional (a position-set union) and stays a valid `<~N>`/`<-N>` operand (the `bg_*` / `comp_*` cases) — though the phrase/exact operators (`<->`, `<N>`) need a SINGLE atom, so they reject even an OR group. The legitimate spellings: `(a <~N> c) & (b <~N> c)` or `(a <~M> b) <~N> c`; `!(a <~N> c)` or `c <!~N> a`.

| label | expression | expected |
| --- | --- | --- |
| `bgErr1` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a & b) <~5> c') ` | `ERR` |
| `bgErr2` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a & b) <-5> c') ` | `ERR` |
| `bgErr3` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a & b) <!~5> c') ` | `ERR` |
| `bgErr4` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a & b) <2> c') ` | `ERR` |
| `bgErr5` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'c <~5> (a & b)') ` | `ERR` |
| `bgErr6` | ` ts_prox_recheck(to_tsvector('simple','p q r s t'),'("p q" & "r s") <~2> t') ` | `ERR` |
| `bgErr7` | ` ts_prox_query('(a & b) <~5> c') ` | `ERR` |
| `bgErr8` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a \| b) <-> c') ` | `ERR` |
| `bgErr9` | ` ts_prox_recheck(to_tsvector('simple','a b c d'),'(a \| (b & c)) <~5> d') ` | `ERR` |
| `notErr1` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(!a) <~5> c') ` | `ERR` |
| `notErr2` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'a <~5> !c') ` | `ERR` |
| `notErr3` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'a <~5> (b <~5> !c)') ` | `ERR` |
| `notErr4` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(a \| !b) <~5> c') ` | `ERR` |
| `notErr5` | ` ts_prox_recheck(to_tsvector('simple','a b c'),'(!a) <!~5> c') ` | `ERR` |
| `notErr6` | ` ts_prox_query('(!a) <~5> c') ` | `ERR` |
| `notOk1` | ` ts_prox_recheck(to_tsvector('simple','a x x x x x x b'),'!(a <~2> b)') ` | `true` |
| `notOk2` | ` ts_prox_recheck(to_tsvector('simple','a b z z z z b'),'a <!~5> b') ` | `false` |
| `notOk3` | ` ts_prox_recheck(to_tsvector('simple','a b z z z z z c'),'a <~5> (b <!~5> c)') ` | `true` |

composition rules, pinned as IDENTITIES (`formA = formB` evaluates `true` on both ports). These state the exact rule for how each operand kind composes — distinct from the value cases above, which pin a specific doc's answer. The docs are chosen to be DISCRIMINATING: `comp_or_dist` uses `a x x c x x b` (a@1 c@4 b@7, where a and b are each >N from c but the span straddles c), so a span implementation would make the two sides disagree — the identity would break. `comp_span_ne_or` is the converse: a proximity group is a span, NOT the OR distribution, so on that same doc the two forms DIFFER (`<>` is `true`).

| label | expression | expected |
| --- | --- | --- |
| `comp_or_dist` | ` ts_prox_recheck(to_tsvector('simple','a x x c x x b'),'(a \| b) <~2> c') = ts_prox_recheck(to_tsvector('simple','a x x c x x b'),'(a <~2> c) \| (b <~2> c)') ` | `true` |
| `comp_or_sym` | ` ts_prox_recheck(to_tsvector('simple','a c b'),'(a \| b) <~2> c') = ts_prox_recheck(to_tsvector('simple','a c b'),'c <~2> (a \| b)') ` | `true` |
| `comp_chain_assoc` | ` ts_prox_recheck(to_tsvector('simple','a x b x c'),'a <~2> b <~2> c') = ts_prox_recheck(to_tsvector('simple','a x b x c'),'(a <~2> b) <~2> c') ` | `true` |
| `comp_span_ne_or` | ` ts_prox_recheck(to_tsvector('simple','a x x c x x b'),'(a <~9> b) <~2> c') <> ts_prox_recheck(to_tsvector('simple','a x x c x x b'),'(a \| b) <~2> c') ` | `true` |

full pipeline: index selection AND recheck (the decomposed two-clause form)

| label | expression | expected |
| --- | --- | --- |
| `f1` | ` to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_recheck(to_tsvector('simple','a x b'),'a <~2> b') ` | `true` |
| `f2` | ` to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_recheck(to_tsvector('simple','a x y z b'),'a <~2> b') ` | `false` |
| `f3` | ` to_tsvector('simple','a alone') @@ ts_prox_query('a <~2> b') AND ts_prox_recheck(to_tsvector('simple','a alone'),'a <~2> b') ` | `false` |
| `f4` | ` to_tsvector('simple','the study of biology') @@ ts_prox_query('study <~3> *ology') AND ts_prox_recheck(to_tsvector('simple','the study of biology'),'study <~3> *ology') ` | `true` |
| `f5` | ` to_tsvector('simple','the study of cats') @@ ts_prox_query('study <~3> *ology') AND ts_prox_recheck(to_tsvector('simple','the study of cats'),'study <~3> *ology') ` | `false` |
| `f6` | ` to_tsvector('simple','ssn 123456789 here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_recheck(to_tsvector('simple','ssn 123456789 here'),'ssn <~3> ##[0-9]{9}##') ` | `true` |
| `f7` | ` to_tsvector('simple','ssn abc here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_recheck(to_tsvector('simple','ssn abc here'),'ssn <~3> ##[0-9]{9}##') ` | `false` |
| `op1` | ` to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_recheck(to_tsvector('simple','a x b'),'a <~2> b') ` | `true` |
| `op2` | ` to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_recheck(to_tsvector('simple','a x y z b'),'a <~2> b') ` | `false` |

positional predicate functions

| label | expression | expected |
| --- | --- | --- |
| `nw1` | ` ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',3) ` | `true` |
| `nw2` | ` ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',6) ` | `false` |
| `nw3` | ` ts_prox_not_within(to_tsvector('simple','confidential report only'),'confidential','email',5) ` | `true` |
| `pre1` | ` ts_prox_pre(to_tsvector('simple','quick brown fox'),'quick','fox',2) ` | `true` |
| `pre2` | ` ts_prox_pre(to_tsvector('simple','quick brown fox'),'fox','quick',2) ` | `false` |
| `w1` | ` ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',2) ` | `true` |
| `w2` | ` ts_prox_within(to_tsvector('simple','the quick brown fox'),'fox','quick',2) ` | `true` |
| `w3` | ` ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',1) ` | `false` |
| `pos1` | ` ts_prox_positions(to_tsvector('simple','apple apple orange'),'apple') ` | `{1,2}` |
| `pos2` | ` ts_prox_positions(to_tsvector('simple','apple'),'zzz') ` | `{}` |
| `pos3` | ` ts_prox_positions_prefix(to_tsvector('simple','apple apply orange'),'appl') ` | `{1,2}` |

same-occurrence chain (ts_prox_chain)

| label | expression | expected |
| --- | --- | --- |
| `win1` | ` ts_prox_chain(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[2,2]) ` | `true` |
| `win2` | ` ts_prox_chain(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[1,1]) ` | `false` |
| `win3` | ` ts_prox_chain(to_tsvector('simple','one two three four five six seven orange nine apple eleven banana'),ARRAY['apple','banana','orange'],ARRAY[2,2]) ` | `false` |
| `winErr` | ` ts_prox_chain(to_tsvector('simple','a b'),ARRAY['a','b'],ARRAY[1,2]) ` | `ERR` |
| `wsp1` | ` ts_prox_chain(to_tsvector('simple','a 2 b 4 5 c'),ARRAY['a','c','b'],ARRAY[6,1]) ` | `false` |
| `wsp2` | ` ts_prox_chain(to_tsvector('simple','a 2 b 4 5 c'),ARRAY['a','b','c'],ARRAY[2,3]) ` | `true` |
| `wpin1` | ` ts_prox_chain(to_tsvector('simple','alpha beta x x x x x x beta gamma'),ARRAY['alpha','beta','gamma'],ARRAY[2,2]) ` | `false` |

`@@ ts_prox_query` index selection (skeleton drives the GIN index)

| label | expression | expected |
| --- | --- | --- |
| `se1` | ` to_tsvector('simple','a b') @@ ts_prox_query('a <~5> b') ` | `true` |
| `se2` | ` to_tsvector('simple','a') @@ ts_prox_query('a <~5> b') ` | `false` |
| `se3` | ` to_tsvector('simple','a') @@ ts_prox_query('a \| b') ` | `true` |
| `se4` | ` to_tsvector('simple','c') @@ ts_prox_query('a \| b') ` | `false` |
| `se5` | ` to_tsvector('simple','a c') @@ ts_prox_query('(a \| b) <~5> c') ` | `true` |
| `se6` | ` to_tsvector('simple','b c') @@ ts_prox_query('(a \| b) <~5> c') ` | `true` |
| `se7` | ` to_tsvector('simple','a') @@ ts_prox_query('(a \| b) <~5> c') ` | `false` |
| `se10` | ` to_tsvector('simple','confidential') @@ ts_prox_query('confidential <!~5> email') ` | `true` |
| `se11` | ` to_tsvector('simple','email') @@ ts_prox_query('confidential <!~5> email') ` | `false` |
| `se12` | ` to_tsvector('simple','foo bar') @@ ts_prox_query('foo & !bar') ` | `true` |
| `se13` | ` to_tsvector('simple','baz') @@ ts_prox_query('foo & !bar') ` | `false` |
| `se14` | ` to_tsvector('simple','quick fox') @@ ts_prox_query('"quick fox"') ` | `true` |
| `se15` | ` to_tsvector('simple','quick brown fox') @@ ts_prox_query('"quick fox"') ` | `false` |
| `se16` | ` to_tsvector('simple','apple') @@ ts_prox_query('appl*') ` | `true` |
| `se17` | ` to_tsvector('simple','orange') @@ ts_prox_query('appl*') ` | `false` |
| `se18` | ` to_tsvector('simple','running tests') @@ ts_prox_query('te?t') ` | `true` |

skeleton lowering (`ts_prox_query_skeleton` exact text)

| label | expression | expected |
| --- | --- | --- |
| `sk1` | ` ts_prox_query_skeleton('a <~5> b') ` | `('a' & 'b')` |
| `sk3` | ` ts_prox_query_skeleton('"quick fox"') ` | `('quick' <-> 'fox')` |
| `sk4` | ` ts_prox_query_skeleton('appl*') ` | `'appl':*` |
| `sk5` | ` ts_prox_query_skeleton('a <2> b') ` | `('a' <2> 'b')` |
| `sk6` | ` ts_prox_query_skeleton('"a b" <~5> c') ` | `(('a' <-> 'b') & 'c')` |
| `sk7` | ` ts_prox_query_skeleton('(a \| b) <~5> c') ` | `(('a' \| 'b') & 'c')` |
| `sk8` | ` ts_prox_query_skeleton('foo & !bar') ` | `'foo'` |
| `sk9` | ` ts_prox_query_skeleton('confidential <!~5> email') ` | `'confidential'` |
| `sk10` | ` ts_prox_query_skeleton('te?t') ` | `'te':*` |
| `sk11` | ` ts_prox_query_skeleton('"appl* pie"') ` | `('appl':* <-> 'pie')` |
| `sk12` | ` ts_prox_query_skeleton('"*ology class"') ` | `'class'` |
| `sk13` | ` ts_prox_query_skeleton('((a <~5> b) <~10> c) <!~3> d') ` | `(('a' & 'b') & 'c')` |
| `sk14` | ` ts_prox_query_skeleton('a & b \| c') ` | `(('a' & 'b') \| 'c')` |
| `sk15` | ` ts_prox_query_skeleton('a <-> b <-> c') ` | `('a' <-> 'b' <-> 'c')` |
| `sk16` | ` ts_prox_query_skeleton('a <!~1> b') ` | `'a'` |

native pushdown lowering (`ts_prox_query_native` / `ts_prox_query_exact` exact text) — the recheck-DROPPING form, built with `tsqueryin` so the lexemes are VERBATIM (unlike the `to_tsquery`-lowered skeleton above). A single-quoted (or bare) term that contains a parser-splitting char — hyphen, apostrophe — must stay ONE lexeme and must NOT be re-tokenized into a parts-phrase; the 2-arg `simple` lexer lowercases ASCII only. The match-table can't reach this (its docs always come from `to_tsvector('simple', …)`, which lays the split parts out consecutively so a re-expanded phrase still hits), so it is pinned here as exact text and against a literal compound-only `::tsvector`.

| label | expression | expected |
| --- | --- | --- |
| `nv1` | ` ts_prox_query_native($$'a-b-c'$$) ` | `'a-b-c'` |
| `nv2` | ` ts_prox_query_native($$'a-b-c-d-e-f'$$) ` | `'a-b-c-d-e-f'` |
| `nv3` | ` ts_prox_query_native($$'it''s'$$) ` | `'it''s'` |
| `nv4` | ` ts_prox_query_native($$'a-b-c' <-> z$$) ` | `'a-b-c' <-> 'z'` |
| `nv5` | ` ts_prox_query_native('a-b-c') ` | `'a-b-c'` |
| `nv6` | ` ts_prox_query_native($$'Café'$$) ` | `'café'` |
| `nv7` | ` ts_prox_query_exact($$'a-b-c'$$) ` | `'a-b-c'` |

…and end-to-end against a vector that stores the compound as a SINGLE lexeme (no split parts — the `proxquery_to_tsvector` / hand-built shape): the literal matches, and the native and exact `@@` both equal the recheck (pre-fix the `to_tsquery` re-expansion missed this).

| label | expression | expected |
| --- | --- | --- |
| `nv8` | ` ts_prox_recheck($$'well-known':1 'fact':2$$::tsvector, $$'well-known'$$) ` | `true` |
| `nv9` | ` $$'well-known':1 'fact':2$$::tsvector @@ ts_prox_query_native($$'well-known'$$) ` | `true` |
| `nv10` | ` $$'well-known':1 'fact':2$$::tsvector @@ ts_prox_query_exact($$'well-known'$$) ` | `true` |

distance clamp `<0>` = same position, on a literal co-located tsvector. The whole
distance-0 family (`<~0>`, `<0>`, `<-0>`) means "same position": only superimposition puts
two distinct lexemes on one slot, and it does so by collapsing an adjacent pair, so a
co-located pair reads as ordered-adjacent — ordered `<-N>` (any N, either direction) matches
it, and the `<!-N>` complement calls it near (not isolated).

| label | expression | expected |
| --- | --- | --- |
| `z0b` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'a <~0> b') ` | `true` |
| `z0c` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'a <0> b') ` | `true` |
| `z0e` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'a <-0> b') ` | `true` |
| `z0g` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'a <-1> b') ` | `true` |
| `z0h` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'b <-1> a') ` | `true` |
| `z0i` | ` ts_prox_recheck($$'a':1 'b':1$$::tsvector,'a <!-1> b') ` | `false` |
| `z0j` | ` ts_prox_recheck($$'a':1 'b':1 'c':3$$::tsvector,'(a <-1> b) <~5> c') ` | `true` |
| `z0f` | ` ts_prox_query_skeleton('a <0> b') ` | `('a' <0> 'b')` |

distance saturation: a large or overflowing distance clamps to MAX (16383) — it does NOT error. The clamp is observable through the phrase-distance skeleton (within/pre lower to `&`, hiding N); `<16384>` (just over), an 8-digit value, and a value past i32 all collapse to the same `<16383>`, and a huge `<~N>` still matches (saturates, not errors).

| label | expression | expected |
| --- | --- | --- |
| `dsat1` | ` ts_prox_query_skeleton('a <16383> b') ` | `('a' <16383> 'b')` |
| `dsat2` | ` ts_prox_query_skeleton('a <16384> b') ` | `('a' <16383> 'b')` |
| `dsat3` | ` ts_prox_query_skeleton('a <99999999> b') ` | `('a' <16383> 'b')` |
| `dsat4` | ` ts_prox_query_skeleton('a <999999999999> b') ` | `('a' <16383> 'b')` |
| `dsat5` | ` ts_prox_recheck(to_tsvector('simple','a x b'),'a <~999999> b') ` | `true` |

single-quoted literal terms (the `''` escape; no operator/glob meaning) matched verbatim against a literal tsvector — shared DSL behavior on both implementations. `'it''s'` resolves to the lexeme it's; an apostrophe-stripped/prefix tsvector misses.

| label | expression | expected |
| --- | --- | --- |
| `litq1` | ` ts_prox_recheck($$'it''s':1$$::tsvector, $$'it''s'$$) ` | `true` |
| `litq2` | ` ts_prox_recheck($$'its':1 'it':2$$::tsvector, $$'it''s'$$) ` | `false` |
| `litq3` | ` ts_prox_recheck($$'a*b':1$$::tsvector, $$'a*b'$$) ` | `true` |

non-ASCII surface coverage: position accessor, prefix scan, skeleton lowering. Locale-robust (no uppercase accents); see docs/CONFIG_AWARE.md for the uppercase-accent / config-aware lexing discussion.

| label | expression | expected |
| --- | --- | --- |
| `uc1` | ` ts_prox_positions(to_tsvector('simple','le café est bon'),'café') ` | `{2}` |
| `uc2` | ` ts_prox_positions(to_tsvector('simple','中文 文档 搜索'),'中文') ` | `{1}` |
| `uc3` | ` ts_prox_query_skeleton('中文 <~2> 搜索') ` | `('中文' & '搜索')` |
| `uc4` | ` ts_prox_positions_prefix(to_tsvector('simple','café cafétéria caffeine'),'café') ` | `{1,2}` |

config-aware (3-arg): query terms resolved through the column's text-search config via to_tsvector(cfg, term). Built-in 'english' (stemming) keeps these locale-independent and runnable on both implementations. The 2-arg simple forms are unchanged; the headline is a SURFACE query term matching a stored STEM.

| label | expression | expected |
| --- | --- | --- |
| `cfg1` | ` ts_prox_recheck(to_tsvector('english','the running shoes'),'running <~2> shoes','english') ` | `true` |
| `cfg2` | ` ts_prox_recheck(to_tsvector('english','the running shoes'),'run <~2> shoe','english') ` | `true` |
| `cfg3` | ` ts_prox_recheck(to_tsvector('english','the walking shoes'),'running <~2> shoes','english') ` | `false` |
| `cfg4` | ` ts_prox_query('running <~2> shoes','english')::text ` | `'run' & 'shoe'` |
| `cfg5` | ` to_tsvector('english','the running shoes') @@ ts_prox_query('running <~2> shoes','english') ` | `true` |
| `cfg6` | ` to_tsvector('english','the running shoes') @@ ts_prox_query('running <~2> shoes','english') AND ts_prox_recheck(to_tsvector('english','the running shoes'),'running <~2> shoes','english') ` | `true` |
| `cfg7` | ` ts_prox_recheck(to_tsvector('english','quick brown foxes jumped'),'fox <~2> jump','english') ` | `true` |
| `cfg8` | ` ts_prox_recheck(to_tsvector('english','the running shoes'),'"running shoes"','english') ` | `true` |
| `cfg9` | ` ts_prox_recheck(to_tsvector('english','the running shoes'),'walking <~2> shoes','english') ` | `false` |

the non-positional-operand rule (`bgErr*`/`notErr*`) fires through the 3-arg config path too — the rejection is in shared normalization, before any config resolution.

| label | expression | expected |
| --- | --- | --- |
| `cfgErrAnd` | ` ts_prox_recheck(to_tsvector('english','a b c'),'(a & b) <~5> c','english') ` | `ERR` |
| `cfgErrNot` | ` ts_prox_recheck(to_tsvector('english','a b c'),'(!a) <~5> c','english') ` | `ERR` |

## Match cases

Recheck pairs run as `ts_prox_recheck(to_tsvector('simple', doc), query)`.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `c1` | `the quick brown fox jumps` | `"quick brown" <~3> jumps` | `true` |
| `c2` | `the quick brown fox jumps` | `"quick brown" <~1> jumps` | `false` |
| `c3` | `alpha beta x gamma delta` | `"alpha beta" <~3> "gamma delta"` | `true` |
| `c4` | `quick brown z z z z z z email` | `"quick brown" <!~3> email` | `true` |
| `c5` | `quick brown email` | `"quick brown" <!~3> email` | `false` |
| `c6` | `the apple pie` | `"appl* pie"` | `true` |
| `c7` | `the orange pie` | `"appl* pie"` | `false` |
| `c8` | `the biology class` | `"*ology class"` | `true` |
| `c9` | `the geography class` | `"*ology class"` | `false` |
| `c10` | `the best test class` | `"te?t class"` | `true` |
| `c11` | `the best tense class` | `"te?t class"` | `false` |
| `c12` | `the biology class` | `*ology <-> class` | `true` |
| `g1` | `this text is confidential` | `*ial` | `true` |
| `g2` | `this text is confidential` | `con*ial` | `true` |
| `g3` | `this text is public` | `con*ial` | `false` |
| `g4` | `pick the best test` | `te?t` | `true` |
| `g5` | `pick the best tense` | `te?t` | `false` |
| `g6` | `we love c sharp` | `'c'` | `true` |
| `g7` | `we love rust` | `'c'` | `false` |
| `gr2` | `a z z z z z z z z z z b c` | `a & (b <~5> c)` | `true` |
| `gr3` | `a z z z z z c` | `(a \| b) <~5> c` | `false` |
| `gr4` | `a z z z z z c` | `a \| (b <~5> c)` | `true` |
| `gr5` | `c alone` | `a & b \| c` | `true` |
| `gr6` | `c alone` | `a & (b \| c)` | `false` |
| `gr7` | `a x b` | `a <-5> b` | `true` |
| `gr8` | `a x b` | `b <-5> a` | `false` |
| `gr9` | `a b z z z z z z b` | `a <!~5> b` | `false` |
| `gr10` | `a b z z z z z z b` | `b <!~5> a` | `true` |
| `m1` | `a x b` | `a <~2> b` | `true` |
| `m2` | `a x y b` | `a <~2> b` | `false` |
| `m3` | `a x y b` | `a <~3> b` | `true` |
| `m4` | `a x b` | `a <-2> b` | `true` |
| `m5` | `b x a` | `a <-2> b` | `false` |
| `m6` | `a x b` | `a <2> b` | `true` |
| `m7` | `a x y b` | `a <2> b` | `false` |
| `m8` | `a b` | `a <-> b` | `true` |
| `m9` | `email confidential foo bar baz qux confidential` | `confidential <!~5> email` | `true` |
| `m10` | `email confidential confidential email` | `confidential <!~5> email` | `false` |
| `m11` | `price foo discount` | `price <!-5> discount` | `false` |
| `m12` | `discount foo price` | `price <!-5> discount` | `true` |
| `m13` | `discount foo price` | `price <!~5> discount` | `false` |
| `nw_pre_b` | `a b x x a` | `a <!~1> b` | `true` |
| `nw_pre_nob` | `a c` | `a <!~1> b` | `true` |
| `m16` | `alpha x beta x gamma` | `alpha <~2> beta <~2> gamma` | `true` |
| `m17` | `alpha x x x beta x x x gamma` | `alpha <~2> beta <~2> gamma` | `false` |
| `m18` | `alpha beta x x x x x x beta gamma` | `alpha <~2> beta <~2> gamma` | `false` |
| `n1` | `a b x c z z z z d` | `("a b" <~5> c) <~10> d` | `true` |
| `n2` | `a b x c z z z z z z z z z z d` | `("a b" <~5> c) <~10> d` | `false` |
| `n3` | `a b c` | `((a <~5> b) <~10> c) <!~3> d` | `true` |
| `o1` | `the cat sat` | `(cat \| dog) <~2> sat` | `true` |
| `o2` | `the dog sat` | `(cat \| dog) <~2> sat` | `true` |
| `o3` | `the bird sat` | `(cat \| dog) <~2> sat` | `false` |
| `o4` | `cat z z z z z email` | `(cat \| dog) <!~2> email` | `true` |
| `r1` | `call me at 123456789 today` | `##[0-9]{9}##` | `true` |
| `r2` | `call me at 12345 today` | `##[0-9]{9}##` | `false` |
| `r3` | `the colour is nice` | `##colou?r##` | `true` |
| `r4` | `the color is nice` | `##colou?r##` | `true` |
| `dist1` | `a b c` | `a <~2> c` | `true` |
| `dist2` | `a b c` | `c <~2> a` | `true` |
| `dist3` | `a b c` | `a <~1> c` | `false` |
| `dist4` | `a b c` | `c <~1> a` | `false` |
| `shp1` | `privileged and confidential` | `confidential <!~5> "privileged and confidential"` | `false` |
| `shp2` | `privileged and confidential w w w w w w w w confidential` | `confidential <!~5> "privileged and confidential"` | `true` |
| `shp3` | `privileged and confidential foo confidential` | `confidential <!~5> "privileged and confidential"` | `false` |
| `cs2` | `the apple pie` | `appl:*` | `true` |
| `cs4` | `apple pie` | `appl:* <~2> pie` | `true` |
| `cs5` | `apple` | `apple*` | `true` |
| `cs6` | `applesauce` | `apple*` | `true` |
| `cs7` | `appl` | `apple*` | `false` |
| `bs1` | `a b` | `'a\b'` | `false` |
| `bs2` | `ab` | `'a\b'` | `false` |
| `ra1` | `the colourful flag` | `##colou?r##` | `false` |
| `ra2` | `the colour is nice` | `##^colou?r$##` | `true` |
| `ra3` | `the cat sat` | `##cat\|dog##` | `true` |
| `ra4` | `category dogma` | `##cat\|dog##` | `false` |
| `ra5` | `the colour is nice` | `##^colou?r##` | `true` |
| `ra6` | `the colour is nice` | `##colou?r$##` | `true` |
| `z0a` | `a b` | `a <~0> b` | `false` |
| `z0d` | `a b` | `a <0> b` | `false` |
| `span1` | `a 2 b 4 5 c` | `(a <~5> c) <~1> b` | `true` |
| `span2` | `a 2 b 4 5 c` | `(a <~5> c) <~2> b` | `true` |
| `span3` | `a x c x x g x x x a x c` | `(a <~2> c) <~1> g` | `false` |
| `span4` | `a x c x x g x x x a x c` | `(a <~2> c) <~1> x` | `true` |
| `chstrict` | `one two three four five six seven orange nine apple eleven banana` | `apple <~2> banana <~2> orange` | `true` |

An `|` (OR) group is a valid proximity operand and DISTRIBUTES — `(a | b) <~N> c` ≡
`(a <~N> c) | (b <~N> c)` (either operand independently within-N of `c`) — because OR is
positional (a position-set union). It does NOT form a span; that's the *proximity*-group
rule below. The headline discriminator is `bg_or_dist` vs `bg_prox_span` on the SAME doc
`a x x c x x b` (a@1 c@4 b@7): the boolean `(a | b) <~2> c` is **false** (neither `a` nor `b`
is within 2 of `c`), whereas the proximity group `(a <~9> b) <~2> c` is **true** (its span
`[1,7]` contains `c`). Each OR leaf may itself be a phrase (resolved to its edge-to-edge
span). An `&` (AND) group, by contrast, is NOT positional and raises on every proximity
operator — it is never silently distributed (the `bgErr*` expression cases).

| label | doc | query | expected |
| --- | --- | --- | --- |
| `bg_or_dist` | `a x x c x x b` | `(a \| b) <~2> c` | `false` |
| `bg_prox_span` | `a x x c x x b` | `(a <~9> b) <~2> c` | `true` |
| `bg_ph_or` | `p q x x x r s t` | `("p q" \| "r s") <~2> t` | `true` |

Compound proximity operands resolve to their *span*, and the distance is measured **edge-to-edge**
(nearest edge to nearest edge). A phrase `"a b"` spans `[start..end]`; a nested `(A <~X> B)` spans
the `[min..max]` it covers per occurrence. So `(A <~X> B) <~Y> (C <~Z> D)` matches when the two
spans come within Y of each other (overlapping spans ⇒ distance 0), while a failed inner threshold
(X or Z) drops the whole match. An inner threshold only *gates* its pair — it never widens the span,
which is always the matched tokens' actual `[min..max]`. So a loose inner `<~10>` over adjacent
tokens still yields a 1-wide span (`gg_inner_gate`), whereas tokens that are genuinely far apart (but
still within the inner threshold) really do span that range and can reach the other group
(`gg_inner_span`). `<~Y>` is symmetric. Phrase-vs-phrase: in `alpha beta x gamma delta` the near
edges are `beta@2` and `gamma@4` (gap 2), so `<~2>` hits and `<~1>` misses — only the *nearest* edge
of each phrase needs to fall in the window, not its far end.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `pp_hit` | `alpha beta x gamma delta` | `"alpha beta" <~2> "gamma delta"` | `true` |
| `pp_miss` | `alpha beta x gamma delta` | `"alpha beta" <~1> "gamma delta"` | `false` |
| `pp_rev` | `alpha beta x gamma delta` | `"gamma delta" <~2> "alpha beta"` | `true` |
| `pt_left` | `x a b` | `x <~1> "a b"` | `true` |
| `pt_left0` | `x a b` | `x <~0> "a b"` | `false` |
| `gg_hit` | `a b q q q c d` | `(a <~1> b) <~4> (c <~1> d)` | `true` |
| `gg_miss` | `a b q q q c d` | `(a <~1> b) <~3> (c <~1> d)` | `false` |
| `gg_inner` | `a b q q q c q d` | `(a <~1> b) <~4> (c <~1> d)` | `false` |
| `gg_overlap` | `a c b d` | `(a <~3> b) <~1> (c <~3> d)` | `true` |
| `gg_inner_gate` | `a b q q q c d` | `(a <~1> b) <~3> (c <~10> d)` | `false` |
| `gg_inner_gate_hit` | `a b q q q c d` | `(a <~1> b) <~4> (c <~10> d)` | `true` |
| `gg_inner_span` | `a b c q q q q q q q d` | `(a <~1> b) <~3> (c <~10> d)` | `true` |

Not-within with a compound operand reasons per WHOLE occurrence (this is the non-obvious one):
`A <!~N> B` is true when some occurrence of `A` has NO `B` within N of *any part of its span*. So a
phrase/group `A` is "near" `B` if its **nearest** edge is within N — touching `B` with one end counts
as near (the whole occurrence is not isolated), even though its far end is beyond N. (For a plain
term operand this is the familiar per-position rule — a term is its own span.) `email a b`: the
phrase `"a b"` spans `[2,3]`; `email@1` is within 1 of the near edge `a@2`, so `"a b" <!~1> email` is
**false** — NOT "no email near", because the phrase touches the email.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `nw_touch_start` | `email a b` | `"a b" <!~1> email` | `false` |
| `nw_touch_end` | `a b email` | `"a b" <!~1> email` | `false` |
| `nw_far` | `a b z z z z email` | `"a b" <!~2> email` | `true` |
| `nw_absent` | `a b c` | `"a b" <!~3> email` | `true` |
| `nw_grp_far` | `x a b y z email` | `(a <~1> b) <!~2> email` | `true` |
| `nw_grp_touch` | `a b email` | `(a <~1> b) <!~1> email` | `false` |

Operator combinations — proximity results combined at the document (boolean) level, ordered
`<-N>`/`<!-N>` over compound operands, and a regex as a proximity operand. (The prefilter drops the
negated/keyless side, so `!(prox)` and `##re##` ride on the recheck; the index-path test confirms
they're still not excluded.) `<-N>` is order-sensitive — `ord_ph_rev` has the phrases reversed.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `bp_and` | `a b c d` | `(a <~2> b) & (c <~2> d)` | `true` |
| `bp_and_miss` | `a b q c q q q d` | `(a <~2> b) & (c <~2> d)` | `false` |
| `bp_or` | `z only here` | `(a <~2> b) \| z` | `true` |
| `bp_not` | `z a q q b` | `z & !(a <~2> b)` | `true` |
| `bp_not_miss` | `z a b` | `z & !(a <~2> b)` | `false` |
| `ord_ph` | `a b x c d` | `"a b" <-2> "c d"` | `true` |
| `ord_ph_rev` | `c d x a b` | `"a b" <-2> "c d"` | `false` |
| `ord_grp` | `a b x c d` | `(a <~1> b) <-2> (c <~1> d)` | `true` |
| `ord_nw_after` | `a b email` | `"a b" <!-2> email` | `false` |
| `ord_nw_before` | `email a b` | `"a b" <!-2> email` | `true` |
| `rx_prox` | `cat and dog` | `cat <~2> ##do.##` | `true` |
| `rx_prox_miss` | `cat and bird` | `cat <~2> ##do.##` | `false` |
| `gx_infix` | `the cat has fur` | `cat <~2> f*r` | `true` |
| `gx_infix_miss` | `the cat sat down` | `cat <~2> f*r` | `false` |
| `gx_infix_left` | `fur near cat` | `f*r <~2> cat` | `true` |
| `gx_qmark` | `the best test now` | `best <~2> te?t` | `true` |
| `gx_qmark_miss` | `the best tense now` | `best <~2> te?t` | `false` |
| `rx_left` | `cat and dog` | `##do.## <~2> cat` | `true` |
| `rx_left_miss` | `cat and bird` | `##do.## <~2> cat` | `false` |
| `or_mixed_operand` | `the study of biology` | `(stud* \| ##zzz##) <~3> biology` | `true` |
| `or_both_sides` | `a x c` | `(a \| b) <~2> (c \| d)` | `true` |

non-ASCII: accented Latin and CJK. Locale-INDEPENDENT (no uppercase to case-fold), so they agree on any CI collation. Two things are deliberately NOT asserted here because their tokenization is locale-dependent (see docs/CONFIG_AWARE.md): uppercase-accent case-folding, and emoji (a token under C, dropped under en_US.UTF-8).

| label | doc | query | expected |
| --- | --- | --- | --- |
| `u1` | `le café est bon` | `café` | `true` |
| `u2` | `le café est bon` | `café <~2> bon` | `true` |
| `u3` | `le café est bon` | `café <~1> bon` | `false` |
| `u4` | `résumé and resume` | `résumé` | `true` |
| `u5` | `plain resume here` | `résumé` | `false` |
| `u6` | `el niño pequeño` | `niño` | `true` |
| `u7` | `el niño pequeño` | `nino` | `false` |
| `u8` | `中文 文档 搜索` | `中文` | `true` |
| `u9` | `中文 文档 搜索` | `中文 <~2> 搜索` | `true` |
| `u10` | `中文 文档 搜索` | `中文 <~1> 搜索` | `false` |
| `u11` | `日本語` | `日本` | `false` |

Multi-hyphen words generalize the single-hyphen rule (`cs_hyph_*` in the config
cases): the stock parser emits the COMPOUND at one position, then EVERY part at
consecutive positions — `a-b-c` → `a-b-c`:1 `a`:2 `b`:3 `c`:4, and `a-b-c-d-e-f`
→ `a-b-c-d-e-f`:1 then `a`..`f`:2..7. So all the bare parts are mutually adjacent
(`a <-> b`, `b <-> c`), the compound precedes part `a` by one, and a `"a b c"`
phrase over the parts hits. The single-quoted whole compound (`'a-b-c'`) matches
the compound lexeme verbatim. `<->`/`<N>` distances are pinned with boundary pairs.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `mh_term` | `a-b-c` | `'a-b-c'` | `true` |
| `mh_ab` | `a-b-c` | `a <-> b` | `true` |
| `mh_bc` | `a-b-c` | `b <-> c` | `true` |
| `mh_ac0` | `a-b-c` | `a <-> c` | `false` |
| `mh_ac1` | `a-b-c` | `a <2> c` | `true` |
| `mh_phrase` | `a-b-c` | `"a b c"` | `true` |
| `mh_chain` | `a-b-c` | `a <-> b <-> c` | `true` |
| `mh_comp_far` | `a-b-c` | `'a-b-c' <-> b` | `false` |

Six-part compound (`a-b-c-d-e-f` → compound:1, parts `a`..`f` at 2..7): the whole
compound is one verbatim lexeme, the six parts form a consecutive phrase, and the
first-to-last part distance is 5 (`a <-> f` misses, `a <5> f` hits, `<~5>` is
symmetric). OR-ing the compound into a near-term reaches it where the bare part can't.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `mh6_term` | `a-b-c-d-e-f` | `'a-b-c-d-e-f'` | `true` |
| `mh6_phrase` | `a-b-c-d-e-f` | `"a b c d e f"` | `true` |
| `mh6_af0` | `a-b-c-d-e-f` | `a <-> f` | `false` |
| `mh6_af1` | `a-b-c-d-e-f` | `a <5> f` | `true` |
| `mh6_af_sym` | `a-b-c-d-e-f` | `a <~5> f` | `true` |
| `mh6_or` | `a-b-c-d-e-f` | `a <~1> (b \| 'a-b-c-d-e-f')` | `true` |

Multi-hyphen with surrounding context (`x a-b-c d` → `x`:1 `a-b-c`:2 `a`:3 `b`:4
`c`:5 `d`:6): the compound at position 2 pushes the parts one slot further from `x`
than they look (x→a = 2, not 1), while the compound itself is adjacent to `x` and
the last part `c` is adjacent to the trailing `d`.

| label | doc | query | expected |
| --- | --- | --- | --- |
| `mhx_x_a0` | `x a-b-c d` | `x <~1> a` | `false` |
| `mhx_x_a1` | `x a-b-c d` | `x <~2> a` | `true` |
| `mhx_x_comp` | `x a-b-c d` | `x <-> 'a-b-c'` | `true` |
| `mhx_cd` | `x a-b-c d` | `c <-> d` | `true` |
| `mhx_ad0` | `x a-b-c d` | `a <~2> d` | `false` |
| `mhx_ad1` | `x a-b-c d` | `a <~3> d` | `true` |

Longer phrases and phrase-to-phrase proximity (doc `the quick brown fox jumps over
the lazy dog`): a 3- and 4-word phrase, a near-miss where an interloper breaks it,
and two multi-word phrases measured edge-to-edge (near edges `fox`@4 and `lazy`@8,
gap 4) — symmetric `<~N>` and order-sensitive `<-N>` (reverse misses).

| label | doc | query | expected |
| --- | --- | --- | --- |
| `lp_p3` | `the quick brown fox jumps over the lazy dog` | `"quick brown fox"` | `true` |
| `lp_p4` | `the quick brown fox jumps over the lazy dog` | `"quick brown fox jumps"` | `true` |
| `lp_p_miss` | `the quick brown lazy fox jumps` | `"quick brown fox"` | `false` |
| `lp_pp0` | `the quick brown fox jumps over the lazy dog` | `"quick brown fox" <~3> "lazy dog"` | `false` |
| `lp_pp1` | `the quick brown fox jumps over the lazy dog` | `"quick brown fox" <~4> "lazy dog"` | `true` |
| `lp_pp_ord` | `the quick brown fox jumps over the lazy dog` | `"quick brown fox" <-4> "lazy dog"` | `true` |
| `lp_pp_rev` | `the quick brown fox jumps over the lazy dog` | `"lazy dog" <-4> "quick brown fox"` | `false` |
| `lp_long_ph` | `one two three four five six seven` | `"two three four five six"` | `true` |

Combination smoke tests — reasonable multi-operator queries a real user might write,
each with its hit/miss twin: boolean-of-proximity (`&`, `\|`, `!`), nested proximity
groups, a proximity span fed into not-within, and a degenerate prefix+suffix+boolean
mix. The point is that combinations don't error and both ports agree (and that
`ts_prox_search` equals the recheck — these all stay index-expressible).

| label | doc | query | expected |
| --- | --- | --- | --- |
| `cmb_and` | `the quick brown fox and the lazy dog` | `(quick <~3> fox) & (lazy <~2> dog)` | `true` |
| `cmb_and_miss` | `the quick brown fox sleeps soundly` | `(quick <~3> fox) & (lazy <~2> dog)` | `false` |
| `cmb_or` | `wear the cat hat today` | `(quick <~5> fox) \| (cat <~2> hat)` | `true` |
| `cmb_not` | `the quick brown fox jumps` | `(quick <~3> fox) & !cat` | `true` |
| `cmb_not_miss` | `the quick brown fox cat` | `(quick <~3> fox) & !cat` | `false` |
| `cmb_nest` | `a b q q c d e` | `(a <~3> b) <~5> (c <-> d)` | `true` |
| `cmb_nest_b` | `a b q q c d e` | `((a <~3> b) <~5> (c <-> d)) & e` | `true` |
| `cmb_nw` | `quick fox z z z z z cat` | `(quick <-3> fox) <!~5> cat` | `true` |
| `cmb_nw_hit` | `quick fox cat here` | `(quick <-3> fox) <!~5> cat` | `false` |
| `cmb_degen` | `study of microbiology in the lab report` | `(stud* <~3> *ology) & report & !exam` | `true` |
| `cmb_pfx_ph` | `the running shoes on sale` | `"runn* shoes" <~3> sale` | `true` |
| `cmb_mix` | `send the confidential report by email now` | `confidential <~2> report <!~5> email` | `false` |

## Config cases

The 3-arg config-aware recheck `ts_prox_recheck(to_tsvector(cfg, doc), query, cfg)`.
Rows whose `config` is `public.simple_unaccent` need the contrib `unaccent`
extension; the runner builds it best-effort and skips those rows if it is absent.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_acc_hit` | `simple` | `bien paré ici` | `*ré` | `true` |
| `cs_acc_miss` | `simple` | `bien pare ici` | `*ré` | `false` |
| `cs_acc_miss2` | `simple` | `bien paré ici` | `*re` | `false` |

simple: the 3-arg path folds a glob run through `cfg`, so an uppercase non-ASCII run is Unicode-lowercased (the 2-arg lexer is ASCII-only) — but the accent is preserved (folds CASE, not accent), so `*É` matches `café`, not `cafe`.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_case_hit` | `simple` | `un CAFÉ noir` | `*É` | `true` |
| `cs_case_acc` | `simple` | `un cafe noir` | `*É` | `false` |

ASCII globs are unaffected by the fold (regression guard for plain-ASCII users).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_ascii_g` | `simple` | `pick the best test` | `te?t` | `true` |
| `cs_ascii_p` | `simple` | `this text is confidential` | `con*ial` | `true` |
| `cs_ascii_pm` | `simple` | `this text is public` | `con*ial` | `false` |

verbatim fallback: a run that resolves to 0 or >1 lexemes (punctuated / host / alphanumeric) is kept as-is, so the glob behaves exactly as the 2-arg path would.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_fb_dot` | `simple` | `x foo.bar baz` | `foo.bar*` | `true` |
| `cs_fb_num` | `simple` | `an abc123 token` | `abc123*` | `true` |

phrase-embedded glob atoms fold too (the phrase atom is a glob node).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_ph_hit` | `simple` | `the biology class` | `"*ology class"` | `true` |
| `cs_ph_miss` | `simple` | `the geography class` | `"*ology class"` | `false` |

Hyphenated words: the parser emits the compound AND each part at CONSECUTIVE positions (`café-bar` → `café-bar`:2 `café`:3 `bar`:4), so the parts are adjacent to their neighbors. On plain `simple` proximity stays ACCENT-SENSITIVE: only the accented spelling of the part is adjacent to `bar` (config decides, as with globs).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_hw_hit` | `simple` | `le café-bar ferme` | `café <-> bar` | `true` |
| `cs_hw_miss` | `simple` | `le café-bar ferme` | `cafe <-> bar` | `false` |

Hyphenated position arithmetic: the parser emits the COMPOUND and each PART at consecutive positions, so `a b-c d` → a:1 b-c:2 b:3 c:4 d:5. The compound sitting at position 2 pushes the parts one slot further from `a` than they look — a→b = 2 (NOT 1), a→c = 3, a→d = 4 — while the two parts b,c are adjacent. Distances are pinned with boundary pairs (within N-1 misses, within N hits); `<~N>` is symmetric within distance, `<->` is ordered-adjacent (distance exactly 1).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_hyph_ab0` | `simple` | `a b-c d` | `a <~1> b` | `false` |
| `cs_hyph_ab1` | `simple` | `a b-c d` | `a <~2> b` | `true` |
| `cs_hyph_ac0` | `simple` | `a b-c d` | `a <~2> c` | `false` |
| `cs_hyph_ac1` | `simple` | `a b-c d` | `a <~3> c` | `true` |
| `cs_hyph_ad0` | `simple` | `a b-c d` | `a <~3> d` | `false` |
| `cs_hyph_ad1` | `simple` | `a b-c d` | `a <~4> d` | `true` |

the two parts are adjacent (the headline answer): `b <-> c` hits, the reverse misses (ordered), and `a <-> b` misses because the compound sits between them.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_hyph_bc` | `simple` | `a b-c d` | `b <-> c` | `true` |
| `cs_hyph_cb` | `simple` | `a b-c d` | `c <-> b` | `false` |
| `cs_hyph_ab_a` | `simple` | `a b-c d` | `a <-> b` | `false` |

Matching a hyphenated word as an OR of its forms. doc `a b c-d` → a:1 b:2 c-d:3 c:4 d:5. The bare PARTS are too far for `a <~2> …` (c is distance 3, d is 4), but the COMPOUND `c-d` sits at distance 2 — so OR-ing the compound in makes the proximity hit. This is the no-C way to "find `a` near the hyphenated word": lean on the compound lexeme, which the parser already places at the word's own position. (`c-d` lexes as a single term even unquoted, since `-` is a word char; the single quotes are just the explicit escape hatch for terms with special characters.)

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_cd_part_c` | `simple` | `a b c-d` | `a <~2> c` | `false` |
| `cs_cd_part_d` | `simple` | `a b c-d` | `a <~2> d` | `false` |
| `cs_cd_compound` | `simple` | `a b c-d` | `a <~2> 'c-d'` | `true` |
| `cs_cd_or` | `simple` | `a b c-d` | `a <~2> (c \| d \| 'c-d')` | `true` |

and the plain boolean AND of a term with a hyphenated term works today.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cs_cd_and` | `simple` | `a b c-d` | `a & 'c-d'` | `true` |

Accent-folding contrast (needs contrib `unaccent`): same queries that stay accent-sensitive on `simple` now strip accents on `simple_unaccent`. Best-effort — skipped wholesale if unaccent isn't installed, so contrib-less CI still passes. Wildcards fold their literal runs to the unaccented form (the new feature).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_q` | `public.simple_unaccent` | `un café noir` | `caf?` | `true` |
| `cu_suffix` | `public.simple_unaccent` | `bien paré ici` | `*ré` | `true` |

`p` recomputed from the folded glob: `café*o` → `cafe*o`, so the starts_with() scan-narrowing keys off `cafe` and finds `cafezinho`.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_infix` | `public.simple_unaccent` | `o cafezinho` | `café*o` | `true` |

an unaccented query glob matches the accented (folded) stored lexeme too.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_plain` | `public.simple_unaccent` | `bien paré ici` | `*re` | `true` |
| `cu_phrase` | `public.simple_unaccent` | `un paré noir` | `"*ré noir"` | `true` |
| `cu_fb` | `public.simple_unaccent` | `x foo.bar baz` | `foo.bar*` | `true` |
| `cu_miss` | `public.simple_unaccent` | `un thé noir` | `caf?` | `false` |

Plain TERM searches: `CAFÉ` is stored as the lexeme `cafe`, so it is found by any accent/case spelling — `cafe`, `café`, `CAFÉ` — and vice versa. (Term and prefix resolution already folded; these pin the headline accent behavior.)

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_term_low` | `public.simple_unaccent` | `un CAFÉ noir` | `cafe` | `true` |
| `cu_term_acc` | `public.simple_unaccent` | `un CAFÉ noir` | `café` | `true` |
| `cu_term_up` | `public.simple_unaccent` | `un CAFÉ noir` | `CAFÉ` | `true` |
| `cu_term_rev` | `public.simple_unaccent` | `un café noir` | `CAFÉ` | `true` |
| `cu_term_miss` | `public.simple_unaccent` | `un CAFÉ noir` | `thé` | `false` |
| `cu_prox_hit` | `public.simple_unaccent` | `un CAFÉ noir` | `cafe <-> noir` | `true` |
| `cu_prox_miss` | `public.simple_unaccent` | `CAFÉ un deux noir` | `cafe <~1> noir` | `false` |

CJK is preserved (unaccent is a no-op on non-Latin letters), so terms, proximity, and even globs work under this config exactly as under `simple`.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_cjk_term` | `public.simple_unaccent` | `中文 文档 搜索` | `中文` | `true` |
| `cu_cjk_prox` | `public.simple_unaccent` | `中文 文档 搜索` | `中文 <~2> 搜索` | `true` |
| `cu_cjk_miss` | `public.simple_unaccent` | `中文 文档 搜索` | `中文 <~1> 搜索` | `false` |
| `cu_cjk_glob` | `public.simple_unaccent` | `中文 文档 搜索` | `中?` | `true` |

Emoji are dropped by the FTS *parser* (Unicode symbols, not letters) under any UTF-8 ctype (C.UTF-8, en_US.UTF-8, ICU) — so they never become lexemes: a bare `😀` query matches nothing, while the surrounding words stay searchable and, since the emoji takes no position, adjacent (`rapport <-> final`). This is parser behavior governed by the database `lc_ctype`, not a proxquery or unaccent limitation, and is identical under plain `simple`. (The pathological bare `C` locale instead glues multibyte runs into one token and breaks case folding, so non-ASCII FTS needs a UTF-8 ctype regardless — the same assumption the existing CJK corpus cases already rely on.)

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_emoji_adj` | `public.simple_unaccent` | `rapport 😀 final` | `rapport <-> final` | `true` |
| `cu_emoji_word` | `public.simple_unaccent` | `rapport 😀 final` | `rapport` | `true` |
| `cu_emoji_term` | `public.simple_unaccent` | `rapport 😀 final` | `😀` | `false` |

The expanded mapping covers the letters+digits word types (numword, numhword, hword_numpart) on top of the all-letter ones, so accents fold on alphanumeric tokens too — `café2` is stored as `cafe2` (it was kept as `café2` when only asciiword/word/hword/hword_part were mapped). Term, reverse-spelling, proximity, and a miss all confirm the close of that gap.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_num_term` | `public.simple_unaccent` | `un café2 noir` | `cafe2` | `true` |
| `cu_num_acc` | `public.simple_unaccent` | `un café2 noir` | `café2` | `true` |
| `cu_num_prox` | `public.simple_unaccent` | `un café2 noir` | `cafe2 <-> noir` | `true` |
| `cu_num_miss` | `public.simple_unaccent` | `un thé2 noir` | `cafe2` | `false` |

numhword compound: `mp3-café` folds whole-token to `mp3-cafe`; its parts `mp3`/`café` land at the next positions (so `mp3 <-> cafe` is adjacent).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_nhw_term` | `public.simple_unaccent` | `un mp3-café ok` | `cafe` | `true` |
| `cu_nhw_prox` | `public.simple_unaccent` | `un mp3-café ok` | `mp3 <-> cafe` | `true` |

Hyphenated-word proximity & phrases under accent folding. `café-bar` → `café-bar`:2 `café`:3 `bar`:4 (compound + parts at CONSECUTIVE positions), so: • unaccented adjacency / phrase reach the folded parts,

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_hw_adj` | `public.simple_unaccent` | `le café-bar ferme` | `cafe <-> bar` | `true` |
| `cu_hw_phrase` | `public.simple_unaccent` | `le café-bar ferme` | `"cafe bar"` | `true` |
| `cu_hw_acc` | `public.simple_unaccent` | `le café-bar ferme` | `"café bar"` | `true` |
| `cu_hw_span` | `public.simple_unaccent` | `le café-bar ferme` | `"cafe bar ferme"` | `true` |

• `<->` is ordered (reverse misses) while `<~N>` is symmetric within distance,

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_hw_rev` | `public.simple_unaccent` | `le café-bar ferme` | `bar <-> cafe` | `false` |
| `cu_hw_near` | `public.simple_unaccent` | `le café-bar ferme` | `ferme <~2> cafe` | `true` |
| `cu_hw_near0` | `public.simple_unaccent` | `le café-bar ferme` | `cafe <~1> ferme` | `false` |

• the COMPOUND occupies the position between `le` and the `café` part, so `le` and `café` are NOT adjacent — a phrase across that boundary misses.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_hw_gap` | `public.simple_unaccent` | `le café-bar ferme` | `"le cafe"` | `false` |

A single-quoted literal `'…'` resolves through the config exactly like a bare term —
the accent/stem-exactness is analyzer-only (there's no superimposed index here to be
exact against). So under `simple` it stays accent-sensitive (`'café'` matches `café`,
not `cafe`), and under `simple_unaccent` it folds (`'café'` matches both spellings).

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `lit_simple_acc` | `simple` | `un café noir` | `'café'` | `true` |
| `lit_simple_miss` | `simple` | `un cafe noir` | `'café'` | `false` |
| `lit_unacc_plain` | `public.simple_unaccent` | `un café noir` | `'café'` | `true` |
| `lit_unacc_fold` | `public.simple_unaccent` | `un cafe noir` | `'café'` | `true` |

Recheck-drop fold under a config (the 3-arg `ts_prox_query_exact` / `ts_prox_search`):
boolean / phrase / term queries shed the per-row recheck even under `simple_unaccent`,
because each term resolves through the config — a single lexeme, or an OR of lexemes for
a parser-split compound (`café-bar` → `bar`/`cafe`/`cafe-bar`), whose `@@` matches exactly
as the recheck unions positions. The differential `cfg-exact` probe asserts both ports
agree on which queries are droppable and that `@@ exact` equals the recheck. (Docs hold the
whole compound, so the probe and the recheck coincide.)

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `cu_drop_bool` | `public.simple_unaccent` | `un CAFÉ noir` | `cafe & noir` | `true` |
| `cu_drop_bool_miss` | `public.simple_unaccent` | `un CAFÉ noir` | `cafe & vin` | `false` |
| `cu_drop_or` | `public.simple_unaccent` | `un CAFÉ noir` | `(vin \| cafe)` | `true` |
| `cu_drop_phrase` | `public.simple_unaccent` | `un café noir` | `"café noir"` | `true` |
| `cu_drop_compound` | `public.simple_unaccent` | `le café-bar ferme` | `café-bar` | `true` |
| `cu_drop_comp_fold` | `public.simple_unaccent` | `le café-bar ferme` | `cafe-bar` | `true` |

Same fold on a built-in stemming config (`english`, no contrib needed): a stemmed term
folds 1:1 (`running` → `run`) so boolean / phrase queries drop the recheck; a stopword
term (`the`) resolves to nothing, so `ts_prox_query_exact` stays NULL and the recheck is
kept — exercising the gate's stopword branch on both ports.

| label | config | doc | query | expected |
| --- | --- | --- | --- | --- |
| `ce_drop_bool` | `english` | `the running shoes` | `running & shoes` | `true` |
| `ce_drop_phrase` | `english` | `the running shoes` | `"running shoes"` | `true` |
| `ce_drop_stem_miss` | `english` | `the walking shoes` | `running & shoes` | `false` |
| `ce_keep_stopword` | `english` | `the running shoes` | `the & running` | `false` |
| `ce_keep_within` | `english` | `the running shoes` | `running <~2> shoes` | `true` |

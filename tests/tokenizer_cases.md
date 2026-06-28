# proxquery tokenizer golden corpus

The contract for the **extension-only** Unicode tokenizer: for each row,
`proxquery_to_tsvector(input, analyzer)` must equal `expected::tsvector`
(tsvector equality, so lexeme order in `expected` is irrelevant; positions and
superimposition ARE checked). Parsed and loaded by `corpus::load_tokenizer`; run
by the `tokenizer_corpus` `#[pg_test]`. This corpus is extension-only — separate
from the cross-implementation parity corpus (tests/parity_cases.md).

Each value is wrapped in `` ` `` so markdown leaves it alone. (One NFC case —
`tf_nfd`, whose input is a decomposed combining codepoint with no readable
plain-text form — lives in the `tokenizer_corpus` test itself, not here.)

Words & case: always Unicode case-fold; underscore is a word char.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tw_basic` | `prox_icu` | `Hello World` | `'hello':1 'world':2` |
| `tw_under` | `prox_icu` | `my_var here` | `'my_var':1 'here':2` |

case-fold collapses ß→ss, so STRASSE and Straße are the same lexeme.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tw_sharp` | `prox_icu` | `STRASSE Straße` | `'strasse':1,2` |

Accents: superimpose the lowercased original AND the accent-folded form.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `ta_super` | `prox_icu` | `un Café noir` | `'un':1 'café':2 'cafe':2 'noir':3` |
| `ta_naive` | `prox_icu` | `naïve` | `'naïve':1 'naive':1` |

atomic letters NFD can't decompose still fold via the unaccent-style table.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `ta_atom` | `prox_icu` | `Smørrebrød` | `'smørrebrød':1 'smorrebrod':1` |

Hyphenated: superimpose compound + parts + the hyphens-removed concatenation at ONE position (so the closed-compound spelling matches too: `c-d`→`cd`, `co-operate`→`cooperate`); each part is also accent/case-normalized (café-bar combines hyphen + accent superimposition).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `th_super` | `prox_icu` | `the c-d test` | `'the':1 'c-d':2 'c':2 'd':2 'cd':2 'test':3` |
| `th_accent` | `prox_icu` | `Café-Bar` | `'café-bar':1 'cafe-bar':1 'café':1 'cafe':1 'bar':1 'cafébar':1 'cafebar':1` |
| `th_ssn` | `prox_icu` | `123-45-6789` | `'123-45-6789':1 '123':1 '45':1 '6789':1 '123456789':1` |

Emails: full address + local + full host + host labels EXCEPT the TLD, all superimposed at the email's single position.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `te_basic` | `prox_icu` | `mail a@b.com here` | `'mail':1 'a@b.com':2 'a':2 'b.com':2 'b':2 'here':3` |
| `te_multi` | `prox_icu` | `john@mail.example.com` | `'john@mail.example.com':1 'john':1 'mail.example.com':1 'mail':1 'example':1` |

URLs: full URL + host only (host decomposed like an email host); no path split.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tu_basic` | `prox_icu` | `see https://x.com/p?q=1 now` | `'see':1 'https://x.com/p?q=1':2 'x.com':2 'x':2 'now':3` |

Bare (scheme-less) hosts: a dotted token whose last label is a 2–24 letter TLD is decomposed like an email host (full + labels except the TLD), so `google` finds `google.com`. Non-host dotted tokens (`a.b.c`, `version2.0`, see `tp_dots`) stay whole.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tu_host` | `prox_icu` | `visit google.com` | `'visit':1 'google.com':2 'google':2` |
| `tu_www` | `prox_icu` | `www.example.com` | `'www.example.com':1 'www':1 'example':1` |

Apostrophes: full + part-before-apostrophe + apostrophe-stripped; curly (right `’` and left `‘`) and the modifier-letter apostrophe `ʼ` are all folded to straight `'` first.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tp_its` | `prox_icu` | `it's` | `'it''s':1 'it':1 'its':1` |
| `tp_poss` | `prox_icu` | `Paul's` | `'paul''s':1 'paul':1 'pauls':1` |
| `tp_curly` | `prox_icu` | `don't` | `'don''t':1 'don':1 'dont':1` |
| `tp_lcurly` | `prox_icu` | `it‘s` | `'it''s':1 'it':1 'its':1` |

Internal punctuation between word chars is KEPT (UAX#29 MidNumLet/MidNumLetQ): `it's.going.` is ONE token (trailing `.` dropped), apostrophe still superimposed; `a.b.c` stays whole. So we do NOT split on an interior `.`/`'`.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tp_dotap` | `prox_icu` | `it's.going.` | `'it''s.going':1 'it':1 'its.going':1` |
| `tp_dots` | `prox_icu` | `a.b.c` | `'a.b.c':1` |

Numbers/IDs: kept as-is (UAX#29), NO variant superimposition.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tn_thou` | `prox_icu` | `qty 1,000 done` | `'qty':1 '1,000':2 'done':3` |
| `tn_dec` | `prox_icu` | `pi 3.14` | `'pi':1 '3.14':2` |
| `tn_id` | `prox_icu` | `ref ABC0001234` | `'ref':1 'abc0001234':2` |

Punctuation/symbols: dropped, consume NO position (so neighbors stay adjacent). This includes text-default symbols like `™` `©` `®` (`Emoji=Yes` but text-presentation): they drop like punctuation, so `Foo™ bar` keeps `foo`/`bar` adjacent — unlike real emoji (`Emoji_Presentation`, kept below).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tx_punct` | `prox_icu` | `a, b! c` | `'a':1 'b':2 'c':3` |
| `tx_lead` | `prox_icu` | `- hello` | `'hello':1` |
| `tx_tm` | `prox_icu` | `Foo™ bar` | `'foo':1 'bar':2` |

[verified] Emoji: preserved as their own lexeme; ZWJ/flag/skin-tone clusters kept intact. Confirm clustering against the segmenter during implementation.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tj_single` | `prox_icu` | `hi 🎂 bye` | `'hi':1 '🎂':2 'bye':3` |
| `tj_family` | `prox_icu` | `👨‍👩‍👧‍👦 ok` | `'👨‍👩‍👧‍👦':1 'ok':2` |
| `tj_flag` | `prox_icu` | `go 🇺🇸 home` | `'go':1 '🇺🇸':2 'home':3` |
| `tj_skin` | `prox_icu` | `👍🏽 yes` | `'👍🏽':1 'yes':2` |

[verified] NFC normalization: decomposed é (e + U+0301) must tokenize identically to composed café. (Input written with an explicit combining acute.) [verified] CJK: engine-dependent. icu does dictionary word segmentation; the unicode-segmentation engine falls to per-character.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tc_icu` | `prox_icu` | `你好世界` | `'你好':1 '世界':2` |
| `tc_uni` | `prox_unicode` | `你好世界` | `'你':1 '好':2 '世':3 '界':4` |
| `tm_mix` | `prox_icu` | `hello 你好 world` | `'hello':1 '你好':2 'world':3` |

Case-fold normalizes ligatures and a few special letters to their ASCII expansion (full Unicode case folding decomposes them): the `fi` ligature, the capital sharp-s `ẞ` (→ `ss`, like the lowercase `ß` of `tw_sharp`), and Greek capital sigma (case-folds to plain `σ`, never the final-form `ς` — so both sigma spellings collide).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tk_lig` | `prox_icu` | `ﬁle` | `'file':1` |
| `tk_sharp_cap` | `prox_icu` | `GROẞE` | `'grosse':1` |
| `tk_sigma` | `prox_icu` | `ΟΔΟΣ` | `'οδοσ':1` |

Compatibility forms are normalized by an NFKC superimposition: NFC stays the base (the original spelling is preserved as a lexeme), and the NFKC-folded variant is superimposed at the same position — just like accent-folding — so a fullwidth / half-width / Roman-numeral / fraction spelling and its canonical ASCII/normal equivalent collapse to one matchable position (`ＡＢＣ` matches `abc`, `Ⅻ` matches `xii`), while both originals stay searchable. NFKC is quick-check gated, so ordinary ASCII / letter / CJK text does no extra work. Two things NFKC deliberately does NOT fold — they aren't compatibility-equivalent under Unicode: non-ASCII digits (Arabic-Indic `١٢٣`, Devanagari) and confusables (Cyrillic `а` vs Latin `a`).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tk_fw_latin` | `prox_icu` | `ＡＢＣ` | `'abc':1 'ａｂｃ':1` |
| `tk_fw_digit` | `prox_icu` | `１２３` | `'123':1 '１２３':1` |
| `tk_hw_kana` | `prox_icu` | `ﾊﾀｶﾅ` | `'ハタカナ':1 'ﾊﾀｶﾅ':1` |
| `tk_roman` | `prox_icu` | `Ⅻ` | `'xii':1 'ⅻ':1` |
| `tk_frac` | `prox_icu` | `½` | `'1⁄2':1 '½':1` |

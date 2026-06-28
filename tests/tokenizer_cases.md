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

Hyphenated: superimpose compound + parts at ONE position; each part also accent/case-normalized (café-bar combines hyphen + accent superimposition).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `th_super` | `prox_icu` | `the c-d test` | `'the':1 'c-d':2 'c':2 'd':2 'test':3` |
| `th_accent` | `prox_icu` | `Café-Bar` | `'café-bar':1 'cafe-bar':1 'café':1 'cafe':1 'bar':1` |

Emails: full address + local + full host + host labels EXCEPT the TLD, all superimposed at the email's single position.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `te_basic` | `prox_icu` | `mail a@b.com here` | `'mail':1 'a@b.com':2 'a':2 'b.com':2 'b':2 'here':3` |
| `te_multi` | `prox_icu` | `john@mail.example.com` | `'john@mail.example.com':1 'john':1 'mail.example.com':1 'mail':1 'example':1` |

URLs: full URL + host only (host decomposed like an email host); no path split.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tu_basic` | `prox_icu` | `see https://x.com/p?q=1 now` | `'see':1 'https://x.com/p?q=1':2 'x.com':2 'x':2 'now':3` |

Apostrophes: full + part-before-apostrophe + apostrophe-stripped; curly → straight.

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tp_its` | `prox_icu` | `it's` | `'it''s':1 'it':1 'its':1` |
| `tp_poss` | `prox_icu` | `Paul's` | `'paul''s':1 'paul':1 'pauls':1` |
| `tp_curly` | `prox_icu` | `don't` | `'don''t':1 'don':1 'dont':1` |

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

Punctuation/symbols: dropped, consume NO position (so neighbors stay adjacent).

| label | analyzer | input | expected |
| --- | --- | --- | --- |
| `tx_punct` | `prox_icu` | `a, b! c` | `'a':1 'b':2 'c':3` |
| `tx_lead` | `prox_icu` | `- hello` | `'hello':1` |

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

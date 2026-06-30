# proxquery analyzer operator corpus

Extension-only: exercises the full DSL operator surface under the custom tokenizer. Loaded by `corpus::load_analyzer_ops`; run by the `analyzer_operator_corpus` `#[pg_test]`, which asserts, for every row, that the `proxquery_recheck` recheck equals `expected`, and for every distinct query that the GIN-indexed `@~@` result equals the bare recheck (probe soundness) and that the plan uses the index when the query carries a key.

The parity corpus (`tests/parity_cases.md`) already covers every operator under the stock cfg/literal resolvers; this is the analyzer-resolver counterpart — its point is the operators that have analyzer-specific resolution (globs/prefix fold through the analyzer; regex scans the superimposed lexemes; the index probe lowering for every operator) and their interaction with superimposition.

Conventions: each value is backticked; a literal `|` (OR) is escaped `\|`. `expected` is `true`/`false`.

## Boolean — AND / OR / NOT / grouping

`prox_icu` superimposes `café` → `café` + `cafe`, so a bare term is accent-insensitive and a `'literal'` is exact (these rows pin both inside boolean operators).

| label         | analyzer   | doc            | query                  | expected |
| ------------- | ---------- | -------------- | ---------------------- | -------- |
| `or_hit`      | `prox_icu` | `un café noir` | `cafe \| zzz`          | `true`   |
| `or_miss`     | `prox_icu` | `un thé noir`  | `cafe \| zzz`          | `false`  |
| `or_lit`      | `prox_icu` | `un cafe noir` | `'café' \| noir`       | `true`   |
| `or_lit_miss` | `prox_icu` | `un cafe noir` | `'café' \| zzz`        | `false`  |
| `and_hit`     | `prox_icu` | `un café noir` | `cafe & noir`          | `true`   |
| `and_miss`    | `prox_icu` | `un café noir` | `cafe & zzz`           | `false`  |
| `not_hit`     | `prox_icu` | `un café noir` | `noir & !zzz`          | `true`   |
| `not_miss`    | `prox_icu` | `un café noir` | `noir & !cafe`         | `false`  |
| `not_lit`     | `prox_icu` | `un cafe noir` | `noir & !'café'`       | `true`   |
| `not_lit2`    | `prox_icu` | `un café noir` | `noir & !'café'`       | `false`  |
| `group`       | `prox_icu` | `un café noir` | `(zzz \| cafe) & noir` | `true`   |

A proximity operand must be positional, so a boolean `&`/`!` as an operand raises through the analyzer path exactly as on the stock path (the rejection is in shared normalization, upstream of the analyzer). `|` (OR) stays a valid operand on every operator — the within ops union its branches' positions, and the exact/phrase ops (`<->`, `<N>`) distribute it into an OR of phrases — with each OR branch resolved through the analyzer (so a bare `cafe` branch still matches superimposed `café`). `!` at the top level (`not_*` above) is fine. `expected = ERR` asserts the raise.

| label                   | analyzer   | doc             | query                        | expected |
| ----------------------- | ---------- | --------------- | ---------------------------- | -------- |
| `prox_and_err`          | `prox_icu` | `cafe noir vin` | `(cafe & noir) <~5> vin`     | `ERR`    |
| `prox_not_err`          | `prox_icu` | `cafe noir vin` | `(!cafe) <~5> vin`           | `ERR`    |
| `prox_not_nested_err`   | `prox_icu` | `cafe noir vin` | `cafe <~5> (noir <~5> !vin)` | `ERR`    |
| `prox_not_or_err`       | `prox_icu` | `cafe noir vin` | `(cafe \| !noir) <~5> vin`   | `ERR`    |
| `prox_or_ok`            | `prox_icu` | `cafe noir vin` | `(cafe \| zzz) <~2> noir`    | `true`   |
| `prox_phrase_or_ok`     | `prox_icu` | `cafe noir vin` | `(cafe \| zzz) <-> noir`     | `true`   |
| `prox_phrase_or_accent` | `prox_icu` | `café noir vin` | `(cafe \| zzz) <-> noir`     | `true`   |
| `prox_phrase_and_err`   | `prox_icu` | `cafe noir vin` | `(cafe & noir) <-> vin`      | `ERR`    |

## Proximity — distance / within / ordered / not-within

Plain ASCII docs (no superimposition) so the position arithmetic is unambiguous: `alpha beta gamma delta` → `alpha`:1 `beta`:2 `gamma`:3 `delta`:4.

| label         | analyzer   | doc                      | query              | expected |
| ------------- | ---------- | ------------------------ | ------------------ | -------- |
| `dist_hit`    | `prox_icu` | `alpha beta gamma delta` | `alpha <2> gamma`  | `true`   |
| `dist_miss`   | `prox_icu` | `alpha beta gamma delta` | `alpha <1> gamma`  | `false`  |
| `pre_hit`     | `prox_icu` | `alpha beta gamma delta` | `alpha <-2> gamma` | `true`   |
| `pre_rev`     | `prox_icu` | `alpha beta gamma delta` | `gamma <-2> alpha` | `false`  |
| `within_hit`  | `prox_icu` | `alpha beta gamma delta` | `gamma <~2> alpha` | `true`   |
| `within_miss` | `prox_icu` | `alpha beta gamma delta` | `alpha <~1> gamma` | `false`  |
| `nw_hit`      | `prox_icu` | `alpha x x x beta`       | `alpha <!~2> beta` | `true`   |
| `nw_miss`     | `prox_icu` | `alpha beta`             | `alpha <!~2> beta` | `false`  |
| `nwo_hit`     | `prox_icu` | `alpha x x x beta`       | `alpha <!-2> beta` | `true`   |
| `nwo_miss`    | `prox_icu` | `alpha beta`             | `alpha <!-2> beta` | `false`  |

## Phrases

A bare phrase is accent-insensitive (`"cafe noir"` matches the superimposed `café`).

| label                | analyzer   | doc            | query           | expected |
| -------------------- | ---------- | -------------- | --------------- | -------- |
| `phrase_hit`         | `prox_icu` | `un café noir` | `"café noir"`   | `true`   |
| `phrase_miss`        | `prox_icu` | `café x noir`  | `"café noir"`   | `false`  |
| `phrase_fold`        | `prox_icu` | `un café noir` | `"cafe noir"`   | `true`   |
| `phrase_quote_inert` | `prox_icu` | `un cafe noir` | `"'café' noir"` | `true`   |

## Globs / prefix — fold through the analyzer

| label         | analyzer   | doc            | query         | expected |
| ------------- | ---------- | -------------- | ------------- | -------- |
| `prefix_hit`  | `prox_icu` | `un café noir` | `caf*`        | `true`   |
| `prefix_miss` | `prox_icu` | `un thé noir`  | `caf*`        | `false`  |
| `prefix_and`  | `prox_icu` | `un café noir` | `caf* & noir` | `true`   |
| `suffix`      | `prox_icu` | `un café noir` | `*oir`        | `true`   |
| `infix`       | `prox_icu` | `un café noir` | `n*r`         | `true`   |
| `single`      | `prox_icu` | `un café noir` | `noi?`        | `true`   |
| `single_miss` | `prox_icu` | `un café noir` | `no?`         | `false`  |

## Regex — scans the (superimposed) lexemes

Paired with a companion term so the probe carries an index key. Patterns are anchored to the whole lexeme (`^(?:…)$`), so `caf.*` matches the superimposed `café`/`cafe`.

| label        | analyzer   | doc            | query              | expected |
| ------------ | ---------- | -------------- | ------------------ | -------- |
| `regex_hit`  | `prox_icu` | `un café noir` | `noir & ##caf.*##` | `true`   |
| `regex_miss` | `prox_icu` | `un café noir` | `noir & ##zzz.*##` | `false`  |

## Accent-sensitive analyzer (`prox_icu_accent`)

No superimposition: `café` ≠ `cafe` on both sides.

| label        | analyzer          | doc            | query          | expected |
| ------------ | ----------------- | -------------- | -------------- | -------- |
| `acc_miss`   | `prox_icu_accent` | `un café noir` | `cafe`         | `false`  |
| `acc_hit`    | `prox_icu_accent` | `un café noir` | `café`         | `true`   |
| `acc_prefix` | `prox_icu_accent` | `un café noir` | `caf*`         | `true`   |
| `acc_or`     | `prox_icu_accent` | `un café noir` | `cafe \| café` | `true`   |

## Unicode-segmentation analyzer (`prox_unicode`)

Per-character CJK segmentation.

| label      | analyzer       | doc         | query     | expected |
| ---------- | -------------- | ----------- | --------- | -------- |
| `uni_term` | `prox_unicode` | `中文 文档` | `中`      | `true`   |
| `uni_and`  | `prox_unicode` | `中文 文档` | `中 & 档` | `true`   |

## Compatibility folding (NFKC)

The index superimposes an NFKC-folded variant, and the query side folds to it too, so a full-width / half-width / Roman-numeral spelling matches its ASCII/normal equivalent either direction. Non-ASCII digits are not compatibility-equivalent, so they stay distinct (the NFKC boundary).

| label             | analyzer   | doc      | query    | expected |
| ----------------- | ---------- | -------- | -------- | -------- |
| `nfkc_fw`         | `prox_icu` | `ＡＢＣ` | `abc`    | `true`   |
| `nfkc_fw_rev`     | `prox_icu` | `abc`    | `ＡＢＣ` | `true`   |
| `nfkc_roman`      | `prox_icu` | `Ⅻ`      | `xii`    | `true`   |
| `nfkc_digit_miss` | `prox_icu` | `１２３` | `999`    | `false`  |
| `nfkc_arab_miss`  | `prox_icu` | `١٢٣`    | `123`    | `false`  |

## Structured-token tailorings

A scheme-less host decomposes (`google` finds `google.com`); a hyphen run also emits the hyphens-removed concatenation (`123456789` finds `123-45-6789`); a text-default symbol (`™`) drops without a position, so a phrase reads across it. Because a hyphen run's parts superimpose onto one slot (`red`, `blue` both at the `red-blue` position), the ordered `<-N>` operator reads adjacently across them — and, the pair being co-located, in either direction.

| label            | analyzer   | doc                      | query           | expected |
| ---------------- | ---------- | ------------------------ | --------------- | -------- |
| `host_bare`      | `prox_icu` | `visit google.com today` | `google`        | `true`   |
| `host_full`      | `prox_icu` | `visit google.com today` | `google.com`    | `true`   |
| `hyphen_concat`  | `prox_icu` | `call 123-45-6789 now`   | `123456789`     | `true`   |
| `hyphen_ord`     | `prox_icu` | `a red-blue sky`         | `red <-1> blue` | `true`   |
| `hyphen_ord_rev` | `prox_icu` | `a red-blue sky`         | `blue <-1> red` | `true`   |
| `sym_phrase`     | `prox_icu` | `Foo™ Bar`               | `"Foo Bar"`     | `true`   |

## Ampersand units (`R&D`, `P&L`)

A `&` run superimposes its compound + parts + concatenation onto one slot (see the tokenizer corpus), so the literal `'R&D'` finds the unit precisely (the `r&d` compound), the concatenation `rd` finds it, and the bare parts `r`/`d` find it. A bare `R&D` query is the boolean `r & d` (the DSL reads `&` as AND) — looser, so it also matches a doc with `r` and `d` apart, where the precise literal `'R&D'` correctly misses.

| label           | analyzer   | doc           | query   | expected |
| --------------- | ---------- | ------------- | ------- | -------- |
| `amp_lit`       | `prox_icu` | `we did R&D`  | `'R&D'` | `true`   |
| `amp_concat`    | `prox_icu` | `we did R&D`  | `rd`    | `true`   |
| `amp_part`      | `prox_icu` | `we did R&D`  | `r`     | `true`   |
| `amp_and`       | `prox_icu` | `we did R&D`  | `R&D`   | `true`   |
| `amp_pl_lit`    | `prox_icu` | `the P&L now` | `'P&L'` | `true`   |
| `amp_lit_spec`  | `prox_icu` | `r and d`     | `'R&D'` | `false`  |
| `amp_and_loose` | `prox_icu` | `r and d`     | `R&D`   | `true`   |

# Config-aware proxquery

By default proxquery matches lexemes **literally** (the `simple` text-search
config: lowercase, no stemming). The config-aware surface lets it instead match a
`tsvector` built with **any** text-search configuration — `english` (stemming),
a custom `simple_unaccent` (accent-folding), your own dictionary chain — so a
surface query term finds the normalized lexemes the column actually stores.

The headline: against an `english` column, `running <~3> shoes` matches a document
stored as `run … shoe`. Against a `simple_unaccent` column, `CAFÉ` matches `café`.

## The idea: proxquery *consumes* a config, it doesn't author one

proxquery matches by **lexeme**. Under a non-`simple` config the stored lexemes
are normalized (stemmed, unaccented, locale-folded), so a query term has to be run
through the **same** config to find them. proxquery does that by resolving each
term through `to_tsvector(cfg, term)` — the exact routine that built your column —
and lowering the index skeleton through `to_tsquery(cfg, …)`. Both sides use the
identical Postgres dictionaries, so selection and recheck agree by construction.

The normalization policy lives entirely in **your** text-search config, not in
proxquery. proxquery only threads the `regconfig` you name into `to_tsvector` /
`to_tsquery`; it contains no stemming or unaccent logic of its own. To change how
terms are normalized, change the config — proxquery follows.

```sql
-- You own the config (this one folds accents; needs the `unaccent` extension):
CREATE TEXT SEARCH CONFIGURATION simple_unaccent (COPY = simple);
ALTER TEXT SEARCH CONFIGURATION simple_unaccent
  ALTER MAPPING FOR asciiword, word, hword, hword_part WITH unaccent, simple;
```

## The surface

The config is passed **explicitly** (there is no session GUC — config is per
query, and stays `IMMUTABLE` so it folds into the index condition):

| Form | Use |
| --- | --- |
| `ts_prox_query(text, regconfig)` | index-selection skeleton under a config |
| `ts_prox_match(tsvector, text, regconfig)` | positional recheck under a config |
| `tsvector @~@ proxquery(cfg, q)` | the single indexable operator, config in a typed right operand |

The existing 2-arg `ts_prox_query(text)` / `ts_prox_match(tsvector, text)` and the
plain `tsvector @~@ text` operator are unchanged — still `simple`, still literal.
This is purely additive.

### As the two-clause form (works everywhere, incl. the pure-SQL port)

```sql
CREATE INDEX ON docs USING gin (body_tsv);   -- body_tsv = to_tsvector('english', body)

SELECT * FROM docs
WHERE body_tsv @@ ts_prox_query('running <~3> shoes', 'english')   -- Bitmap Index Scan
  AND ts_prox_match(body_tsv, 'running <~3> shoes', 'english');     -- recheck filter
```

### As the single operator (extension only)

```sql
SELECT * FROM docs
WHERE body_tsv @~@ proxquery('english', 'running <~3> shoes');
```

`proxquery(cfg, q)` builds a typed `(regconfig, text)` pair; a second `@~@` over
that type keeps one operator symbol. Its planner support function rewrites it to
`body_tsv @@ ts_prox_query(proxquery)` for the GIN index, so it plans **exactly**
like the two-clause form — index selection plus recheck:

```text
Bitmap Heap Scan on docs
  Filter: (body_tsv @~@ '(english,"running <~3> shoes")'::proxquery)   -- recheck
  ->  Bitmap Index Scan on docs_body_tsv_idx
        Index Cond: (body_tsv @@ ts_prox_query('(english,…)'::proxquery))  -- selection
```

## How it works

- **Skeleton (selection).** The skeleton string is **config-independent** — the
  same presence skeleton as `simple`. Only the wrapping config differs:
  `to_tsquery(cfg, ts_prox_query_skeleton(q))`. `to_tsquery` runs each quoted
  lexeme through the config's dictionaries (`'running'` → `'run'`), so the index
  selects on the stored, normalized lexemes.
- **Recheck (positions).** Each `Term` resolves to its lexeme set via
  `to_tsvector(cfg, term)` and unions their positions; a `Prefix` is normalized
  through the config before the prefix scan (so `café*` matches the stored `cafe…`).
  Resolution is cached per `(config, term)` for the scan.
- **What stays config-agnostic.** Globs (`*ology`, `te?t`) and `##regex##` scan
  the **stored** lexemes verbatim — they are matched as-is, by design. Under a
  stemming config that means they match stems (`*ology` won't match a stored
  `biolog`); that is the only sensible behavior, since the stored lexeme is what
  exists. Keep wildcard/regex literal parts in mind under a normalizing config.

## Locale independence as a bonus

The `simple` default folds case **by the database locale**, so an uppercase
accented term (`CAFÉ`) can mismatch a stored `café` on a `C`/`C.UTF-8` database vs
an `en_US.UTF-8` one. Routing terms through a config that **unaccents** (e.g.
`simple_unaccent`) removes the accented characters entirely, so matching becomes
ASCII and **locale-independent** — `CAFÉ` finds `café` on any collation. (Verified
across `C` and `en_US.UTF-8`.)

## Caveats

- **Phrases + stopwords.** A quoted phrase resolves its atoms independently, so a
  phrase whose atoms include a stopword under the config (e.g. `"the quick fox"`
  under `english`) matches nothing — the exact-gap recheck doesn't reproduce the
  dropped-stopword offset that `phraseto_tsquery` would. Use proximity operators
  (`quick <~2> fox`) for stopword-spanning phrases, or `simple`.
- **Stopword terms.** A bare term that the config drops (a stopword) resolves to
  zero lexemes and so matches nothing — consistently in both ports.
- **Multi-lexeme terms.** A term a stemmer/thesaurus expands to several lexemes is
  treated as their OR (positions unioned) — correct for same-position synonyms.
- **Wildcards / regex** match stored lexemes (= stems under a stemming config); see
  above.
- **Pass the config you built the column with.** Like `to_tsquery('english', …)`,
  resolution uses whatever `regconfig` you name; a mismatch against the column's
  config silently under-matches.

## Backward compatibility

The 2-arg functions and the `tsvector @~@ text` operator are untouched (`simple`,
literal). Everything above is additive.

## Pure-SQL parity

The pure-SQL port ([PURE_SQL.md](PURE_SQL.md)) ships the same 3-arg
`ts_prox_query` / `ts_prox_match` overloads, with identical results — both ports
call the same Postgres `to_tsvector` / `to_tsquery` builtins, so they can't drift
(checked by the differential and fuzz suites, now including config-aware cases).
The `@~@ proxquery(cfg, q)` operator is **extension only** — like `@~@` itself, its
planner support function is C-only — so under the pure port you write the two-clause
form with the 3-arg functions.

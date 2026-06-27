-- proxquery — config-aware recheck corpus (single source of truth, part 3)
-- =========================================================================
-- (label, cfg, doc, query, expected) tuples driving the 3-arg config-aware recheck
--     ts_prox_match(to_tsvector(cfg, doc), query, cfg)
-- on BOTH implementations via proxquery_diff_test.sql (which also asserts the
-- soundness invariant: a `true` recheck whose query carries an index key must also be
-- selected by `to_tsvector(cfg,doc) @@ ts_prox_query(query,cfg)` — recheck ⟹ probe).
--
-- Focus: `*`/`?` glob atoms now fold their literal runs through `cfg` (see
-- `_prox_fold_glob` / `fold_glob_cfg`), so a wildcard search inherits the column's
-- character normalization and agrees with the folded `to_tsquery(cfg,'p':*)` probe.
--
-- Configs: `simple` and `english` are built-in (always present). The contrib-free
-- rows demonstrate the fold via CASE folding — `to_tsvector(simple, …)` Unicode-
-- lowercases a glob run (e.g. `É`→`é`) that the ASCII-only query lexer leaves alone —
-- and verify `simple` stays accent-SENSITIVE (the feature is config-driven, not
-- unaccent-hardcoded). The accent-STRIPPING contrast needs `simple_unaccent`, which
-- requires the `unaccent` contrib extension; it is built best-effort at the end and
-- its rows are added only when that succeeds, so this corpus still runs on a Postgres
-- without contrib. `simple_unaccent` is schema-qualified (`public.simple_unaccent`)
-- so it resolves under either implementation's pinned search_path.
-- doc/query are dollar-quoted so quotes, backslashes and `|` need no escaping.

DROP TABLE IF EXISTS _prox_cfg_match;
CREATE TEMP TABLE _prox_cfg_match(label text, cfg text, doc text, query text, expected text);

INSERT INTO _prox_cfg_match(label, cfg, doc, query, expected) VALUES
  -- simple: wildcards stay ACCENT-SENSITIVE (config-driven, not hardcoded unaccent).
  ('cs_acc_hit',  'simple', $d$bien paré ici$d$,        $q$*ré$q$,           $x$true$x$),
  ('cs_acc_miss', 'simple', $d$bien pare ici$d$,        $q$*ré$q$,           $x$false$x$),
  ('cs_acc_miss2','simple', $d$bien paré ici$d$,        $q$*re$q$,           $x$false$x$),
  -- simple: the 3-arg path folds a glob run through `cfg`, so an uppercase non-ASCII
  -- run is Unicode-lowercased (the 2-arg lexer is ASCII-only) — but the accent is
  -- preserved (folds CASE, not accent), so `*É` matches `café`, not `cafe`.
  ('cs_case_hit', 'simple', $d$un CAFÉ noir$d$,          $q$*É$q$,            $x$true$x$),
  ('cs_case_acc', 'simple', $d$un cafe noir$d$,          $q$*É$q$,            $x$false$x$),
  -- ASCII globs are unaffected by the fold (regression guard for plain-ASCII users).
  ('cs_ascii_g',  'simple', $d$pick the best test$d$,    $q$te?t$q$,          $x$true$x$),
  ('cs_ascii_p',  'simple', $d$this text is confidential$d$, $q$con*ial$q$,   $x$true$x$),
  ('cs_ascii_pm', 'simple', $d$this text is public$d$,   $q$con*ial$q$,       $x$false$x$),
  -- verbatim fallback: a run that resolves to 0 or >1 lexemes (punctuated / host /
  -- alphanumeric) is kept as-is, so the glob behaves exactly as the 2-arg path would.
  ('cs_fb_dot',   'simple', $d$x foo.bar baz$d$,         $q$foo.bar*$q$,      $x$true$x$),
  ('cs_fb_num',   'simple', $d$an abc123 token$d$,       $q$abc123*$q$,       $x$true$x$),
  -- phrase-embedded glob atoms fold too (the phrase atom is a glob node).
  ('cs_ph_hit',   'simple', $d$the biology class$d$,     $q$"*ology class"$q$, $x$true$x$),
  ('cs_ph_miss',  'simple', $d$the geography class$d$,   $q$"*ology class"$q$, $x$false$x$),
  -- Hyphenated words: the parser emits the compound AND each part at CONSECUTIVE
  -- positions (`café-bar` → `café-bar`:2 `café`:3 `bar`:4), so the parts are adjacent
  -- to their neighbors. On plain `simple` proximity stays ACCENT-SENSITIVE: only the
  -- accented spelling of the part is adjacent to `bar` (config decides, as with globs).
  ('cs_hw_hit',   'simple', $d$le café-bar ferme$d$,     $q$café <-> bar$q$,   $x$true$x$),
  ('cs_hw_miss',  'simple', $d$le café-bar ferme$d$,     $q$cafe <-> bar$q$,   $x$false$x$),
  -- Hyphenated position arithmetic: the parser emits the COMPOUND and each PART at
  -- consecutive positions, so `a b-c d` → a:1 b-c:2 b:3 c:4 d:5. The compound sitting
  -- at position 2 pushes the parts one slot further from `a` than they look —
  --   a→b = 2 (NOT 1), a→c = 3, a→d = 4 — while the two parts b,c are adjacent.
  -- Distances are pinned with boundary pairs (within N-1 misses, within N hits);
  -- `<~N>` is symmetric within distance, `<->` is ordered-adjacent (distance exactly 1).
  ('cs_hyph_ab0', 'simple', $d$a b-c d$d$, $q$a <~1> b$q$, $x$false$x$),
  ('cs_hyph_ab1', 'simple', $d$a b-c d$d$, $q$a <~2> b$q$, $x$true$x$),
  ('cs_hyph_ac0', 'simple', $d$a b-c d$d$, $q$a <~2> c$q$, $x$false$x$),
  ('cs_hyph_ac1', 'simple', $d$a b-c d$d$, $q$a <~3> c$q$, $x$true$x$),
  ('cs_hyph_ad0', 'simple', $d$a b-c d$d$, $q$a <~3> d$q$, $x$false$x$),
  ('cs_hyph_ad1', 'simple', $d$a b-c d$d$, $q$a <~4> d$q$, $x$true$x$),
  -- the two parts are adjacent (the headline answer): `b <-> c` hits, the reverse
  -- misses (ordered), and `a <-> b` misses because the compound sits between them.
  ('cs_hyph_bc',  'simple', $d$a b-c d$d$, $q$b <-> c$q$, $x$true$x$),
  ('cs_hyph_cb',  'simple', $d$a b-c d$d$, $q$c <-> b$q$, $x$false$x$),
  ('cs_hyph_ab_a','simple', $d$a b-c d$d$, $q$a <-> b$q$, $x$false$x$);

-- Accent-folding contrast (needs contrib `unaccent`): same queries that stay
-- accent-sensitive on `simple` now strip accents on `simple_unaccent`. Best-effort —
-- skipped wholesale if unaccent isn't installed, so contrib-less CI still passes.
DO $setup$
BEGIN
    CREATE EXTENSION IF NOT EXISTS unaccent;
    EXECUTE 'DROP TEXT SEARCH CONFIGURATION IF EXISTS public.simple_unaccent';
    EXECUTE 'CREATE TEXT SEARCH CONFIGURATION public.simple_unaccent (COPY = pg_catalog.simple)';
    EXECUTE 'ALTER TEXT SEARCH CONFIGURATION public.simple_unaccent
               ALTER MAPPING FOR asciiword, word, numword,
                                 asciihword, hword, numhword,
                                 hword_asciipart, hword_part, hword_numpart
               WITH unaccent, simple';
    INSERT INTO _prox_cfg_match(label, cfg, doc, query, expected) VALUES
      -- Wildcards fold their literal runs to the unaccented form (the new feature).
      ('cu_q',     'public.simple_unaccent', $d$un café noir$d$,   $q$caf?$q$,         $x$true$x$),
      ('cu_suffix','public.simple_unaccent', $d$bien paré ici$d$,  $q$*ré$q$,          $x$true$x$),
      -- `p` recomputed from the folded glob: `café*o` → `cafe*o`, so the starts_with()
      -- scan-narrowing keys off `cafe` and finds `cafezinho`.
      ('cu_infix', 'public.simple_unaccent', $d$o cafezinho$d$,    $q$café*o$q$,       $x$true$x$),
      -- an unaccented query glob matches the accented (folded) stored lexeme too.
      ('cu_plain', 'public.simple_unaccent', $d$bien paré ici$d$,  $q$*re$q$,          $x$true$x$),
      ('cu_phrase','public.simple_unaccent', $d$un paré noir$d$,   $q$"*ré noir"$q$,   $x$true$x$),
      ('cu_fb',    'public.simple_unaccent', $d$x foo.bar baz$d$,  $q$foo.bar*$q$,     $x$true$x$),
      ('cu_miss',  'public.simple_unaccent', $d$un thé noir$d$,    $q$caf?$q$,         $x$false$x$),
      -- Plain TERM searches: `CAFÉ` is stored as the lexeme `cafe`, so it is found by
      -- any accent/case spelling — `cafe`, `café`, `CAFÉ` — and vice versa. (Term and
      -- prefix resolution already folded; these pin the headline accent behavior.)
      ('cu_term_low', 'public.simple_unaccent', $d$un CAFÉ noir$d$,      $q$cafe$q$,          $x$true$x$),
      ('cu_term_acc', 'public.simple_unaccent', $d$un CAFÉ noir$d$,      $q$café$q$,          $x$true$x$),
      ('cu_term_up',  'public.simple_unaccent', $d$un CAFÉ noir$d$,      $q$CAFÉ$q$,          $x$true$x$),
      ('cu_term_rev', 'public.simple_unaccent', $d$un café noir$d$,      $q$CAFÉ$q$,          $x$true$x$),
      ('cu_term_miss','public.simple_unaccent', $d$un CAFÉ noir$d$,      $q$thé$q$,           $x$false$x$),
      ('cu_prox_hit', 'public.simple_unaccent', $d$un CAFÉ noir$d$,      $q$cafe <-> noir$q$,  $x$true$x$),
      ('cu_prox_miss','public.simple_unaccent', $d$CAFÉ un deux noir$d$, $q$cafe <~1> noir$q$, $x$false$x$),
      -- CJK is preserved (unaccent is a no-op on non-Latin letters), so terms,
      -- proximity, and even globs work under this config exactly as under `simple`.
      ('cu_cjk_term', 'public.simple_unaccent', $d$中文 文档 搜索$d$,     $q$中文$q$,           $x$true$x$),
      ('cu_cjk_prox', 'public.simple_unaccent', $d$中文 文档 搜索$d$,     $q$中文 <~2> 搜索$q$,  $x$true$x$),
      ('cu_cjk_miss', 'public.simple_unaccent', $d$中文 文档 搜索$d$,     $q$中文 <~1> 搜索$q$,  $x$false$x$),
      ('cu_cjk_glob', 'public.simple_unaccent', $d$中文 文档 搜索$d$,     $q$中?$q$,            $x$true$x$),
      -- Emoji are dropped by the FTS *parser* (Unicode symbols, not letters) under any
      -- UTF-8 ctype (C.UTF-8, en_US.UTF-8, ICU) — so they never become lexemes: a bare
      -- `😀` query matches nothing, while the surrounding words stay searchable and,
      -- since the emoji takes no position, adjacent (`rapport <-> final`). This is parser
      -- behavior governed by the database `lc_ctype`, not a proxquery or unaccent
      -- limitation, and is identical under plain `simple`. (The pathological bare `C`
      -- locale instead glues multibyte runs into one token and breaks case folding, so
      -- non-ASCII FTS needs a UTF-8 ctype regardless — the same assumption the existing
      -- CJK corpus cases already rely on.)
      ('cu_emoji_adj', 'public.simple_unaccent', $d$rapport 😀 final$d$, $q$rapport <-> final$q$, $x$true$x$),
      ('cu_emoji_word','public.simple_unaccent', $d$rapport 😀 final$d$, $q$rapport$q$,           $x$true$x$),
      ('cu_emoji_term','public.simple_unaccent', $d$rapport 😀 final$d$, $q$😀$q$,                $x$false$x$);
    -- The expanded mapping covers the letters+digits word types (numword, numhword,
    -- hword_numpart) on top of the all-letter ones, so accents fold on alphanumeric
    -- tokens too — `café2` is stored as `cafe2` (it was kept as `café2` when only
    -- asciiword/word/hword/hword_part were mapped). Term, reverse-spelling, proximity,
    -- and a miss all confirm the close of that gap.
    INSERT INTO _prox_cfg_match(label, cfg, doc, query, expected) VALUES
      ('cu_num_term', 'public.simple_unaccent', $d$un café2 noir$d$,  $q$cafe2$q$,          $x$true$x$),
      ('cu_num_acc',  'public.simple_unaccent', $d$un café2 noir$d$,  $q$café2$q$,          $x$true$x$),
      ('cu_num_prox', 'public.simple_unaccent', $d$un café2 noir$d$,  $q$cafe2 <-> noir$q$, $x$true$x$),
      ('cu_num_miss', 'public.simple_unaccent', $d$un thé2 noir$d$,   $q$cafe2$q$,          $x$false$x$),
      -- numhword compound: `mp3-café` folds whole-token to `mp3-cafe`; its parts
      -- `mp3`/`café` land at the next positions (so `mp3 <-> cafe` is adjacent).
      ('cu_nhw_term', 'public.simple_unaccent', $d$un mp3-café ok$d$, $q$cafe$q$,           $x$true$x$),
      ('cu_nhw_prox', 'public.simple_unaccent', $d$un mp3-café ok$d$, $q$mp3 <-> cafe$q$,   $x$true$x$),
      -- Hyphenated-word proximity & phrases under accent folding. `café-bar` →
      -- `café-bar`:2 `café`:3 `bar`:4 (compound + parts at CONSECUTIVE positions), so:
      --  • unaccented adjacency / phrase reach the folded parts,
      ('cu_hw_adj',    'public.simple_unaccent', $d$le café-bar ferme$d$, $q$cafe <-> bar$q$,     $x$true$x$),
      ('cu_hw_phrase', 'public.simple_unaccent', $d$le café-bar ferme$d$, $q$"cafe bar"$q$,       $x$true$x$),
      ('cu_hw_acc',    'public.simple_unaccent', $d$le café-bar ferme$d$, $q$"café bar"$q$,       $x$true$x$),
      ('cu_hw_span',   'public.simple_unaccent', $d$le café-bar ferme$d$, $q$"cafe bar ferme"$q$, $x$true$x$),
      --  • `<->` is ordered (reverse misses) while `<~N>` is symmetric within distance,
      ('cu_hw_rev',    'public.simple_unaccent', $d$le café-bar ferme$d$, $q$bar <-> cafe$q$,     $x$false$x$),
      ('cu_hw_near',   'public.simple_unaccent', $d$le café-bar ferme$d$, $q$ferme <~2> cafe$q$,  $x$true$x$),
      ('cu_hw_near0',  'public.simple_unaccent', $d$le café-bar ferme$d$, $q$cafe <~1> ferme$q$,  $x$false$x$),
      --  • the COMPOUND occupies the position between `le` and the `café` part, so
      --    `le` and `café` are NOT adjacent — a phrase across that boundary misses.
      ('cu_hw_gap',    'public.simple_unaccent', $d$le café-bar ferme$d$, $q$"le cafe"$q$,        $x$false$x$);
    RAISE NOTICE 'config corpus: simple_unaccent cases enabled (unaccent present)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'config corpus: unaccent unavailable (%); accent-fold cases skipped', SQLERRM;
END
$setup$;

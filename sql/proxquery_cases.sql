-- proxquery — shared test corpus (single source of truth, part 1)
-- ===============================================================
-- Each row is (label, expr, expected): `expr` is a portable SQL expression using
-- only the `ts_prox_*` surface, and `expected` is its `::text` result (or `ERR`
-- when it must raise). This file holds everything that ISN'T a plain
-- `(doc, query) -> bool` recheck pair: skeletons, positions, the predicate
-- functions, `@@` selection, the decomposed two-clause form, errors, chains, and
-- literal-tsvector cases. The recheck pairs live in proxquery_match_cases.sql as
-- typed `(doc, query, expected)` tuples so they can also drive the @~@/index test.
--
-- This file ONLY populates the `_prox_cases` temp table (no search_path, no
-- runner), so it can be loaded ahead of any runner:
--   * proxquery_pure_test.sql  — golden check vs `expected`, one install (psql).
--   * proxquery_diff_test.sql  — differential: extension vs pure port vs expected.

DROP TABLE IF EXISTS _prox_cases;
CREATE TEMP TABLE _prox_cases(label text, expr text, expected text);

INSERT INTO _prox_cases(label, expr, expected) VALUES
  -- malformed / error behavior (raises ⇒ ERR)
  ('err1',   $e$ ts_prox_query('*ology') $e$, $x$ERR$x$),
  ('err2',   $e$ ts_prox_match(to_tsvector('simple','a b'),'(a <~5> b') $e$, $x$ERR$x$),
  ('err3',   $e$ ts_prox_match(to_tsvector('simple','a b'),'a <!5> b') $e$, $x$ERR$x$),
  ('err4',   $e$ ts_prox_match(to_tsvector('simple','a b'),'a &') $e$, $x$ERR$x$),
  ('err5',   $e$ ts_prox_match(to_tsvector('simple','alpha beta'),'##[##') $e$, $x$ERR$x$),
  ('err6',   $e$ ts_prox_match(to_tsvector('simple','alpha beta'),'alpha | ##[##') $e$, $x$ERR$x$),
  ('err7',   $e$ ts_prox_query('!foo') $e$, $x$ERR$x$),
  ('err8',   $e$ ts_prox_match(to_tsvector('simple','a b'),'') $e$, $x$ERR$x$),
  ('bst1',   $e$ ts_prox_match(to_tsvector('simple','something here'),'something *') $e$, $x$ERR$x$),
  -- full pipeline: index selection AND recheck (the decomposed two-clause form)
  ('f1',     $e$ to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x b'),'a <~2> b') $e$, $x$true$x$),
  ('f2',     $e$ to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x y z b'),'a <~2> b') $e$, $x$false$x$),
  ('f3',     $e$ to_tsvector('simple','a alone') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a alone'),'a <~2> b') $e$, $x$false$x$),
  ('f4',     $e$ to_tsvector('simple','the study of biology') @@ ts_prox_query('study <~3> *ology') AND ts_prox_match(to_tsvector('simple','the study of biology'),'study <~3> *ology') $e$, $x$true$x$),
  ('f5',     $e$ to_tsvector('simple','the study of cats') @@ ts_prox_query('study <~3> *ology') AND ts_prox_match(to_tsvector('simple','the study of cats'),'study <~3> *ology') $e$, $x$false$x$),
  ('f6',     $e$ to_tsvector('simple','ssn 123456789 here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_match(to_tsvector('simple','ssn 123456789 here'),'ssn <~3> ##[0-9]{9}##') $e$, $x$true$x$),
  ('f7',     $e$ to_tsvector('simple','ssn abc here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_match(to_tsvector('simple','ssn abc here'),'ssn <~3> ##[0-9]{9}##') $e$, $x$false$x$),
  ('op1',    $e$ to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x b'),'a <~2> b') $e$, $x$true$x$),
  ('op2',    $e$ to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x y z b'),'a <~2> b') $e$, $x$false$x$),
  -- positional predicate functions
  ('nw1',    $e$ ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',3) $e$, $x$true$x$),
  ('nw2',    $e$ ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',6) $e$, $x$false$x$),
  ('nw3',    $e$ ts_prox_not_within(to_tsvector('simple','confidential report only'),'confidential','email',5) $e$, $x$true$x$),
  ('pre1',   $e$ ts_prox_pre(to_tsvector('simple','quick brown fox'),'quick','fox',2) $e$, $x$true$x$),
  ('pre2',   $e$ ts_prox_pre(to_tsvector('simple','quick brown fox'),'fox','quick',2) $e$, $x$false$x$),
  ('w1',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',2) $e$, $x$true$x$),
  ('w2',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'fox','quick',2) $e$, $x$true$x$),
  ('w3',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',1) $e$, $x$false$x$),
  ('pos1',   $e$ ts_prox_positions(to_tsvector('simple','apple apple orange'),'apple') $e$, $x${1,2}$x$),
  ('pos2',   $e$ ts_prox_positions(to_tsvector('simple','apple'),'zzz') $e$, $x${}$x$),
  ('pos3',   $e$ ts_prox_positions_prefix(to_tsvector('simple','apple apply orange'),'appl') $e$, $x${1,2}$x$),
  -- same-occurrence chain (ts_prox_chain)
  ('win1',   $e$ ts_prox_chain(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[2,2]) $e$, $x$true$x$),
  ('win2',   $e$ ts_prox_chain(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[1,1]) $e$, $x$false$x$),
  ('win3',   $e$ ts_prox_chain(to_tsvector('simple','one two three four five six seven orange nine apple eleven banana'),ARRAY['apple','banana','orange'],ARRAY[2,2]) $e$, $x$false$x$),
  ('winErr', $e$ ts_prox_chain(to_tsvector('simple','a b'),ARRAY['a','b'],ARRAY[1,2]) $e$, $x$ERR$x$),
  ('wsp1',   $e$ ts_prox_chain(to_tsvector('simple','a 2 b 4 5 c'),ARRAY['a','c','b'],ARRAY[6,1]) $e$, $x$false$x$),
  ('wsp2',   $e$ ts_prox_chain(to_tsvector('simple','a 2 b 4 5 c'),ARRAY['a','b','c'],ARRAY[2,3]) $e$, $x$true$x$),
  ('wpin1',  $e$ ts_prox_chain(to_tsvector('simple','alpha beta x x x x x x beta gamma'),ARRAY['alpha','beta','gamma'],ARRAY[2,2]) $e$, $x$false$x$),
  -- `@@ ts_prox_query` index selection (skeleton drives the GIN index)
  ('se1',    $e$ to_tsvector('simple','a b') @@ ts_prox_query('a <~5> b') $e$, $x$true$x$),
  ('se2',    $e$ to_tsvector('simple','a') @@ ts_prox_query('a <~5> b') $e$, $x$false$x$),
  ('se3',    $e$ to_tsvector('simple','a') @@ ts_prox_query('a | b') $e$, $x$true$x$),
  ('se4',    $e$ to_tsvector('simple','c') @@ ts_prox_query('a | b') $e$, $x$false$x$),
  ('se5',    $e$ to_tsvector('simple','a c') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$true$x$),
  ('se6',    $e$ to_tsvector('simple','b c') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$true$x$),
  ('se7',    $e$ to_tsvector('simple','a') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$false$x$),
  ('se8',    $e$ to_tsvector('simple','a b c') @@ ts_prox_query('(a & b) <~5> c') $e$, $x$true$x$),
  ('se9',    $e$ to_tsvector('simple','a c') @@ ts_prox_query('(a & b) <~5> c') $e$, $x$false$x$),
  ('se10',   $e$ to_tsvector('simple','confidential') @@ ts_prox_query('confidential <!~5> email') $e$, $x$true$x$),
  ('se11',   $e$ to_tsvector('simple','email') @@ ts_prox_query('confidential <!~5> email') $e$, $x$false$x$),
  ('se12',   $e$ to_tsvector('simple','foo bar') @@ ts_prox_query('foo & !bar') $e$, $x$true$x$),
  ('se13',   $e$ to_tsvector('simple','baz') @@ ts_prox_query('foo & !bar') $e$, $x$false$x$),
  ('se14',   $e$ to_tsvector('simple','quick fox') @@ ts_prox_query('"quick fox"') $e$, $x$true$x$),
  ('se15',   $e$ to_tsvector('simple','quick brown fox') @@ ts_prox_query('"quick fox"') $e$, $x$false$x$),
  ('se16',   $e$ to_tsvector('simple','apple') @@ ts_prox_query('appl*') $e$, $x$true$x$),
  ('se17',   $e$ to_tsvector('simple','orange') @@ ts_prox_query('appl*') $e$, $x$false$x$),
  ('se18',   $e$ to_tsvector('simple','running tests') @@ ts_prox_query('te?t') $e$, $x$true$x$),
  -- skeleton lowering (`ts_prox_query_skeleton` exact text)
  ('sk1',    $e$ ts_prox_query_skeleton('a <~5> b') $e$, $x$('a' & 'b')$x$),
  ('sk2',    $e$ ts_prox_query_skeleton('(a & b) <~5> c') $e$, $x$(('a' & 'c') & ('b' & 'c'))$x$),
  ('sk3',    $e$ ts_prox_query_skeleton('"quick fox"') $e$, $x$('quick' <-> 'fox')$x$),
  ('sk4',    $e$ ts_prox_query_skeleton('appl*') $e$, $x$'appl':*$x$),
  ('sk5',    $e$ ts_prox_query_skeleton('a <2> b') $e$, $x$('a' <2> 'b')$x$),
  ('sk6',    $e$ ts_prox_query_skeleton('"a b" <~5> c') $e$, $x$(('a' <-> 'b') & 'c')$x$),
  ('sk7',    $e$ ts_prox_query_skeleton('(a | b) <~5> c') $e$, $x$(('a' | 'b') & 'c')$x$),
  ('sk8',    $e$ ts_prox_query_skeleton('foo & !bar') $e$, $x$'foo'$x$),
  ('sk9',    $e$ ts_prox_query_skeleton('confidential <!~5> email') $e$, $x$'confidential'$x$),
  ('sk10',   $e$ ts_prox_query_skeleton('te?t') $e$, $x$'te':*$x$),
  ('sk11',   $e$ ts_prox_query_skeleton('"appl* pie"') $e$, $x$('appl':* <-> 'pie')$x$),
  ('sk12',   $e$ ts_prox_query_skeleton('"*ology class"') $e$, $x$'class'$x$),
  ('sk13',   $e$ ts_prox_query_skeleton('((a <~5> b) <~10> c) <!~3> d') $e$, $x$(('a' & 'b') & 'c')$x$),
  ('sk14',   $e$ ts_prox_query_skeleton('a & b | c') $e$, $x$(('a' & 'b') | 'c')$x$),
  ('sk15',   $e$ ts_prox_query_skeleton('a <-> b <-> c') $e$, $x$('a' <-> 'b' <-> 'c')$x$),
  -- distance clamp `<0>` = same position, on a literal co-located tsvector
  ('z0b',    $e$ ts_prox_match($$'a':1 'b':1$$::tsvector,'a <~0> b') $e$, $x$true$x$),
  ('z0c',    $e$ ts_prox_match($$'a':1 'b':1$$::tsvector,'a <0> b') $e$, $x$true$x$),
  ('z0e',    $e$ ts_prox_match($$'a':1 'b':1$$::tsvector,'a <-0> b') $e$, $x$false$x$),
  ('z0f',    $e$ ts_prox_query_skeleton('a <0> b') $e$, $x$('a' <0> 'b')$x$);

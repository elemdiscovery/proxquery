-- proxquery — self-test (portable across both implementations)
-- ============================================================
-- Verifies an install against the known-good values from the extension's own
-- test suite. It uses only the portable surface (the `ts_prox_*` functions and
-- the two-clause proximity form), so the SAME suite passes against either:
--   * the pure-SQL port:  psql -f sql/proxquery_pure.sql
--   * the native extension installed into the same schema:
--                         CREATE EXTENSION proxquery SCHEMA proxquery;
-- Then:   psql -d yourdb -f sql/proxquery_pure_test.sql
--
-- Prints "all N cases passed" on success, or RAISEs with the failing cases.

SET client_min_messages = notice;
SET search_path = proxquery, pg_catalog;

CREATE OR REPLACE FUNCTION _prox_selftest_eval(expr text) RETURNS text
    LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    EXECUTE 'SELECT (' || expr || ')::text' INTO r;
    RETURN coalesce(r, '<null>');
EXCEPTION WHEN OTHERS THEN RETURN 'ERR';
END $f$;

DROP TABLE IF EXISTS _prox_cases;
CREATE TEMP TABLE _prox_cases(label text, expr text, expected text);

INSERT INTO _prox_cases(label, expr, expected) VALUES
  ('c1',     $e$ ts_prox_match(to_tsvector('simple','the quick brown fox jumps'),'"quick brown" <~3> jumps') $e$, $x$true$x$),
  ('c10',    $e$ ts_prox_match(to_tsvector('simple','the best test class'),'"te?t class"') $e$, $x$true$x$),
  ('c11',    $e$ ts_prox_match(to_tsvector('simple','the best tense class'),'"te?t class"') $e$, $x$false$x$),
  ('c12',    $e$ ts_prox_match(to_tsvector('simple','the biology class'),'*ology <-> class') $e$, $x$true$x$),
  ('c2',     $e$ ts_prox_match(to_tsvector('simple','the quick brown fox jumps'),'"quick brown" <~1> jumps') $e$, $x$false$x$),
  ('c3',     $e$ ts_prox_match(to_tsvector('simple','alpha beta x gamma delta'),'"alpha beta" <~3> "gamma delta"') $e$, $x$true$x$),
  ('c4',     $e$ ts_prox_match(to_tsvector('simple','quick brown z z z z z z email'),'"quick brown" <!~3> email') $e$, $x$true$x$),
  ('c5',     $e$ ts_prox_match(to_tsvector('simple','quick brown email'),'"quick brown" <!~3> email') $e$, $x$false$x$),
  ('c6',     $e$ ts_prox_match(to_tsvector('simple','the apple pie'),'"appl* pie"') $e$, $x$true$x$),
  ('c7',     $e$ ts_prox_match(to_tsvector('simple','the orange pie'),'"appl* pie"') $e$, $x$false$x$),
  ('c8',     $e$ ts_prox_match(to_tsvector('simple','the biology class'),'"*ology class"') $e$, $x$true$x$),
  ('c9',     $e$ ts_prox_match(to_tsvector('simple','the geography class'),'"*ology class"') $e$, $x$false$x$),
  ('err1',   $e$ ts_prox_query('*ology') $e$, $x$ERR$x$),
  ('err2',   $e$ ts_prox_match(to_tsvector('simple','a b'),'(a <~5> b') $e$, $x$ERR$x$),
  ('err3',   $e$ ts_prox_match(to_tsvector('simple','a b'),'a <!5> b') $e$, $x$ERR$x$),
  ('err4',   $e$ ts_prox_match(to_tsvector('simple','a b'),'a &') $e$, $x$ERR$x$),
  ('err5',   $e$ ts_prox_match(to_tsvector('simple','alpha beta'),'##[##') $e$, $x$ERR$x$),
  ('err6',   $e$ ts_prox_match(to_tsvector('simple','alpha beta'),'alpha | ##[##') $e$, $x$ERR$x$),
  ('err7',   $e$ ts_prox_query('!foo') $e$, $x$ERR$x$),
  ('err8',   $e$ ts_prox_match(to_tsvector('simple','a b'),'') $e$, $x$ERR$x$),
  ('f1',     $e$ to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x b'),'a <~2> b') $e$, $x$true$x$),
  ('f2',     $e$ to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x y z b'),'a <~2> b') $e$, $x$false$x$),
  ('f3',     $e$ to_tsvector('simple','a alone') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a alone'),'a <~2> b') $e$, $x$false$x$),
  ('f4',     $e$ to_tsvector('simple','the study of biology') @@ ts_prox_query('study <~3> *ology') AND ts_prox_match(to_tsvector('simple','the study of biology'),'study <~3> *ology') $e$, $x$true$x$),
  ('f5',     $e$ to_tsvector('simple','the study of cats') @@ ts_prox_query('study <~3> *ology') AND ts_prox_match(to_tsvector('simple','the study of cats'),'study <~3> *ology') $e$, $x$false$x$),
  ('f6',     $e$ to_tsvector('simple','ssn 123456789 here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_match(to_tsvector('simple','ssn 123456789 here'),'ssn <~3> ##[0-9]{9}##') $e$, $x$true$x$),
  ('f7',     $e$ to_tsvector('simple','ssn abc here') @@ ts_prox_query('ssn <~3> ##[0-9]{9}##') AND ts_prox_match(to_tsvector('simple','ssn abc here'),'ssn <~3> ##[0-9]{9}##') $e$, $x$false$x$),
  ('g1',     $e$ ts_prox_match(to_tsvector('simple','this text is confidential'),'*ial') $e$, $x$true$x$),
  ('g2',     $e$ ts_prox_match(to_tsvector('simple','this text is confidential'),'con*ial') $e$, $x$true$x$),
  ('g3',     $e$ ts_prox_match(to_tsvector('simple','this text is public'),'con*ial') $e$, $x$false$x$),
  ('g4',     $e$ ts_prox_match(to_tsvector('simple','pick the best test'),'te?t') $e$, $x$true$x$),
  ('g5',     $e$ ts_prox_match(to_tsvector('simple','pick the best tense'),'te?t') $e$, $x$false$x$),
  ('g6',     $e$ ts_prox_match(to_tsvector('simple','we love c sharp'),'''c''') $e$, $x$true$x$),
  ('g7',     $e$ ts_prox_match(to_tsvector('simple','we love rust'),'''c''') $e$, $x$false$x$),
  ('gr1',    $e$ ts_prox_match(to_tsvector('simple','a z z z z z z z z z z b c'),'(a & b) <~5> c') $e$, $x$false$x$),
  ('gr10',   $e$ ts_prox_match(to_tsvector('simple','a b z z z z z z b'),'b <!~5> a') $e$, $x$true$x$),
  ('gr2',    $e$ ts_prox_match(to_tsvector('simple','a z z z z z z z z z z b c'),'a & (b <~5> c)') $e$, $x$true$x$),
  ('gr3',    $e$ ts_prox_match(to_tsvector('simple','a z z z z z c'),'(a | b) <~5> c') $e$, $x$false$x$),
  ('gr4',    $e$ ts_prox_match(to_tsvector('simple','a z z z z z c'),'a | (b <~5> c)') $e$, $x$true$x$),
  ('gr5',    $e$ ts_prox_match(to_tsvector('simple','c alone'),'a & b | c') $e$, $x$true$x$),
  ('gr6',    $e$ ts_prox_match(to_tsvector('simple','c alone'),'a & (b | c)') $e$, $x$false$x$),
  ('gr7',    $e$ ts_prox_match(to_tsvector('simple','a x b'),'a <-5> b') $e$, $x$true$x$),
  ('gr8',    $e$ ts_prox_match(to_tsvector('simple','a x b'),'b <-5> a') $e$, $x$false$x$),
  ('gr9',    $e$ ts_prox_match(to_tsvector('simple','a b z z z z z z b'),'a <!~5> b') $e$, $x$false$x$),
  ('m1',     $e$ ts_prox_match(to_tsvector('simple','a x b'),'a <~2> b') $e$, $x$true$x$),
  ('m10',    $e$ ts_prox_match(to_tsvector('simple','email confidential confidential email'),'confidential <!~5> email') $e$, $x$false$x$),
  ('m11',    $e$ ts_prox_match(to_tsvector('simple','price foo discount'),'price <!-5> discount') $e$, $x$false$x$),
  ('m12',    $e$ ts_prox_match(to_tsvector('simple','discount foo price'),'price <!-5> discount') $e$, $x$true$x$),
  ('m13',    $e$ ts_prox_match(to_tsvector('simple','discount foo price'),'price <!~5> discount') $e$, $x$false$x$),
  ('m14',    $e$ ts_prox_match(to_tsvector('simple','a c b'),'(a & b) <~2> c') $e$, $x$true$x$),
  ('m15',    $e$ ts_prox_match(to_tsvector('simple','a w w w w c b'),'(a & b) <~2> c') $e$, $x$false$x$),
  ('m16',    $e$ ts_prox_match(to_tsvector('simple','alpha x beta x gamma'),'alpha <~2> beta <~2> gamma') $e$, $x$true$x$),
  ('m17',    $e$ ts_prox_match(to_tsvector('simple','alpha x x x beta x x x gamma'),'alpha <~2> beta <~2> gamma') $e$, $x$false$x$),
  ('m18',    $e$ ts_prox_match(to_tsvector('simple','alpha beta x x x x x x beta gamma'),'alpha <~2> beta <~2> gamma') $e$, $x$false$x$),
  ('m2',     $e$ ts_prox_match(to_tsvector('simple','a x y b'),'a <~2> b') $e$, $x$false$x$),
  ('m3',     $e$ ts_prox_match(to_tsvector('simple','a x y b'),'a <~3> b') $e$, $x$true$x$),
  ('m4',     $e$ ts_prox_match(to_tsvector('simple','a x b'),'a <-2> b') $e$, $x$true$x$),
  ('m5',     $e$ ts_prox_match(to_tsvector('simple','b x a'),'a <-2> b') $e$, $x$false$x$),
  ('m6',     $e$ ts_prox_match(to_tsvector('simple','a x b'),'a <2> b') $e$, $x$true$x$),
  ('m7',     $e$ ts_prox_match(to_tsvector('simple','a x y b'),'a <2> b') $e$, $x$false$x$),
  ('m8',     $e$ ts_prox_match(to_tsvector('simple','a b'),'a <-> b') $e$, $x$true$x$),
  ('m9',     $e$ ts_prox_match(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential <!~5> email') $e$, $x$true$x$),
  ('n1',     $e$ ts_prox_match(to_tsvector('simple','a b x c z z z z d'),'("a b" <~5> c) <~10> d') $e$, $x$true$x$),
  ('n2',     $e$ ts_prox_match(to_tsvector('simple','a b x c z z z z z z z z z z d'),'("a b" <~5> c) <~10> d') $e$, $x$false$x$),
  ('n3',     $e$ ts_prox_match(to_tsvector('simple','a b c'),'((a <~5> b) <~10> c) <!~3> d') $e$, $x$true$x$),
  ('nw1',    $e$ ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',3) $e$, $x$true$x$),
  ('nw2',    $e$ ts_prox_not_within(to_tsvector('simple','email confidential foo bar baz qux confidential'),'confidential','email',6) $e$, $x$false$x$),
  ('nw3',    $e$ ts_prox_not_within(to_tsvector('simple','confidential report only'),'confidential','email',5) $e$, $x$true$x$),
  ('o1',     $e$ ts_prox_match(to_tsvector('simple','the cat sat'),'(cat | dog) <~2> sat') $e$, $x$true$x$),
  ('o2',     $e$ ts_prox_match(to_tsvector('simple','the dog sat'),'(cat | dog) <~2> sat') $e$, $x$true$x$),
  ('o3',     $e$ ts_prox_match(to_tsvector('simple','the bird sat'),'(cat | dog) <~2> sat') $e$, $x$false$x$),
  ('o4',     $e$ ts_prox_match(to_tsvector('simple','cat z z z z z email'),'(cat | dog) <!~2> email') $e$, $x$true$x$),
  ('op1',    $e$ to_tsvector('simple','a x b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x b'),'a <~2> b') $e$, $x$true$x$),
  ('op2',    $e$ to_tsvector('simple','a x y z b') @@ ts_prox_query('a <~2> b') AND ts_prox_match(to_tsvector('simple','a x y z b'),'a <~2> b') $e$, $x$false$x$),
  ('pos1',   $e$ ts_prox_positions(to_tsvector('simple','apple apple orange'),'apple') $e$, $x${1,2}$x$),
  ('pos2',   $e$ ts_prox_positions(to_tsvector('simple','apple'),'zzz') $e$, $x${}$x$),
  ('pos3',   $e$ ts_prox_positions_prefix(to_tsvector('simple','apple apply orange'),'appl') $e$, $x${1,2}$x$),
  ('pre1',   $e$ ts_prox_pre(to_tsvector('simple','quick brown fox'),'quick','fox',2) $e$, $x$true$x$),
  ('pre2',   $e$ ts_prox_pre(to_tsvector('simple','quick brown fox'),'fox','quick',2) $e$, $x$false$x$),
  ('r1',     $e$ ts_prox_match(to_tsvector('simple','call me at 123456789 today'),'##[0-9]{9}##') $e$, $x$true$x$),
  ('r2',     $e$ ts_prox_match(to_tsvector('simple','call me at 12345 today'),'##[0-9]{9}##') $e$, $x$false$x$),
  ('r3',     $e$ ts_prox_match(to_tsvector('simple','the colour is nice'),'##colou?r##') $e$, $x$true$x$),
  ('r4',     $e$ ts_prox_match(to_tsvector('simple','the color is nice'),'##colou?r##') $e$, $x$true$x$),
  ('se1',    $e$ to_tsvector('simple','a b') @@ ts_prox_query('a <~5> b') $e$, $x$true$x$),
  ('se10',   $e$ to_tsvector('simple','confidential') @@ ts_prox_query('confidential <!~5> email') $e$, $x$true$x$),
  ('se11',   $e$ to_tsvector('simple','email') @@ ts_prox_query('confidential <!~5> email') $e$, $x$false$x$),
  ('se12',   $e$ to_tsvector('simple','foo bar') @@ ts_prox_query('foo & !bar') $e$, $x$true$x$),
  ('se13',   $e$ to_tsvector('simple','baz') @@ ts_prox_query('foo & !bar') $e$, $x$false$x$),
  ('se14',   $e$ to_tsvector('simple','quick fox') @@ ts_prox_query('"quick fox"') $e$, $x$true$x$),
  ('se15',   $e$ to_tsvector('simple','quick brown fox') @@ ts_prox_query('"quick fox"') $e$, $x$false$x$),
  ('se16',   $e$ to_tsvector('simple','apple') @@ ts_prox_query('appl*') $e$, $x$true$x$),
  ('se17',   $e$ to_tsvector('simple','orange') @@ ts_prox_query('appl*') $e$, $x$false$x$),
  ('se18',   $e$ to_tsvector('simple','running tests') @@ ts_prox_query('te?t') $e$, $x$true$x$),
  ('se2',    $e$ to_tsvector('simple','a') @@ ts_prox_query('a <~5> b') $e$, $x$false$x$),
  ('se3',    $e$ to_tsvector('simple','a') @@ ts_prox_query('a | b') $e$, $x$true$x$),
  ('se4',    $e$ to_tsvector('simple','c') @@ ts_prox_query('a | b') $e$, $x$false$x$),
  ('se5',    $e$ to_tsvector('simple','a c') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$true$x$),
  ('se6',    $e$ to_tsvector('simple','b c') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$true$x$),
  ('se7',    $e$ to_tsvector('simple','a') @@ ts_prox_query('(a | b) <~5> c') $e$, $x$false$x$),
  ('se8',    $e$ to_tsvector('simple','a b c') @@ ts_prox_query('(a & b) <~5> c') $e$, $x$true$x$),
  ('se9',    $e$ to_tsvector('simple','a c') @@ ts_prox_query('(a & b) <~5> c') $e$, $x$false$x$),
  ('sk1',    $e$ ts_prox_query_skeleton('a <~5> b') $e$, $x$('a' & 'b')$x$),
  ('sk10',   $e$ ts_prox_query_skeleton('te?t') $e$, $x$'te':*$x$),
  ('sk11',   $e$ ts_prox_query_skeleton('"appl* pie"') $e$, $x$('appl':* <-> 'pie')$x$),
  ('sk12',   $e$ ts_prox_query_skeleton('"*ology class"') $e$, $x$'class'$x$),
  ('sk13',   $e$ ts_prox_query_skeleton('((a <~5> b) <~10> c) <!~3> d') $e$, $x$(('a' & 'b') & 'c')$x$),
  ('sk14',   $e$ ts_prox_query_skeleton('a & b | c') $e$, $x$(('a' & 'b') | 'c')$x$),
  ('sk15',   $e$ ts_prox_query_skeleton('a <-> b <-> c') $e$, $x$('a' <-> 'b' <-> 'c')$x$),
  ('sk2',    $e$ ts_prox_query_skeleton('(a & b) <~5> c') $e$, $x$(('a' & 'c') & ('b' & 'c'))$x$),
  ('sk3',    $e$ ts_prox_query_skeleton('"quick fox"') $e$, $x$('quick' <-> 'fox')$x$),
  ('sk4',    $e$ ts_prox_query_skeleton('appl*') $e$, $x$'appl':*$x$),
  ('sk5',    $e$ ts_prox_query_skeleton('a <2> b') $e$, $x$('a' <2> 'b')$x$),
  ('sk6',    $e$ ts_prox_query_skeleton('"a b" <~5> c') $e$, $x$(('a' <-> 'b') & 'c')$x$),
  ('sk7',    $e$ ts_prox_query_skeleton('(a | b) <~5> c') $e$, $x$(('a' | 'b') & 'c')$x$),
  ('sk8',    $e$ ts_prox_query_skeleton('foo & !bar') $e$, $x$'foo'$x$),
  ('sk9',    $e$ ts_prox_query_skeleton('confidential <!~5> email') $e$, $x$'confidential'$x$),
  ('w1',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',2) $e$, $x$true$x$),
  ('w2',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'fox','quick',2) $e$, $x$true$x$),
  ('w3',     $e$ ts_prox_within(to_tsvector('simple','the quick brown fox'),'quick','fox',1) $e$, $x$false$x$),
  ('win1',   $e$ ts_prox_window(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[2,2]) $e$, $x$true$x$),
  ('win2',   $e$ ts_prox_window(to_tsvector('simple','alpha xx beta yy gamma'),ARRAY['alpha','beta','gamma'],ARRAY[1,1]) $e$, $x$false$x$),
  ('win3',   $e$ ts_prox_window(to_tsvector('simple','one two three four five six seven orange nine apple eleven banana'),ARRAY['apple','banana','orange'],ARRAY[2,2]) $e$, $x$false$x$),
  ('winErr', $e$ ts_prox_window(to_tsvector('simple','a b'),ARRAY['a','b'],ARRAY[1,2]) $e$, $x$ERR$x$);

DO $$
DECLARE r record; fails int := 0; n int;
BEGIN
    FOR r IN SELECT label, _prox_selftest_eval(expr) AS got, expected FROM _prox_cases ORDER BY label LOOP
        IF r.got IS DISTINCT FROM r.expected THEN
            RAISE WARNING 'FAIL %  got=[%]  expected=[%]', r.label, r.got, r.expected;
            fails := fails + 1;
        END IF;
    END LOOP;
    SELECT count(*) INTO n FROM _prox_cases;
    IF fails > 0 THEN
        RAISE EXCEPTION 'proxquery pure self-test: % of % case(s) FAILED', fails, n;
    END IF;
    RAISE NOTICE 'proxquery pure self-test: all % cases passed', n;
END $$;

DROP FUNCTION _prox_selftest_eval(text);

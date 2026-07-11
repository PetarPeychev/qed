package main

import "core:slice"
import "core:strings"
import "core:testing"
import ts "lib:tree_sitter"

// Runs `query_src` over a fresh C parse of `src` and returns the text of each
// match's first capture that survives predicate evaluation. Self-contained: it
// builds its own parser/query/cursor and touches none of the g_syntaxes cache.
@(private = "file")
pred_survivors :: proc(src, query_src: string) -> [dynamic]string {
	lang := ts.tree_sitter_c()
	parser := ts.parser_new()
	defer ts.parser_delete(parser)
	ts.parser_set_language(parser, lang)
	tree := ts.parser_parse_string(parser, nil, raw_data(src), u32(len(src)))
	defer ts.tree_delete(tree)

	eoff: u32
	etype: ts.QueryError
	query := ts.query_new(lang, raw_data(query_src), u32(len(query_src)), &eoff, &etype)
	defer ts.query_delete(query)

	preds := query_predicates_build(query)
	defer query_predicates_destroy(&preds)

	cursor := ts.query_cursor_new()
	defer ts.query_cursor_delete(cursor)
	ts.query_cursor_exec(cursor, query, ts.tree_root_node(tree))

	nt := NodeText{src = src}
	out := make([dynamic]string)
	match: ts.QueryMatch
	for ts.query_cursor_next_match(cursor, &match) {
		if !predicate_pass(preds[match.pattern_index], &match, nt) {
			continue
		}
		if match.capture_count > 0 {
			out_str := pred_node_text(nt, match.captures[0].node)
			append(&out, out_str)
		}
	}
	return out
}

@(private = "file")
pred_has :: proc(list: [dynamic]string, s: string) -> bool {
	return slice.contains(list[:], s)
}

@(test)
test_predicate_match :: proc(t: ^testing.T) {
	src := "int FOO = 1; int bar = 2; int Baz = 3;"

	// #match? — regex, SCREAMING_CASE only.
	eq := pred_survivors(src, `((identifier) @id (#match? @id "^[A-Z][A-Z_]*$"))`)
	defer delete(eq)
	testing.expect(t, pred_has(eq, "FOO"), "#match? keeps FOO")
	testing.expect(t, !pred_has(eq, "bar"), "#match? rejects bar")
	testing.expect(t, !pred_has(eq, "Baz"), "#match? rejects Baz (has lowercase)")

	// #not-match? — inverse.
	nm := pred_survivors(src, `((identifier) @id (#not-match? @id "^[A-Z][A-Z_]*$"))`)
	defer delete(nm)
	testing.expect(t, !pred_has(nm, "FOO"), "#not-match? rejects FOO")
	testing.expect(t, pred_has(nm, "bar"), "#not-match? keeps bar")
}

@(test)
test_predicate_eq :: proc(t: ^testing.T) {
	src := "int foo = 1;"

	// #eq? capture-vs-string.
	keep := pred_survivors(src, `((identifier) @id (#eq? @id "foo"))`)
	defer delete(keep)
	testing.expect(t, pred_has(keep, "foo"), "#eq? keeps matching literal")

	drop := pred_survivors(src, `((identifier) @id (#eq? @id "other"))`)
	defer delete(drop)
	testing.expect(t, len(drop) == 0, "#eq? rejects non-matching literal")

	neq := pred_survivors(src, `((identifier) @id (#not-eq? @id "foo"))`)
	defer delete(neq)
	testing.expect(t, len(neq) == 0, "#not-eq? rejects the equal literal")
}

@(test)
test_predicate_eq_capture_vs_capture :: proc(t: ^testing.T) {
	// x == x survives; y != z rejected.
	src := "void f(void){ x = x; y = z; }"
	q := `(assignment_expression left: (identifier) @l right: (identifier) @r (#eq? @l @r))`
	got := pred_survivors(src, q)
	defer delete(got)
	testing.expect(t, pred_has(got, "x"), "capture-vs-capture #eq? keeps x = x")
	testing.expect(t, !pred_has(got, "y"), "capture-vs-capture #eq? rejects y = z")
}

@(test)
test_predicate_any_of :: proc(t: ^testing.T) {
	src := "int foo; int bar; int baz;"
	got := pred_survivors(src, `((identifier) @id (#any-of? @id "foo" "baz"))`)
	defer delete(got)
	testing.expect(t, pred_has(got, "foo"), "#any-of? keeps foo")
	testing.expect(t, pred_has(got, "baz"), "#any-of? keeps baz")
	testing.expect(t, !pred_has(got, "bar"), "#any-of? rejects bar")

	inv := pred_survivors(src, `((identifier) @id (#not-any-of? @id "foo" "baz"))`)
	defer delete(inv)
	testing.expect(t, pred_has(inv, "bar"), "#not-any-of? keeps bar")
	testing.expect(t, !pred_has(inv, "foo"), "#not-any-of? rejects foo")
}

@(test)
test_predicate_lua_match :: proc(t: ^testing.T) {
	src := "int FOO; int Bar; int baz;"
	got := pred_survivors(src, `((identifier) @id (#lua-match? @id "^[A-Z][A-Z0-9_]*$"))`)
	defer delete(got)
	testing.expect(t, pred_has(got, "FOO"), "#lua-match? keeps FOO")
	testing.expect(t, !pred_has(got, "Bar"), "#lua-match? rejects Bar")
	testing.expect(t, !pred_has(got, "baz"), "#lua-match? rejects baz")
}

@(test)
test_predicate_unknown_is_noop :: proc(t: ^testing.T) {
	// An unknown predicate (#is-not? local, a nvim locals-scope extension qed does
	// not track) must be ignored, leaving the pattern to match unconditionally.
	src := "int foo; int bar;"
	got := pred_survivors(src, `((identifier) @id (#is-not? @id "local"))`)
	defer delete(got)
	testing.expect(t, pred_has(got, "foo") && pred_has(got, "bar"), "unknown predicate keeps all matches")

	// A known predicate alongside an unknown one is still enforced.
	mixed := pred_survivors(src, `((identifier) @id (#eq? @id "foo") (#is-not? @id "local"))`)
	defer delete(mixed)
	testing.expect(t, pred_has(mixed, "foo"), "known #eq? still enforced with unknown sibling")
	testing.expect(t, !pred_has(mixed, "bar"), "known #eq? rejects bar despite unknown sibling")
}

// Runs `query_src` over a C parse of `src` and reports on the first match. The
// failed predicate's kind + rendered description are captured before teardown
// (their strings point into the query, freed here). Self-contained.
@(private = "file")
pred_first_report :: proc(src, query_src: string) -> (passed: bool, kind: PredKind, desc: string) {
	lang := ts.tree_sitter_c()
	parser := ts.parser_new()
	ts.parser_set_language(parser, lang)
	tree := ts.parser_parse_string(parser, nil, raw_data(src), u32(len(src)))

	eoff: u32
	etype: ts.QueryError
	query := ts.query_new(lang, raw_data(query_src), u32(len(query_src)), &eoff, &etype)
	preds := query_predicates_build(query)

	cursor := ts.query_cursor_new()
	ts.query_cursor_exec(cursor, query, ts.tree_root_node(tree))
	nt := NodeText{src = src}
	match: ts.QueryMatch
	report := PredicateReport{passed = true}
	if ts.query_cursor_next_match(cursor, &match) {
		report = predicate_report(preds[match.pattern_index], &match, nt)
	}
	passed = report.passed
	if !passed {
		kind = report.failed.kind
		desc = strings.clone(predicate_describe(report.failed))
	}

	ts.query_cursor_delete(cursor)
	query_predicates_destroy(&preds)
	ts.query_delete(query)
	ts.tree_delete(tree)
	ts.parser_delete(parser)
	return
}

@(test)
test_predicate_report :: proc(t: ^testing.T) {
	// A lowercase identifier is rejected by @constant's SCREAMING_CASE #match?; the
	// reporting pass names which predicate did the rejecting.
	passed, kind, desc := pred_first_report("int foo = 1;", `((identifier) @constant (#match? @constant "^[A-Z][A-Z_]*$"))`)
	defer delete(desc)
	testing.expect(t, !passed, "lowercase identifier fails the #match? predicate")
	testing.expect_value(t, kind, PredKind.Match)
	testing.expect_value(t, desc, `#match? "^[A-Z][A-Z_]*$"`)

	// An all-caps identifier passes the same predicate: no failure reported.
	pass, _, _ := pred_first_report("int FOO = 1;", `((identifier) @constant (#match? @constant "^[A-Z][A-Z_]*$"))`)
	testing.expect(t, pass, "SCREAMING_CASE identifier passes the predicate")

	// #any-of? rejection is described with its value list.
	anyok, _, anydesc := pred_first_report("int bar;", `((identifier) @c (#any-of? @c "foo" "baz"))`)
	defer delete(anydesc)
	testing.expect(t, !anyok, "bar is not in the any-of set")
	testing.expect_value(t, anydesc, "#any-of? foo baz")
}

@(test)
test_predicate_has_parent :: proc(t: ^testing.T) {
	// #not-has-parent?: the identifier inside a call's argument list has parent
	// argument_list; one in a plain declaration does not.
	src := "void f(void){ g(inside); int outside; }"
	got := pred_survivors(src, `((identifier) @id (#not-has-parent? @id argument_list))`)
	defer delete(got)
	testing.expect(t, pred_has(got, "outside"), "#not-has-parent? keeps node outside argument_list")
	testing.expect(t, !pred_has(got, "inside"), "#not-has-parent? rejects node whose parent is argument_list")
}

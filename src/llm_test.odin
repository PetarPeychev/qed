package main

import "core:strings"
import "core:testing"

@(test)
test_build_prompt_includes_whole_file :: proc(t: ^testing.T) {
	b := test_buffer("from dataclasses import dataclass", "", "class Point:", "    pass")
	defer buffer_destroy(&b)

	// select the two class lines
	prompt := llm_build_prompt(&b, "make it a dataclass", {2, 0}, {3, 8})

	testing.expect(t, strings.contains(prompt, "from dataclasses import dataclass"), "prefix/import present")
	testing.expect(t, strings.contains(prompt, "<<<SELECT\nclass Point:\n    pass\nSELECT>>>"), "selection marked")
	testing.expect(t, strings.contains(prompt, "make it a dataclass"), "instruction present")
}

@(test)
test_extract_no_fence :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_extract_code("hello\nworld"), "hello\nworld")
}

@(test)
test_extract_wrapped :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_extract_code("```odin\nx := 1\n```"), "x := 1")
}

@(test)
test_extract_no_lang :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_extract_code("```\nfoo\n```"), "foo")
}

@(test)
test_extract_strips_preamble :: proc(t: ^testing.T) {
	// model reasons first, then fences the answer
	reply := "Sure, here's the refactor:\n\n```python\n@dataclass\nclass P:\n    x: int\n```"
	testing.expect_value(t, llm_extract_code(reply), "@dataclass\nclass P:\n    x: int")
}

@(test)
test_extract_takes_last_block :: proc(t: ^testing.T) {
	// reasoning contains an example fence; the real answer is the last block
	reply := "I could do ```old``` but better:\n```\nnew_code()\n```"
	testing.expect_value(t, llm_extract_code(reply), "new_code()")
}

@(test)
test_translate_before_edit :: proc(t: ^testing.T) {
	// cursor above the edited region is unchanged
	c := cursor_translate_after_edit({1, 2}, {3, 0}, {5, 0}, {3, 0})
	testing.expect_value(t, c, Cursor{1, 2})
}

@(test)
test_translate_after_edit_row_shift :: proc(t: ^testing.T) {
	// edit removes 2 rows below cursor's line; a cursor further down shifts up by 2
	c := cursor_translate_after_edit({10, 4}, {3, 0}, {5, 0}, {3, 0})
	testing.expect_value(t, c, Cursor{8, 4})
}

@(test)
test_translate_same_row_after :: proc(t: ^testing.T) {
	// cursor on the edit's end row, past `to`: col re-based onto new_end
	c := cursor_translate_after_edit({5, 8}, {5, 0}, {5, 4}, {5, 2})
	testing.expect_value(t, c, Cursor{5, 6})
}

@(test)
test_translate_inside_clamps :: proc(t: ^testing.T) {
	c := cursor_translate_after_edit({4, 1}, {3, 0}, {5, 0}, {3, 7})
	testing.expect_value(t, c, Cursor{3, 7})
}

@(test)
test_reframe_trailing_newline :: proc(t: ^testing.T) {
	// selection over-ran into the next line; the trailing "\n" must survive
	testing.expect_value(t, llm_reframe("@dataclass\nclass P:\n    x: int", "class P:\n    pass\n"), "@dataclass\nclass P:\n    x: int\n")
}

@(test)
test_reframe_leading_indent :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_reframe("y = 2", "    x = 1"), "    y = 2")
}

@(test)
test_reframe_no_framing :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_reframe("abc", "xyz"), "abc")
}

@(test)
test_reframe_both_sides :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_reframe("X", "\n  Y  \n"), "\n  X  \n")
}

@(test)
test_reframe_all_whitespace :: proc(t: ^testing.T) {
	testing.expect_value(t, llm_reframe("X", "\n\n"), "\n\nX")
}

@(test)
test_locate_single :: proc(t: ^testing.T) {
	b := test_buffer("aaa", "target", "bbb")
	defer buffer_destroy(&b)

	from, to, ok := llm_locate(&b, "target", {1, 0})
	testing.expect(t, ok)
	testing.expect_value(t, from, Cursor{1, 0})
	testing.expect_value(t, to, Cursor{1, 6})
}

@(test)
test_locate_multiline :: proc(t: ^testing.T) {
	b := test_buffer("one", "two", "three")
	defer buffer_destroy(&b)

	from, to, ok := llm_locate(&b, "two\nthree", {1, 0})
	testing.expect(t, ok)
	testing.expect_value(t, from, Cursor{1, 0})
	testing.expect_value(t, to, Cursor{2, 5})
}

@(test)
test_locate_absent :: proc(t: ^testing.T) {
	b := test_buffer("one", "two")
	defer buffer_destroy(&b)

	_, _, ok := llm_locate(&b, "missing", {0, 0})
	testing.expect(t, !ok)
}

@(test)
test_locate_nearest_of_duplicates :: proc(t: ^testing.T) {
	b := test_buffer("dup", "x", "dup", "y", "dup")
	defer buffer_destroy(&b)

	from, _, ok := llm_locate(&b, "dup", {2, 1})
	testing.expect(t, ok)
	testing.expect_value(t, from, Cursor{2, 0})
}

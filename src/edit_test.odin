package main

import "core:strings"
import "core:testing"

@(private = "file")
buffer_string :: proc(b: ^Buffer) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for line, i in b.lines {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_bytes(&sb, line.text[:])
	}
	return strings.to_string(sb)
}

@(test)
test_undo_coalesces_typing_run :: proc(t: ^testing.T) {
	b := test_buffer("")
	defer buffer_destroy(&b)

	buffer_insert_rune(&b, 'h')
	buffer_insert_rune(&b, 'i')
	testing.expect_value(t, buffer_string(&b), "hi")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "")
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_redo_restores_typing_run :: proc(t: ^testing.T) {
	b := test_buffer("")
	defer buffer_destroy(&b)

	buffer_insert_rune(&b, 'h')
	buffer_insert_rune(&b, 'i')
	buffer_undo(&b)

	buffer_redo(&b)
	testing.expect_value(t, buffer_string(&b), "hi")
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_newline_indents_after_opener :: proc(t: ^testing.T) {
	b := test_buffer("func() {")
	defer buffer_destroy(&b)
	b.cursor = {0, 8}

	buffer_newline(&b)
	testing.expect_value(t, buffer_string(&b), "func() {\n    ")
	testing.expect_value(t, b.cursor, Cursor{1, 4})
}

@(test)
test_newline_splits_brace_pair :: proc(t: ^testing.T) {
	b := test_buffer("func() {}")
	defer buffer_destroy(&b)
	b.cursor = {0, 8}

	buffer_newline(&b)
	testing.expect_value(t, buffer_string(&b), "func() {\n    \n}")
	testing.expect_value(t, b.cursor, Cursor{1, 4})
}

@(test)
test_newline_indents_after_colon_python :: proc(t: ^testing.T) {
	b := test_buffer("if x:")
	defer buffer_destroy(&b)
	b.language = .Python
	b.cursor = {0, 5}

	buffer_newline(&b)
	testing.expect_value(t, buffer_string(&b), "if x:\n    ")
	testing.expect_value(t, b.cursor, Cursor{1, 4})
}

@(test)
test_newline_colon_ignored_non_python :: proc(t: ^testing.T) {
	b := test_buffer("if x:")
	defer buffer_destroy(&b)
	b.cursor = {0, 5}

	buffer_newline(&b)
	testing.expect_value(t, buffer_string(&b), "if x:\n")
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}

@(test)
test_close_dedent_aligns_to_opener :: proc(t: ^testing.T) {
	b := test_buffer("if x {", "    foo", "    ")
	defer buffer_destroy(&b)
	b.cursor = {2, 4}

	handled := buffer_close_dedent(&b, '}')
	testing.expect(t, handled)
	testing.expect_value(t, buffer_string(&b), "if x {\n    foo\n}")
	testing.expect_value(t, b.cursor, Cursor{2, 1})
}

@(test)
test_close_dedent_skips_non_blank_prefix :: proc(t: ^testing.T) {
	b := test_buffer("    foo")
	defer buffer_destroy(&b)
	b.cursor = {0, 7}

	handled := buffer_close_dedent(&b, ')')
	testing.expect(t, !handled)
	testing.expect_value(t, buffer_string(&b), "    foo")
}

@(test)
test_indent_width_detect :: proc(t: ^testing.T) {
	two := test_buffer("def f():", "  x = 1", "  if x:", "    y = 2")
	defer buffer_destroy(&two)
	testing.expect_value(t, indent_width_detect(two.lines[:]), 2)

	four := test_buffer("func() {", "    a := 1", "    if a {", "        b := 2")
	defer buffer_destroy(&four)
	testing.expect_value(t, indent_width_detect(four.lines[:]), 4)

	flat := test_buffer("no", "indent", "here")
	defer buffer_destroy(&flat)
	testing.expect_value(t, indent_width_detect(flat.lines[:]), TAB_WIDTH)
}

@(test)
test_newline_breaks_coalescing :: proc(t: ^testing.T) {
	b := test_buffer("")
	defer buffer_destroy(&b)

	buffer_insert_rune(&b, 'a')
	buffer_newline(&b)
	buffer_insert_rune(&b, 'b')
	testing.expect_value(t, buffer_string(&b), "a\nb")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a\n")
	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a")
	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "")
}

@(test)
test_cursor_move_seals_group :: proc(t: ^testing.T) {
	b := test_buffer("")
	defer buffer_destroy(&b)

	buffer_insert_rune(&b, 'a')
	buffer_undo_commit(&b)
	buffer_insert_rune(&b, 'b')
	testing.expect_value(t, buffer_string(&b), "ab")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a")
	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "")
}

@(test)
test_backspace_deletes_indent :: proc(t: ^testing.T) {
	b := test_buffer("        pass") // 8 leading spaces, width 4
	defer buffer_destroy(&b)
	b.cursor = {0, 8}

	buffer_backspace(&b)
	testing.expect_value(t, buffer_string(&b), "    pass")
	testing.expect_value(t, b.cursor, Cursor{0, 4})
}

@(test)
test_backspace_partial_indent_snaps_to_stop :: proc(t: ^testing.T) {
	b := test_buffer("      x") // 6 leading spaces
	defer buffer_destroy(&b)
	b.cursor = {0, 6}

	buffer_backspace(&b) // snaps back to the width-4 stop: removes 2
	testing.expect_value(t, buffer_string(&b), "    x")
	testing.expect_value(t, b.cursor, Cursor{0, 4})
}

@(test)
test_backspace_after_text_is_single_char :: proc(t: ^testing.T) {
	b := test_buffer("    ab") // spaces then text
	defer buffer_destroy(&b)
	b.cursor = {0, 6}

	buffer_backspace(&b) // not in leading whitespace -> one char
	testing.expect_value(t, buffer_string(&b), "    a")
	testing.expect_value(t, b.cursor, Cursor{0, 5})
}

@(test)
test_undo_backspace :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 3}

	buffer_backspace(&b)
	testing.expect_value(t, buffer_string(&b), "ab")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 3})
}

@(test)
test_new_edit_clears_redo :: proc(t: ^testing.T) {
	b := test_buffer("")
	defer buffer_destroy(&b)

	buffer_insert_rune(&b, 'a')
	buffer_insert_rune(&b, 'b')
	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "")

	buffer_insert_rune(&b, 'c')
	buffer_redo(&b)
	testing.expect_value(t, buffer_string(&b), "c")
}

@(test)
test_undo_empty_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

@(test)
test_move_line_down_single :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_move_lines(&b, +1)
	testing.expect_value(t, buffer_string(&b), "b\na\nc")
	testing.expect_value(t, b.cursor, Cursor{1, 1})

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a\nb\nc")
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

@(test)
test_move_line_up_single :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	b.cursor = {2, 1}

	buffer_move_lines(&b, -1)
	testing.expect_value(t, buffer_string(&b), "a\nc\nb")
	testing.expect_value(t, b.cursor, Cursor{1, 1})
}

@(test)
test_move_line_up_at_top_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("a", "b")
	defer buffer_destroy(&b)
	b.cursor = {0, 0}

	buffer_move_lines(&b, -1)
	testing.expect_value(t, buffer_string(&b), "a\nb")
	testing.expect_value(t, len(b.undo), 0)
}

@(test)
test_move_line_down_at_bottom_is_noop :: proc(t: ^testing.T) {
	b := test_buffer("a", "b")
	defer buffer_destroy(&b)
	b.cursor = {1, 0}

	buffer_move_lines(&b, +1)
	testing.expect_value(t, buffer_string(&b), "a\nb")
	testing.expect_value(t, len(b.undo), 0)
}

@(test)
test_move_line_down_into_last :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	b.cursor = {1, 0}

	buffer_move_lines(&b, +1)
	testing.expect_value(t, buffer_string(&b), "a\nc\nb")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a\nb\nc")
}

@(test)
test_move_lines_block_selection :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c", "d")
	defer buffer_destroy(&b)
	b.selection = Cursor{1, 0}
	b.cursor = {2, 1}

	buffer_move_lines(&b, -1)
	testing.expect_value(t, buffer_string(&b), "b\nc\na\nd")
	testing.expect_value(t, b.cursor, Cursor{1, 1})
	anchor, _ := b.selection.?
	testing.expect_value(t, anchor, Cursor{0, 0})

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a\nb\nc\nd")
}

@(test)
test_move_lines_selection_trailing_col_zero :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c", "d")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {2, 0}

	buffer_move_lines(&b, +1)
	testing.expect_value(t, buffer_string(&b), "c\na\nb\nd")
}

@(test)
test_undo_redo_multiline :: proc(t: ^testing.T) {
	b := test_buffer("ac")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_insert_text(&b, "1\n22\n333", .Atomic)
	testing.expect_value(t, buffer_string(&b), "a1\n22\n333c")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "ac")
	testing.expect_value(t, b.cursor, Cursor{0, 1})

	buffer_redo(&b)
	testing.expect_value(t, buffer_string(&b), "a1\n22\n333c")
	testing.expect_value(t, b.cursor, Cursor{2, 3})
}

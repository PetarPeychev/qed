package main

import "core:strings"
import "core:testing"

@(private = "file")
test_buffer :: proc(lines: ..string) -> Buffer {
	b: Buffer
	b.lines = make([dynamic]Line, 0, len(lines))
	for l in lines {
		line: Line
		append(&line.text, ..transmute([]u8)l)
		append(&b.lines, line)
	}
	if len(b.lines) == 0 {
		append(&b.lines, Line{})
	}
	return b
}

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
test_selection_range_orders_endpoints :: proc(t: ^testing.T) {
	b := test_buffer("hello")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 4}
	b.cursor = {0, 1}

	from, to, ok := selection_range(&b)
	testing.expect(t, ok)
	testing.expect_value(t, from, Cursor{0, 1})
	testing.expect_value(t, to, Cursor{0, 4})
}

@(test)
test_selection_empty_is_inactive :: proc(t: ^testing.T) {
	b := test_buffer("hello")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 2}
	b.cursor = {0, 2}

	testing.expect(t, !selection_active(&b))
}

@(test)
test_replace_selection_undo_redo :: proc(t: ^testing.T) {
	b := test_buffer("hello world")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {0, 5}

	buffer_replace_selection(&b, "HI")
	testing.expect_value(t, buffer_string(&b), "HI world")
	testing.expect_value(t, b.cursor, Cursor{0, 2})
	_, has := b.selection.?
	testing.expect(t, !has)

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "hello world")

	buffer_redo(&b)
	testing.expect_value(t, buffer_string(&b), "HI world")
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_delete_selection_across_lines :: proc(t: ^testing.T) {
	b := test_buffer("abc", "def")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 1}
	b.cursor = {1, 2}

	buffer_delete_selection(&b)
	testing.expect_value(t, buffer_string(&b), "af")
	testing.expect_value(t, b.cursor, Cursor{0, 1})

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "abc\ndef")
}

@(test)
test_type_replaces_selection :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {0, 3}

	buffer_type_rune(&b, 'x')
	testing.expect_value(t, buffer_string(&b), "x")
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

@(test)
test_indent_block_undo :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {2, 1}

	buffer_indent(&b)
	testing.expect_value(t, buffer_string(&b), "    a\n    b\n    c")
	testing.expect_value(t, b.cursor, Cursor{2, 5})
	anchor, _ := b.selection.?
	testing.expect_value(t, anchor, Cursor{0, 4})

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "a\nb\nc")
}

@(test)
test_indent_excludes_trailing_line_at_col_zero :: proc(t: ^testing.T) {
	b := test_buffer("a", "b", "c")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {2, 0}

	buffer_indent(&b)
	testing.expect_value(t, buffer_string(&b), "    a\n    b\nc")
	testing.expect_value(t, b.cursor, Cursor{2, 0})
}

@(test)
test_dedent_block_removes_up_to_tab_width :: proc(t: ^testing.T) {
	b := test_buffer("      x", "  y")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {1, 3}

	buffer_dedent(&b)
	testing.expect_value(t, buffer_string(&b), "  x\ny")

	buffer_undo(&b)
	testing.expect_value(t, buffer_string(&b), "      x\n  y")
}

@(test)
test_indent_dedent_round_trip :: proc(t: ^testing.T) {
	b := test_buffer(" x", "  y", "z")
	defer buffer_destroy(&b)
	b.selection = Cursor{0, 0}
	b.cursor = {2, 1}

	buffer_indent(&b)
	testing.expect_value(t, buffer_string(&b), "     x\n      y\n    z")

	buffer_dedent(&b)
	testing.expect_value(t, buffer_string(&b), " x\n  y\nz")
}

@(test)
test_dedent_single_line_no_selection :: proc(t: ^testing.T) {
	b := test_buffer("        code")
	defer buffer_destroy(&b)
	b.cursor = {0, 8}

	buffer_dedent(&b)
	testing.expect_value(t, buffer_string(&b), "    code")
	testing.expect_value(t, b.cursor, Cursor{0, 4})
}

@(test)
test_dedent_noop_without_leading_spaces :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	buffer_dedent(&b)
	testing.expect_value(t, buffer_string(&b), "abc")
	testing.expect_value(t, len(b.undo), 0)
}

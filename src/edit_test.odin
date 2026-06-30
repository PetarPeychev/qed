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

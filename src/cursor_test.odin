package main

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

@(test)
test_move_left_right_within_line :: proc(t: ^testing.T) {
	b := test_buffer("abc")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}

	cursor_move_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 2})
	cursor_move_left(&b)
	cursor_move_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_move_left_wraps_to_prev_line :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {1, 0}

	cursor_move_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

@(test)
test_move_right_wraps_to_next_line :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	cursor_move_right(&b)
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}

@(test)
test_move_up_down_preserves_goal_col :: proc(t: ^testing.T) {
	b := test_buffer("hello", "hi", "world")
	defer buffer_destroy(&b)
	b.cursor = {0, 5}
	b.goal_col = 5

	cursor_move_down_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{1, 2})

	cursor_move_down_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{2, 5})
}

@(test)
test_move_home_end :: proc(t: ^testing.T) {
	b := test_buffer("hello")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	cursor_move_end(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 5})
	cursor_move_home(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_move_buffer_start_end :: proc(t: ^testing.T) {
	b := test_buffer("abc", "de", "fghi")
	defer buffer_destroy(&b)
	b.cursor = {1, 1}

	cursor_move_buffer_end(&b)
	testing.expect_value(t, b.cursor, Cursor{2, 4})
	cursor_move_buffer_start(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_move_word_right :: proc(t: ^testing.T) {
	b := test_buffer("foo   bar.baz")
	defer buffer_destroy(&b)
	b.cursor = {0, 0}

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 3})

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 6})

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 9})

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 10})

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 13})
}

@(test)
test_move_word_right_crosses_line :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {0, 2}

	cursor_move_word_right(&b)
	testing.expect_value(t, b.cursor, Cursor{1, 0})
}

@(test)
test_move_word_left :: proc(t: ^testing.T) {
	b := test_buffer("foo   bar.baz")
	defer buffer_destroy(&b)
	b.cursor = {0, 13}

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 10})

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 9})

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 6})

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 3})

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_move_word_left_crosses_line :: proc(t: ^testing.T) {
	b := test_buffer("ab", "cd")
	defer buffer_destroy(&b)
	b.cursor = {1, 0}

	cursor_move_word_left(&b)
	testing.expect_value(t, b.cursor, Cursor{0, 2})
}

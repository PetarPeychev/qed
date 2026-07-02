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

@(test)
test_visual_col_expands_tabs :: proc(t: ^testing.T) {
	text := transmute([]u8)string("\tab\tc")
	testing.expect_value(t, visual_col(text, 0), 0)
	testing.expect_value(t, visual_col(text, 1), 4)
	testing.expect_value(t, visual_col(text, 2), 5)
	testing.expect_value(t, visual_col(text, 3), 6)
	testing.expect_value(t, visual_col(text, 4), 8)
	testing.expect_value(t, visual_col(text, 5), 9)
	testing.expect_value(t, visual_width(text), 9)
}

@(test)
test_visual_col_no_tabs :: proc(t: ^testing.T) {
	text := transmute([]u8)string("hello")
	testing.expect_value(t, visual_col(text, 3), 3)
	testing.expect_value(t, visual_width(text), 5)
}

@(test)
test_col_at_visual_snaps_across_tabs :: proc(t: ^testing.T) {
	text := transmute([]u8)string("\tab\tc")
	testing.expect_value(t, col_at_visual(text, 0), 0)
	testing.expect_value(t, col_at_visual(text, 1), 0)
	testing.expect_value(t, col_at_visual(text, 3), 1)
	testing.expect_value(t, col_at_visual(text, 4), 1)
	testing.expect_value(t, col_at_visual(text, 5), 2)
	testing.expect_value(t, col_at_visual(text, 8), 4)
	testing.expect_value(t, col_at_visual(text, 100), 5)
}

@(test)
test_goal_col_is_visual_across_tabs :: proc(t: ^testing.T) {
	b := test_buffer("\tabc", "xyzwvu")
	defer buffer_destroy(&b)
	b.cursor = {0, 1}
	cursor_goal_sync(&b)
	testing.expect_value(t, b.goal_col, 4)

	cursor_move_down_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{1, 4})

	cursor_move_up_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{0, 1})
}

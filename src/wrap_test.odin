package main

import "core:testing"

@(test)
test_line_wrap_word_boundary :: proc(t: ^testing.T) {
	text := transmute([]u8)string("the quick brown fox")
	segs := line_wrap(text, 10)
	testing.expect_value(t, len(segs), 2)
	testing.expect_value(t, segs[0], 0)
	testing.expect_value(t, segs[1], 10) // break after "the quick ", before "brown"
}

@(test)
test_line_wrap_no_wrap :: proc(t: ^testing.T) {
	testing.expect_value(t, len(line_wrap(transmute([]u8)string("short"), 80)), 1)
	testing.expect_value(t, len(line_wrap(transmute([]u8)string(""), 80)), 1)
	testing.expect_value(t, len(line_wrap(nil, 0)), 1)
}

@(test)
test_line_wrap_long_word_hard_break :: proc(t: ^testing.T) {
	segs := line_wrap(transmute([]u8)string("abcdefghij"), 4)
	testing.expect_value(t, len(segs), 3)
	testing.expect_value(t, segs[1], 4)
	testing.expect_value(t, segs[2], 8)
}

@(test)
test_wrap_subrow :: proc(t: ^testing.T) {
	text := transmute([]u8)string("the quick brown fox")
	testing.expect_value(t, wrap_subrow(text, 10, 3), 0)
	testing.expect_value(t, wrap_subrow(text, 10, 12), 1)
}

@(test)
test_cursor_visual_down_stays_in_line :: proc(t: ^testing.T) {
	b := test_buffer("the quick brown fox")
	defer buffer_destroy(&b)
	b.wrap = true
	b.wrap_width = 10
	b.cursor = {0, 0}
	b.goal_col = 0

	cursor_move_down_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{0, 10}) // start of the 2nd visual row

	cursor_move_up_n(&b, 1)
	testing.expect_value(t, b.cursor, Cursor{0, 0})
}

@(test)
test_cursor_visual_end :: proc(t: ^testing.T) {
	b := test_buffer("the quick brown fox")
	defer buffer_destroy(&b)
	b.wrap = true
	b.wrap_width = 10

	b.cursor = {0, 10}
	cursor_move_end(&b)
	testing.expect_value(t, b.cursor.col, 19) // last row reaches the true line end
}

@(test)
test_cursor_smart_home_wrap :: proc(t: ^testing.T) {
	// Alt+Left path. Continuation visual row: first press -> visual-row start,
	// second -> logical line start.
	b := test_buffer("the quick brown fox")
	defer buffer_destroy(&b)
	b.wrap = true
	b.wrap_width = 10
	b.cursor = {0, 13} // inside "brown" on the 2nd visual row

	cursor_move_home_smart(&b)
	testing.expect_value(t, b.cursor.col, 10)
	cursor_move_home_smart(&b)
	testing.expect_value(t, b.cursor.col, 0)

	// First visual row stays indent-aware.
	b2 := test_buffer("    hi there")
	defer buffer_destroy(&b2)
	b2.wrap = true
	b2.wrap_width = 40
	b2.cursor = {0, 8}
	cursor_move_home_smart(&b2)
	testing.expect_value(t, b2.cursor.col, 4) // first non-whitespace
	cursor_move_home_smart(&b2)
	testing.expect_value(t, b2.cursor.col, 0)
}

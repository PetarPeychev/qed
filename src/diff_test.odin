package main

import "core:testing"

@(private = "file")
diff_marks :: proc(base, cur: []u64) -> []DiffMark {
	marks := make([]DiffMark, len(cur))
	hunks := make([dynamic]DiffHunk)
	defer delete(hunks)
	diff_lines(base, cur, marks, &hunks)
	return marks
}

@(private = "file")
diff_hunks :: proc(base, cur: []u64) -> [dynamic]DiffHunk {
	marks := make([]DiffMark, len(cur))
	defer delete(marks)
	hunks := make([dynamic]DiffHunk)
	diff_lines(base, cur, marks, &hunks)
	return hunks
}

@(test)
test_diff_identical :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.None)
	testing.expect_value(t, marks[1], DiffMark.None)
	testing.expect_value(t, marks[2], DiffMark.None)
}

@(test)
test_diff_insert_middle :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 9, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.None)
	testing.expect_value(t, marks[1], DiffMark.Added)
	testing.expect_value(t, marks[2], DiffMark.None)
	testing.expect_value(t, marks[3], DiffMark.None)
}

@(test)
test_diff_modify :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 9, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.None)
	testing.expect_value(t, marks[1], DiffMark.Modified)
	testing.expect_value(t, marks[2], DiffMark.None)
}

@(test)
test_diff_delete_middle :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3, 4}, {1, 4})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.Deleted)
	testing.expect_value(t, marks[1], DiffMark.None)
}

@(test)
test_diff_delete_at_end :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.Deleted)
}

@(test)
test_diff_append :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2}, {1, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.None)
	testing.expect_value(t, marks[1], DiffMark.None)
	testing.expect_value(t, marks[2], DiffMark.Added)
}

@(test)
test_diff_all_added_from_empty :: proc(t: ^testing.T) {
	marks := diff_marks({}, {1, 2})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.Added)
	testing.expect_value(t, marks[1], DiffMark.Added)
}

@(test)
test_diff_two_hunks :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3, 4, 5}, {9, 2, 3, 4, 8})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.Modified)
	testing.expect_value(t, marks[1], DiffMark.None)
	testing.expect_value(t, marks[2], DiffMark.None)
	testing.expect_value(t, marks[3], DiffMark.None)
	testing.expect_value(t, marks[4], DiffMark.Modified)
}

@(test)
test_diff_modify_then_extra_add :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 5}, {1, 3, 4, 5})
	defer delete(marks)
	testing.expect_value(t, marks[0], DiffMark.None)
	testing.expect_value(t, marks[1], DiffMark.Modified)
	testing.expect_value(t, marks[2], DiffMark.Added)
	testing.expect_value(t, marks[3], DiffMark.None)
}

@(test)
test_hunk_modify :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2, 3}, {1, 9, 3})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0].row, 1)
	testing.expect_value(t, hunks[0].above, true)
	testing.expect_value(t, hunks[0].lo, 1)
	testing.expect_value(t, hunks[0].hi, 2)
	testing.expect_value(t, hunks[0].new_n, 1)
}

@(test)
test_hunk_delete_middle :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2, 3, 4}, {1, 4})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0].row, 0)
	testing.expect_value(t, hunks[0].above, false)
	testing.expect_value(t, hunks[0].lo, 1)
	testing.expect_value(t, hunks[0].hi, 3)
	testing.expect_value(t, hunks[0].new_n, 0)
}

@(test)
test_hunk_delete_at_top :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2, 3}, {3})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0].row, 0)
	testing.expect_value(t, hunks[0].above, true)
	testing.expect_value(t, hunks[0].lo, 0)
	testing.expect_value(t, hunks[0].hi, 2)
}

@(test)
test_hunk_pure_add_none :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2}, {1, 2, 3})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 0)
}

@(test)
test_word_span_middle :: proc(t: ^testing.T) {
	o, n := diff_word_span("foo(a, b)", "foo(a, c)")
	testing.expect_value(t, o[0], 7)
	testing.expect_value(t, o[1], 8)
	testing.expect_value(t, n[0], 7)
	testing.expect_value(t, n[1], 8)
}

@(test)
test_word_span_prefix :: proc(t: ^testing.T) {
	o, n := diff_word_span("line 28", "line 28 content here")
	testing.expect_value(t, o[0], 7)
	testing.expect_value(t, o[1], 7)
	testing.expect_value(t, n[0], 7)
	testing.expect_value(t, n[1], 20)
	o2, n2 := diff_word_span("line 28 content here", "line 28")
	testing.expect_value(t, o2[0], 7)
	testing.expect_value(t, o2[1], 20)
	testing.expect_value(t, n2[0], 7)
	testing.expect_value(t, n2[1], 7)
}

@(test)
test_word_span_grow :: proc(t: ^testing.T) {
	o, n := diff_word_span("abc", "abXYc")
	testing.expect_value(t, o[0], 2)
	testing.expect_value(t, o[1], 2)
	testing.expect_value(t, n[0], 2)
	testing.expect_value(t, n[1], 4)
}

@(test)
test_diff_myers_both_empty :: proc(t: ^testing.T) {
	ops, ok := diff_myers({}, {})
	testing.expect(t, ok && len(ops) == 0, "two empty sides diff to nothing")
}

@(test)
test_diff_runs_collision_is_a_change :: proc(t: ^testing.T) {
	hunks := diff_runs({.Equal, .Equal, .Equal}, {"a", "b", "c"}, {"a", "X", "c"})
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0], [4]int{1, 1, 1, 1})
}

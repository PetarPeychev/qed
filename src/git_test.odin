package main

import "core:testing"

@(private = "file")
diff_marks :: proc(base, cur: []u64) -> []GitMark {
	marks := make([]GitMark, len(cur))
	hunks := make([dynamic]GitHunk)
	defer delete(hunks)
	git_diff(base, cur, marks, &hunks)
	return marks
}

@(private = "file")
diff_hunks :: proc(base, cur: []u64) -> [dynamic]GitHunk {
	marks := make([]GitMark, len(cur))
	defer delete(marks)
	hunks := make([dynamic]GitHunk)
	git_diff(base, cur, marks, &hunks)
	return hunks
}

@(test)
test_git_diff_identical :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.None)
	testing.expect_value(t, marks[1], GitMark.None)
	testing.expect_value(t, marks[2], GitMark.None)
}

@(test)
test_git_diff_insert_middle :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 9, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.None)
	testing.expect_value(t, marks[1], GitMark.Added)
	testing.expect_value(t, marks[2], GitMark.None)
	testing.expect_value(t, marks[3], GitMark.None)
}

@(test)
test_git_diff_modify :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1, 9, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.None)
	testing.expect_value(t, marks[1], GitMark.Modified)
	testing.expect_value(t, marks[2], GitMark.None)
}

@(test)
test_git_diff_delete_middle :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3, 4}, {1, 4})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.Deleted)
	testing.expect_value(t, marks[1], GitMark.None)
}

@(test)
test_git_diff_delete_at_end :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3}, {1})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.Deleted)
}

@(test)
test_git_diff_append :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2}, {1, 2, 3})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.None)
	testing.expect_value(t, marks[1], GitMark.None)
	testing.expect_value(t, marks[2], GitMark.Added)
}

@(test)
test_git_diff_all_added_from_empty :: proc(t: ^testing.T) {
	marks := diff_marks({}, {1, 2})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.Added)
	testing.expect_value(t, marks[1], GitMark.Added)
}

@(test)
test_git_diff_two_hunks :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 3, 4, 5}, {9, 2, 3, 4, 8})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.Modified)
	testing.expect_value(t, marks[1], GitMark.None)
	testing.expect_value(t, marks[2], GitMark.None)
	testing.expect_value(t, marks[3], GitMark.None)
	testing.expect_value(t, marks[4], GitMark.Modified)
}

@(test)
test_git_diff_modify_then_extra_add :: proc(t: ^testing.T) {
	marks := diff_marks({1, 2, 5}, {1, 3, 4, 5})
	defer delete(marks)
	testing.expect_value(t, marks[0], GitMark.None)
	testing.expect_value(t, marks[1], GitMark.Modified)
	testing.expect_value(t, marks[2], GitMark.Added)
	testing.expect_value(t, marks[3], GitMark.None)
}

@(test)
test_git_hunk_modify :: proc(t: ^testing.T) {
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
test_git_hunk_delete_middle :: proc(t: ^testing.T) {
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
test_git_hunk_delete_at_top :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2, 3}, {3})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0].row, 0)
	testing.expect_value(t, hunks[0].above, true)
	testing.expect_value(t, hunks[0].lo, 0)
	testing.expect_value(t, hunks[0].hi, 2)
}

@(test)
test_git_hunk_pure_add_none :: proc(t: ^testing.T) {
	hunks := diff_hunks({1, 2}, {1, 2, 3})
	defer delete(hunks)
	testing.expect_value(t, len(hunks), 0)
}

@(test)
test_git_word_span_middle :: proc(t: ^testing.T) {
	o, n := git_word_span("foo(a, b)", "foo(a, c)")
	testing.expect_value(t, o[0], 7)
	testing.expect_value(t, o[1], 8)
	testing.expect_value(t, n[0], 7)
	testing.expect_value(t, n[1], 8)
}

@(test)
test_git_word_span_grow :: proc(t: ^testing.T) {
	o, n := git_word_span("abc", "abXYc")
	testing.expect_value(t, o[0], 2)
	testing.expect_value(t, o[1], 2)
	testing.expect_value(t, n[0], 2)
	testing.expect_value(t, n[1], 4)
}

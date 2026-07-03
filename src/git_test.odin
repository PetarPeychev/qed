package main

import "core:testing"

@(private = "file")
diff_marks :: proc(base, cur: []u64) -> []GitMark {
	marks := make([]GitMark, len(cur))
	git_diff(base, cur, marks)
	return marks
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

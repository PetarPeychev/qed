package main

import "core:testing"

@(test)
git_numstat_line_parse :: proc(t: ^testing.T) {
	path, size, ok := git_numstat_line("3\t1\tsrc/a b.odin", false)
	testing.expect(t, ok)
	testing.expect_value(t, path, "src/a b.odin")
	testing.expect_value(t, size, GitDiffSize{3, 1})

	_, _, ok = git_numstat_line("-\t-\timg.png", false)
	testing.expect(t, !ok, "binary skipped")

	path, size, ok = git_numstat_line("dir/x:y.txt:7", true)
	testing.expect(t, ok)
	testing.expect_value(t, path, "dir/x:y.txt")
	testing.expect_value(t, size, GitDiffSize{7, 0})

	_, _, ok = git_numstat_line("garbage", true)
	testing.expect(t, !ok)

	path, size, ok = git_numstat_line("0\t4\tgone.txt", false)
	testing.expect(t, ok)
	testing.expect_value(t, path, "gone.txt")
	testing.expect_value(t, size, GitDiffSize{0, 4})

	testing.expect_value(t, git_numstat_path("old.txt => new.txt"), "new.txt")
	testing.expect_value(t, git_numstat_path("src/{a => b}/f.odin"), "src/b/f.odin")
	testing.expect_value(t, git_numstat_path("src/{ => sub}/f.odin"), "src/sub/f.odin")
	testing.expect_value(t, git_numstat_path("src/{sub => }/f.odin"), "src/f.odin")
	testing.expect_value(t, git_numstat_path("{old => }/f.odin"), "f.odin")
	testing.expect_value(t, git_numstat_path("dir/{x.txt => y.txt}"), "dir/y.txt")
}

@(test)
git_diffsize_label_format :: proc(t: ^testing.T) {
	testing.expect_value(t, git_diffsize_label({}), "")
	testing.expect_value(t, git_diffsize_label({9, 2}), "+9 -2")
}

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

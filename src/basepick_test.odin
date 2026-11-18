package main

import "core:testing"

@(test)
git_name_status_line_parse :: proc(t: ^testing.T) {
	path, mark, ok := git_name_status_line("M\tsrc/a.odin")
	testing.expect(t, ok)
	testing.expect_value(t, path, "src/a.odin")
	testing.expect_value(t, mark, GitMark.Modified)

	path, mark, ok = git_name_status_line("A\t\"new file.txt\"")
	testing.expect(t, ok)
	testing.expect_value(t, path, "new file.txt")
	testing.expect_value(t, mark, GitMark.Added)

	_, _, ok = git_name_status_line("D\tgone.txt")
	testing.expect(t, !ok, "deletions skipped")
	_, _, ok = git_name_status_line("garbage")
	testing.expect(t, !ok)
}

@(test)
basepick_parse_sections :: proc(t: ^testing.T) {
	out := "@@DEFAULT@@\norigin/main\n@@REFS@@\nmain\nfeature/x\norigin/HEAD\norigin/main\n@@LOG@@\nabc1234 fix: thing\ndef5678 feat: other\n"
	entries, ok := basepick_parse(out, context.temp_allocator)
	testing.expect(t, ok)
	want := []BasePickEntry {
		{"HEAD", "", "", false, false},
		{"Merge base with origin/main", "origin/main", "origin/main...", true, false},
		{"main", "main", "main", false, false},
		{"feature/x", "feature/x", "feature/x", false, false},
		{"origin/main", "origin/main", "origin/main", false, false},
		{"abc1234 fix: thing", "abc1234", "abc1234", false, true},
		{"def5678 feat: other", "def5678", "def5678", false, true},
	}
	testing.expect_value(t, len(entries), len(want))
	for w, i in want {
		if i < len(entries) {
			testing.expect_value(t, entries[i], w)
		}
	}

	none, nok := basepick_parse("", context.temp_allocator)
	testing.expect(t, !nok, "not a repo")
	testing.expect_value(t, len(none), 0)

	bare, bok := basepick_parse("@@DEFAULT@@\n@@REFS@@\n@@LOG@@\n", context.temp_allocator)
	testing.expect(t, bok)
	testing.expect_value(t, len(bare), 1)
}

@(test)
filetree_scan_apply_base_section :: proc(t: ^testing.T) {
	ed: Editor
	ed.working_root = "/r"
	defer {
		filetree_clear_status(&ed.filetree)
		delete(ed.filetree.status)
		delete(ed.filetree.ignored)
		delete(ed.filetree.diffsize)
	}
	out := "@@REPO@@ /r/a\n@@BASE@@\nM\tcommitted.txt\nA\tadded.txt\nD\tgone.txt\n@@STATUS@@\n M head_only.txt\n?? untracked.txt\n!! ignored.log\n@@REPO@@ /r/b\n M plain.txt\n"
	filetree_scan_apply(&ed, out)
	st := ed.filetree.status
	testing.expect_value(t, st["/r/a/committed.txt"], GitMark.Modified)
	testing.expect_value(t, st["/r/a/added.txt"], GitMark.Added)
	testing.expect_value(t, st["/r/a/untracked.txt"], GitMark.Added)
	testing.expect(t, "/r/a/gone.txt" not_in st, "deleted vs base not listed")
	testing.expect(t, "/r/a/head_only.txt" not_in st, "tracked status replaced by base diff")
	testing.expect(t, ed.filetree.ignored["/r/a/ignored.log"], "ignored kept")
	testing.expect_value(t, st["/r/b/plain.txt"], GitMark.Modified)
}

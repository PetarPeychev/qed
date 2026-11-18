package main

import "core:testing"

@(test)
git_name_status_line_parse :: proc(t: ^testing.T) {
	path, old, mark, ok := git_name_status_line("M\tsrc/a.odin")
	testing.expect(t, ok)
	testing.expect_value(t, path, "src/a.odin")
	testing.expect_value(t, old, "")
	testing.expect_value(t, mark, GitMark.Modified)

	path, old, mark, ok = git_name_status_line("A\t\"new file.txt\"")
	testing.expect(t, ok)
	testing.expect_value(t, path, "new file.txt")
	testing.expect_value(t, mark, GitMark.Added)

	path, old, mark, ok = git_name_status_line("D\tgone.txt")
	testing.expect(t, ok)
	testing.expect_value(t, path, "gone.txt")
	testing.expect_value(t, mark, GitMark.Deleted)

	path, old, mark, ok = git_name_status_line("R087\tsrc/old.odin\tlib/new.odin")
	testing.expect(t, ok)
	testing.expect_value(t, path, "lib/new.odin")
	testing.expect_value(t, old, "src/old.odin")
	testing.expect_value(t, mark, GitMark.Modified)

	_, _, _, ok = git_name_status_line("R100\tonly-one")
	testing.expect(t, !ok)
	_, _, _, ok = git_name_status_line("garbage")
	testing.expect(t, !ok)
}

@(test)
git_porcelain_line_parse :: proc(t: ^testing.T) {
	Case :: struct {
		line, path, old: string,
		mark:            GitMark,
		ok:              bool,
	}
	cases := []Case {
		{" M a.txt", "a.txt", "", .Modified, true},
		{"?? new.txt", "new.txt", "", .Added, true},
		{"A  staged.txt", "staged.txt", "", .Added, true},
		{"!! build/", "build", "", .None, true},
		{" D gone.txt", "gone.txt", "", .Deleted, true},
		{"D  rm.txt", "rm.txt", "", .Deleted, true},
		{"R  old.txt -> sub/new.txt", "sub/new.txt", "old.txt", .Modified, true},
		{"RM old.txt -> new.txt", "new.txt", "old.txt", .Modified, true},
		{"RD old.txt -> new.txt", "old.txt", "", .Deleted, true},
		{"AD temp.txt", "", "", .None, false},
		{"x", "", "", .None, false},
	}
	for c in cases {
		path, old, mark, ok := git_porcelain_line(c.line)
		testing.expectf(t, ok == c.ok && (!ok || path == c.path && old == c.old && mark == c.mark), "%q -> %q %q %v %v", c.line, path, old, mark, ok)
	}
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
		delete(ed.filetree.renames)
		delete(ed.filetree.deleted)
	}
	out := "@@REPO@@ /r/a\n@@BASE@@\nM\tcommitted.txt\nA\tadded.txt\nD\tsub/gone.txt\nR091\told.txt\tmoved.txt\n@@STATUS@@\n M head_only.txt\n?? untracked.txt\n!! ignored.log\n@@NUMSTAT@@\n2\t1\t{old.txt => moved.txt}\n0\t3\tsub/gone.txt\n@@REPO@@ /r/b\n M plain.txt\nR  x.txt -> y.txt\n D lost.txt\n"
	filetree_scan_apply(&ed, out)
	ft := &ed.filetree
	st := ft.status
	testing.expect_value(t, st["/r/a/committed.txt"], GitMark.Modified)
	testing.expect_value(t, st["/r/a/added.txt"], GitMark.Added)
	testing.expect_value(t, st["/r/a/untracked.txt"], GitMark.Added)
	testing.expect_value(t, st["/r/a/sub/gone.txt"], GitMark.Deleted)
	testing.expect_value(t, st["/r/a/sub"], GitMark.Modified)
	testing.expect_value(t, st["/r/a/moved.txt"], GitMark.Modified)
	testing.expect(t, "/r/a/old.txt" not_in st, "rename listed once, at the new path")
	testing.expect_value(t, ft.renames["/r/a/moved.txt"], "/r/a/old.txt")
	testing.expect_value(t, ft.diffsize["/r/a/moved.txt"], GitDiffSize{2, 1})
	testing.expect_value(t, ft.diffsize["/r/a/sub/gone.txt"], GitDiffSize{0, 3})
	testing.expect(t, "/r/a/head_only.txt" not_in st, "tracked status replaced by base diff")
	testing.expect(t, ft.ignored["/r/a/ignored.log"], "ignored kept")
	testing.expect_value(t, st["/r/b/plain.txt"], GitMark.Modified)
	testing.expect_value(t, st["/r/b/y.txt"], GitMark.Modified)
	testing.expect_value(t, ft.renames["/r/b/y.txt"], "/r/b/x.txt")
	testing.expect_value(t, st["/r/b/lost.txt"], GitMark.Deleted)
	testing.expect_value(t, len(ft.deleted), 2)
}

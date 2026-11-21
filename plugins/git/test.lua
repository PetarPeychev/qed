local repo = require("repo")
local picker = require("picker")
local tree = require("tree")

local T = {}

local function init(t, files)
	t.ok(t.sh("git init -q && git symbolic-ref HEAD refs/heads/main && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false"), "git init")
	for name, body in pairs(files) do
		qed.fs.write(qed.path.join(qed.root(), name), body)
	end
	t.ok(t.sh("git add -A && git commit -q -m seed"), "seed commit")
end

local function open(t, name, body)
	local b = t.open(name, body)
	t.settle()
	return b
end

local function save(t, b)
	t.key("Ctrl+s")
	t.wait(function() return not qed.buf.modified(b) end)
	t.settle()
end

local function seg(t, id)
	for _, s in ipairs(t.editor().status) do
		if s.owner == "git" and s.id == id then
			return s
		end
	end
end

local function on_screen(t, needle)
	for y = 0, 23 do
		if t.screen(y):find(needle, 1, true) then
			return true
		end
	end
	return false, t.screen(22)
end

local function mark(t, b, row, want)
	return function() return t.marks(b)[row] == want end
end

local function pick_base(t, query, selected)
	qed.run("Git: Set Diff Base")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.kind == "pick" end)
	t.type(query)
	if selected then
		t.wait(function() return t.ui().selected == selected end)
	end
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	t.settle()
end

local function base(t)
	local s = seg(t, "base")
	local icon = qed.theme.icon("status_diff_base")
	return s and s.text:sub(#icon + 1) or ""
end

local function git_tab_lists(t, name)
	t.key("Alt+g")
	t.settle()
	local found = false
	for y = 0, 21 do
		found = found or t.screen(y):find(name, 1, true) ~= nil
	end
	t.key("Esc")
	return found
end

function T.parse_picker_entries(t)
	local e = picker.entries("origin/main", {"main", "feature/x", "origin/HEAD", "origin/main"}, {"abc1234 fix: thing", "def5678 feat: other"})
	local want = {
		{label = "HEAD"},
		{label = "Merge base with origin/main", ref = "origin/main", name = "origin/main...", merge = true},
		{label = "main", ref = "main", name = "main"},
		{label = "feature/x", ref = "feature/x", name = "feature/x"},
		{label = "origin/main", ref = "origin/main", name = "origin/main"},
		{label = "abc1234 fix: thing", ref = "abc1234", name = "abc1234", commit = true},
		{label = "def5678 feat: other", ref = "def5678", name = "def5678", commit = true},
	}
	t.eq(#e, #want, "entry count")
	for i, w in ipairs(want) do
		t.eq(qed.json.encode(e[i]), qed.json.encode(w), "entry " .. i)
	end
	t.eq(#picker.entries("", {}, {}), 1, "a repo without refs offers HEAD only")
end

function T.parse_numstat(t)
	local a, d = repo.numstat("4\t2\ta.txt\n-\t-\tb.bin\n0\t3\tgone.txt\n", false)
	t.eq(a, 4, "numstat adds")
	t.eq(d, 5, "numstat deletes, binaries skipped")
	a, d = repo.numstat("new.txt:5\nblob.dat:0\ndir/x:y.txt:7\ngarbage\n", true)
	t.eq(a, 12, "untracked lines")
	t.eq(d, 0)
end

function T.parse_name_status(t)
	local function ns(line)
		return qed.json.encode({tree.name_status_line(line)})
	end
	t.eq(ns("M\tsrc/a.odin"), '["src/a.odin","modified"]')
	t.eq(ns('A\t"new file.txt"'), '["new file.txt","added"]')
	t.eq(ns("D\tgone.txt"), '["gone.txt","deleted"]')
	t.eq(ns("R087\tsrc/old.odin\tlib/new.odin"), '["lib/new.odin","modified","src/old.odin"]')
	t.eq(tree.name_status_line("R100\tonly-one"), nil)
	t.eq(tree.name_status_line("garbage"), nil)
end

function T.parse_porcelain(t)
	local cases = {
		{" M a.txt", "a.txt", "modified"},
		{"?? new.txt", "new.txt", "added"},
		{"A  staged.txt", "staged.txt", "added"},
		{"!! build/", "build", "ignored"},
		{" D gone.txt", "gone.txt", "deleted"},
		{"D  rm.txt", "rm.txt", "deleted"},
		{"R  old.txt -> sub/new.txt", "sub/new.txt", "modified", "old.txt"},
		{"RM old.txt -> new.txt", "new.txt", "modified", "old.txt"},
		{"RD old.txt -> new.txt", "old.txt", "deleted"},
		{"AD temp.txt"},
		{'?? "with space.txt"', "with space.txt", "added"},
		{"?? dir/sub/", "dir/sub", "added"},
		{" M  padded.txt ", "padded.txt", "modified"},
		{"MM both.txt", "both.txt", "modified"},
		{"x"},
	}
	for _, c in ipairs(cases) do
		t.eq(qed.json.encode({tree.porcelain_line(c[1])}), qed.json.encode({c[2], c[3], c[4]}), c[1])
	end
end

function T.parse_numstat_paths(t)
	t.eq(qed.json.encode({tree.numstat_line("3\t1\tsrc/a b.odin", false)}), '["src/a b.odin",3,1]')
	t.eq(tree.numstat_line("-\t-\timg.png", false), nil, "binary skipped")
	t.eq(qed.json.encode({tree.numstat_line("dir/x:y.txt:7", true)}), '["dir/x:y.txt",7,0]')
	t.eq(tree.numstat_line("garbage", true), nil)
	t.eq(tree.numstat_path("old.txt => new.txt"), "new.txt")
	t.eq(tree.numstat_path("src/{a => b}/f.odin"), "src/b/f.odin")
	t.eq(tree.numstat_path("src/{ => sub}/f.odin"), "src/sub/f.odin")
	t.eq(tree.numstat_path("src/{sub => }/f.odin"), "src/f.odin")
	t.eq(tree.numstat_path("{old => }/f.odin"), "f.odin")
	t.eq(tree.numstat_path("dir/{x.txt => y.txt}"), "dir/y.txt")
	t.eq(tree.numstat_path('"quoted name.txt"'), "quoted name.txt")
	t.eq(tree.numstat_path("plain/path.txt"), "plain/path.txt")
end

function T.parse_tree_status(t)
	local files, ignored = {}, {}
	tree.parse(files, ignored, "/r/a", {
		base = "M\tcommitted.txt\nA\tadded.txt\nD\tsub/gone.txt\nR091\told.txt\tmoved.txt\n",
		status = " M head_only.txt\n?? untracked.txt\n!! ignored.log\n",
		numstat = "2\t1\t{old.txt => moved.txt}\n0\t3\tsub/gone.txt\n",
		untracked = "untracked.txt:4\n",
	})
	tree.parse(files, ignored, "/r/b", {status = " M plain.txt\nR  x.txt -> y.txt\n D lost.txt\n", numstat = "", untracked = ""})
	local function f(p) return qed.json.encode(files[p]) end
	t.eq(files["/r/a/committed.txt"].mark, "modified")
	t.eq(files["/r/a/added.txt"].mark, "added")
	t.eq(f("/r/a/untracked.txt"), qed.json.encode({mark = "added", added = 4, removed = 0}))
	t.eq(f("/r/a/sub/gone.txt"), qed.json.encode({mark = "deleted", added = 0, removed = 3}))
	t.eq(f("/r/a/moved.txt"), qed.json.encode({mark = "modified", from = "/r/a/old.txt", added = 2, removed = 1}))
	t.eq(files["/r/a/old.txt"], nil, "rename listed once, at the new path")
	t.eq(files["/r/a/head_only.txt"], nil, "tracked status replaced by the base diff")
	t.eq(qed.json.encode(ignored), '["/r/a/ignored.log"]')
	t.eq(files["/r/b/plain.txt"].mark, "modified")
	t.eq(f("/r/b/y.txt"), qed.json.encode({mark = "modified", from = "/r/b/x.txt"}))
	t.eq(files["/r/b/lost.txt"].mark, "deleted")
	files["/r/c/deep/z.txt"] = {mark = "modified", from = "/r/c/other/x.txt"}
	local view = tree.view(files, {})
	local icon = qed.theme.icon("tree_renamed")
	t.eq(view.marks["/r/b/y.txt"].suffix, icon .. " x.txt", "a rename in place names the old file")
	t.eq(view.marks["/r/c/deep/z.txt"].suffix, icon .. " ../other/x.txt", "a move names the old path from the new dir")
end

function T.not_a_repo_picker(t)
	qed.run("Git: Set Diff Base")
	t.wait(function() return (t.message()) == "Working directory is not a git repository" end)
	t.eq(t.ui(), nil, "no picker outside a repo")
end

function T.base_follows_moves(t)
	init(t, {["file.txt"] = "one\ntwo\nthree\n"})
	local b = open(t, "file.txt", "one\ntwo\nthree\n")
	t.eq(t.marks(b)[2], "", "clean against HEAD")
	qed.buf.insert(b, {row = 2, col = 4}, "X")
	save(t, b)
	t.eq(t.marks(b)[2], "modified")

	t.ok(t.sh("git commit -qam second"))
	t.eq(t.marks(b)[2], "modified", "stale until the poll sees HEAD move")
	t.wait(mark(t, b, 2, ""), 5000)

	t.ok(t.sh("git branch basebr HEAD~1"))
	pick_base(t, "basebr", "basebr")
	t.wait(mark(t, b, 2, "modified"))

	t.ok(t.sh("git branch -f basebr HEAD"))
	t.eq(t.marks(b)[2], "modified", "stale until the poll sees the branch move")
	t.wait(mark(t, b, 2, ""), 5000)
end

function T.set_diff_base(t)
	init(t, {["file.txt"] = "one\ntwo\nthree\n"})
	local b = open(t, "file.txt", "one\ntwo\nthree\n")
	qed.buf.insert(b, {row = 2, col = 4}, "X")
	save(t, b)
	t.ok(t.sh("git commit -q -am second && git branch \"zb'ase\" HEAD~1"))
	t.wait(mark(t, b, 2, ""), 5000)
	t.ok(not git_tab_lists(t, "file.txt"), "committed file is clean against HEAD")
	t.eq(base(t), "", "no base label at HEAD")

	pick_base(t, "seed")
	local bs = base(t)
	t.ok(bs:match("^%x+$") and #bs >= 4 and #bs < 40, "labelled with the short sha: " .. bs)
	t.eq(t.marks(b)[2], "modified")
	t.eq(t.marks(b)[1], "")
	t.ok(on_screen(t, qed.theme.icon("status_diff_base") .. bs), "status bar shows the base")
	t.wait(function() local s = seg(t, "diff"); return s ~= nil and s.text == "+1 -1" end, 5000)
	t.ok(on_screen(t, "+1 -1"), "diff size is against the base")
	t.ok(git_tab_lists(t, "file.txt"), "Git tab lists the file changed since the base")

	pick_base(t, "zb'", "zb'ase")
	t.eq(base(t), "zb'ase")
	t.eq(t.marks(b)[2], "modified")

	t.ok(t.sh("git branch -f \"zb'ase\" HEAD"))
	t.wait(mark(t, b, 2, ""), 5000)
	t.settle()
	t.ok(not git_tab_lists(t, "file.txt"), "moved branch is followed by the Git tab")
	t.eq(seg(t, "diff").text, "", "no diff against the moved branch")

	pick_base(t, "", "HEAD")
	t.eq(base(t), "")
	t.eq(t.marks(b)[2], "")
	t.ok(not on_screen(t, qed.theme.icon("status_diff_base")), "no base indicator at HEAD")
end

function T.merge_base(t)
	init(t, {["file.txt"] = "one\ntwo\n"})
	t.ok(t.sh("git checkout -q -b feature && printf 'one\\nTWO\\n' > file.txt && git commit -qam f && git checkout -q main && printf 'ONE\\ntwo\\n' > file.txt && git commit -qam m && git checkout -q feature"))
	local b = open(t, "file.txt", "one\nTWO\n")
	pick_base(t, "merge", "Merge base with main")
	t.eq(base(t), "main...")
	t.eq(t.marks(b)[1], "", "line 1 matches the merge base, not main")
	t.eq(t.marks(b)[2], "modified")
end

function T.stat_segments(t)
	init(t, {["file.txt"] = "committed\n"})
	open(t, "file.txt", "committed\n")
	t.wait(function() local s = seg(t, "branch"); return s ~= nil and s.text ~= "" end, 5000)
	t.eq(seg(t, "branch").text, qed.theme.icon("status_branch") .. " main")
	t.eq(seg(t, "ahead_behind").text, "", "no upstream, no ahead/behind")

	qed.fs.write(qed.path.join(qed.root(), "file.txt"), "changed\nextra\n")
	qed.fs.write(qed.path.join(qed.root(), "new.txt"), "n1\nn2")
	qed.fs.write(qed.path.join(qed.root(), ".gitignore"), "*.log\n")
	qed.fs.write(qed.path.join(qed.root(), "debug.log"), "a\nb\nc\n")
	qed.fs.write(qed.path.join(qed.root(), "blob.dat"), "\0\1\n\2\n")
	t.wait(function() return seg(t, "diff").text == "+5 -1" end, 5000)
	local d = seg(t, "diff")
	t.eq(#d.chunks, 2)
	t.eq(d.chunks[1].color, "git_added")
	t.eq(d.chunks[2].color, "git_deleted")
	t.ok(on_screen(t, qed.theme.icon("status_branch") .. " main  +5 -1"), "branch then diff size")

	t.ok(t.sh("git branch up && git branch -q -u up && git commit -q --allow-empty -m ahead"))
	t.wait(function() return seg(t, "ahead_behind").text == qed.theme.icon("status_ahead") .. "1" end, 5000)
	t.eq(seg(t, "ahead_behind").sep, " ")
	t.ok(on_screen(t, "main " .. qed.theme.icon("status_ahead") .. "1"), "ahead count sits next to the branch")
end

function T.restore_staged_deletion(t)
	init(t, {["file.txt"] = "x\n", ["gone.txt"] = "alpha\nbeta\n"})
	t.ok(t.sh("git rm -q gone.txt"))
	t.settle()
	t.key("Alt+g")
	t.settle()
	t.ok(on_screen(t, "gone.txt"), "staged deletion listed")
	t.key("Enter")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.kind == "confirm" end)
	t.key("Down")
	t.key("Enter")
	t.wait(function() return (t.message()) == "Restored gone.txt" end)
	t.eq(qed.fs.read(qed.path.join(qed.root(), "gone.txt")), "alpha\nbeta\n", "restored on disk")
	t.ok(t.sh("git diff --quiet HEAD -- gone.txt && git ls-files --error-unmatch gone.txt"), "index restored too")
end

function T.restore_refuses_live_file(t)
	init(t, {["a.txt"] = "x\n"})
	qed.fs.write(qed.path.join(qed.root(), "a.txt"), "y\n")
	t.settle()
	t.key("Alt+g")
	t.settle()
	t.ok(on_screen(t, "a.txt"))
	t.key("Enter")
	t.wait(function() return not t.editor().tree end)
	t.eq(qed.fs.read(qed.path.join(qed.root(), "a.txt")), "y\n", "a live file opens instead of restoring")
end

function T.disable_removes_git(t)
	init(t, {["file.txt"] = "one\n"})
	local b = open(t, "file.txt", "one\n")
	qed.buf.insert(b, {row = 1, col = 4}, "X")
	t.eq(t.marks(b)[1], "modified")
	t.wait(function() local s = seg(t, "branch"); return s ~= nil and s.text ~= "" end, 5000)
	t.config({enabled = false}, {hot = true})
	t.eq(t.marks(b)[1], "", "no diff base without the plugin")
	t.eq(seg(t, "branch"), nil, "segments cleared")
	t.ok(not pcall(qed.run, "Git: Set Diff Base"), "commands removed")
	t.config({enabled = true}, {hot = true})
	t.settle()
	t.eq(t.marks(b)[1], "modified", "base back on re-enable")
end

function T.status_order(t)
	init(t, {["file.txt"] = "one\ntwo\n", ["other.txt"] = "x\n"})
	t.ok(t.sh("git branch up && git branch -q -u up && git commit -q --allow-empty -m ahead && git branch basebr HEAD~1"))
	open(t, "other.txt", "x\n")
	local b = open(t, "file.txt", "one\ntwo\n")
	qed.buf.insert(b, {row = 1, col = 4}, "X")
	save(t, b)
	qed.status.set("late", {text = "LATE"})
	pick_base(t, "basebr", "basebr")
	t.wait(function() return seg(t, "diff").text == "+1 -1" end, 5000)
	local icon = qed.theme.icon
	local want = ("%s main %s1  %sbasebr  +1 -1  [3/3]  LATE"):format(icon("status_branch"), icon("status_ahead"), icon("status_diff_base"))
	local found, row = on_screen(t, want)
	t.ok(found, "branch, ahead, base, diff size, buffer counter, then other plugins: " .. tostring(row))
	qed.status.clear("late")
	t.eq(qed.buf.set_base(b, "one\n", {label = "m"}), true, "a later plugin's base goes on top")
	t.ok(on_screen(t, "+1 -1  " .. icon("status_diff_base") .. "m  [3/3]"), "another plugin's label sits after the git segments")
end

function T.welcome_shows_base(t)
	init(t, {["file.txt"] = "one\n"})
	t.ok(t.sh("git branch basebr"))
	t.eq(qed.buf.list()[1] ~= nil, true)
	qed.close(qed.buf.current())
	t.ok(t.editor().welcome, "welcome screen")
	pick_base(t, "basebr", "basebr")
	t.wait(function() return on_screen(t, qed.theme.icon("status_diff_base") .. "basebr") end, 5000)
end

function T.stacking_with_another_plugin(t)
	init(t, {["file.txt"] = "one\ntwo\n"})
	local b = open(t, "file.txt", "one\ntwo\n")
	qed.buf.insert(b, {row = 1, col = 4}, "X")
	save(t, b)
	t.eq(t.marks(b)[1], "modified", "git base")
	t.eq(qed.buf.set_base(b, "oneX\ntwo\nthree\n"), true)
	t.eq(t.marks(b)[1], "", "the later plugin's base wins")
	t.ok(t.sh("mv .git .git.off"))
	save(t, b)
	t.eq(t.marks(b)[1], "", "git's transient nil changes nothing on top")
	t.ok(t.sh("mv .git.off .git"))
	save(t, b)
	t.eq(t.marks(b)[1], "", "git setting its base again stays beneath")
	t.eq(qed.buf.set_base(b, nil), false)
	t.eq(t.marks(b)[1], "modified", "clearing reveals git's base")
end

function T.close_buffer_mid_fetch(t)
	init(t, {["file.txt"] = "one\n", ["b.txt"] = "b\n"})
	open(t, "file.txt", "one\n")
	t.fake_spawn(" show ", {stdout = "b\n", delay_ms = 300})
	local b2 = t.open("b.txt", "b\n")
	t.pump(50)
	qed.close(b2)
	t.pump(2500)
	t.settle()
	t.ok(not qed.buf.valid(b2), "closed")
end

function T.git_vanishes_mid_session(t)
	init(t, {["file.txt"] = "one\n"})
	local b = open(t, "file.txt", "one\n")
	qed.buf.insert(b, {row = 1, col = 4}, "X")
	t.eq(t.marks(b)[1], "modified")
	t.wait(function() local s = seg(t, "branch"); return s ~= nil and s.text ~= "" end, 5000)
	t.fake_spawn("git -C", {code = 127, stderr = "sh: 1: git: not found"})
	save(t, b)
	t.eq(t.marks(b)[1], "", "no base once git is gone")
	t.wait(function() return seg(t, "branch").text == "" end, 5000)
	t.eq(seg(t, "diff").text, "")
end

return T

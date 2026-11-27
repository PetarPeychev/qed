local repo = require("repo")
local picker = require("picker")
local tree = require("tree")

local tests = {}

local function init(test, files)
	test.ok(test.sh("git init -q && git symbolic-ref HEAD refs/heads/main && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false"), "git init")
	for name, body in pairs(files) do
		qed.fs.write(qed.path.join(qed.root(), name), body)
	end
	test.ok(test.sh("git add -A && git commit -q -m seed"), "seed commit")
end

local function open(test, name, body)
	local buffer = test.open(name, body)
	test.settle()
	return buffer
end

local function save(test, buffer)
	test.key("Ctrl+s")
	test.wait(function() return not buffer:modified() end)
	test.settle()
end

local function seg(test, id)
	for _, segment in ipairs(test.editor().status) do
		if segment.owner == "git" and segment.id == id then
			return segment
		end
	end
end

local function on_screen(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false, test.screen(22)
end

local function mark(test, buffer, row, want)
	return function() return test.marks(buffer)[row] == want end
end

local function pick_base(test, query, selected)
	test.wait(function() return qed.run("Git: Set Diff Base") end)
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "pick" end)
	test.type(query)
	if selected then
		test.wait(function() return test.ui().selected == selected end)
	end
	test.key("Enter")
	test.wait(function() return test.ui() == nil end)
	test.settle()
end

local function base(test)
	local segment = seg(test, "base")
	local icon = qed.theme.icon("status_diff_base")
	return segment and segment.text:sub(#icon + 1) or ""
end

local function git_tab_lists(test, name)
	test.key("Alt+g")
	test.settle()
	local found = false
	for screen_row = 0, 21 do
		found = found or test.screen(screen_row):find(name, 1, true) ~= nil
	end
	test.key("Esc")
	return found
end

function tests.parse_picker_entries(test)
	local entries = picker.entries("origin/main", {"main", "feature/x", "origin/HEAD", "origin/main"}, {"abc1234 fix: thing", "def5678 feat: other"})
	local want = {
		{label = "HEAD"},
		{label = "Merge base with origin/main", ref = "origin/main", name = "origin/main...", merge = true},
		{label = "main", ref = "main", name = "main"},
		{label = "feature/x", ref = "feature/x", name = "feature/x"},
		{label = "origin/main", ref = "origin/main", name = "origin/main"},
		{label = "abc1234 fix: thing", ref = "abc1234", name = "abc1234", commit = true},
		{label = "def5678 feat: other", ref = "def5678", name = "def5678", commit = true},
	}
	test.eq(#entries, #want, "entry count")
	for i, wanted in ipairs(want) do
		test.eq(qed.json.encode(entries[i]), qed.json.encode(wanted), "entry " .. i)
	end
	test.eq(#picker.entries("", {}, {}), 1, "a repo without refs offers HEAD only")
end

function tests.parse_numstat(test)
	local additions, deleted = repo.numstat("4\t2\ta.txt\n-\t-\tb.bin\n0\t3\tgone.txt\n", false)
	test.eq(additions, 4, "numstat adds")
	test.eq(deleted, 5, "numstat deletes, binaries skipped")
	additions, deleted = repo.numstat("new.txt:5\nblob.dat:0\ndir/x:y.txt:7\ngarbage\n", true)
	test.eq(additions, 12, "untracked lines")
	test.eq(deleted, 0)
end

function tests.parse_name_status(test)
	local function ns(line)
		return qed.json.encode({tree.name_status_line(line)})
	end
	test.eq(ns("M\tsrc/a.odin"), '["src/a.odin","modified"]')
	test.eq(ns('A\t"new file.txt"'), '["new file.txt","added"]')
	test.eq(ns("D\tgone.txt"), '["gone.txt","deleted"]')
	test.eq(ns("R087\tsrc/old.odin\tlib/new.odin"), '["lib/new.odin","modified","src/old.odin"]')
	test.eq(tree.name_status_line("R100\tonly-one"), nil)
	test.eq(tree.name_status_line("garbage"), nil)
end

function tests.parse_porcelain(test)
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
	for _, case in ipairs(cases) do
		test.eq(qed.json.encode({tree.porcelain_line(case[1])}), qed.json.encode({case[2], case[3], case[4]}), case[1])
	end
end

function tests.parse_numstat_paths(test)
	test.eq(qed.json.encode({tree.numstat_line("3\t1\tsrc/a b.odin", false)}), '["src/a b.odin",3,1]')
	test.eq(tree.numstat_line("-\t-\timg.png", false), nil, "binary skipped")
	test.eq(qed.json.encode({tree.numstat_line("dir/x:y.txt:7", true)}), '["dir/x:y.txt",7,0]')
	test.eq(tree.numstat_line("garbage", true), nil)
	test.eq(tree.numstat_path("old.txt => new.txt"), "new.txt")
	test.eq(tree.numstat_path("src/{a => b}/f.odin"), "src/b/f.odin")
	test.eq(tree.numstat_path("src/{ => sub}/f.odin"), "src/sub/f.odin")
	test.eq(tree.numstat_path("src/{sub => }/f.odin"), "src/f.odin")
	test.eq(tree.numstat_path("{old => }/f.odin"), "f.odin")
	test.eq(tree.numstat_path("dir/{x.txt => y.txt}"), "dir/y.txt")
	test.eq(tree.numstat_path('"quoted name.txt"'), "quoted name.txt")
	test.eq(tree.numstat_path("plain/path.txt"), "plain/path.txt")
end

function tests.parse_tree_status(test)
	local files, ignored = {}, {}
	tree.parse(files, ignored, "/r/a", {
		base = "M\tcommitted.txt\nA\tadded.txt\nD\tsub/gone.txt\nR091\told.txt\tmoved.txt\n",
		status = " M head_only.txt\n?? untracked.txt\n!! ignored.log\n",
		numstat = "2\t1\t{old.txt => moved.txt}\n0\t3\tsub/gone.txt\n",
		untracked = "untracked.txt:4\n",
	})
	tree.parse(files, ignored, "/r/b", {status = " M plain.txt\nR  x.txt -> y.txt\n D lost.txt\n", numstat = "", untracked = ""})
	local function file_json(path) return qed.json.encode(files[path]) end
	test.eq(files["/r/a/committed.txt"].mark, "modified")
	test.eq(files["/r/a/added.txt"].mark, "added")
	test.eq(file_json("/r/a/untracked.txt"), qed.json.encode({mark = "added", added = 4, removed = 0}))
	test.eq(file_json("/r/a/sub/gone.txt"), qed.json.encode({mark = "deleted", added = 0, removed = 3}))
	test.eq(file_json("/r/a/moved.txt"), qed.json.encode({mark = "modified", from = "/r/a/old.txt", added = 2, removed = 1}))
	test.eq(files["/r/a/old.txt"], nil, "rename listed once, at the new path")
	test.eq(files["/r/a/head_only.txt"], nil, "tracked status replaced by the base diff")
	test.eq(qed.json.encode(ignored), '["/r/a/ignored.log"]')
	test.eq(files["/r/b/plain.txt"].mark, "modified")
	test.eq(file_json("/r/b/y.txt"), qed.json.encode({mark = "modified", from = "/r/b/x.txt"}))
	test.eq(files["/r/b/lost.txt"].mark, "deleted")
	files["/r/c/deep/z.txt"] = {mark = "modified", from = "/r/c/other/x.txt"}
	local view = tree.view(files, {})
	local icon = qed.theme.icon("tree_renamed")
	test.eq(view.marks["/r/b/y.txt"].suffix, icon .. " x.txt", "a rename in place names the old file")
	test.eq(view.marks["/r/c/deep/z.txt"].suffix, icon .. " ../other/x.txt", "a move names the old path from the new dir")
end

function tests.not_a_repo_picker(test)
	test.wait(function() return qed.run("Git: Set Diff Base") end)
	test.wait(function() return (test.message()) == "Working directory is not a git repository" end)
	test.eq(test.ui(), nil, "no picker outside a repo")
end

function tests.base_follows_moves(test)
	init(test, {["file.txt"] = "one\ntwo\nthree\n"})
	local buffer = open(test, "file.txt", "one\ntwo\nthree\n")
	test.eq(test.marks(buffer)[2], "", "clean against HEAD")
	buffer:insert({row = 2, col = 4}, "X")
	save(test, buffer)
	test.eq(test.marks(buffer)[2], "modified")

	test.ok(test.sh("git commit -qam second"))
	test.eq(test.marks(buffer)[2], "modified", "stale until the poll sees HEAD move")
	test.tick()
	test.wait(mark(test, buffer, 2, ""), 5000)

	test.ok(test.sh("git branch basebr HEAD~1"))
	pick_base(test, "basebr", "basebr")
	test.wait(mark(test, buffer, 2, "modified"))

	test.ok(test.sh("git branch -f basebr HEAD"))
	test.eq(test.marks(buffer)[2], "modified", "stale until the poll sees the branch move")
	test.tick()
	test.wait(mark(test, buffer, 2, ""), 5000)
end

function tests.set_diff_base(test)
	init(test, {["file.txt"] = "one\ntwo\nthree\n"})
	local buffer = open(test, "file.txt", "one\ntwo\nthree\n")
	buffer:insert({row = 2, col = 4}, "X")
	save(test, buffer)
	test.ok(test.sh("git commit -q -am second && git branch \"zb'ase\" HEAD~1"))
	test.tick()
	test.wait(mark(test, buffer, 2, ""), 5000)
	test.ok(not git_tab_lists(test, "file.txt"), "committed file is clean against HEAD")
	test.eq(base(test), "", "no base label at HEAD")

	pick_base(test, "seed")
	local bs = base(test)
	test.ok(bs:match("^%x+$") and #bs >= 4 and #bs < 40, "labelled with the short sha: " .. bs)
	test.eq(test.marks(buffer)[2], "modified")
	test.eq(test.marks(buffer)[1], "")
	test.ok(on_screen(test, qed.theme.icon("status_diff_base") .. bs), "status bar shows the base")
	test.wait(function() local segment = seg(test, "diff"); return segment ~= nil and segment.text == "+1 -1" end, 5000)
	test.ok(on_screen(test, "+1 -1"), "diff size is against the base")
	test.ok(git_tab_lists(test, "file.txt"), "Git tab lists the file changed since the base")

	pick_base(test, "zb'", "zb'ase")
	test.eq(base(test), "zb'ase")
	test.eq(test.marks(buffer)[2], "modified")

	test.ok(test.sh("git branch -f \"zb'ase\" HEAD"))
	test.tick()
	test.wait(mark(test, buffer, 2, ""), 5000)
	test.settle()
	test.ok(not git_tab_lists(test, "file.txt"), "moved branch is followed by the Git tab")
	test.eq(seg(test, "diff").text, "", "no diff against the moved branch")

	pick_base(test, "", "HEAD")
	test.eq(base(test), "")
	test.eq(test.marks(buffer)[2], "")
	test.ok(not on_screen(test, qed.theme.icon("status_diff_base")), "no base indicator at HEAD")
end

function tests.merge_base(test)
	init(test, {["file.txt"] = "one\ntwo\n"})
	test.ok(test.sh("git checkout -q -b feature && printf 'one\\nTWO\\n' > file.txt && git commit -qam f && git checkout -q main && printf 'ONE\\ntwo\\n' > file.txt && git commit -qam m && git checkout -q feature"))
	local buffer = open(test, "file.txt", "one\nTWO\n")
	pick_base(test, "merge", "Merge base with main")
	test.eq(base(test), "main...")
	test.eq(test.marks(buffer)[1], "", "line 1 matches the merge base, not main")
	test.eq(test.marks(buffer)[2], "modified")
end

function tests.stat_segments(test)
	init(test, {["file.txt"] = "committed\n"})
	open(test, "file.txt", "committed\n")
	test.tick()
	test.wait(function() local segment = seg(test, "branch"); return segment ~= nil and segment.text ~= "" end, 5000)
	test.eq(seg(test, "branch").text, qed.theme.icon("status_branch") .. " main")
	test.eq(seg(test, "ahead_behind").text, "", "no upstream, no ahead/behind")

	qed.fs.write(qed.path.join(qed.root(), "file.txt"), "changed\nextra\n")
	qed.fs.write(qed.path.join(qed.root(), "new.txt"), "n1\nn2")
	qed.fs.write(qed.path.join(qed.root(), ".gitignore"), "*.log\n")
	qed.fs.write(qed.path.join(qed.root(), "debug.log"), "a\nb\nc\n")
	qed.fs.write(qed.path.join(qed.root(), "blob.dat"), "\0\1\n\2\n")
	test.tick()
	test.wait(function() return seg(test, "diff").text == "+5 -1" end, 5000)
	local deleted = seg(test, "diff")
	test.eq(#deleted.chunks, 2)
	test.eq(deleted.chunks[1].color, "git_added")
	test.eq(deleted.chunks[2].color, "git_deleted")
	test.ok(on_screen(test, qed.theme.icon("status_branch") .. " main  +5 -1"), "branch then diff size")

	test.ok(test.sh("git branch up && git branch -q -u up && git commit -q --allow-empty -m ahead"))
	test.tick()
	test.wait(function() return seg(test, "ahead_behind").text == qed.theme.icon("status_ahead") .. "1" end, 5000)
	test.eq(seg(test, "ahead_behind").sep, " ")
	test.ok(on_screen(test, "main " .. qed.theme.icon("status_ahead") .. "1"), "ahead count sits next to the branch")
end

function tests.restore_staged_deletion(test)
	init(test, {["file.txt"] = "x\n", ["gone.txt"] = "alpha\nbeta\n"})
	test.ok(test.sh("git rm -q gone.txt"))
	test.settle()
	test.key("Alt+g")
	test.settle()
	test.ok(on_screen(test, "gone.txt"), "staged deletion listed")
	test.key("Enter")
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "confirm" end)
	test.key("Down")
	test.key("Enter")
	test.wait(function() return (test.message()) == "Restored gone.txt" end)
	test.eq(qed.fs.read(qed.path.join(qed.root(), "gone.txt")), "alpha\nbeta\n", "restored on disk")
	test.ok(test.sh("git diff --quiet HEAD -- gone.txt && git ls-files --error-unmatch gone.txt"), "index restored too")
end

function tests.restore_refuses_live_file(test)
	init(test, {["a.txt"] = "x\n"})
	qed.fs.write(qed.path.join(qed.root(), "a.txt"), "y\n")
	test.settle()
	test.key("Alt+g")
	test.settle()
	test.ok(on_screen(test, "a.txt"))
	test.key("Enter")
	test.wait(function() return not test.editor().tree end)
	test.eq(qed.fs.read(qed.path.join(qed.root(), "a.txt")), "y\n", "a live file opens instead of restoring")
end

function tests.disable_removes_git(test)
	init(test, {["file.txt"] = "one\n"})
	local buffer = open(test, "file.txt", "one\n")
	buffer:insert({row = 1, col = 4}, "X")
	test.eq(test.marks(buffer)[1], "modified")
	test.tick()
	test.wait(function() local segment = seg(test, "branch"); return segment ~= nil and segment.text ~= "" end, 5000)
	test.config({enabled = false}, {hot = true})
	test.eq(test.marks(buffer)[1], "", "no diff base without the plugin")
	test.eq(seg(test, "branch"), nil, "segments cleared")
	test.ok(not pcall(qed.run, "Git: Set Diff Base"), "commands removed")
	test.config({enabled = true}, {hot = true})
	test.settle()
	test.eq(test.marks(buffer)[1], "modified", "base back on re-enable")
end

function tests.status_order(test)
	init(test, {["file.txt"] = "one\ntwo\n", ["other.txt"] = "x\n"})
	test.ok(test.sh("git branch up && git branch -q -u up && git commit -q --allow-empty -m ahead && git branch basebr HEAD~1"))
	open(test, "other.txt", "x\n")
	local buffer = open(test, "file.txt", "one\ntwo\n")
	buffer:insert({row = 1, col = 4}, "X")
	save(test, buffer)
	qed.status.set("late", {text = "LATE"})
	pick_base(test, "basebr", "basebr")
	test.wait(function() return seg(test, "diff").text == "+1 -1" end, 5000)
	local icon = qed.theme.icon
	local want = ("%s main %s1  %sbasebr  +1 -1  [3/3]  LATE"):format(icon("status_branch"), icon("status_ahead"), icon("status_diff_base"))
	local found, row = on_screen(test, want)
	test.ok(found, "branch, ahead, base, diff size, buffer counter, then other plugins: " .. tostring(row))
	qed.status.clear("late")
	test.eq(buffer:set_base("one\n", {label = "m"}), true, "a later plugin's base goes on top")
	test.ok(on_screen(test, "+1 -1  " .. icon("status_diff_base") .. "m  [3/3]"), "another plugin's label sits after the git segments")
end

function tests.welcome_shows_base(test)
	init(test, {["file.txt"] = "one\n"})
	test.ok(test.sh("git branch basebr"))
	test.eq(qed.buf.list()[1] ~= nil, true)
	qed.close(qed.buf.current())
	test.ok(test.editor().welcome, "welcome screen")
	pick_base(test, "basebr", "basebr")
	test.wait(function() return on_screen(test, qed.theme.icon("status_diff_base") .. "basebr") end, 5000)
end

function tests.stacking_with_another_plugin(test)
	init(test, {["file.txt"] = "one\ntwo\n"})
	local buffer = open(test, "file.txt", "one\ntwo\n")
	buffer:insert({row = 1, col = 4}, "X")
	save(test, buffer)
	test.eq(test.marks(buffer)[1], "modified", "git base")
	test.eq(buffer:set_base("oneX\ntwo\nthree\n"), true)
	local mine = buffer:base()
	test.ok(mine ~= nil and mine ~= "git", "the later plugin's base is shown")
	test.eq(test.marks(buffer)[1], "", "the later plugin's base wins")
	test.ok(test.sh("mv .git .git.off"))
	save(test, buffer)
	test.eq(test.marks(buffer)[1], "", "git's transient nil changes nothing on top")
	test.ok(test.sh("mv .git.off .git"))
	save(test, buffer)
	test.eq(test.marks(buffer)[1], "", "git setting its base again stays beneath")
	test.eq(buffer:set_base(nil), true)
	test.eq(buffer:base(), "git", "clearing reveals git's base")
	test.eq(test.marks(buffer)[1], "modified", "clearing reveals git's base")
end

function tests.close_buffer_mid_fetch(test)
	init(test, {["file.txt"] = "one\n", ["b.txt"] = "b\n"})
	open(test, "file.txt", "one\n")
	test.fake_spawn(" show ", {stdout = "b\n", delay_ms = 300})
	local b2 = test.open("b.txt", "b\n")
	test.pump(50)
	qed.close(b2)
	test.pump(400)
	test.tick()
	test.settle()
	test.ok(not b2:valid(), "closed")
end

function tests.git_vanishes_mid_session(test)
	init(test, {["file.txt"] = "one\n"})
	local buffer = open(test, "file.txt", "one\n")
	buffer:insert({row = 1, col = 4}, "X")
	test.eq(test.marks(buffer)[1], "modified")
	test.tick()
	test.wait(function() local segment = seg(test, "branch"); return segment ~= nil and segment.text ~= "" end, 5000)
	test.fake_spawn("git -C", {code = 127, stderr = "sh: 1: git: not found"})
	save(test, buffer)
	test.eq(test.marks(buffer)[1], "", "no base once git is gone")
	test.tick()
	test.wait(function() return seg(test, "branch").text == "" end, 5000)
	test.eq(seg(test, "diff").text, "")
end

local function tree_labels(test)
	return table.concat(test.ui().labels, ",")
end

local function root_path(name)
	return qed.path.join(qed.root(), name)
end

local function git_tab(test)
	if not test.editor().tree then
		test.wait(function() return qed.run("Git: Changes") end)
	end
	test.settle()
	test.wait(function() local state = qed.plugin("filetree").state(); return state ~= nil and state.tab == "Git" end)
end

local function bar(test, name)
	git_tab(test)
	local entry = qed.plugin("filetree").mark(root_path(name))
	return entry and entry.bar or ""
end

local function git_select(test, name)
	git_tab(test)
	if test.ui().query ~= "" then
		test.key("Esc")
	end
	test.type(name)
	test.settle()
	test.wait(function() return test.ui().selected == name end)
end

local function tree_run(test, command, name)
	if name then
		git_select(test, name)
	else
		git_tab(test)
	end
	test.ok(qed.run(command, {scope = "filetree"}), command .. " available")
end

local function confirm(test, choice)
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "confirm" end)
	if choice == 2 then
		test.key("Down")
	end
	test.key("Enter")
	test.settle()
end

local function checkpoint(test)
	test.wait(function() return qed.run("Git: Checkpoint") end)
	test.wait(function() return ((test.message()) or ""):match("^Checkpoint %x+$") ~= nil end)
	test.settle()
end

local function reviewed(test)
	init(test, {["a.txt"] = "one\ntwo\n", ["keep.txt"] = "keep\n"})
	qed.fs.write(root_path("u.txt"), "untracked\n")
	checkpoint(test)
	qed.fs.write(root_path("a.txt"), "one\nTWO\n")
	qed.fs.write(root_path("u.txt"), "untracked\nmore\n")
	qed.fs.write(root_path("new.txt"), "fresh\n")
	test.ok(test.sh("rm keep.txt"))
end

function tests.checkpoint_is_a_diff_base(test)
	init(test, {["a.txt"] = "one\ntwo\n", ["keep.txt"] = "keep\n"})
	qed.fs.write(root_path("u.txt"), "untracked\n")
	qed.fs.write(root_path("a.txt"), "one\nTWO\n")
	local buffer = open(test, "a.txt", "one\nTWO\n")
	test.eq(test.marks(buffer)[2], "modified", "modified against HEAD")
	checkpoint(test)
	test.eq(base(test), "checkpoint")
	test.eq(test.marks(buffer)[2], "", "clean against the checkpoint")
	test.eq(bar(test, "a.txt"), "", "a.txt unchanged since the checkpoint")
	test.eq(bar(test, "u.txt"), "", "an untracked file in the checkpoint is not added")
	test.key("Esc")
	test.ok(test.sh("test \"$(git status --porcelain)\" = \"$(printf ' M a.txt\\n?? u.txt')\""), "HEAD and the index untouched")

	buffer:insert({row = 1, col = 1}, "zero\n")
	save(test, buffer)
	test.eq(test.marks(buffer)[1], "added", "an edit marks against the checkpoint")
	qed.fs.write(root_path("u.txt"), "untracked\nmore\n")
	qed.fs.write(root_path("new.txt"), "fresh\n")
	test.ok(test.sh("rm keep.txt"))
	test.eq(bar(test, "a.txt"), "git_modified")
	test.eq(bar(test, "u.txt"), "git_modified", "an untracked file changed since the checkpoint")
	test.eq(bar(test, "new.txt"), "git_added", "a file created since the checkpoint")
	test.eq(bar(test, "keep.txt"), "git_deleted", "a file deleted since the checkpoint")
	test.key("Esc")
	test.tick()
	test.wait(function() return seg(test, "diff").text == "+3 -1" end, 5000)

	pick_base(test, "", "HEAD")
	test.eq(base(test), "")
	test.eq(test.marks(buffer)[3], "modified", "back on HEAD")
	pick_base(test, "Checkpoint", nil)
	test.eq(base(test), "checkpoint", "the picker lists the checkpoint")
	test.eq(test.marks(buffer)[3], "")
end

function tests.accept_file_and_all(test)
	reviewed(test)
	test.eq(bar(test, "new.txt"), "git_added")
	tree_run(test, "Git: Accept File", "new.txt")
	test.wait(function() return (test.message()) == "Accepted new.txt" end)
	test.key("Esc")
	test.eq(bar(test, "new.txt"), "", "an accepted file drops off")
	test.eq(bar(test, "a.txt"), "git_modified", "the others stay")
	tree_run(test, "Git: Accept File", "keep.txt")
	test.wait(function() return (test.message()) == "Accepted keep.txt" end)
	test.key("Esc")
	test.eq(bar(test, "keep.txt"), "", "an accepted deletion drops off")
	test.ok(test.sh("test \"$(git status --porcelain)\" = \"$(printf ' M a.txt\\n D keep.txt\\n?? new.txt\\n?? u.txt')\""), "HEAD and the index untouched")

	tree_run(test, "Git: Accept All")
	test.wait(function() return ((test.message()) or ""):match("^Checkpoint ") ~= nil end)
	test.settle()
	test.eq(bar(test, "a.txt"), "")
	test.eq(bar(test, "u.txt"), "")
	test.eq(test.ui().hint, "No changes")
end

function tests.accept_needs_a_checkpoint_base(test)
	reviewed(test)
	pick_base(test, "", "HEAD")
	git_select(test, "a.txt")
	test.eq(qed.run("Git: Accept File", {scope = "filetree"}), nil, "unavailable against HEAD")
	test.eq(qed.run("Git: Accept All", {scope = "filetree"}), nil)
end

function tests.restore_against_head(test)
	init(test, {["a.txt"] = "one\n", ["gone.txt"] = "alpha\n"})
	qed.fs.write(root_path("a.txt"), "changed\n")
	test.ok(test.sh("echo staged > staged.txt && git add staged.txt && echo x > b.txt && git add b.txt && echo mod >> a.txt && git add a.txt && rm gone.txt"))
	tree_run(test, "Git: Restore File", "a.txt")
	confirm(test, 1)
	test.eq(qed.fs.read(root_path("a.txt")), "changed\nmod\n", "Cancel keeps the file")
	tree_run(test, "Git: Restore File", "a.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Restored a.txt" end)
	test.eq(qed.fs.read(root_path("a.txt")), "one\n")
	test.key("Esc")
	tree_run(test, "Git: Restore File", "staged.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Deleted staged.txt" end)
	test.ok(not qed.fs.exists(root_path("staged.txt")), "an added file is deleted")
	test.key("Esc")
	tree_run(test, "Git: Restore File", "gone.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Restored gone.txt" end)
	test.eq(qed.fs.read(root_path("gone.txt")), "alpha\n", "a deleted file is recreated")
	test.ok(test.sh("test \"$(git status --porcelain)\" = 'A  b.txt'"), "restored files match HEAD in the index too")
end

function tests.restore_against_checkpoint(test)
	reviewed(test)
	local buffer = open(test, "u.txt", "untracked\nmore\n")
	open(test, "new.txt", "fresh\n")
	tree_run(test, "Git: Restore File", "u.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Restored u.txt" end)
	test.eq(qed.fs.read(root_path("u.txt")), "untracked\n", "back to its checkpoint content")
	test.key("Esc")
	tree_run(test, "Git: Restore File", "new.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Deleted new.txt" end)
	test.ok(not qed.fs.exists(root_path("new.txt")), "a file new since the checkpoint is deleted")
	test.key("Esc")
	tree_run(test, "Git: Restore File", "keep.txt")
	confirm(test, 2)
	test.wait(function() return (test.message()) == "Restored keep.txt" end)
	test.eq(qed.fs.read(root_path("keep.txt")), "keep\n")
	test.key("Esc")
	test.ok(test.sh("test \"$(git status --porcelain)\" = \"$(printf ' M a.txt\\n?? u.txt')\""), "the index untouched")
	test.poll_disk()
	test.eq(buffer:text(), "untracked\n", "the clean buffer reloads")
	for _, open_buffer in ipairs(qed.buf.list()) do
		test.ok(open_buffer:path() ~= root_path("new.txt"), "the deleted file's buffer is closed")
	end
end

function tests.restore_refuses_unsaved(test)
	reviewed(test)
	local buffer = open(test, "a.txt", "one\nTWO\n")
	buffer:insert({row = 1, col = 1}, "x")
	tree_run(test, "Git: Restore File", "a.txt")
	test.wait(function() return (test.message()) == "Unsaved edits in a.txt" end)
	test.eq(test.ui().kind ~= "confirm", true, "no confirm")
	test.eq(qed.fs.read(root_path("a.txt")), "one\nTWO\n")
end

function tests.checkpoint_failures_change_nothing(test)
	reviewed(test)
	test.fake_spawn("write-tree", {code = 1, stderr = "fatal: broken"})
	tree_run(test, "Git: Accept File", "new.txt")
	test.wait(function() return (test.message()) == "Accept failed: fatal: broken" end)
	test.key("Esc")
	test.eq(bar(test, "new.txt"), "git_added", "a failed accept keeps the checkpoint")
	test.key("Esc")
	test.ok(qed.run("Git: Checkpoint"))
	test.wait(function() return (test.message()) == "Checkpoint failed: fatal: broken" end)
	test.eq(base(test), "checkpoint", "a failed checkpoint keeps the base")
	test.fake_spawn("ls-tree", {code = 128, stderr = "fatal: broken"})
	tree_run(test, "Git: Restore File", "u.txt")
	test.wait(function() return (test.message()) == "Restore failed: cannot read checkpoint" end)
	test.eq(qed.fs.read(root_path("u.txt")), "untracked\nmore\n", "a failed lookup writes nothing")
end

function tests.checkpoint_outside_a_repo(test)
	test.wait(function() return qed.run("Git: Checkpoint") end)
	test.wait(function() return (test.message()) == "Working directory is not a git repository" end)
	test.eq(base(test), "")
end

function tests.checkpoint_resets_on_root_change(test)
	reviewed(test)
	test.ok(test.sh("mkdir -p sub"))
	test.ok(qed.set_root(root_path("sub")))
	test.settle()
	test.eq(base(test), "", "a root change drops the checkpoint base")
	test.wait(function() return qed.run("Git: Set Diff Base") end)
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "pick" end)
	for _, label in ipairs(test.ui().labels) do
		test.ok(not label:match("^Checkpoint"), "and the picker entry")
	end
	test.key("Esc")
end

function tests.walk_starts_outside_a_repo(test)
	test.ok(test.sh("mkdir -p proj/sub && echo x > proj/sub/b.txt"))
	test.fake_spawn("find ", {delay_ms = 2500})
	test.ok(qed.set_root(qed.path.join(qed.root(), "proj")))
	test.pump(300)
	qed.run("File Tree: All")
	test.key("Alt+e")
	test.eq(tree_labels(test), "sub,b.txt", "expand all runs before the nested repo search ends")
	test.key("Alt+g")
	test.eq(test.ui().hint, "Loading git status")
	test.wait(function() return test.ui().hint == "Not a git repository" end, 8000)
end

function tests.status_failure_releases_the_walk(test)
	test.ok(test.sh("mkdir -p proj/sub && echo x > proj/sub/b.txt && git -C proj init -q"))
	test.fake_spawn("status --porcelain", {code = 128, stderr = "fatal: broken"})
	test.ok(qed.set_root(qed.path.join(qed.root(), "proj")))
	test.settle()
	qed.run("File Tree: All")
	test.key("Alt+e")
	test.eq(tree_labels(test), "sub,b.txt", "the walk is not held after a failed status")
	test.key("Alt+g")
	test.eq(test.ui().hint, "Git status failed")
end

return tests

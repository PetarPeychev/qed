local repo = require("repo")
local picker = require("picker")

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
	return false
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
	local got
	local h = qed.command{name = "Probe Base", run = function(ctx) got = ctx.base end}
	qed.run("Probe Base")
	t.wait(function() return got ~= nil end)
	h:remove()
	return got
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
	t.eq(base(t).ref, "HEAD")

	pick_base(t, "seed")
	local bs = base(t)
	t.eq(#bs.ref, 40, "a commit pick is a fixed sha")
	t.eq(bs.merge, false)
	t.eq(bs.label, bs.ref:sub(1, #bs.label), "labelled with the short sha")
	t.eq(t.marks(b)[2], "modified")
	t.eq(t.marks(b)[1], "")
	t.ok(on_screen(t, qed.theme.icon("status_diff_base") .. bs.label), "status bar shows the base")
	t.wait(function() local s = seg(t, "diff"); return s ~= nil and s.text == "+1 -1" end, 5000)
	t.ok(on_screen(t, "+1 -1"), "diff size is against the base")
	t.ok(git_tab_lists(t, "file.txt"), "Git tab lists the file changed since the base")

	pick_base(t, "zb'", "zb'ase")
	t.eq(base(t).ref, "zb'ase")
	t.eq(base(t).merge, false)
	t.eq(t.marks(b)[2], "modified")

	t.ok(t.sh("git branch -f \"zb'ase\" HEAD"))
	t.wait(mark(t, b, 2, ""), 5000)
	t.settle()
	t.ok(not git_tab_lists(t, "file.txt"), "moved branch is followed by the Git tab")
	t.eq(seg(t, "diff").text, "", "no diff against the moved branch")

	pick_base(t, "", "HEAD")
	t.eq(base(t).ref, "HEAD")
	t.eq(t.marks(b)[2], "")
	t.ok(not on_screen(t, qed.theme.icon("status_diff_base")), "no base indicator at HEAD")
end

function T.merge_base(t)
	init(t, {["file.txt"] = "one\ntwo\n"})
	t.ok(t.sh("git checkout -q -b feature && printf 'one\\nTWO\\n' > file.txt && git commit -qam f && git checkout -q main && printf 'ONE\\ntwo\\n' > file.txt && git commit -qam m && git checkout -q feature"))
	local b = open(t, "file.txt", "one\nTWO\n")
	pick_base(t, "merge", "Merge base with main")
	local bs = base(t)
	t.eq(bs.ref, "main")
	t.eq(bs.merge, true)
	t.eq(bs.label, "main...")
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

return T

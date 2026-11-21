local T = {}

local function rg(t)
	local ok = t.sh("command -v rg")
	-- CI sets QED_REQUIRE_RG so a runner without rg fails instead of skipping these tests
	t.ok(ok or not t.sh('[ -n "$QED_REQUIRE_RG" ]'), "QED_REQUIRE_RG is set but rg is not on PATH")
	return ok
end

local function write(name, body)
	local path = qed.path.join(qed.root(), name)
	qed.fs.write(path, body)
	return path
end

local function results(t)
	t.wait(function()
		local ui = t.ui()
		return ui ~= nil and ui.matches > 0
	end)
	return t.ui()
end

local function open(t)
	t.key("Alt+F")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.id == "search" end)
end

local function on_screen(t, needle)
	for y = 0, 23 do
		if t.screen(y):find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function git_init(t, files)
	t.ok(t.sh("git init -q && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false"), "git init")
	for name, body in pairs(files) do
		write(name, body)
	end
	t.ok(t.sh("git add -A && git commit -q -m seed"), "seed commit")
end

local function changes_tab(t)
	t.key("Alt+f")
	t.settle()
	t.key("Right")
	t.key("Right")
	t.settle()
end

function T.search_opens_hit(t)
	if not rg(t) then
		return
	end
	write("hay.txt", "first line\nneedle_xyz here\n")
	open(t)
	t.type("needle_xyz")
	local ui = results(t)
	t.eq(ui.selected, "hay.txt:2  needle_xyz here", "label is path:row  text")
	t.ok(on_screen(t, "needle_xyz here"), "the preview or list shows the hit")
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	t.eq(qed.path.base(qed.buf.path()), "hay.txt", "Enter opens the hit")
	t.eq(qed.buf.cursor().row, 2, "on its row")
end

function T.results_sorted_and_counted(t)
	if not rg(t) then
		return
	end
	write("b.txt", "zz_needle\nzz_needle\n")
	write("a.txt", "x zz_needle\n")
	open(t)
	t.type("zz_needle")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.matches == 3 end)
	local ui = t.ui()
	t.eq(ui.labels[1], "a.txt:1  x zz_needle")
	t.eq(ui.labels[2], "b.txt:1  zz_needle")
	t.eq(ui.labels[3], "b.txt:2  zz_needle")
	t.ok(on_screen(t, "3│"), "the match count renders by the divider")
	t.key("Esc")
end

function T.short_query_hint(t)
	if not rg(t) then
		return
	end
	write("q.txt", "q\n")
	open(t)
	t.wait(function() return t.ui().hint ~= "" end)
	t.ok(on_screen(t, "Type at least 2 characters to search"), "the hint renders")
	t.type("q")
	t.pump(200)
	t.eq(t.ui().matches, 0, "one char does not search")
	t.key("Esc")
	t.config({min_query = 1}, {hot = true})
	open(t)
	t.type("q")
	results(t)
	t.eq(t.ui().hint, "", "a search clears the hint")
	t.key("Esc")
end

function T.query_not_persisted(t)
	if not rg(t) then
		return
	end
	t.open("main.txt", "needle_xyz here\nneedle_xyz again\nneedle_xyz third")
	open(t)
	t.type("needle_xyz")
	results(t)
	t.key("Esc")

	open(t)
	t.eq(t.ui().query, "", "the query does not persist")
	t.key("Esc")

	qed.buf.set_selection(nil, {row = 1, col = 1}, {row = 1, col = 11})
	open(t)
	t.eq(t.ui().query, "needle_xyz", "a single-line selection pre-fills")
	local ui = results(t)
	t.eq(ui.selected, t.ui().labels[1], "a pre-fill starts on the first match")
	t.key("Esc")
end

function T.dash_scope(t)
	if not rg(t) then
		return
	end
	write("-dash/f.txt", "needle_xyz in dash")
	t.key("Alt+f")
	t.settle()
	open(t)
	t.type("needle_xyz")
	local ui = results(t)
	t.eq(ui.labels[1], "-dash/f.txt:1  needle_xyz in dash", "a scope path starting with - is a path")
	t.key("Esc")
	t.key("Esc")
end

function T.chord_closes(t)
	if not rg(t) then
		return
	end
	open(t)
	t.key("Alt+F")
	t.eq(t.ui(), nil, "the opening chord closes the picker")
end

function T.rg_missing(t)
	t.fake_spawn("command -v rg", {code = 1})
	t.key("Alt+F")
	t.pump(50)
	t.eq(t.ui(), nil, "no picker without rg")
	local msg, level, source = t.message()
	t.eq(msg, "ripgrep (rg) not found")
	t.eq(level, "error")
	t.eq(source, "Search")
end

function T.tree_dir_scope(t)
	if not rg(t) then
		return
	end
	write("sub/inner.txt", "needle_xyz inside sub")
	write("outside.txt", "needle_xyz at root")
	t.key("Alt+f")
	t.settle()
	open(t)
	t.ok(t.editor().tree, "the tree stays open underneath")
	t.type("needle_xyz")
	local ui = results(t)
	for _, label in ipairs(ui.labels) do
		t.ok(label:sub(1, 4) == "sub/", "confined to the selected dir: " .. label)
	end
	t.key("Esc")
	t.eq(t.ui().id, "filetree", "Esc closes the search, the tree resumes")
	t.key("Esc")
end

function T.tree_open_result_closes_tree(t)
	if not rg(t) then
		return
	end
	write("hay.txt", "first line\nneedle_xyz here\n")
	t.key("Alt+f")
	t.settle()
	open(t)
	t.type("needle_xyz")
	results(t)
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	t.ok(not t.editor().tree, "opening a result closes the tree")
	t.eq(qed.path.base(qed.buf.path()), "hay.txt")
	t.eq(qed.buf.cursor().row, 2)
end

function T.tree_changes_scope(t)
	if not rg(t) or not t.sh("command -v git") then
		return
	end
	git_init(t, {["committed.txt"] = "committed needle_xyz\n"})
	write("new.txt", "fresh needle_xyz\n")
	changes_tab(t)
	t.key("Ctrl+a")
	open(t)
	t.type("needle_xyz")
	local ui = results(t)
	for _, label in ipairs(ui.labels) do
		t.ok(label:find("new.txt", 1, true) == 1, "confined to changed files: " .. label)
	end
	t.key("Esc")
	t.key("Esc")
end

function T.tree_changes_dir_scope(t)
	if not rg(t) or not t.sh("command -v git") then
		return
	end
	git_init(t, {["committed.txt"] = "committed needle_xyz\n"})
	write("sub/mod.txt", "fresh needle_xyz\n")
	write("root_new.txt", "needle_xyz root\n")
	changes_tab(t)
	open(t)
	t.type("needle_xyz")
	local ui = results(t)
	for _, label in ipairs(ui.labels) do
		t.ok(label:sub(1, 4) == "sub/", "confined to changed files under the dir: " .. label)
	end
	t.key("Esc")
	t.key("Esc")
end

local function fifo_scope(t, body)
	write("a.txt", body)
	t.ok(t.sh("mkfifo b_fifo"), "mkfifo")
	t.key("Alt+f")
	t.settle()
	for _ = 1, 4 do
		t.key("Up")
	end
	t.key("Shift+Down")
end

function T.streams_while_rg_runs(t)
	if not rg(t) then
		return
	end
	fifo_scope(t, "x needle_fifo\n")
	open(t)
	t.type("needle_fifo")
	local ui = results(t)
	t.eq(ui.labels[1], "a.txt:1  x needle_fifo", "a hit shows while rg still runs")
	t.eq(t.procs(), 1, "rg is still blocked on the fifo")
	t.type("x")
	t.pump(250)
	t.eq(t.procs(), 1, "a requery kills the previous rg")
	t.key("Esc")
	t.eq(t.procs(), 0, "closing kills rg")
	t.key("Esc")
end

function T.enter_while_rg_runs(t)
	if not rg(t) then
		return
	end
	fifo_scope(t, "first\nneedle_enter here\n")
	open(t)
	t.type("needle_enter")
	results(t)
	t.eq(t.procs(), 1, "rg still runs")
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	t.eq(qed.path.base(qed.buf.path()), "a.txt", "Enter opens a visible hit without waiting for rg")
	t.eq(qed.buf.cursor().row, 2)
	t.eq(t.procs(), 0, "and kills rg")
end

function T.cap_kills_rg(t)
	if not rg(t) then
		return
	end
	local lines = {}
	for i = 1, 600 do
		lines[i] = "needle_cap " .. i
	end
	fifo_scope(t, table.concat(lines, "\n") .. "\n")
	open(t)
	t.type("needle_cap")
	t.wait(function() local ui = t.ui(); return ui.matches == 500 and t.procs() == 0 end)
	t.ok(on_screen(t, "500+"), "the count shows 500+")
	local ui = t.ui()
	t.eq(ui.labels[1], "a.txt:1  needle_cap 1", "shown in key order")
	t.eq(ui.labels[2], "a.txt:2  needle_cap 2")
	t.key("Esc")
	t.key("Esc")
end

function T.dedupes_rows(t)
	if not rg(t) then
		return
	end
	write("d.txt", "needle_dup and needle_dup\n")
	open(t)
	t.type("needle_dup")
	results(t)
	t.pump(100)
	t.eq(t.ui().matches, 1, "two hits on one row are one item")
	t.key("Esc")
end

function T.rg_failure_hint(t)
	if not rg(t) then
		return
	end
	t.fake_spawn("rg --vimgrep", {code = 2})
	open(t)
	t.type("needle_fail")
	t.wait(function() return t.ui().hint == "Search failed: rg exit code 2" end)
	t.key("Esc")
end

return T

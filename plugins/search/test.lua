local tests = {}

local function rg(test)
	local ok = test.sh("command -v rg")
	-- CI sets QED_REQUIRE_RG so a runner without rg fails instead of skipping these tests
	test.ok(ok or not test.sh('[ -n "$QED_REQUIRE_RG" ]'), "QED_REQUIRE_RG is set but rg is not on PATH")
	return ok
end

-- the search view while it is open, else whatever pane is up
local function current(test)
	return qed.plugin("search").state() or test.ui()
end

local function write(name, body)
	local path = qed.path.join(qed.root(), name)
	qed.fs.write(path, body)
	return path
end

local function results(test)
	test.wait(function()
		local ui = current(test)
		return ui ~= nil and ui.matches > 0
	end)
	return current(test)
end

local function open(test)
	test.key("Alt+F")
	test.wait(function() local ui = current(test); return ui ~= nil and ui.id == "search" end)
end

local function on_screen(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function git_init(test, files)
	test.ok(test.sh("git init -q && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false"), "git init")
	for name, body in pairs(files) do
		write(name, body)
	end
	test.ok(test.sh("git add -A && git commit -q -m seed"), "seed commit")
end

local function changes_tab(test)
	test.key("Alt+f")
	test.settle()
	test.key("Tab")
	test.key("Tab")
	test.settle()
end

function tests.search_opens_hit(test)
	if not rg(test) then
		return
	end
	write("hay.txt", "first line\nneedle_xyz here\n")
	open(test)
	test.type("needle_xyz")
	local ui = results(test)
	test.eq(ui.selected, "hay.txt:2  needle_xyz here", "label is path:row  text")
	test.ok(on_screen(test, "needle_xyz here"), "the preview or list shows the hit")
	test.key("Enter")
	test.wait(function() return current(test) == nil end)
	test.eq(qed.path.base(qed.buf.current():path()), "hay.txt", "Enter opens the hit")
	test.eq(qed.buf.current():cursor().row, 2, "on its row")
end

function tests.results_sorted_and_counted(test)
	if not rg(test) then
		return
	end
	write("b.txt", "zz_needle\nzz_needle\n")
	write("a.txt", "x zz_needle\n")
	open(test)
	test.type("zz_needle")
	test.wait(function() local ui = current(test); return ui ~= nil and ui.matches == 3 end)
	local ui = current(test)
	test.eq(ui.labels[1], "a.txt:1  x zz_needle")
	test.eq(ui.labels[2], "b.txt:1  zz_needle")
	test.eq(ui.labels[3], "b.txt:2  zz_needle")
	test.wait(function() return on_screen(test, " 3│") end)
	test.ok(on_screen(test, " 3│"), "the match count renders at the end of the query row, by the preview's divider")
	test.key("Esc")
end

function tests.short_query_hint(test)
	if not rg(test) then
		return
	end
	write("q.txt", "q\n")
	open(test)
	test.wait(function() return current(test).hint ~= "" end)
	test.ok(on_screen(test, "Type at least 2 characters to search"), "the hint renders")
	test.type("q")
	test.pump(200)
	test.eq(current(test).matches, 0, "one char does not search")
	test.key("Esc")
	test.config({min_query = 1}, {hot = true})
	open(test)
	test.type("q")
	results(test)
	test.eq(current(test).hint, "", "a search clears the hint")
	test.key("Esc")
end

function tests.query_not_persisted(test)
	if not rg(test) then
		return
	end
	test.open("main.txt", "needle_xyz here\nneedle_xyz again\nneedle_xyz third")
	open(test)
	test.type("needle_xyz")
	results(test)
	test.key("Esc")

	open(test)
	test.eq(current(test).query, "", "the query does not persist")
	test.key("Esc")

	qed.buf.current():set_selection({row = 1, col = 1}, {row = 1, col = 11})
	open(test)
	test.eq(current(test).query, "needle_xyz", "a single-line selection pre-fills")
	local ui = results(test)
	test.eq(ui.selected, current(test).labels[1], "a pre-fill starts on the first match")
	test.key("Esc")
end

function tests.dash_scope(test)
	if not rg(test) then
		return
	end
	write("-dash/f.txt", "needle_xyz in dash")
	test.key("Alt+f")
	test.settle()
	open(test)
	test.type("needle_xyz")
	local ui = results(test)
	test.eq(ui.labels[1], "-dash/f.txt:1  needle_xyz in dash", "a scope path starting with - is a path")
	test.key("Esc")
	test.key("Esc")
end

function tests.chord_closes(test)
	if not rg(test) then
		return
	end
	open(test)
	test.key("Alt+F")
	test.eq(current(test), nil, "the opening chord closes the picker")
end

function tests.rg_missing(test)
	test.fake_spawn("command -v rg", {code = 1})
	test.key("Alt+F")
	test.pump(50)
	test.eq(current(test), nil, "no picker without rg")
	local msg, level, source = test.message()
	test.eq(msg, "ripgrep (rg) not found")
	test.eq(level, "error")
	test.eq(source, "Search")
end

function tests.tree_dir_scope(test)
	if not rg(test) then
		return
	end
	write("sub/inner.txt", "needle_xyz inside sub")
	write("outside.txt", "needle_xyz at root")
	test.key("Alt+f")
	test.settle()
	open(test)
	test.ok(test.editor().tree, "the tree stays open underneath")
	test.type("needle_xyz")
	local ui = results(test)
	for _, label in ipairs(ui.labels) do
		test.ok(label:sub(1, 4) == "sub/", "confined to the selected dir: " .. label)
	end
	test.key("Esc")
	test.eq(current(test).id, "filetree", "Esc closes the search, the tree resumes")
	test.key("Esc")
end

function tests.tree_open_result_closes_tree(test)
	if not rg(test) then
		return
	end
	write("hay.txt", "first line\nneedle_xyz here\n")
	test.key("Alt+f")
	test.settle()
	open(test)
	test.type("needle_xyz")
	results(test)
	test.key("Enter")
	test.wait(function() return current(test) == nil end)
	test.ok(not test.editor().tree, "opening a result closes the tree")
	test.eq(qed.path.base(qed.buf.current():path()), "hay.txt")
	test.eq(qed.buf.current():cursor().row, 2)
end

function tests.tree_changes_scope(test)
	if not rg(test) or not test.sh("command -v git") then
		return
	end
	git_init(test, {["committed.txt"] = "committed needle_xyz\n"})
	write("new.txt", "fresh needle_xyz\n")
	changes_tab(test)
	test.key("Ctrl+a")
	open(test)
	test.type("needle_xyz")
	local ui = results(test)
	for _, label in ipairs(ui.labels) do
		test.ok(label:find("new.txt", 1, true) == 1, "confined to changed files: " .. label)
	end
	test.key("Esc")
	test.key("Esc")
end

function tests.tree_changes_dir_scope(test)
	if not rg(test) or not test.sh("command -v git") then
		return
	end
	git_init(test, {["committed.txt"] = "committed needle_xyz\n"})
	write("sub/mod.txt", "fresh needle_xyz\n")
	write("root_new.txt", "needle_xyz root\n")
	changes_tab(test)
	open(test)
	test.type("needle_xyz")
	local ui = results(test)
	for _, label in ipairs(ui.labels) do
		test.ok(label:sub(1, 4) == "sub/", "confined to changed files under the dir: " .. label)
	end
	test.key("Esc")
	test.key("Esc")
end

local function fifo_scope(test, body)
	write("a.txt", body)
	test.ok(test.sh("mkfifo b_fifo"), "mkfifo")
	test.key("Alt+f")
	test.settle()
	for _ = 1, 4 do
		test.key("Up")
	end
	test.key("Shift+Down")
end

-- b.txt is read at once, a_fifo blocks rg until the test writes to it: its hit arrives last but sorts first
local function late_top_scope(test)
	write("b.txt", "needle_sort one\nneedle_sort two\n")
	test.ok(test.sh("mkfifo a_fifo"), "mkfifo")
	test.key("Alt+f")
	test.settle()
	for _ = 1, 4 do
		test.key("Up")
	end
	test.key("Shift+Down")
	open(test)
	test.type("needle_sort")
	test.wait(function() local ui = current(test); return ui ~= nil and ui.matches == 2 end)
end

function tests.highlight_follows_the_top_row_while_streaming(test)
	if not rg(test) then
		return
	end
	late_top_scope(test)
	test.eq(current(test).selected, "b.txt:1  needle_sort one", "the first hit is highlighted")
	test.ok(test.sh("printf 'needle_sort late\\n' > a_fifo"), "the late hit arrives")
	test.wait(function() return current(test).matches == 3 end)
	test.eq(current(test).labels[1], "a_fifo:1  needle_sort late", "the late hit sorts first")
	test.eq(current(test).selected, "a_fifo:1  needle_sort late", "the highlight follows the top row")
	test.key("Esc")
end

function tests.highlight_stays_where_the_user_moved_it(test)
	if not rg(test) then
		return
	end
	late_top_scope(test)
	test.key("Down")
	test.eq(current(test).selected, "b.txt:2  needle_sort two", "the user moved the highlight")
	test.ok(test.sh("printf 'needle_sort late\\n' > a_fifo"), "the late hit arrives")
	test.wait(function() return current(test).matches == 3 end)
	test.eq(current(test).selected, "b.txt:2  needle_sort two", "a new top row does not take the highlight back")
	test.key("Esc")
end

function tests.streams_while_rg_runs(test)
	if not rg(test) then
		return
	end
	fifo_scope(test, "x needle_fifo\n")
	open(test)
	test.type("needle_fifo")
	local ui = results(test)
	test.eq(ui.labels[1], "a.txt:1  x needle_fifo", "a hit shows while rg still runs")
	test.eq(test.procs(), 1, "rg is still blocked on the fifo")
	test.type("x")
	test.pump(250)
	test.eq(test.procs(), 1, "a requery kills the previous rg")
	test.key("Esc")
	test.eq(test.procs(), 0, "closing kills rg")
	test.key("Esc")
end

function tests.enter_while_rg_runs(test)
	if not rg(test) then
		return
	end
	fifo_scope(test, "first\nneedle_enter here\n")
	open(test)
	test.type("needle_enter")
	results(test)
	test.eq(test.procs(), 1, "rg still runs")
	test.key("Enter")
	test.wait(function() return current(test) == nil end)
	test.eq(qed.path.base(qed.buf.current():path()), "a.txt", "Enter opens a visible hit without waiting for rg")
	test.eq(qed.buf.current():cursor().row, 2)
	test.eq(test.procs(), 0, "and kills rg")
end

function tests.cap_kills_rg(test)
	if not rg(test) then
		return
	end
	local lines = {}
	for i = 1, 600 do
		lines[i] = "needle_cap " .. i
	end
	fifo_scope(test, table.concat(lines, "\n") .. "\n")
	open(test)
	test.type("needle_cap")
	test.wait(function() local ui = current(test); return ui.matches == 500 and test.procs() == 0 end)
	test.ok(on_screen(test, "500+"), "the count shows 500+")
	local ui = current(test)
	test.eq(ui.labels[1], "a.txt:1  needle_cap 1", "shown in key order")
	test.eq(ui.labels[2], "a.txt:2  needle_cap 2")
	test.key("Esc")
	test.key("Esc")
end

function tests.dedupes_rows(test)
	if not rg(test) then
		return
	end
	write("d.txt", "needle_dup and needle_dup\n")
	open(test)
	test.type("needle_dup")
	results(test)
	test.pump(100)
	test.eq(current(test).matches, 1, "two hits on one row are one item")
	test.key("Esc")
end

function tests.rg_failure_hint(test)
	if not rg(test) then
		return
	end
	test.fake_spawn("rg --vimgrep", {code = 2})
	open(test)
	test.type("needle_fail")
	test.wait(function() return current(test).hint == "Search failed: rg exit code 2" end)
	test.key("Esc")
end

return tests

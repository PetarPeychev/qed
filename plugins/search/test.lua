local T = {}

local function rg(t)
	return t.sh("command -v rg")
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
	t.wait(function() return t.ui() ~= nil end)
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
	t.eq(t.ui().query, "q")
	results(t)
	t.eq(t.ui().hint, "", "a search clears the hint")
	t.key("Esc")
end

function T.query_and_selection_persist(t)
	if not rg(t) then
		return
	end
	t.open("main.txt", "needle_xyz here\nneedle_xyz again\nneedle_xyz third")
	open(t)
	t.type("needle_xyz")
	results(t)
	t.wait(function() return t.ui().matches >= 2 end)
	t.key("Down")
	local second = t.ui().selected
	t.key("Esc")

	open(t)
	t.eq(t.ui().query, "needle_xyz", "the query persists")
	t.wait(function() local ui = t.ui(); return ui.matches > 0 and ui.selected == second end)
	t.key("Esc")

	qed.buf.set_selection(nil, {row = 1, col = 1}, {row = 1, col = 11})
	open(t)
	t.eq(t.ui().query, "needle_xyz", "a single-line selection pre-fills")
	local ui = results(t)
	t.eq(ui.selected, t.ui().labels[1], "a pre-fill starts on the first match")
	t.key("Esc")
end

function T.fast_close_keeps_query(t)
	if not rg(t) then
		return
	end
	open(t)
	t.type("typed_fast")
	t.key("Esc")
	open(t)
	t.eq(t.ui().query, "typed_fast", "keystrokes inside the debounce survive the close")
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
	t.eq(source, "Find")
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
	t.eq(t.ui(), nil, "Esc closes the search")
	t.ok(t.editor().tree, "the tree resumes")
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

return T

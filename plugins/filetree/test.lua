local tests = {}

local function labels(test)
	return table.concat(test.ui().labels, ",")
end

local function select(test, label)
	local ui = test.ui()
	for i, shown in ipairs(ui.labels) do
		if shown == label then
			for _ = 1, #ui.labels do
				test.key("Up")
			end
			for _ = 2, i do
				test.key("Down")
			end
			return true
		end
	end
	return false
end

local function on_screen(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false
end

function tests.opens_on_a_tab_and_switches(test)
	test.sh("mkdir -p sub && echo x > sub/b.txt && echo y > a.txt")
	test.open("a.txt")
	qed.run("File Tree: All")
	test.ok(test.editor().tree, "All opens the tree")
	test.eq(labels(test), "sub,a.txt,start.txt", "dirs first, collapsed")
	test.ok(on_screen(test, "All │ Open"), "the tab row")
	test.key("Tab")
	test.eq(labels(test), "a.txt,start.txt", "the Open tab lists open buffers")
	test.key("Shift+Tab")
	test.eq(labels(test), "sub,a.txt,start.txt", "Shift+Tab goes back to All")
	test.key("Shift+Tab")
	test.eq(labels(test), "", "Shift+Tab wraps to the empty Unsaved tab")
	test.key("Tab")
	test.eq(test.ui().selected, "a.txt", "back on All from an empty tab, the current file is highlighted")
	test.key("Tab")
	test.key("Alt+u")
	test.eq(labels(test), "", "the Unsaved tab")
	test.key("Alt+u")
	test.ok(not test.editor().tree, "the active tab's chord closes")
	qed.run("File Tree: Open")
	test.eq(labels(test), "a.txt,start.txt")
	test.key("Alt+f")
	test.eq(labels(test), "sub,a.txt,start.txt", "a tab chord switches over an open tree")
	test.key("Esc")
	test.ok(not test.editor().tree)
end

function tests.filter_and_enter(test)
	test.sh("mkdir -p sub/deep && echo x > sub/deep/c.txt")
	qed.run("File Tree: All")
	test.type("c.t")
	test.settle()
	test.eq(labels(test), "sub/deep/c.txt", "the filter ranks paths")
	test.key("Esc")
	test.eq(test.ui().query, "", "Esc clears the filter first")
	test.ok(select(test, "sub"))
	test.key("Enter")
	test.eq(labels(test), "sub,deep,start.txt", "Enter on a dir expands it")
	test.key("Alt+e")
	test.eq(labels(test), "sub,start.txt", "Expand/Collapse All collapses when one is open")
	test.key("Alt+e")
	test.eq(labels(test), "sub,deep,c.txt,start.txt", "then expands all")
	test.ok(select(test, "c.txt"))
	test.key("Enter")
	test.ok(not test.editor().tree, "Enter on a file opens it and closes the tree")
	test.eq(qed.path.base(qed.buf.current():path()), "c.txt")
end

function tests.new_rename_delete(test)
	qed.run("File Tree: All")
	test.key("Ctrl+n")
	test.type("dir/new.txt")
	test.key("Enter")
	test.ok(qed.fs.exists("dir/new.txt"), "New creates the file and its parents")
	test.eq(test.ui().selected, "new.txt", "and selects it")
	test.key("Ctrl+r")
	test.key("Ctrl+a")
	test.type("renamed.txt")
	test.key("Enter")
	test.ok(qed.fs.exists("dir/renamed.txt") and not qed.fs.exists("dir/new.txt"), "Rename")
	test.eq(test.ui().selected, "renamed.txt")
	test.key("Ctrl+n")
	test.type("made/")
	test.key("Enter")
	local st = qed.fs.stat("dir/made")
	test.ok(st and st.type == "dir", "a trailing / makes a dir next to the selected file")
	test.key("Ctrl+n")
	test.type("x.txt")
	test.key("Enter")
	test.ok(qed.fs.exists("dir/made/x.txt"), "New on a dir creates inside it")
	test.key("Ctrl+n")
	test.type("x.txt")
	test.key("Enter")
	test.eq(test.message(), "Already exists")
	test.key("Ctrl+d")
	test.eq(test.ui().kind, "confirm")
	test.eq(labels(test), "Cancel,Delete")
	test.key("Down")
	test.key("Enter")
	test.ok(not qed.fs.exists("dir/made/x.txt"), "Delete")
	test.eq(test.message(), "Deleted x.txt")
	test.eq(test.ui().selected, "made", "the selection moves to the row above")
end

function tests.copy_paste_and_range(test)
	test.sh("echo a > a.txt && echo b > b.txt")
	qed.run("File Tree: All")
	test.ok(select(test, "a.txt"))
	test.key("Shift+Down")
	test.key("Ctrl+c")
	test.eq(test.message(), "Copied 2 items")
	test.key("Ctrl+v")
	test.ok(qed.fs.exists("a (copy).txt") and qed.fs.exists("b (copy).txt"), "paste copies with a suffix")
	test.eq(test.message(), "Pasted 2 items")
	test.key("Ctrl+a")
	test.key("Ctrl+d")
	test.eq(test.ui().kind, "confirm")
	test.key("Esc")
	test.ok(test.editor().tree and qed.fs.exists("a.txt"), "Esc cancels the delete")
end

function tests.palette_lists_tree_commands(test)
	test.sh("echo x > .hidden")
	qed.run("File Tree: All")
	test.key("Ctrl+p")
	test.ok(test.editor().palette, "Ctrl+P opens the scoped palette")
	test.type("toggle dot")
	test.ok(on_screen(test, "File Tree: Toggle Dotfiles"), "it lists the tree's commands")
	test.key("Enter")
	test.ok(test.editor().tree and not test.editor().palette, "running one returns to the tree")
	test.eq(labels(test), ".hidden,start.txt", "dotfiles show")
end

function tests.welcome_lists_tree_commands(test)
	for _, buffer in ipairs(qed.buf.list()) do
		qed.close(buffer, {discard = {buffer}})
	end
	test.ok(test.editor().welcome, "on the welcome screen")
	test.key("Alt+f")
	test.ok(test.editor().tree, "Alt+f opens the tree on the welcome screen")
end

function tests.dangling_symlinks_count_as_taken(test)
	test.sh("echo a > a.txt && ln -s nowhere ghost.txt && mkdir d && ln -s nowhere d/a.txt")
	qed.run("File Tree: All")
	test.ok(select(test, "a.txt"))
	test.key("Ctrl+n")
	test.type("ghost.txt")
	test.key("Enter")
	test.eq(test.message(), "Already exists", "New refuses a dangling symlink's name")
	test.ok(not qed.fs.exists("ghost.txt") and qed.fs.exists("ghost.txt", {follow = false}), "and leaves the link alone")
	test.ok(select(test, "a.txt"))
	test.key("Ctrl+c")
	test.ok(select(test, "d"))
	test.key("Ctrl+v")
	test.ok(qed.fs.exists("d/a (copy).txt"), "paste steps past a dangling symlink's name")
	test.ok(qed.fs.exists("d/a.txt", {follow = false}) and not qed.fs.exists("d/a.txt"), "the link stays")
end

function tests.ranges_drop_nested_rows(test)
	test.sh("mkdir -p sub && echo x > sub/b.txt")
	qed.run("File Tree: All")
	test.ok(select(test, "sub"))
	test.key("Enter")
	test.key("Shift+Down")
	test.key("Ctrl+c")
	test.eq(test.message(), "Copied sub", "a dir stands for its selected rows")
	test.key("Ctrl+d")
	test.eq(test.ui().kind, "confirm")
	test.ok(on_screen(test, "Delete sub/ and its contents?"), "one item to delete")
	test.key("Esc")
end

function tests.paste_failure_shows_the_reason(test)
	test.sh("echo a > a.txt && mkdir ro && chmod 555 ro")
	qed.run("File Tree: All")
	test.ok(select(test, "a.txt"))
	test.key("Ctrl+c")
	test.ok(select(test, "ro"))
	test.key("Ctrl+v")
	local msg, level = test.message()
	test.ok(msg:find("Paste failed: a.txt: ", 1, true) == 1, "the error names the file and the reason: " .. msg)
	test.eq(level, "error", "no success summary covers it")
	test.sh("chmod 755 ro")
end

function tests.close_discards_only_approved_ids(test)
	local buffer = test.open("u.txt", "x")
	buffer:insert({row = 1, col = 1}, "y")
	test.ok(not qed.close(buffer, {discard = {}}), "an unapproved unsaved buffer stays")
	test.ok(qed.close(buffer, {discard = {buffer}}), "an approved one closes")
end

local function screen_find(test, needle)
	for screen_row = 0, 39 do
		local row = test.screen(screen_row)
		local at = row:find(needle, 1, true)
		if at then
			return screen_row, utf8.len(row:sub(1, at - 1))
		end
	end
end

function tests.git_preview_colors_the_diff(test)
	test.resize(160, 40)
	local base, text = {}, {}
	for i = 1, 40 do
		base[i] = "row " .. i
		text[#text + 1] = i == 10 and "row 10 changed" or "row " .. i
		if i == 30 then
			text[#text + 1] = "added"
		end
	end
	qed.fs.write(qed.path.join(qed.root(), "app.txt"), table.concat(base, "\n") .. "\n")
	qed.fs.write(qed.path.join(qed.root(), "old.txt"), "gone\nfor good\n")
	test.ok(test.sh("git init -q && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false && git add -A && git commit -q -m seed"), "seed commit")
	qed.fs.write(qed.path.join(qed.root(), "app.txt"), table.concat(text, "\n") .. "\n")
	test.ok(test.sh("rm old.txt"))
	test.settle()
	test.key("Alt+g")
	test.wait(function() return screen_find(test, "⋮") ~= nil end)

	local live, x = screen_find(test, "row 10 changed")
	local ghost = screen_find(test, "row 10 ")
	local plain = screen_find(test, "row 11")
	test.eq(ghost, live - 1, "diff-only: the old line is a ghost row above the change")
	test.ok(test.bg(x, ghost) ~= test.bg(x, plain), "the ghost row is tinted")
	test.ok(test.bg(x, live) ~= test.bg(x, plain), "the modified row is tinted")
	test.ok(test.bg(x + 7, live) ~= test.bg(x, live), "its changed word is emphasized")
	test.ok(test.screen(live):find("10 row 10 changed", 1, true), "real line numbers")
	test.ok(screen_find(test, "28 row 28"), "real line numbers after the gap")
	local added, added_x = screen_find(test, "31 added")
	test.ok(added and test.bg(added_x + 3, added) ~= test.bg(added_x + 3, added + 1), "the added row is tinted")
	test.ok(not screen_find(test, "row 20"), "rows away from the changes are hidden")

	test.key("Alt+d")
	test.wait(function() return screen_find(test, "⋮") == nil end)
	test.ok(screen_find(test, " 1 row 1 "), "the whole file from the top")
	live, x = screen_find(test, "row 10 changed")
	ghost = screen_find(test, "row 10 ")
	test.eq(ghost, live - 1, "whole file: the ghost row stays")
	test.ok(test.bg(x, live) ~= test.bg(x, live + 1), "and the tint")
	test.ok(test.screen(live):find("10 row 10 changed", 1, true), "real line numbers")

	test.key("Down")
	test.wait(function() return screen_find(test, "for good") ~= nil end)
	local gone, gone_x = screen_find(test, "1 gone")
	test.ok(test.bg(gone_x + 2, gone) ~= test.bg(gone_x + 2, gone + 3), "a deleted file shows its old text tinted as removed")
end

function tests.open_reveals_the_current_file(test)
	test.sh("mkdir -p x/y && echo z > x/y/z.txt && echo w > w.txt")
	test.open("x/y/z.txt")
	qed.run("File Tree: All")
	test.eq(labels(test), "x,y,z.txt,start.txt,w.txt", "its dirs expand")
	test.eq(test.ui().selected, "z.txt", "and it is highlighted")
end

function tests.git_to_all_reveals_the_current_file(test)
	test.ok(test.sh("git init -q && git config user.email e2e@qed.test && git config user.name qed && git config commit.gpgsign false"), "git init")
	test.sh("mkdir -p a/b/c && echo one > a/b/c/deep.txt && echo top > top.txt")
	test.ok(test.sh("git add -A && git commit -q -m seed"), "seed commit")
	test.sh("echo two >> a/b/c/deep.txt")
	test.open("a/b/c/deep.txt")
	test.settle()
	test.key("Alt+g")
	test.wait(function() return test.ui().selected == "deep.txt" end)
	test.eq(qed.plugin("filetree").state().tab, "Git", "the Git tab highlights the changed current file")
	test.key("Alt+f")
	test.eq(qed.plugin("filetree").state().tab, "All")
	test.eq(labels(test), "a,b,c,deep.txt,start.txt,top.txt", "All expands down to it")
	test.eq(test.ui().selected, "deep.txt")
end

function tests.a_tab_without_the_current_file_falls_back_to_its_last_row(test)
	test.sh("echo a > a.txt && echo b > b.txt && echo c > c.txt")
	for _, name in ipairs({"a.txt", "b.txt"}) do
		test.open(name):insert({row = 1, col = 1}, "x")
	end
	test.open("c.txt")
	qed.run("File Tree: Unsaved")
	test.eq(labels(test), "a.txt,b.txt")
	test.eq(test.ui().selected, "a.txt", "the first row without a last row")
	test.key("Down")
	test.key("Esc")
	qed.run("File Tree: Unsaved")
	test.eq(test.ui().selected, "b.txt", "reopened on its last row")
	test.key("Alt+f")
	test.eq(test.ui().selected, "c.txt", "All lands on the current file")
	test.key("Alt+u")
	test.eq(test.ui().selected, "b.txt", "switching back lands on the last row again")
end

function tests.a_tab_that_lists_the_current_file_later_still_lands_on_it(test)
	test.sh("mkdir -p x/y && echo z > x/y/z.txt && echo w > w.txt")
	test.open("x/y/z.txt")
	local tree = qed.plugin("filetree")
	tree.set_tab{label = "Late", paths = {}, empty = "loading"}
	test.settle()
	tree.open("Late")
	test.settle()
	test.eq(labels(test), "", "nothing listed yet")
	local root = qed.root()
	tree.set_tab{label = "Late", paths = {root .. "/w.txt", root .. "/x/y/z.txt"}}
	test.settle()
	test.eq(test.ui().selected, "z.txt", "the file is highlighted once the tab lists it")
	test.key("Up")
	tree.set_tab{label = "Late", paths = {root .. "/w.txt", root .. "/x/y/z.txt"}, empty = "again"}
	test.settle()
	test.eq(test.ui().selected, "y", "a moved highlight stays put")
	tree.remove_tab("Late")
end

return tests

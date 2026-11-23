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
	test.key("Right")
	test.eq(labels(test), "a.txt,start.txt", "the Open tab lists open buffers")
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

return tests

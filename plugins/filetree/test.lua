local T = {}

local function labels(t)
	return table.concat(t.ui().labels, ",")
end

local function select(t, label)
	local ui = t.ui()
	for i, l in ipairs(ui.labels) do
		if l == label then
			for _ = 1, #ui.labels do
				t.key("Up")
			end
			for _ = 2, i do
				t.key("Down")
			end
			return true
		end
	end
	return false
end

local function on_screen(t, needle)
	for y = 0, 23 do
		if t.screen(y):find(needle, 1, true) then
			return true
		end
	end
	return false
end

function T.opens_on_a_tab_and_switches(t)
	t.sh("mkdir -p sub && echo x > sub/b.txt && echo y > a.txt")
	t.open("a.txt")
	qed.run("File Tree: All")
	t.ok(t.editor().tree, "All opens the tree")
	t.eq(labels(t), "sub,a.txt,start.txt", "dirs first, collapsed")
	t.ok(on_screen(t, "All │ Open"), "the tab row")
	t.key("Right")
	t.eq(labels(t), "a.txt,start.txt", "the Open tab lists open buffers")
	t.key("Alt+u")
	t.eq(labels(t), "", "the Unsaved tab")
	t.key("Alt+u")
	t.ok(not t.editor().tree, "the active tab's chord closes")
	qed.run("File Tree: Open")
	t.eq(labels(t), "a.txt,start.txt")
	t.key("Alt+f")
	t.eq(labels(t), "sub,a.txt,start.txt", "a tab chord switches over an open tree")
	t.key("Esc")
	t.ok(not t.editor().tree)
end

function T.filter_and_enter(t)
	t.sh("mkdir -p sub/deep && echo x > sub/deep/c.txt")
	qed.run("File Tree: All")
	t.type("c.t")
	t.settle()
	t.eq(labels(t), "sub/deep/c.txt", "the filter ranks paths")
	t.key("Esc")
	t.eq(t.ui().query, "", "Esc clears the filter first")
	t.ok(select(t, "sub"))
	t.key("Enter")
	t.eq(labels(t), "sub,deep,start.txt", "Enter on a dir expands it")
	t.key("Alt+e")
	t.eq(labels(t), "sub,start.txt", "Expand/Collapse All collapses when one is open")
	t.key("Alt+e")
	t.eq(labels(t), "sub,deep,c.txt,start.txt", "then expands all")
	t.ok(select(t, "c.txt"))
	t.key("Enter")
	t.ok(not t.editor().tree, "Enter on a file opens it and closes the tree")
	t.eq(qed.path.base(qed.buf.path(qed.buf.current())), "c.txt")
end

function T.new_rename_delete(t)
	qed.run("File Tree: All")
	t.key("Ctrl+n")
	t.type("dir/new.txt")
	t.key("Enter")
	t.ok(qed.fs.exists("dir/new.txt"), "New creates the file and its parents")
	t.eq(t.ui().selected, "new.txt", "and selects it")
	t.key("Ctrl+r")
	t.key("Ctrl+a")
	t.type("renamed.txt")
	t.key("Enter")
	t.ok(qed.fs.exists("dir/renamed.txt") and not qed.fs.exists("dir/new.txt"), "Rename")
	t.eq(t.ui().selected, "renamed.txt")
	t.key("Ctrl+n")
	t.type("made/")
	t.key("Enter")
	local st = qed.fs.stat("dir/made")
	t.ok(st and st.type == "dir", "a trailing / makes a dir next to the selected file")
	t.key("Ctrl+n")
	t.type("x.txt")
	t.key("Enter")
	t.ok(qed.fs.exists("dir/made/x.txt"), "New on a dir creates inside it")
	t.key("Ctrl+n")
	t.type("x.txt")
	t.key("Enter")
	t.eq(t.message(), "Already exists")
	t.key("Ctrl+d")
	t.eq(t.ui().kind, "confirm")
	t.eq(labels(t), "Cancel,Delete")
	t.key("Down")
	t.key("Enter")
	t.ok(not qed.fs.exists("dir/made/x.txt"), "Delete")
	t.eq(t.message(), "Deleted x.txt")
	t.eq(t.ui().selected, "made", "the selection moves to the row above")
end

function T.copy_paste_and_range(t)
	t.sh("echo a > a.txt && echo b > b.txt")
	qed.run("File Tree: All")
	t.ok(select(t, "a.txt"))
	t.key("Shift+Down")
	t.key("Ctrl+c")
	t.eq(t.message(), "Copied 2 items")
	t.key("Ctrl+v")
	t.ok(qed.fs.exists("a (copy).txt") and qed.fs.exists("b (copy).txt"), "paste copies with a suffix")
	t.eq(t.message(), "Pasted 2 items")
	t.key("Ctrl+a")
	t.key("Ctrl+d")
	t.eq(t.ui().kind, "confirm")
	t.key("Esc")
	t.ok(t.editor().tree and qed.fs.exists("a.txt"), "Esc cancels the delete")
end

function T.palette_lists_tree_commands(t)
	t.sh("echo x > .hidden")
	qed.run("File Tree: All")
	t.key("Ctrl+p")
	t.ok(t.editor().palette, "Ctrl+P opens the scoped palette")
	t.type("toggle dot")
	t.ok(on_screen(t, "File Tree: Toggle Dotfiles"), "it lists the tree's commands")
	t.key("Enter")
	t.ok(t.editor().tree and not t.editor().palette, "running one returns to the tree")
	t.eq(labels(t), ".hidden,start.txt", "dotfiles show")
end

function T.welcome_lists_tree_commands(t)
	for _, b in ipairs(qed.buf.list()) do
		qed.close(b, {discard = {b}})
	end
	t.ok(t.editor().welcome, "on the welcome screen")
	t.key("Alt+f")
	t.ok(t.editor().tree, "Alt+f opens the tree on the welcome screen")
end

function T.dangling_symlinks_count_as_taken(t)
	t.sh("echo a > a.txt && ln -s nowhere ghost.txt && mkdir d && ln -s nowhere d/a.txt")
	qed.run("File Tree: All")
	t.ok(select(t, "a.txt"))
	t.key("Ctrl+n")
	t.type("ghost.txt")
	t.key("Enter")
	t.eq(t.message(), "Already exists", "New refuses a dangling symlink's name")
	t.ok(not qed.fs.exists("ghost.txt") and qed.fs.exists("ghost.txt", {follow = false}), "and leaves the link alone")
	t.ok(select(t, "a.txt"))
	t.key("Ctrl+c")
	t.ok(select(t, "d"))
	t.key("Ctrl+v")
	t.ok(qed.fs.exists("d/a (copy).txt"), "paste steps past a dangling symlink's name")
	t.ok(qed.fs.exists("d/a.txt", {follow = false}) and not qed.fs.exists("d/a.txt"), "the link stays")
end

function T.ranges_drop_nested_rows(t)
	t.sh("mkdir -p sub && echo x > sub/b.txt")
	qed.run("File Tree: All")
	t.ok(select(t, "sub"))
	t.key("Enter")
	t.key("Shift+Down")
	t.key("Ctrl+c")
	t.eq(t.message(), "Copied sub", "a dir stands for its selected rows")
	t.key("Ctrl+d")
	t.eq(t.ui().kind, "confirm")
	t.ok(on_screen(t, "Delete sub/ and its contents?"), "one item to delete")
	t.key("Esc")
end

function T.paste_failure_shows_the_reason(t)
	t.sh("echo a > a.txt && mkdir ro && chmod 555 ro")
	qed.run("File Tree: All")
	t.ok(select(t, "a.txt"))
	t.key("Ctrl+c")
	t.ok(select(t, "ro"))
	t.key("Ctrl+v")
	local msg, level = t.message()
	t.ok(msg:find("Paste failed: a.txt: ", 1, true) == 1, "the error names the file and the reason: " .. msg)
	t.eq(level, "error", "no success summary covers it")
	t.sh("chmod 755 ro")
end

function T.close_discards_only_approved_ids(t)
	local b = t.open("u.txt", "x")
	qed.buf.insert(b, {row = 1, col = 1}, "y")
	t.ok(not qed.close(b, {discard = {}}), "an unapproved unsaved buffer stays")
	t.ok(qed.close(b, {discard = {b}}), "an approved one closes")
end

return T

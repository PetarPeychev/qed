local T = {}

local CHANGE = "Cwd: Change Working Directory"

function T.enter_switches_to_the_typed_dir(t)
	t.sh("mkdir -p sub/inner")
	local root = qed.root()
	qed.run(CHANGE)
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "the picker opens")
	t.eq(ui.query, root .. "/", "prefilled with the root")
	t.eq(table.concat(ui.labels, ","), "sub")
	t.type("su/")
	t.eq(t.ui().query, root .. "/sub/", "/ drills into the match")
	t.eq(table.concat(t.ui().labels, ","), "inner")
	t.key("Enter")
	t.ok(t.ui() == nil, "Enter closes the picker")
	t.eq(qed.root(), root .. "/sub")
	t.eq(t.message(), "Working directory: " .. root .. "/sub")
end

function T.not_a_directory_keeps_the_picker(t)
	local root = qed.root()
	qed.run(CHANGE)
	t.type("nope")
	t.key("Enter")
	local msg, level, source = t.message()
	t.eq(msg, "Not a directory: " .. root .. "/nope")
	t.eq(level, "error")
	t.eq(source, "Cwd")
	t.eq(t.ui().query, root .. "/nope", "the typed path stays")
	t.key("Esc")
	t.eq(qed.root(), root)
end

function T.unsaved_cancel_returns_with_the_typed_path(t)
	t.sh("mkdir -p sub")
	local root = qed.root()
	local b = t.open("a.txt", "x")
	qed.buf.insert(b, {row = 1, col = 1}, "y")
	qed.run(CHANGE)
	t.type("sub")
	t.key("Enter")
	local ui = t.ui()
	t.eq(ui.kind, "confirm")
	t.eq(table.concat(ui.labels, ","), "Cancel,Close all")
	t.key("Enter")
	t.eq(t.ui().kind, "pick", "Cancel returns to the picker")
	t.eq(t.ui().query, root .. "/sub", "with the typed path")
	t.eq(qed.root(), root)
	t.key("Enter")
	t.key("Down")
	t.key("Enter")
	t.ok(t.ui() == nil, "Close all switches and closes")
	t.eq(qed.root(), root .. "/sub")
	t.ok(not qed.buf.valid(b), "the unsaved buffer is gone")
end

return T

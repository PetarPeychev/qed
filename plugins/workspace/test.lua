local tests = {}

local CHANGE = "Workspace: Open Directory"

-- a dialog over the picker, else the picker itself
local function current(test)
	local ui = test.ui()
	if ui then
		return ui
	end
	local state = qed.plugin("workspace").state()
	if state then
		state.kind = "pick"
	end
	return state
end

function tests.enter_switches_to_the_typed_dir(test)
	test.sh("mkdir -p sub/inner")
	local root = qed.root()
	qed.run(CHANGE)
	local ui = current(test)
	test.ok(ui and ui.kind == "pick", "the picker opens")
	test.eq(ui.query, root .. "/", "prefilled with the root")
	test.eq(table.concat(ui.labels, ","), "sub")
	test.type("su/")
	test.eq(current(test).query, root .. "/sub/", "/ drills into the match")
	test.eq(table.concat(current(test).labels, ","), "inner")
	test.key("Enter")
	test.ok(current(test) == nil, "Enter closes the picker")
	test.eq(qed.root(), root .. "/sub")
	test.eq(test.message(), "Working directory: " .. root .. "/sub")
end

function tests.not_a_directory_keeps_the_picker(test)
	local root = qed.root()
	qed.run(CHANGE)
	test.type("nope")
	test.key("Enter")
	local msg, level, source = test.message()
	test.eq(msg, "Not a directory: " .. root .. "/nope")
	test.eq(level, "error")
	test.eq(source, "Workspace")
	test.eq(current(test).query, root .. "/nope", "the typed path stays")
	test.key("Esc")
	test.eq(qed.root(), root)
end

function tests.unsaved_cancel_returns_with_the_typed_path(test)
	test.sh("mkdir -p sub")
	local root = qed.root()
	local buffer = test.open("a.txt", "x")
	buffer:insert({row = 1, col = 1}, "y")
	qed.run(CHANGE)
	test.type("sub")
	test.key("Enter")
	local ui = current(test)
	test.eq(ui.kind, "confirm")
	test.eq(table.concat(ui.labels, ","), "Cancel,Close All")
	test.key("Enter")
	test.eq(current(test).kind, "pick", "Cancel returns to the picker")
	test.eq(current(test).query, root .. "/sub", "with the typed path")
	test.eq(qed.root(), root)
	test.key("Enter")
	test.key("Down")
	test.key("Enter")
	test.ok(current(test) == nil, "Close all switches and closes")
	test.eq(qed.root(), root .. "/sub")
	test.ok(not buffer:valid(), "the unsaved buffer is gone")
end

return tests

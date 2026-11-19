local T = {}

local function message_is(t, text)
	return function() return (t.message()) == text end
end

local function exited(name)
	return function()
		local st = qed.term.state(name)
		return st ~= nil and not st.running
	end
end

local function running(name)
	return function()
		local st = qed.term.state(name)
		return st ~= nil and st.running
	end
end

local function picking(t, selected)
	return function()
		local ui = t.ui()
		return ui ~= nil and ui.kind == "pick" and ui.selected == selected
	end
end

local function choose(t, item, action)
	qed.run("Tasks")
	t.wait(function() return t.ui() ~= nil end)
	t.type(item)
	t.wait(picking(t, item))
	t.key("Enter")
	if action then
		t.wait(function() local ui = t.ui(); return ui ~= nil and ui.query == "" end)
		t.type(action)
		t.wait(picking(t, action))
		t.key("Enter")
	end
	t.wait(function() return t.ui() == nil end)
end

local function details(t)
	qed.run("Tasks")
	t.wait(function() return t.ui() ~= nil end)
	local ui = t.ui()
	t.key("Esc")
	t.wait(function() return t.ui() == nil end)
	return ui
end

function T.term_api_exit_code_and_event(t)
	local seen = {}
	qed.on("term_exit", function(name, code) seen[#seen + 1] = name .. ":" .. code end)
	t.eq(qed.term.create{name = "ex", cmd = "echo hi; exit 3"}, "ex")
	t.wait(exited("ex"))
	t.eq(qed.term.state("ex").code, 3, "exit code")
	t.wait(function() return #seen == 1 end)
	t.eq(seen[1], "ex:3")
	t.eq(qed.term.state("ex").pid, nil, "no pid once exited")
end

function T.term_api_create_rules(t)
	t.ok(not pcall(qed.term.create, {name = "shell", cmd = "true"}), "the default shell name is refused")
	t.ok(not pcall(qed.term.create, {cmd = "true"}), "a name is required")
	t.eq(qed.term.create{name = "live", cmd = "sleep 30"}, "live")
	local pid = qed.term.state("live").pid
	local ok, err = qed.term.create{name = "live", cmd = "sleep 30"}
	t.eq(ok, nil)
	t.eq(err, "already running")
	t.eq(qed.term.create{name = "live", cmd = "sleep 31", restart = true}, "live")
	t.ok(qed.term.state("live").running and qed.term.state("live").pid ~= pid, "restart = true replaces a live session")
	t.eq(qed.term.state("nope"), nil)
	local _, serr = qed.term.show("nope")
	t.eq(serr, "no such session")
end

function T.term_api_restart_kill_list_close(t)
	local exits = 0
	qed.on("term_exit", function() exits = exits + 1 end)
	qed.term.create{name = "r", cmd = "sleep 30"}
	local pid = qed.term.state("r").pid
	t.ok(qed.term.restart("r"))
	t.ok(qed.term.state("r").pid ~= pid, "restart respawns")
	t.ok(qed.term.kill("r"))
	t.eq(qed.term.state("r").running, false)
	t.eq(qed.term.state("r").code, 137, "killed by SIGKILL")
	t.wait(function() return exits == 1 end)
	t.pump(50)
	t.eq(exits, 1, "restart fires no term_exit, kill does")
	local names = {}
	for _, st in ipairs(qed.term.list()) do
		names[#names + 1] = st.name
	end
	t.eq(table.concat(names, ","), "r")
	local _, nerr = qed.term.send("r", "x")
	t.eq(nerr, "not running")
	t.ok(qed.term.close("r"))
	t.eq(#qed.term.list(), 0)
end

function T.term_api_cwd_env_send_show(t)
	t.open("sub/x.txt", "x")
	qed.term.create{name = "sh", cwd = "sub", env = {QED_T = "envval"}}
	t.wait(running("sh"))
	qed.term.send("sh", "echo \"$QED_T\" \"$PWD\" > out.txt; exit\r")
	t.wait(exited("sh"), 5000)
	local out = qed.fs.read(qed.path.join(qed.root(), "sub/out.txt"))
	t.eq(out, "envval " .. qed.path.join(qed.root(), "sub") .. "\n")
	t.ok(qed.term.show("sh"))
	t.eq(t.editor().session, "sh")
	qed.term.hide()
	t.ok(not t.editor().terminal, "hide closes the pane")
end

function T.picker_lists_state(t)
	t.config{list = {{name = "quick", cmd = "true"}, {name = "idle", cmd = "sleep 30"}}}
	qed.term.create{name = "other", cmd = "exit 2"}
	t.wait(exited("other"))
	local ui = details(t)
	t.eq(ui.matches, 3, "configured tasks plus other sessions")
end

function T.run_show_restart_kill(t)
	t.config{list = {{name = "srv", cmd = "echo srv_up; sleep 30"}}}
	choose(t, "srv")
	t.wait(running("srv"))
	t.wait(message_is(t, "started"))
	local pid = qed.term.state("srv").pid
	choose(t, "srv", "Show")
	t.eq(t.editor().session, "srv", "show switches the pane to the task")
	qed.term.hide()
	choose(t, "srv", "Restart")
	t.ok(qed.term.state("srv").running and qed.term.state("srv").pid ~= pid, "restart respawns")
	choose(t, "srv", "Kill")
	t.wait(exited("srv"))
	t.wait(message_is(t, "killed (signal 9)"))
	choose(t, "srv", "Run")
	t.wait(running("srv"))
end

function T.exit_messages(t)
	t.config{list = {{name = "bad", cmd = "exit 4"}, {name = "good", cmd = "true"}}}
	choose(t, "bad")
	t.wait(message_is(t, "failed (exit 4)"))
	local _, level, source = t.message()
	t.eq(level, "error")
	t.eq(source, "bad")
	choose(t, "good")
	t.wait(message_is(t, "exited 0"))
end

function T.invalid_entries_warn(t)
	t.config{list = {{name = "shell", cmd = "x"}, {name = "nocmd"}, {name = "a", cmd = "x"}, {name = "a", cmd = "y"}, {name = "b", cmd = "x", bogus = 1}}}
	t.ok(t.log_has("warn", "", "\"shell\" is the terminal pane's own session"), "reserved name")
	t.ok(t.log_has("warn", "", "\"nocmd\": cmd must be a non-empty string"), "missing cmd")
	t.ok(t.log_has("warn", "", "\"a\": duplicate name"), "duplicate")
	t.ok(t.log_has("warn", "", "ignoring unknown key \"bogus\""), "unknown key")
	t.eq(details(t).matches, 2)
end

return T

local T = {}

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

function T.exit_code_and_event(t)
	local seen = {}
	qed.on("term_exit", function(name, code) seen[#seen + 1] = name .. ":" .. code end)
	t.eq(qed.term.create{name = "ex", cmd = "echo hi; exit 3"}, true)
	t.wait(exited("ex"))
	t.eq(qed.term.state("ex").code, 3, "exit code")
	t.wait(function() return #seen == 1 end)
	t.eq(seen[1], "ex:3")
	t.eq(qed.term.state("ex").pid, nil, "no pid once exited")
end

function T.open_close_events(t)
	local seen = {}
	qed.on("term_open", function(name) seen[#seen + 1] = "open:" .. name end)
	qed.on("term_close", function(name) seen[#seen + 1] = "close:" .. name end)
	qed.term.create{name = "ev", cmd = "sleep 30"}
	qed.term.restart("ev")
	qed.term.close("ev")
	t.wait(function() return #seen == 3 end)
	t.eq(table.concat(seen, ","), "open:ev,open:ev,close:ev")
end

function T.create_rules(t)
	t.ok(not pcall(qed.term.create, {name = "shell", cmd = "true"}), "the default shell name is refused")
	t.ok(not pcall(qed.term.create, {cmd = "true"}), "a name is required")
	t.eq(qed.term.create{name = "live", cmd = "sleep 30"}, true)
	local pid = qed.term.state("live").pid
	local ok, err = qed.term.create{name = "live", cmd = "sleep 30"}
	t.eq(ok, nil)
	t.eq(err, "already running")
	t.eq(qed.term.create{name = "live", cmd = "sleep 31", restart = true}, true)
	t.ok(qed.term.state("live").running and qed.term.state("live").pid ~= pid, "restart = true replaces a live session")
	t.eq(qed.term.state("nope"), nil)
	for _, f in ipairs({qed.term.kill, qed.term.restart, qed.term.close}) do
		t.ok(not pcall(f, "shell"), "plugins cannot kill, restart or close the shell")
	end
	local _, serr = qed.term.show("nope")
	t.eq(serr, "no such session")
end

function T.restart_kill_list_close(t)
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

function T.cwd_env_send_show(t)
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

return T

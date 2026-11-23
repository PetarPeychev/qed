local tests = {}

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

function tests.exit_code_and_event(test)
	local seen = {}
	qed:on("term_exit", function(name, code) seen[#seen + 1] = name .. ":" .. code end)
	test.eq(qed.term.create{name = "ex", cmd = "echo hi; exit 3"}, true)
	test.wait(exited("ex"))
	test.eq(qed.term.state("ex").code, 3, "exit code")
	test.wait(function() return #seen == 1 end)
	test.eq(seen[1], "ex:3")
	test.eq(qed.term.state("ex").pid, nil, "no pid once exited")
end

function tests.open_close_events(test)
	local seen = {}
	qed:on("term_open", function(name) seen[#seen + 1] = "open:" .. name end)
	qed:on("term_close", function(name) seen[#seen + 1] = "close:" .. name end)
	qed.term.create{name = "ev", cmd = "sleep 30"}
	qed.term.restart("ev")
	qed.term.close("ev")
	test.wait(function() return #seen == 3 end)
	test.eq(table.concat(seen, ","), "open:ev,open:ev,close:ev")
end

function tests.create_rules(test)
	test.ok(not pcall(qed.term.create, {name = "shell", cmd = "true"}), "the default shell name is refused")
	test.ok(not pcall(qed.term.create, {cmd = "true"}), "a name is required")
	test.eq(qed.term.create{name = "live", cmd = "sleep 30"}, true)
	local pid = qed.term.state("live").pid
	local ok, err = qed.term.create{name = "live", cmd = "sleep 30"}
	test.eq(ok, nil)
	test.eq(err, "already running")
	test.eq(qed.term.create{name = "live", cmd = "sleep 31", restart = true}, true)
	test.ok(qed.term.state("live").running and qed.term.state("live").pid ~= pid, "restart = true replaces a live session")
	test.eq(qed.term.state("nope"), nil)
	for _, call in ipairs({qed.term.kill, qed.term.restart, qed.term.close}) do
		test.ok(not pcall(call, "shell"), "plugins cannot kill, restart or close the shell")
	end
	local _, serr = qed.plugin("terminal").show("nope")
	test.eq(serr, "no such session")
end

function tests.restart_kill_list_close(test)
	local exits = 0
	qed:on("term_exit", function() exits = exits + 1 end)
	qed.term.create{name = "r", cmd = "sleep 30"}
	local pid = qed.term.state("r").pid
	test.ok(qed.term.restart("r"))
	test.ok(qed.term.state("r").pid ~= pid, "restart respawns")
	test.ok(qed.term.kill("r"))
	test.eq(qed.term.state("r").running, false)
	test.eq(qed.term.state("r").code, 137, "killed by SIGKILL")
	test.wait(function() return exits == 1 end)
	test.pump(50)
	test.eq(exits, 1, "restart fires no term_exit, kill does")
	local names = {}
	for _, st in ipairs(qed.term.list()) do
		names[#names + 1] = st.name
	end
	test.eq(table.concat(names, ","), "r")
	local _, nerr = qed.term.send("r", "x")
	test.eq(nerr, "not running")
	test.ok(qed.term.close("r"))
	test.eq(#qed.term.list(), 0)
end

function tests.cwd_env_send_show(test)
	test.open("sub/x.txt", "x")
	qed.term.create{name = "sh", cwd = "sub", env = {QED_T = "envval"}}
	test.wait(running("sh"))
	qed.term.send("sh", "echo \"$QED_T\" \"$PWD\" > out.txt; exit\r")
	test.wait(exited("sh"), 5000)
	local out = qed.fs.read(qed.path.join(qed.root(), "sub/out.txt"))
	test.eq(out, "envval " .. qed.path.join(qed.root(), "sub") .. "\n")
	test.ok(qed.plugin("terminal").show("sh"))
	test.wait(function() return test.editor().session == "sh" end)
	qed.plugin("terminal").hide()
	test.wait(function() return not test.editor().terminal end)
end

return tests

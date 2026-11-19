local ENTRY_KEYS = {name = true, cmd = true, cwd = true, env = true}

local tasks = {}
local mine = {}
local seen

local function warn(text)
	qed.message("config.json: " .. text, {level = "warn", source = ""})
end

local function say(name, text, level)
	qed.message(text, {level = level, source = name})
end

local function exit_text(code)
	if code == 0 then
		return "exited 0", "info"
	elseif code > 128 and code < 160 then
		return ("killed (signal %d)"):format(code - 128), "warn"
	end
	return ("failed (exit %d)"):format(code), "error"
end

local function state_text(st)
	if not st then
		return "not started"
	elseif st.running then
		return "running"
	end
	return (exit_text(st.code))
end

local function failed(code)
	return code ~= nil and select(2, exit_text(code)) == "error"
end

local function status()
	local running, bad = 0, false
	for _, st in ipairs(qed.term.list()) do
		if st.name ~= "shell" then
			if st.running then
				running = running + 1
			elseif failed(st.code) then
				bad = true
			end
		end
	end
	if running == 0 and not bad then
		qed.status.clear("tasks")
		return
	end
	qed.status.set("tasks", {text = ("tasks %d"):format(running), color = bad and "error_foreground" or nil})
end

local function validate(e, i, names)
	local where = ("plugins.tasks.list[%d]"):format(i)
	if type(e) ~= "table" then
		return nil, where .. " must be an object"
	end
	if type(e.name) ~= "string" or e.name == "" then
		return nil, where .. ".name must be a non-empty string"
	end
	where = ("plugins.tasks %q"):format(e.name)
	if e.name == "shell" then
		return nil, where .. ": \"shell\" is the terminal pane's own session"
	end
	if e.name:sub(1, 4) == "cmd:" then
		return nil, where .. ": names starting with \"cmd:\" are the commands plugin's task sessions"
	end
	if names[e.name] then
		return nil, where .. ": duplicate name"
	end
	for k in pairs(e) do
		if not ENTRY_KEYS[k] then
			warn(("%s: ignoring unknown key %q"):format(where, tostring(k)))
		end
	end
	if type(e.cmd) ~= "string" or e.cmd == "" then
		return nil, where .. ": cmd must be a non-empty string"
	end
	if e.cwd ~= nil and type(e.cwd) ~= "string" then
		return nil, where .. ": cwd must be a string"
	end
	local env = e.env or {}
	if type(env) ~= "table" then
		return nil, where .. ": env must be an object"
	end
	for k, v in pairs(env) do
		if type(k) ~= "string" or type(v) ~= "string" then
			return nil, where .. ": env must map names to strings"
		end
	end
	return {name = e.name, cmd = e.cmd, cwd = e.cwd, env = env}
end

local function apply(cfg)
	local encoded = qed.json.encode(cfg.list or {})
	if encoded == seen then
		return
	end
	seen = encoded
	tasks = {}
	if type(cfg.list) ~= "table" then
		warn("plugins.tasks.list must be a list")
		return
	end
	local names = {}
	for i, e in ipairs(cfg.list) do
		local t, err = validate(e, i, names)
		if t then
			names[t.name] = true
			tasks[#tasks + 1] = t
		else
			warn(err)
		end
	end
end

local function find(name)
	for _, t in ipairs(tasks) do
		if t.name == name then
			return t
		end
	end
end

local function start(t)
	local name, err = qed.term.create{name = t.name, cmd = t.cmd, cwd = t.cwd, env = t.env, restart = true}
	if not name then
		say(t.name, err, "error")
		return
	end
	mine[t.name] = true
	say(t.name, "started")
	return true
end

local function rerun(name)
	local t = find(name)
	if t then
		start(t)
		return
	end
	local ok, err = qed.term.restart(name)
	if not ok then
		say(name, err, "error")
	end
end

local function items()
	local list, listed = {}, {}
	for _, t in ipairs(tasks) do
		listed[t.name] = true
		list[#list + 1] = {label = t.name, detail = state_text(qed.term.state(t.name))}
	end
	for _, st in ipairs(qed.term.list()) do
		if st.name ~= "shell" and not listed[st.name] then
			list[#list + 1] = {label = st.name, detail = state_text(st)}
		end
	end
	return list
end

local function actions(name)
	local st = qed.term.state(name)
	if not st then
		return {}
	elseif st.running then
		return {"Show", "Restart", "Kill"}
	end
	return {"Show", find(name) and "Run" or "Restart", "Close"}
end

local function pick()
	local list = items()
	if #list == 0 then
		qed.message("no tasks: add them to plugins.tasks.list")
		return
	end
	local item, err = qed.pick{items = list, prompt = "Tasks >"}
	if not item then
		if err then
			qed.message("Tasks: " .. err, "warn")
		end
		return
	end
	local name = item.label
	local choices = actions(name)
	if #choices == 0 then
		local t = find(name)
		if t and start(t) then
			qed.term.show(name)
		end
		return
	end
	local action = qed.pick{items = choices, prompt = name .. " >"}
	if action == "Show" then
		qed.term.show(name)
	elseif action == "Kill" then
		qed.term.kill(name)
	elseif action == "Restart" or action == "Run" then
		rerun(name)
	elseif action == "Close" then
		qed.term.close(name)
	end
end

return {
	defaults = {list = {}},
	setup = function(cfg)
		apply(cfg)
		qed.command{name = "Tasks", welcome = true, run = pick}
		qed.on("config_changed", function() apply(qed.config()) end)
		qed.on("term_exit", function(name, code)
			if mine[name] then
				say(name, exit_text(code))
			end
			status()
		end)
		qed.on("term_open", status)
		qed.on("term_close", status)
	end,
}

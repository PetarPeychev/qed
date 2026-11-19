local OUTPUTS = {message = true, log = true, replace = true, insert = true, clipboard = true, terminal = true, task = true, locations = true}
local STDIN = {none = true, selection = true, buffer = true, ["selection-or-buffer"] = true}
local SAVE = {none = true, current = true, all = true}
local SAVE_NONE = {replace = true, insert = true, clipboard = true}
local ENTRY_KEYS = {name = true, run = true, output = true, stdin = true, cwd = true, save = true, when = true, key = true, env = true}
local WHEN_KEYS = {pane = true, language = true, glob = true, selection = true, git = true, exists = true}
local PANES = {editor = true, filetree = true}
local PLACEHOLDERS = {file = true, files = true, dir = true, root = true, name = true, stem = true, ext = true, line = true, col = true, selection = true, word = true, base = true}
local CURSOR_PLACEHOLDERS = {line = true, col = true, selection = true, word = true}
local RUNNING_HINT_MS = 400
local TASK_PREFIX = "cmd:"
local ENV_VALUE_MAX = 64 * 1024

local handles = {}
local running = {}
local tasks = {}
local seen

local function warn(text)
	qed.message("config.json: " .. text, {level = "warn", source = ""})
end

local function say(name, text, level)
	qed.message(text, {level = level, source = name})
end

local function first_line(s)
	for line in s:gmatch("[^\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			return line
		end
	end
end

local function lines_of(s)
	local out = {}
	for line in (s:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
		out[#out + 1] = line
	end
	if out[#out] == "" then
		out[#out] = nil
	end
	return out
end

local function contains(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

local function string_list(v)
	if type(v) == "string" then
		return {v}
	end
	if type(v) ~= "table" then
		return nil
	end
	for _, s in ipairs(v) do
		if type(s) ~= "string" then
			return nil
		end
	end
	return v
end

local function glob_pattern(glob)
	local p = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
	p = p:gsub("%*%*", "\1"):gsub("%*", "[^/]*"):gsub("%?", "[^/]"):gsub("\1", ".*")
	return "^" .. p .. "$"
end

local function glob_match(path, globs, root)
	for _, g in ipairs(globs) do
		local subject = g:find("/", 1, true) and (qed.path.rel(path, root) or path) or qed.path.base(path)
		if subject:match(glob_pattern(g)) then
			return true
		end
	end
	return false
end

local function in_repo(dir)
	while dir ~= "" do
		if qed.fs.exists(qed.path.join(dir, ".git")) then
			return true
		end
		local parent = qed.path.dir(dir)
		if parent == dir then
			return false
		end
		dir = parent
	end
	return false
end

local function quoted_placeholder(run)
	local quote, i = nil, 1
	while i <= #run do
		local ch = run:sub(i, i)
		if ch == "\\" and quote ~= "'" then
			i = i + 1
		elseif quote == nil and (ch == "'" or ch == '"') then
			quote = ch
		elseif ch == quote then
			quote = nil
		elseif ch == "{" and quote then
			local name = run:match("^{(%a+)}", i)
			if name and PLACEHOLDERS[name] then
				return name
			end
		end
		i = i + 1
	end
end

local function uses(s, names)
	local texts = {s.run, s.cwd or ""}
	for _, v in pairs(s.env) do
		texts[#texts + 1] = v
	end
	for _, text in ipairs(texts) do
		for name in text:gmatch("{(%a+)}") do
			if names[name] then
				return true
			end
		end
	end
	return false
end

local function validate(e, i)
	local where = ("plugins.commands.list[%d]"):format(i)
	if type(e) ~= "table" then
		return nil, where .. " must be an object"
	end
	if type(e.name) ~= "string" or e.name == "" then
		return nil, where .. ".name must be a non-empty string"
	end
	where = ("plugins.commands %q"):format(e.name)
	for k in pairs(e) do
		if not ENTRY_KEYS[k] then
			warn(("%s: ignoring unknown key %q"):format(where, tostring(k)))
		end
	end
	local output = e.output or "message"
	local s = {name = e.name, run = e.run, output = output, stdin = e.stdin or "none", save = e.save or (SAVE_NONE[output] and "none" or "current"), cwd = e.cwd, key = e.key, env = e.env or {}}
	if type(s.run) ~= "string" or s.run == "" then
		return nil, where .. ": run must be a non-empty string"
	end
	for key, set in pairs({output = OUTPUTS, stdin = STDIN, save = SAVE}) do
		if not set[s[key]] then
			return nil, ("%s: unknown %s %q"):format(where, key, tostring(s[key]))
		end
	end
	if (s.cwd ~= nil and type(s.cwd) ~= "string") or (s.key ~= nil and type(s.key) ~= "string") then
		return nil, where .. ": cwd and key must be strings"
	end
	if type(s.env) ~= "table" then
		return nil, where .. ": env must be an object"
	end
	for k, v in pairs(s.env) do
		if type(k) ~= "string" or type(v) ~= "string" then
			return nil, where .. ": env must map names to strings"
		end
	end
	local quoted = quoted_placeholder(s.run)
	if quoted then
		return nil, ("%s: {%s} is inside quotes in run; placeholders are quoted for you, remove the quotes"):format(where, quoted)
	end
	if (s.output == "terminal" or s.output == "task") and s.stdin ~= "none" then
		return nil, ("%s: stdin does not apply to output %q"):format(where, s.output)
	end
	local w = e.when or {}
	if type(w) ~= "table" then
		return nil, where .. ": when must be an object"
	end
	for k in pairs(w) do
		if not WHEN_KEYS[k] then
			warn(("%s: ignoring unknown key when.%s"):format(where, tostring(k)))
		end
	end
	s.panes = string_list(w.pane or "editor")
	if not s.panes or #s.panes == 0 then
		return nil, where .. ": when.pane must be \"editor\", \"filetree\" or a list of them"
	end
	for _, pane in ipairs(s.panes) do
		if not PANES[pane] then
			return nil, ("%s: unknown when.pane %q"):format(where, pane)
		end
	end
	s.edits = s.output == "replace" or s.output == "insert" or s.stdin ~= "none"
	if s.edits and contains(s.panes, "filetree") then
		return nil, where .. ": output replace/insert and stdin need when.pane \"editor\""
	end
	s.needs_buf = s.edits or uses(s, CURSOR_PLACEHOLDERS)
	for _, k in ipairs({"language", "glob", "exists"}) do
		s[k] = w[k] ~= nil and string_list(w[k]) or nil
		if w[k] ~= nil and not s[k] then
			return nil, ("%s: when.%s must be a string or a list of strings"):format(where, k)
		end
	end
	for _, k in ipairs({"selection", "git"}) do
		if w[k] ~= nil and type(w[k]) ~= "boolean" then
			return nil, ("%s: when.%s must be a boolean"):format(where, k)
		end
		s[k] = w[k]
	end
	return s
end

local function selection_of(ctx, pane)
	return pane == "editor" and ctx.selection_text or nil
end

local function matches(s, ctx, pane)
	if s.needs_buf and pane == "editor" and not ctx.buf then
		return false
	end
	if s.language and (pane ~= "editor" or not contains(s.language, ctx.language)) then
		return false
	end
	if s.glob then
		local paths = pane == "filetree" and (ctx.files or {}) or {ctx.path}
		if #paths == 0 then
			return false
		end
		for _, p in ipairs(paths) do
			if p == "" or not glob_match(p, s.glob, ctx.root) then
				return false
			end
		end
	end
	if s.selection ~= nil and (selection_of(ctx, pane) ~= nil) ~= s.selection then
		return false
	end
	if s.git ~= nil and in_repo(ctx.root) ~= s.git then
		return false
	end
	if s.exists then
		for _, f in ipairs(s.exists) do
			if not qed.fs.exists(qed.path.join(ctx.root, f)) then
				return false
			end
		end
	end
	return true
end

local function word_at(line, col)
	local from, to = col, col - 1
	while from > 1 and line:sub(from - 1, from - 1):match("[%w_]") do
		from = from - 1
	end
	while to < #line and line:sub(to + 1, to + 1):match("[%w_]") do
		to = to + 1
	end
	return line:sub(from, to)
end

local function values(ctx, pane)
	local v = {root = ctx.root, selection = selection_of(ctx, pane) or "", line = "", col = "", word = ""}
	if pane == "filetree" then
		v.file = ctx.file or ""
		v.files = ctx.files or {}
	else
		v.file = ctx.path or ""
		v.files = v.file ~= "" and {v.file} or {}
	end
	local st = v.file ~= "" and qed.fs.stat(v.file)
	if st and st.type == "dir" then
		v.dir = v.file
	else
		v.dir = v.file ~= "" and qed.path.dir(v.file) or ctx.root
	end
	v.name = v.file ~= "" and qed.path.base(v.file) or ""
	v.stem, v.ext = v.name:match("^(.+)%.([^.]*)$")
	if not v.stem then
		v.stem, v.ext = v.name, ""
	end
	if pane == "editor" and ctx.buf then
		local c = qed.buf.cursor(ctx.buf)
		v.line, v.col = tostring(c.row), tostring(c.col)
		v.word = word_at(qed.buf.line(ctx.buf, c.row), c.col)
	end
	v.base = ctx.base.ref
	v.base_merge = ctx.base.merge
	return v
end

local function expand(s, v, quote)
	return (s:gsub("{(%a+)}", function(k)
		local x = v[k]
		if k == "files" then
			local parts = {}
			for i, f in ipairs(x) do
				parts[i] = quote and qed.shell_quote(f) or f
			end
			return table.concat(parts, " ")
		end
		if type(x) ~= "string" then
			return nil
		end
		return quote and qed.shell_quote(x) or x
	end))
end

local function environment(s, v)
	local env = {
		QED_FILE = v.file,
		QED_FILES = table.concat(v.files, "\n"),
		QED_DIR = v.dir,
		QED_ROOT = v.root,
		QED_NAME = v.name,
		QED_STEM = v.stem,
		QED_EXT = v.ext,
		QED_LINE = v.line,
		QED_COL = v.col,
		QED_SELECTION = v.selection,
		QED_WORD = v.word,
		QED_BASE = v.base,
	}
	for k, x in pairs(env) do
		if #x > ENV_VALUE_MAX then
			env[k] = nil
		end
	end
	for k, x in pairs(s.env) do
		env[k] = expand(x, v, false)
	end
	return env
end

local function save_first(s, b)
	local targets = {}
	if s.save == "current" and b then
		targets = {b}
	elseif s.save == "all" then
		targets = qed.buf.list()
	end
	for _, t in ipairs(targets) do
		if qed.buf.valid(t) and qed.buf.modified(t) and qed.buf.path(t) ~= "" then
			local ok, err = qed.save(t)
			if not ok then
				return false, ("cannot save %s: %s"):format(qed.path.base(qed.buf.path(t)), err or "failed")
			end
		end
	end
	return true
end

local function trim_newline(out, input)
	out = out:gsub("\r\n", "\n")
	if input:sub(-1) ~= "\n" and out:sub(-1) == "\n" then
		out = out:sub(1, -2)
	end
	return out
end

local function exit_text(code)
	if code == 0 then
		return "exited 0", "info"
	elseif code > 128 and code < 160 then
		return ("killed (signal %d)"):format(code - 128), "warn"
	end
	return ("failed (exit %d)"):format(code), "error"
end

local function plain_error(err)
	return (tostring(err):gsub("^[^\n]-:%d+: ", ""))
end

local function failure(s, r)
	local why = first_line(r.stderr) or first_line(r.stdout)
	say(s.name, ("failed (exit %d)%s"):format(r.code, why and (": " .. why) or ""), "error")
end

local function show_log(s, r)
	local lines = {}
	for _, l in ipairs(lines_of(r.stdout)) do
		lines[#lines + 1] = l
	end
	for _, l in ipairs(lines_of(r.stderr)) do
		lines[#lines + 1] = {text = l, color = "error_foreground"}
	end
	local pane = qed.pane{title = s.name, lines = lines, footer = ("exit %d  ·  Esc close"):format(r.code)}
	if not pane then
		qed.log("info", ("%s output:\n%s%s"):format(s.name, r.stdout, r.stderr))
		say(s.name, "output in Debug: Message Log (another pane is open)", "warn")
	elseif r.code ~= 0 then
		failure(s, r)
	end
end

local function edit_buffer(s, r, job)
	local b = job.buf
	if r.code ~= 0 then
		failure(s, r)
		return
	end
	if not qed.buf.valid(b) then
		return
	end
	local applied
	if s.output == "insert" then
		local out = trim_newline(r.stdout, "")
		applied = qed.edit(b, function()
			local stop = qed.buf.insert(b, job.cursor, out)
			qed.buf.set_cursor(b, stop)
		end, {rev = job.rev})
	elseif job.from then
		local out = trim_newline(r.stdout, job.region)
		applied = qed.edit(b, function()
			local stop = qed.buf.replace(b, job.from, job.to, out)
			qed.buf.set_selection(b, job.from, stop)
		end, {rev = job.rev})
	else
		applied = qed.buf.set_text(b, trim_newline(r.stdout, job.region), {rev = job.rev})
	end
	if not applied then
		say(s.name, "skipped: buffer changed", "warn")
	else
		say(s.name, "done")
	end
end

local LOCATION_PATTERNS = {
	"^(.-):(%d+):(%d+):%s*(.*)$",
	"^(.-):(%d+):(%d+)()$",
	"^(.-):(%d+):%s*(.*)$",
	"^(.-):(%d+)()$",
}

local function parse_location(line)
	for i, pat in ipairs(LOCATION_PATTERNS) do
		local file, row, a, b = line:match(pat)
		if file and file ~= "" then
			if i <= 2 then
				return file, row, a, type(b) == "string" and b or ""
			end
			return file, row, nil, type(a) == "string" and a or ""
		end
	end
end

local function parse_locations(text, cwd)
	local items = {}
	for _, line in ipairs(lines_of(text)) do
		local file, row, col, msg = parse_location(line)
		if file then
			local path = file:sub(1, 1) == "/" and file or qed.path.join(cwd, file)
			local st = qed.fs.stat(path)
			if st and st.type == "file" then
				local label = ("%s:%s%s"):format(qed.path.rel(path) or path, row, col and (":" .. col) or "")
				if msg ~= "" then
					label = label .. ": " .. msg
				end
				items[#items + 1] = {label = label, path = path, pos = {row = tonumber(row), col = tonumber(col) or 1}}
			end
		end
	end
	return items
end

local function jump_to(item)
	local b, err = qed.open(item.path)
	if not b then
		qed.message(("cannot open %s: %s"):format(item.path, err or "failed"), "error")
		return
	end
	local row = math.max(1, math.min(item.pos.row, qed.buf.line_count(b)))
	local line = qed.buf.line(b, row)
	local col = math.max(1, math.min(item.pos.col, #line + 1))
	while col > 1 and col <= #line and (line:byte(col) & 0xC0) == 0x80 do
		col = col - 1
	end
	qed.jump(b, {row = row, col = col})
end

local function show_locations(s, r, cwd)
	local items = parse_locations(r.stdout .. "\n" .. r.stderr, cwd)
	if #items == 0 then
		if r.code ~= 0 and first_line(r.stderr) then
			failure(s, r)
		else
			say(s.name, "no locations")
		end
		return
	end
	local item, err = qed.pick{items = items, prompt = s.name .. " >"}
	if err == "busy" then
		say(s.name, ("%d location(s); another pane is open"):format(#items), "warn")
	elseif item then
		jump_to(item)
	end
end

local function deliver(s, r, job)
	if s.output == "message" then
		if r.code ~= 0 then
			failure(s, r)
		else
			say(s.name, first_line(r.stdout) or "done")
		end
	elseif s.output == "log" then
		show_log(s, r)
	elseif s.output == "replace" or s.output == "insert" then
		edit_buffer(s, r, job)
	elseif s.output == "clipboard" then
		if r.code ~= 0 then
			failure(s, r)
		else
			qed.clipboard.set(trim_newline(r.stdout, ""))
			say(s.name, "copied output")
		end
	elseif s.output == "locations" then
		show_locations(s, r, job.cwd)
	end
end

local function merge_base(ref, cwd)
	local ok, r = pcall(qed.spawn, {argv = {"git", "merge-base", ref, "HEAD"}, cwd = cwd})
	local rev = ok and r and r.code == 0 and first_line(r.stdout)
	return rev or ref
end

local function selection_text(b, from, to)
	local sel = qed.buf.lines(b, from.row, to.row)
	sel[#sel] = sel[#sel]:sub(1, to.col - 1)
	sel[1] = sel[1]:sub(from.col)
	return table.concat(sel, "\n")
end

local function execute(s, pane, ctx, state)
	local v = values(ctx, pane)
	local b = pane == "editor" and ctx.buf or nil
	local ok, err = save_first(s, b)
	if not ok then
		say(s.name, err, "error")
		return
	end
	if state.cancelled or (b and not qed.buf.valid(b)) then
		return
	end
	local job = {buf = b, cwd = s.cwd and qed.path.abs(expand(s.cwd, v, false)) or ctx.root}
	local stdin
	if s.edits then
		job.rev = qed.buf.rev(b)
		job.cursor = qed.buf.cursor(b)
		job.from, job.to = qed.buf.selection(b)
		job.region = job.from and selection_text(b, job.from, job.to) or qed.buf.text(b)
		if s.stdin == "buffer" then
			stdin = job.from and qed.buf.text(b) or job.region
		elseif s.stdin == "selection-or-buffer" then
			stdin = job.region
		elseif s.stdin == "selection" then
			stdin = job.from and job.region or ""
		end
	end
	if v.base_merge then
		v.base = merge_base(v.base, job.cwd)
	end
	local cmd = expand(s.run, v, true)
	if s.output == "terminal" then
		if s.cwd then
			cmd = ("(cd %s && %s)"):format(qed.shell_quote(job.cwd), cmd)
		end
		local st = qed.term.state("shell")
		if st and st.busy then
			say(s.name, "terminal busy", "error")
			return
		end
		local shown, terr = qed.term.show("shell")
		if not shown then
			say(s.name, terr, "error")
			return
		end
		qed.term.send("shell", "\x15" .. cmd .. "\r")
		return
	end
	if s.output == "task" then
		local session = TASK_PREFIX .. s.name
		local started, name, terr = pcall(qed.term.create, {name = session, cmd = cmd, cwd = job.cwd, env = environment(s, v), restart = true})
		if not started or not name then
			say(s.name, started and terr or plain_error(name), "error")
			return
		end
		tasks[session] = s.name
		say(s.name, "started")
		return
	end
	local started, proc = pcall(qed.spawn_bg, {cmd = cmd, stdin = stdin, cwd = job.cwd, env = environment(s, v)})
	if not started then
		say(s.name, plain_error(proc), "error")
		return
	end
	state.proc = proc
	qed.defer(RUNNING_HINT_MS, function()
		if running[s.name] == state and not state.cancelled then
			state.hinted = true
			say(s.name, "running…")
		end
	end)
	local r, werr = proc:wait()
	if state.hinted then
		qed.message("", {source = ""})
	end
	if state.cancelled then
		say(s.name, "cancelled", "warn")
		return
	end
	if not r then
		say(s.name, werr or "failed", "error")
		return
	end
	deliver(s, r, job)
end

local function run(s, pane, ctx)
	if running[s.name] then
		say(s.name, "already running", "warn")
		return
	end
	local state = {proc = nil, cancelled = false, hinted = false}
	running[s.name] = state
	local ok, err = pcall(execute, s, pane, ctx, state)
	if running[s.name] == state then
		running[s.name] = nil
	end
	if not ok then
		error(err, 0)
	end
end

local function register(list)
	for _, h in ipairs(handles) do
		h:remove()
	end
	handles = {}
	if type(list) ~= "table" then
		warn("plugins.commands.list must be a list")
		return
	end
	for i, entry in ipairs(list) do
		local s, err = validate(entry, i)
		if not s then
			warn(err)
		else
			for _, pane in ipairs(s.panes) do
				local ok, h = pcall(qed.command, {
					name = s.name,
					key = s.key,
					scope = pane,
					welcome = pane == "editor" and not s.needs_buf,
					when = function(ctx) return matches(s, ctx, pane) end,
					run = function(ctx) run(s, pane, ctx) end,
				})
				if ok then
					handles[#handles + 1] = h
				else
					warn(("plugins.commands %q: %s"):format(s.name, plain_error(h)))
				end
			end
		end
	end
end

local function apply(cfg)
	local encoded = qed.json.encode(cfg.list or {})
	if encoded ~= seen then
		seen = encoded
		register(cfg.list or {})
	end
end

local function cancel()
	for _, state in pairs(running) do
		state.cancelled = true
		if state.proc then
			state.proc:kill()
		end
	end
end

return {
	defaults = {list = {}},
	setup = function(cfg)
		qed.command{
			name = "Commands: Cancel",
			welcome = true,
			when = function() return next(running) ~= nil end,
			run = cancel,
		}
		apply(cfg)
		qed.on("config_changed", function() apply(qed.config()) end)
		qed.on("term_exit", function(name, code)
			if tasks[name] then
				say(tasks[name], exit_text(code))
			end
		end)
	end,
}

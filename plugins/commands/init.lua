local OUTPUTS = {message = true, log = true, replace = true, insert = true, clipboard = true, terminal = true, locations = true}
local STDIN = {none = true, selection = true, buffer = true, ["selection-or-buffer"] = true}
local SAVE = {none = true, current = true, all = true}
local ENTRY_KEYS = {name = true, run = true, output = true, stdin = true, cwd = true, save = true, when = true, key = true, env = true}
local WHEN_KEYS = {pane = true, language = true, glob = true, selection = true, git = true, exists = true}
local PANES = {editor = true, filetree = true}
local RUNNING_HINT_MS = 400

local handles = {}
local running = {}
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

local function as_list(v)
	if type(v) == "string" then
		return {v}
	end
	return v
end

local function string_list(v)
	v = as_list(v)
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
	local s = {name = e.name, run = e.run, output = e.output or "message", stdin = e.stdin or "none", save = e.save or "current", cwd = e.cwd, key = e.key, env = e.env or {}}
	if type(s.run) ~= "string" or s.run == "" then
		return nil, where .. ": run must be a non-empty string"
	end
	if not OUTPUTS[s.output] then
		return nil, ("%s: unknown output %q"):format(where, tostring(s.output))
	end
	if not STDIN[s.stdin] then
		return nil, ("%s: unknown stdin %q"):format(where, tostring(s.stdin))
	end
	if not SAVE[s.save] then
		return nil, ("%s: unknown save %q"):format(where, tostring(s.save))
	end
	if s.cwd ~= nil and type(s.cwd) ~= "string" then
		return nil, where .. ": cwd must be a string"
	end
	if s.key ~= nil and type(s.key) ~= "string" then
		return nil, where .. ": key must be a string"
	end
	if type(s.env) ~= "table" then
		return nil, where .. ": env must be an object"
	end
	for k, v in pairs(s.env) do
		if type(k) ~= "string" or type(v) ~= "string" then
			return nil, where .. ": env must map names to strings"
		end
	end
	if s.output == "terminal" and s.stdin ~= "none" then
		return nil, where .. ": stdin does not apply to output \"terminal\""
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
	s.needs_buf = s.output == "replace" or s.output == "insert" or s.stdin ~= "none"
	if s.needs_buf and (s.panes[1] == "filetree" or s.panes[2] == "filetree") then
		return nil, where .. ": output replace/insert and stdin need when.pane \"editor\""
	end
	for _, k in ipairs({"language", "glob", "exists"}) do
		if w[k] ~= nil then
			s[k] = string_list(w[k])
			if not s[k] then
				return nil, ("%s: when.%s must be a string or a list of strings"):format(where, k)
			end
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

local function contains(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

local function matches(s, ctx, pane)
	if s.needs_buf and not ctx.buf then
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
	if s.selection ~= nil and (ctx.selection_text ~= nil) ~= s.selection then
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
	local v = {root = ctx.root, selection = ctx.selection_text or "", line = "", col = "", word = ""}
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
	local base = ctx.base
	v.base = base.ref
	v.base_merge = base.merge
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

local function parse_locations(text, cwd)
	local items = {}
	for _, line in ipairs(lines_of(text)) do
		local file, row, col, msg = line:match("^(.-):(%d+):(%d+):%s*(.*)$")
		if not file then
			file, row, msg = line:match("^(.-):(%d+):%s*(.*)$")
		end
		if file and file ~= "" then
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
	local rev = ok and r.code == 0 and first_line(r.stdout)
	return rev or ref
end

local function run(s, pane, ctx)
	if running[s.name] then
		say(s.name, "already running", "warn")
		return
	end
	local v = values(ctx, pane)
	local b = pane == "editor" and ctx.buf or nil
	running[s.name] = {}
	local ok, err = save_first(s, b)
	if not ok then
		running[s.name] = nil
		say(s.name, err, "error")
		return
	end
	if b and not qed.buf.valid(b) then
		running[s.name] = nil
		return
	end
	local job = {buf = b, cwd = s.cwd and qed.path.abs(expand(s.cwd, v, false)) or ctx.root}
	if b then
		job.rev = qed.buf.rev(b)
		job.cursor = qed.buf.cursor(b)
		job.from, job.to = qed.buf.selection(b)
		if job.from then
			local sel = qed.buf.lines(b, job.from.row, job.to.row)
			sel[#sel] = sel[#sel]:sub(1, job.to.col - 1)
			sel[1] = sel[1]:sub(job.from.col)
			job.region = table.concat(sel, "\n")
		else
			job.region = qed.buf.text(b)
		end
	end
	if v.base_merge then
		v.base = merge_base(v.base, job.cwd)
	end
	local cmd = expand(s.run, v, true)
	if s.output == "terminal" then
		running[s.name] = nil
		local done, terr = qed.terminal.run(cmd, {cwd = s.cwd and job.cwd or nil})
		if not done then
			say(s.name, terr, "error")
		end
		return
	end
	local stdin
	if s.stdin == "buffer" or (s.stdin == "selection-or-buffer" and not job.from) then
		stdin = qed.buf.text(b)
	elseif s.stdin ~= "none" then
		stdin = job.from and job.region or ""
	end
	local state = {}
	running[s.name] = state
	local started, proc = pcall(qed.spawn_bg, {cmd = cmd, stdin = stdin, cwd = job.cwd, env = environment(s, v)})
	if not started then
		running[s.name] = nil
		say(s.name, tostring(proc), "error")
		return
	end
	state.proc = proc
	qed.defer(RUNNING_HINT_MS, function()
		if running[s.name] == state then
			say(s.name, "running…")
		end
	end)
	local r, werr = proc:wait()
	running[s.name] = nil
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
					warn(("plugins.commands %q: %s"):format(s.name, h))
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
		if state.proc then
			state.cancelled = true
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
	end,
}

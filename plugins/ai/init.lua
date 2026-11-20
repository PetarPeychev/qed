local cfg, hook, hooks
local ranges, tints, ghosts
local edits = {}
local waiting = {}
local fim = {enabled = false, warned = false, gen = 0}
local seen = {}

local CONTEXT_BYTES = 64 * 1024

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function last_find(s, needle)
	local at
	local i = 1
	while true do
		local j = s:find(needle, i, true)
		if not j then
			return at
		end
		at, i = j, j + 1
	end
end

-- the last fence wins: a model that reasons first may quote example snippets
local function extract(s)
	local close = last_find(s, "```")
	if not close then
		return trim(s)
	end
	local open = last_find(s:sub(1, close - 1), "```")
	local inner = open and s:sub(open + 3, close - 1) or s:sub(close + 3)
	local nl = inner:find("\n", 1, true)
	if nl then
		inner = inner:sub(nl + 1)
	end
	return trim(inner)
end

-- models drop or invent surrounding whitespace, so the selection's own framing is kept
local function reframe(core, original)
	local lead = original:match("^%s*")
	if #lead == #original then
		return lead .. core
	end
	return lead .. core .. original:match("%s*$")
end

local function before(a, b)
	return a.row < b.row or (a.row == b.row and a.col < b.col)
end

-- Unlike a plain plugin edit, a position at `from` stays put, so a selection keeps covering the new text.
local function translate(p, from, to, new_end)
	if not before(from, p) then
		return p
	end
	if not before(to, p) then
		return new_end
	end
	local out = {row = p.row + new_end.row - to.row, col = p.col}
	if p.row == to.row then
		out.col = new_end.col + p.col - to.col
	end
	return out
end

local function offset(lines, pos)
	local n = 0
	for r = 1, pos.row - 1 do
		n = n + #lines[r] + 1
	end
	return n + pos.col
end

local function build_prompt(b, instruction, from, to)
	local lines = qed.buf.lines(b)
	local text = table.concat(lines, "\n")
	local a, z = offset(lines, from), offset(lines, to)
	local selection = text:sub(a, z - 1)
	local marked = text:sub(1, a - 1) .. "<<<SELECT\n" .. selection .. "\nSELECT>>>" .. text:sub(z)
	local path = qed.buf.path(b)
	local fill = {
		{"{path}", path ~= "" and path or "(unsaved buffer)"},
		{"{instruction}", instruction},
		{"{file}", marked},
		{"{selection}", selection},
	}
	local prompt = cfg.edit_prompt
	for _, f in ipairs(fill) do
		prompt = prompt:gsub(f[1], function() return f[2] end)
	end
	return prompt, selection
end

local function spaces()
	ranges = qed.deco.ns("ranges")
	tints = qed.deco.ns("tints")
	ghosts = qed.deco.ns("ghosts")
end

local changed, reloaded, closed

-- Subscribed only while something listens, so an idle plugin costs no task per keystroke.
local function sync_hook()
	local want = #edits > 0 or fim.enabled
	if want and not hook then
		hook = qed.on("buf_changed", changed)
	elseif not want and hook then
		hook:off()
		hook = nil
	end
	if #edits > 0 and not hooks then
		hooks = {qed.on("buf_reload", reloaded), qed.on("buf_close", closed)}
	elseif #edits == 0 and hooks then
		hooks[1]:off()
		hooks[2]:off()
		hooks = nil
	end
end

local function status()
	if #edits > 0 then
		qed.status.set("edits", {text = "AI:" .. #edits, side = "right", drop = 5})
	else
		qed.status.clear("edits")
	end
end

local function retint(b)
	if not qed.buf.valid(b) then
		return
	end
	qed.deco.clear(b, tints)
	local live = false
	for _, wb in pairs(waiting) do
		live = live or wb == b
	end
	for _, e in ipairs(edits) do
		if e.buf == b then
			live = true
			local from, to = qed.deco.range(b, ranges, e.mark)
			if from then
				local last = to.row
				if to.col == 1 and to.row > from.row then
					last = to.row - 1
				end
				qed.deco.tint(b, tints, from.row, last, "ai_edit_background", "ai_edit")
			end
		end
	end
	if not live then
		qed.deco.clear(b, ranges)
	end
end

local function drop(e)
	for i, x in ipairs(edits) do
		if x == e then
			table.remove(edits, i)
			break
		end
	end
	e.done = true
	retint(e.buf)
	status()
	sync_hook()
end

local function apply(e, r)
	local raw = r.stdout
	qed.log("debug", ("response (%dB):\n%s"):format(#raw, raw))
	if r.code ~= 0 then
		qed.log("debug", ("command exited %d (%dB reply)"):format(r.code, #raw))
		qed.message(("Command failed (exit %d)"):format(r.code), "error")
		return
	end
	local core = extract(raw)
	if core == "" then
		qed.log("debug", ("no usable code block in reply (%dB raw)"):format(#raw))
		qed.message("Empty result, discarded", "error")
		return
	end
	local b = e.buf
	if not qed.buf.valid(b) then
		qed.message("Buffer closed, discarded", "error")
		return
	end
	local from, to = qed.deco.range(b, ranges, e.mark)
	if not from then
		qed.message("Edit discarded: block changed", "error")
		return
	end
	qed.log("debug", ("applied at %d:%d (%dB)"):format(from.row - 1, from.col - 1, #core))
	local cursor = qed.buf.cursor(b)
	local sel_from, sel_to = qed.buf.selection(b)
	local anchor
	if sel_from then
		anchor = (sel_to.row == cursor.row and sel_to.col == cursor.col) and sel_from or sel_to
	end
	local new_end
	qed.edit(b, function()
		new_end = qed.buf.replace(b, from, to, reframe(core, e.original))
	end)
	cursor = translate(cursor, from, to, new_end)
	if anchor then
		qed.buf.set_selection(b, translate(anchor, from, to, new_end), cursor)
	else
		qed.buf.set_cursor(b, cursor)
	end
	qed.message("Edit applied")
end

local function edit_selection(ctx)
	local b = ctx.buf
	local from, to = qed.buf.selection(b)
	if not from then
		qed.message("Select a block first", "error")
		return
	end
	spaces()
	local mark = qed.deco.mark(b, ranges, from, to)
	waiting[mark] = b
	local instruction = qed.prompt{prompt = "AI edit:"}
	waiting[mark] = nil
	local function abandon(msg)
		if qed.buf.valid(b) then
			retint(b)
		end
		if msg then
			qed.message(msg, "error")
		end
	end
	if instruction == nil then
		return abandon()
	end
	if instruction == "" then
		return abandon("Empty instruction")
	end
	from, to = nil, nil
	if qed.buf.valid(b) then
		from, to = qed.deco.range(b, ranges, mark)
	end
	if not from then
		return abandon("Edit discarded: block changed")
	end
	if trim(cfg.chat_command) == "" then
		return abandon("plugins.ai.chat_command is empty")
	end
	local prompt, selection = build_prompt(b, instruction, from, to)
	qed.log("debug", ("prompt (%dB):\n%s"):format(#prompt, prompt))
	local ok, proc = pcall(qed.spawn_bg, {cmd = cfg.chat_command, stdin = prompt})
	if not ok then
		qed.log("debug", ("spawn failed: %s (%s)"):format(cfg.chat_command, proc))
		return abandon("Could not start command")
	end
	local e = {proc = proc, buf = b, original = selection, mark = mark}
	edits[#edits + 1] = e
	retint(b)
	status()
	sync_hook()
	qed.log("debug", ("request sent: %s (%dB prompt)"):format(cfg.chat_command, #prompt))
	qed.message(("Edit sent (%d running)"):format(#edits))
	local r = proc:wait()
	if e.done or not r then
		return
	end
	apply(e, r)
	drop(e)
end

local function cancel_all()
	local n = #edits
	local bufs = {}
	for _, e in ipairs(edits) do
		e.done = true
		e.proc:kill()
		bufs[e.buf] = true
	end
	edits = {}
	for b in pairs(bufs) do
		retint(b)
	end
	status()
	sync_hook()
	if n > 0 then
		qed.message(("Cancelled %d edit(s)"):format(n))
	end
end

local function prune(b, why, all)
	local cancelled = 0
	for i = #edits, 1, -1 do
		local e = edits[i]
		if e.buf == b and (all or not qed.deco.range(b, ranges, e.mark)) then
			e.done = true
			e.proc:kill()
			table.remove(edits, i)
			cancelled = cancelled + 1
		end
	end
	if cancelled > 0 then
		if why then
			qed.message("Edit cancelled: " .. why)
		end
		status()
		sync_hook()
	end
	if not all then
		retint(b)
	end
end

reloaded = function(b)
	if qed.buf.valid(b) then
		prune(b, "file reloaded")
	end
end

closed = function(b)
	prune(b, nil, true)
end

local function fim_stop()
	fim.gen = fim.gen + 1
	if fim.timer then
		fim.timer:stop()
		fim.timer = nil
	end
	if fim.proc then
		fim.proc:kill()
		fim.proc = nil
	end
end

local function fim_dismiss()
	fim_stop()
	if fim.buf and qed.buf.valid(fim.buf) then
		qed.deco.clear(fim.buf, ghosts)
	end
end

local function fim_parse(raw)
	local ok, val = pcall(qed.json.decode, raw)
	if not ok or type(val) ~= "table" or type(val.choices) ~= "table" or type(val.choices[1]) ~= "table" then
		return ""
	end
	local c0 = val.choices[1]
	if type(c0.message) == "table" and type(c0.message.content) == "string" then
		return c0.message.content
	end
	return type(c0.text) == "string" and c0.text or ""
end

local function fim_request(b, gen, typed_at, typed_rev)
	if gen ~= fim.gen or not qed.buf.valid(b) or qed.buf.current() ~= b or qed.buf.selection(b) then
		return
	end
	local pos, rev = qed.buf.cursor(b), qed.buf.rev(b)
	if rev ~= typed_rev or pos.row ~= typed_at.row or pos.col ~= typed_at.col then
		return
	end
	local env = cfg.completion_api_key_env
	if not env:match("^[%a_][%w_]*$") then
		if not fim.warned then
			fim.warned = true
			qed.message(("Inline completion: completion_api_key_env %q is not a variable name"):format(env), "warn")
		end
		return
	end
	if (os.getenv(env) or "") == "" then
		if not fim.warned then
			fim.warned = true
			qed.message(("Inline completion: $%s is not set"):format(env), "warn")
		end
		return
	end
	local lo = math.max(1, pos.row - cfg.completion_context_lines)
	local hi = math.min(qed.buf.line_count(b), pos.row + cfg.completion_context_lines)
	local lines = qed.buf.lines(b, lo, hi)
	local at = pos.row - lo + 1
	local cur = lines[at]
	local prefix = table.concat(lines, "\n", 1, at - 1) .. (at > 1 and "\n" or "") .. cur:sub(1, pos.col - 1)
	local suffix = cur:sub(pos.col) .. (at < #lines and "\n" or "") .. table.concat(lines, "\n", at + 1)
	if #prefix > CONTEXT_BYTES then
		prefix = prefix:sub(-CONTEXT_BYTES):gsub("^[\128-\191]+", "")
	end
	if #suffix > CONTEXT_BYTES then
		suffix = suffix:sub(1, CONTEXT_BYTES):gsub("[\192-\255][\128-\191]*$", "")
	end
	local body = qed.json.encode{
		model = cfg.completion_model,
		prompt = prefix,
		suffix = suffix,
		max_tokens = cfg.completion_max_tokens,
		temperature = 0,
	}
	-- The body goes on stdin: the spawn unlinks its temp at once, so a lazily opened `@file` would race to empty.
	-- The key reaches curl through a here-doc on fd 3, never through argv (visible in /proc).
	local cmd = ("curl -s --max-time 10 -X POST %s -H 'Content-Type: application/json' -H @/dev/fd/3 --data-binary @- 3<<EOF\nAuthorization: Bearer $%s\nEOF")
		:format(qed.shell_quote(cfg.completion_endpoint), env)
	local ok, proc = pcall(qed.spawn_bg, {cmd = cmd, stdin = body})
	if not ok then
		qed.log("debug", ("spawn failed: curl (%s)"):format(proc))
		return
	end
	fim.proc = proc
	qed.log("debug", ("request fired: prefix=%dB suffix=%dB"):format(#prefix, #suffix))
	local r = proc:wait()
	if gen ~= fim.gen or not r then
		return
	end
	fim.proc = nil
	local text = fim_parse(r.stdout):gsub("\n+$", "")
	local now = qed.buf.valid(b) and qed.buf.cursor(b)
	local moved = not now or qed.buf.current() ~= b or qed.buf.rev(b) ~= rev or now.row ~= pos.row or now.col ~= pos.col
	if r.code ~= 0 then
		qed.log("debug", ("curl exited %d (%dB reply)"):format(r.code, #r.stdout))
	else
		qed.log("debug", ("response %dB -> %dB suggestion, moved=%s, raw=%q"):format(#r.stdout, #text, tostring(moved), r.stdout:sub(1, 200)))
	end
	if not moved and text:find("%S") then
		spaces()
		fim.buf = b
		qed.deco.inline(b, ghosts, pos, text, {rev = rev})
	end
end

local function fim_typed(b)
	fim_stop()
	if not fim.enabled or qed.buf.selection(b) or qed.buf.big(b) then
		return
	end
	local gen, at, rev = fim.gen, qed.buf.cursor(b), qed.buf.rev(b)
	fim.timer = qed.defer(cfg.completion_debounce_ms, function()
		fim.timer = nil
		fim_request(b, gen, at, rev)
	end)
end

local function configure(c)
	cfg = c
	if c.completion_enabled ~= seen.completion_enabled then
		seen.completion_enabled = c.completion_enabled
		fim.enabled = c.completion_enabled
		if not fim.enabled then
			fim_dismiss()
		end
		sync_hook()
	end
end

changed = function(b, _, typed)
	if not qed.buf.valid(b) then
		return
	end
	if #edits > 0 then
		prune(b, "block edited")
	end
	if typed then
		fim_typed(b)
	end
end

return {
	setup = function()
		qed.meta{display_name = "AI"}
		configure(qed.options{
			chat_command = "claude -p",
			edit_prompt = "You are editing the file {path}. Its full current content is below, with the region to rewrite marked between <<<SELECT and SELECT>>>. You may read other project files for context and reason briefly first if you need to. Then give the replacement for the marked region, and nothing else, inside a single markdown fenced code block (```). Do not repeat the surrounding code or the markers, and write nothing after the closing fence.\n\nInstruction: {instruction}\n\n{file}",
			completion_enabled = false,
			completion_endpoint = "https://codestral.mistral.ai/v1/fim/completions",
			completion_model = "codestral-latest",
			completion_api_key_env = "CODESTRAL_API_KEY",
			completion_max_tokens = 256,
			completion_debounce_ms = 350,
			completion_context_lines = 200,
		})
		qed.command{
			name = "Edit Selection",
			key = "Ctrl+k",
			when = function(ctx) return ctx.buf ~= nil end,
			run = edit_selection,
		}
		qed.command{name = "Cancel Edits", run = cancel_all}
		qed.command{name = "Toggle Inline Completion", run = function()
			fim.enabled = not fim.enabled
			fim.warned = false
			if not fim.enabled then
				fim_dismiss()
			end
			sync_hook()
			qed.message("Inline completion: " .. (fim.enabled and "on" or "off"))
		end}
		qed.on("config_changed", function() configure(qed.config()) end)
	end,
}

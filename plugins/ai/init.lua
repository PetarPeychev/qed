local cfg, hook, hooks
local ranges, tints, ghosts
local edits = {}
local waiting = {}
local fim = {enabled = false, warned = false, gen = 0}

local CONTEXT_BYTES = 64 * 1024

local function trim(source)
	return (source:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function last_find(source, needle)
	local at
	local i = 1
	while true do
		local found = source:find(needle, i, true)
		if not found then
			return at
		end
		at, i = found, found + 1
	end
end

-- the last fence wins: a model that reasons first may quote example snippets
local function extract(source)
	local close = last_find(source, "```")
	if not close then
		return trim(source)
	end
	local open = last_find(source:sub(1, close - 1), "```")
	local inner = open and source:sub(open + 3, close - 1) or source:sub(close + 3)
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

local function before(left, right)
	return left.row < right.row or (left.row == right.row and left.col < right.col)
end

local function translate(point, from, to, new_end)
	if not before(from, point) then
		return point
	end
	if not before(to, point) then
		return new_end
	end
	local out = {row = point.row + new_end.row - to.row, col = point.col}
	if point.row == to.row then
		out.col = new_end.col + point.col - to.col
	end
	return out
end

local function offset(lines, pos)
	local count = 0
	for row = 1, pos.row - 1 do
		count = count + #lines[row] + 1
	end
	return count + pos.col
end

local function build_prompt(buffer, instruction, from, to)
	local lines = buffer:lines()
	local text = table.concat(lines, "\n")
	local start_offset, end_offset = offset(lines, from), offset(lines, to)
	local selection = text:sub(start_offset, end_offset - 1)
	local marked = text:sub(1, start_offset - 1) .. "<<<SELECT\n" .. selection .. "\nSELECT>>>" .. text:sub(end_offset)
	local path = buffer:path()
	local fill = {
		{"{path}", path ~= "" and path or "(unsaved buffer)"},
		{"{instruction}", instruction},
		{"{file}", marked},
		{"{selection}", selection},
	}
	local prompt = cfg.edit_prompt
	for _, substitution in ipairs(fill) do
		prompt = prompt:gsub(substitution[1], function() return substitution[2] end)
	end
	return prompt, selection
end

local function spaces()
	ranges = qed.deco.ns("ranges")
	tints = qed.deco.ns("tints")
	ghosts = qed.deco.ns("ghosts")
end

local changed, reloaded, closed

local function sync_hook()
	local want = #edits > 0 or fim.enabled
	if want and not hook then
		hook = qed:on("buf_changed", changed)
	elseif not want and hook then
		hook:off()
		hook = nil
	end
	if #edits > 0 and not hooks then
		hooks = {qed:on("buf_reload", reloaded), qed:on("buf_close", closed)}
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

local function retint(buffer)
	if not buffer:valid() then
		return
	end
	qed.deco.clear(buffer, tints)
	local live = false
	for _, wb in pairs(waiting) do
		live = live or wb == buffer
	end
	for _, edit in ipairs(edits) do
		if edit.buf == buffer then
			live = true
			local from, to = qed.deco.range(buffer, ranges, edit.mark)
			if from then
				local last = to.row
				if to.col == 1 and to.row > from.row then
					last = to.row - 1
				end
				qed.deco.tint(buffer, tints, from.row, last, {color = "ai_edit_background", alpha = "ai_edit"})
			end
		end
	end
	if not live then
		qed.deco.clear(buffer, ranges)
	end
end

local function drop(edit)
	for i, other in ipairs(edits) do
		if other == edit then
			table.remove(edits, i)
			break
		end
	end
	edit.done = true
	retint(edit.buf)
	status()
	sync_hook()
end

local function apply(edit, result)
	local raw = result.stdout
	qed.log(("response (%dB):\n%s"):format(#raw, raw), "debug")
	if result.code ~= 0 then
		qed.log(("command exited %d (%dB reply)"):format(result.code, #raw), "debug")
		qed.message(("Command failed (exit %d)"):format(result.code), "error")
		return
	end
	local core = extract(raw)
	if core == "" then
		qed.log(("no usable code block in reply (%dB raw)"):format(#raw), "debug")
		qed.message("Empty result, discarded", "error")
		return
	end
	local buffer = edit.buf
	if not buffer:valid() then
		qed.message("Buffer closed, discarded", "error")
		return
	end
	local from, to = qed.deco.range(buffer, ranges, edit.mark)
	if not from then
		qed.message("Edit discarded: block changed", "error")
		return
	end
	qed.log(("applied at %d:%d (%dB)"):format(from.row, from.col, #core), "debug")
	local cursor = buffer:cursor()
	local sel_from, sel_to = buffer:selection()
	local anchor
	if sel_from then
		anchor = (sel_to.row == cursor.row and sel_to.col == cursor.col) and sel_from or sel_to
	end
	local new_end
	qed.edit(buffer, function()
		new_end = buffer:replace(from, to, reframe(core, edit.original))
	end)
	cursor = translate(cursor, from, to, new_end)
	if anchor then
		buffer:set_selection(translate(anchor, from, to, new_end), cursor)
	else
		buffer:set_cursor(cursor)
	end
	qed.message("Edit applied")
end

local function edit_selection(ctx)
	local buffer = ctx.buf
	local from, to = buffer:selection()
	if not from then
		qed.message("Select a block first", "error")
		return
	end
	spaces()
	local mark = qed.deco.mark(buffer, ranges, from, to)
	waiting[mark] = buffer
	local instruction = qed.prompt{prompt = "AI edit:"}
	waiting[mark] = nil
	local function abandon(msg)
		if buffer:valid() then
			retint(buffer)
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
	if buffer:valid() then
		from, to = qed.deco.range(buffer, ranges, mark)
	end
	if not from then
		return abandon("Edit discarded: block changed")
	end
	if trim(cfg.edit_command) == "" then
		return abandon("plugins.ai.edit_command is empty")
	end
	local prompt, selection = build_prompt(buffer, instruction, from, to)
	qed.log(("prompt (%dB):\n%s"):format(#prompt, prompt), "debug")
	local proc, err = qed.spawn_bg{cmd = cfg.edit_command, stdin = prompt}
	if not proc then
		qed.log(("spawn failed: %s (%s)"):format(cfg.edit_command, err), "debug")
		return abandon("Could not start command")
	end
	local edit = {proc = proc, buf = buffer, original = selection, mark = mark}
	edits[#edits + 1] = edit
	retint(buffer)
	status()
	sync_hook()
	qed.log(("request sent: %s (%dB prompt)"):format(cfg.edit_command, #prompt), "debug")
	qed.message(("Edit sent (%d running)"):format(#edits))
	local result = proc:wait()
	if edit.done or not result then
		return
	end
	apply(edit, result)
	drop(edit)
end

local function cancel_all()
	local count = #edits
	local bufs = {}
	for _, edit in ipairs(edits) do
		edit.done = true
		edit.proc:kill()
		bufs[edit.buf] = true
	end
	edits = {}
	for buffer in pairs(bufs) do
		retint(buffer)
	end
	status()
	sync_hook()
	if count > 0 then
		qed.message(("Cancelled %d edit(s)"):format(count))
	else
		qed.message("No edits running")
	end
end

local function prune(buffer, why, all)
	local cancelled = 0
	for i = #edits, 1, -1 do
		local edit = edits[i]
		if edit.buf == buffer and (all or not qed.deco.range(buffer, ranges, edit.mark)) then
			edit.done = true
			edit.proc:kill()
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
		retint(buffer)
	end
end

reloaded = function(buffer)
	if buffer:valid() then
		prune(buffer, "file reloaded")
	end
end

closed = function(buffer)
	prune(buffer, nil, true)
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
	if fim.buf and fim.buf:valid() then
		qed.deco.clear(fim.buf, ghosts)
	end
end

local function fim_parse(raw)
	local val = qed.json.decode(raw)
	if type(val) ~= "table" or type(val.choices) ~= "table" or type(val.choices[1]) ~= "table" then
		return ""
	end
	local c0 = val.choices[1]
	if type(c0.message) == "table" and type(c0.message.content) == "string" then
		return c0.message.content
	end
	return type(c0.text) == "string" and c0.text or ""
end

local function fim_request(buffer, gen, typed_at, typed_rev)
	if gen ~= fim.gen or not buffer:valid() or qed.buf.current() ~= buffer or buffer:selection() then
		return
	end
	local pos, rev = buffer:cursor(), buffer:rev()
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
	local hi = math.min(buffer:line_count(), pos.row + cfg.completion_context_lines)
	local lines = buffer:lines(lo, hi)
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
	local proc, err = qed.spawn_bg{cmd = cmd, stdin = body}
	if not proc then
		qed.log(("spawn failed: curl (%s)"):format(err), "debug")
		return
	end
	fim.proc = proc
	qed.log(("request fired: prefix=%dB suffix=%dB"):format(#prefix, #suffix), "debug")
	local result = proc:wait()
	if gen ~= fim.gen or not result then
		return
	end
	fim.proc = nil
	local text = fim_parse(result.stdout):gsub("\n+$", "")
	local now = buffer:valid() and buffer:cursor()
	local moved = not now or qed.buf.current() ~= buffer or buffer:rev() ~= rev or now.row ~= pos.row or now.col ~= pos.col
	if result.code ~= 0 then
		qed.log(("curl exited %d (%dB reply)"):format(result.code, #result.stdout), "debug")
	else
		qed.log(("response %dB -> %dB suggestion, moved=%s, raw=%q"):format(#result.stdout, #text, tostring(moved), result.stdout:sub(1, 200)), "debug")
	end
	if not moved and text:find("%S") then
		spaces()
		fim.buf = buffer
		qed.deco.inline(buffer, ghosts, pos, text, {rev = rev})
	end
end

local function fim_typed(buffer)
	fim_stop()
	if not fim.enabled or buffer:selection() or buffer:big() then
		return
	end
	local gen, at, rev = fim.gen, buffer:cursor(), buffer:rev()
	fim.timer = qed.defer(cfg.completion_debounce_ms, function()
		fim.timer = nil
		fim_request(buffer, gen, at, rev)
	end)
end

local function configure(config, changed)
	cfg = config
	if not changed or changed.completion_enabled then
		fim.enabled = config.completion_enabled
		if not fim.enabled then
			fim_dismiss()
		end
		sync_hook()
	end
end

changed = function(buffer, _, typed)
	if not buffer:valid() then
		return
	end
	if #edits > 0 then
		prune(buffer, "block edited")
	end
	if typed then
		fim_typed(buffer)
	end
end

return {
	setup = function()
		qed.meta{display_name = "AI", description = "Selection edits and inline completion from an LLM"}
		configure(qed.options({
			edit_command = "claude -p",
			edit_prompt = "You are editing the file {path}. Its full current content is below, with the region to rewrite marked between <<<SELECT and SELECT>>>. You may read other project files for context and reason briefly first if you need to. Then give the replacement for the marked region, and nothing else, inside a single markdown fenced code block (```). Do not repeat the surrounding code or the markers, and write nothing after the closing fence.\n\nInstruction: {instruction}\n\n{file}",
			completion_enabled = false,
			completion_endpoint = "https://codestral.mistral.ai/v1/fim/completions",
			completion_model = "codestral-latest",
			completion_api_key_env = "CODESTRAL_API_KEY",
			completion_max_tokens = 256,
			completion_debounce_ms = 350,
			completion_context_lines = 200,
		}, {
			edit_command = "Command that answers an edit request on stdin",
			edit_prompt = "Edit request template: {path}, {instruction}, {file}",
			completion_enabled = "Inline completion while typing",
			completion_endpoint = "FIM endpoint for inline completion",
			completion_model = "Model sent to the FIM endpoint",
			completion_api_key_env = "Environment variable holding the FIM API key",
			completion_max_tokens = "Max tokens per completion",
			completion_debounce_ms = "Typing pause before a completion is requested",
			completion_context_lines = "Lines of context before and after the cursor",
		}))
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
		qed:on("config_changed", function(changed) configure(qed.config(), changed) end)
	end,
}

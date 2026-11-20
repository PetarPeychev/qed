local on = {}
local seen = {}
local commands = {}

local KNOBS = {
	on_save = "format",
	trim_whitespace_on_save = "trim",
	final_newline_on_save = "newline",
}

local LSP_ERRORS = {
	disabled = "No formatter for this buffer",
	["no server"] = "No language server for this buffer",
	unavailable = "Formatting not available",
	timeout = "LSP format timed out",
}

local function trim_len(line, markdown)
	local n = #line:match("[ \t]*$")
	-- Two+ trailing spaces on a markdown content line are a hard line break.
	if n > 0 and markdown and n < #line and line:sub(-2) == "  " then
		return 0
	end
	return n
end

local function fixups(b)
	if not on.trim and not on.newline then
		return
	end
	local markdown = qed.buf.language(b) == "markdown"
	local lines = qed.buf.lines(b)
	local last = #lines
	local last_trim = on.trim and trim_len(lines[last], markdown) or 0
	local newline = on.newline and #lines[last] > last_trim
	local cuts = {}
	if on.trim then
		for row, line in ipairs(lines) do
			local n = trim_len(line, markdown)
			if n > 0 then
				cuts[#cuts + 1] = {row = row, col = #line - n + 1, to = #line + 1}
			end
		end
	end
	if #cuts == 0 and not newline then
		return
	end
	qed.edit(b, function()
		for _, c in ipairs(cuts) do
			qed.buf.delete(b, {row = c.row, col = c.col}, {row = c.row, col = c.to})
		end
		if newline then
			local eof = {row = last, col = #qed.buf.line(b, last) + 1}
			local cur = qed.buf.cursor(b)
			local keep = cur.row == eof.row and cur.col == eof.col and not qed.buf.selection(b)
			qed.buf.insert(b, eof, "\n")
			if keep then
				qed.buf.set_cursor(b, eof)
			end
		end
	end)
	qed.log("debug", ("fixups: trimmed %d line(s), final-newline=%s"):format(#cuts, tostring(newline)))
end

local function external(b, cmd, on_save)
	local tool = cmd:match("^%S+") or cmd
	local path = qed.buf.path(b)
	local file = path ~= "" and path or qed.path.join(qed.root(), "untitled")
	local run = cmd:gsub("{file}", function() return qed.shell_quote(file) end)
	local rev = qed.buf.rev(b)
	local input = qed.buf.text(b)
	local ok, r = pcall(qed.spawn, {cmd = run, stdin = input, cwd = qed.path.dir(file)})
	if not qed.buf.valid(b) then
		return
	end
	if not ok or r.code ~= 0 or r.stdout == "" then
		if ok and r.code == 127 then
			qed.message("Formatter not found: " .. tool, "error")
		else
			qed.message(tool .. " failed", "error")
		end
		qed.log("debug", ("%s: %s"):format(tool, ok and ("exit " .. r.code .. " " .. r.stderr) or r))
		return
	end
	qed.log("debug", ("ran %s: %dB in, %dB out"):format(tool, #input, #r.stdout))
	local out = r.stdout:gsub("\r\n", "\n")
	if out == input then
		if not on_save then
			qed.message("No formatting changes")
		end
		return
	end
	local set, applied = pcall(qed.buf.set_text, b, out, {rev = rev})
	if not set then
		qed.message(("%s failed: %s"):format(tool, applied), "error")
	elseif not applied then
		if not on_save then
			qed.message("skipped: buffer changed", "warn")
		end
	elseif not on_save then
		qed.message("Formatted")
	end
end

local function lsp(b, on_save)
	local rev = qed.buf.rev(b)
	local ok, err = qed.lsp.format(b)
	if on_save or not qed.buf.valid(b) then
		return
	end
	if ok then
		qed.message(qed.buf.rev(b) ~= rev and "Formatted" or "No formatting changes")
	elseif err == "stale" then
		qed.message("skipped: buffer changed", "warn")
	elseif LSP_ERRORS[err] then
		qed.message(LSP_ERRORS[err], "error")
	end
end

local function format(b, on_save)
	local cmd = commands[qed.buf.language(b)]
	if cmd and cmd ~= "" then
		external(b, cmd, on_save)
	else
		lsp(b, on_save)
	end
end

local function apply(cfg)
	for key, knob in pairs(KNOBS) do
		if cfg[key] ~= seen[key] then
			seen[key] = cfg[key]
			on[knob] = cfg[key]
		end
	end
	commands = cfg.commands or {}
end

local function toggle(name, knob, label)
	qed.command{name = name, run = function()
		on[knob] = not on[knob]
		qed.message(("%s on save: %s"):format(label, on[knob] and "on" or "off"))
	end}
end

return {
	setup = function()
		apply(qed.options{
			on_save = false,
			trim_whitespace_on_save = false,
			final_newline_on_save = false,
			commands = {
				python = "ruff format --stdin-filename {file} -",
				go = "gofmt",
				rust = "rustfmt --edition 2021",
				sql = "sql-formatter",
				toml = "taplo fmt --stdin-filepath {file} -",
				json = "prettier --parser json --stdin-filepath {file}",
			},
		})
		qed.command{
			name = "Document",
			when = function(ctx) return ctx.buf ~= nil end,
			run = function(ctx) format(ctx.buf, false) end,
		}
		toggle("Toggle on Save", "format", "Format")
		toggle("Toggle Trim Whitespace on Save", "trim", "Trim whitespace")
		toggle("Toggle Final Newline on Save", "newline", "Final newline")
		qed.on("config_changed", function() apply(qed.config()) end)
		qed.on("buf_pre_save", function(b)
			fixups(b)
			if on.format then
				format(b, true)
			end
		end)
	end,
}

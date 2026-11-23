local on = {}
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
	local markdown = b:language() == "markdown"
	local last = b:line_count()
	local tail = b:line(last)
	local last_trim = on.trim and trim_len(tail, markdown) or 0
	local newline = on.newline and #tail > last_trim
	local cuts = {}
	if on.trim then
		local rows, from, to = b:find_trailing()
		for i, row in ipairs(rows) do
			if not markdown or trim_len(b:line(row), true) > 0 then
				cuts[#cuts + 1] = {row = row, col = from[i], to = to[i]}
			end
		end
	end
	if #cuts == 0 and not newline then
		return
	end
	qed.edit(b, function()
		for _, c in ipairs(cuts) do
			b:delete({row = c.row, col = c.col}, {row = c.row, col = c.to})
		end
		if newline then
			local eof = {row = last, col = #b:line(last) + 1}
			local cur = b:cursor()
			local keep = cur.row == eof.row and cur.col == eof.col and not b:selection()
			b:insert(eof, "\n")
			if keep then
				b:set_cursor(eof)
			end
		end
	end)
	qed.log(("fixups: trimmed %d line(s), final-newline=%s"):format(#cuts, tostring(newline)), "debug")
end

local function external(b, cmd, on_save)
	local tool = cmd:match("^%S+") or cmd
	local path = b:path()
	local file = path ~= "" and path or qed.path.join(qed.root(), "untitled")
	local run = cmd:gsub("{file}", function() return qed.shell_quote(file) end)
	local rev = b:rev()
	local input = b:text()
	local r, err = qed.spawn{cmd = run, stdin = input, cwd = qed.path.dir(file)}
	if not b:valid() then
		return
	end
	if not r or r.code ~= 0 or r.stdout == "" then
		if r and r.code == 127 then
			qed.message("Formatter not found: " .. tool, "error")
		else
			qed.message(tool .. " failed", "error")
		end
		qed.log(("%s: %s"):format(tool, r and ("exit " .. r.code .. " " .. r.stderr) or err), "debug")
		return
	end
	qed.log(("ran %s: %dB in, %dB out"):format(tool, #input, #r.stdout), "debug")
	local out = r.stdout:gsub("\r\n", "\n")
	if out == input then
		if not on_save then
			qed.message("No formatting changes")
		end
		return
	end
	local set, applied = pcall(b.set_text, b, out, {rev = rev})
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
	local rev = b:rev()
	local ok, err = qed.lsp.format(b)
	if on_save or not b:valid() then
		return
	end
	if ok then
		qed.message(b:rev() ~= rev and "Formatted" or "No formatting changes")
	elseif err == "stale" then
		qed.message("skipped: buffer changed", "warn")
	elseif LSP_ERRORS[err] then
		qed.message(LSP_ERRORS[err], "error")
	end
end

local function format(b, on_save)
	local cmd = commands[b:language()]
	if cmd and cmd ~= "" then
		external(b, cmd, on_save)
	else
		lsp(b, on_save)
	end
end

local function apply(cfg, changed)
	for key, knob in pairs(KNOBS) do
		if not changed or changed[key] then
			on[knob] = cfg[key]
		end
	end
	commands = cfg.commands or {}
end

local function toggle(name, knob, label)
	qed.command{name = name, run = function()
		on[knob] = not on[knob]
		qed.message(("%s: %s"):format(label, on[knob] and "on" or "off"))
	end}
end

return {
	setup = function()
		qed.meta{description = "Formats on save and trims whitespace"}
		apply(qed.options({
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
		}, {
			on_save = "Format on save",
			trim_whitespace_on_save = "Trim trailing whitespace on save",
			final_newline_on_save = "End the file with a newline on save",
			commands = "Formatter per language: a stdin to stdout command, {file} is the path",
		}))
		qed.command{
			name = "Document",
			when = function(ctx) return ctx.buf ~= nil end,
			run = function(ctx) format(ctx.buf, false) end,
		}
		toggle("Toggle on Save", "format", "On save")
		toggle("Toggle Trim Whitespace on Save", "trim", "Trim whitespace on save")
		toggle("Toggle Final Newline on Save", "newline", "Final newline on save")
		qed:on("config_changed", function(changed) apply(qed.config(), changed) end)
		qed:on("buf_pre_save", function(b)
			fixups(b)
			if on.format then
				format(b, true)
			end
		end)
	end,
}

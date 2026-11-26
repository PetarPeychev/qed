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
	local trailing = #line:match("[ \t]*$")
	-- Two+ trailing spaces on a markdown content line are a hard line break.
	if trailing > 0 and markdown and trailing < #line and line:sub(-2) == "  " then
		return 0
	end
	return trailing
end

local function fixups(buffer)
	if not on.trim and not on.newline then
		return
	end
	local markdown = buffer:language() == "markdown"
	local last = buffer:line_count()
	local tail = buffer:line(last)
	local last_trim = on.trim and trim_len(tail, markdown) or 0
	local newline = on.newline and #tail > last_trim
	local cuts = {}
	if on.trim then
		local rows, from, to = buffer:find_trailing()
		for i, row in ipairs(rows) do
			if not markdown or trim_len(buffer:line(row), true) > 0 then
				cuts[#cuts + 1] = {row = row, col = from[i], to = to[i]}
			end
		end
	end
	if #cuts == 0 and not newline then
		return
	end
	qed.edit(buffer, function()
		for _, cut in ipairs(cuts) do
			buffer:delete({row = cut.row, col = cut.col}, {row = cut.row, col = cut.to})
		end
		if newline then
			local eof = {row = last, col = #buffer:line(last) + 1}
			local cur = buffer:cursor()
			local keep = cur.row == eof.row and cur.col == eof.col and not buffer:selection()
			buffer:insert(eof, "\n")
			if keep then
				buffer:set_cursor(eof)
			end
		end
	end)
	qed.log(("fixups: trimmed %d line(s), final-newline=%s"):format(#cuts, tostring(newline)), "debug")
end

local function external(buffer, cmd, on_save)
	local tool = cmd:match("^%S+") or cmd
	local path = buffer:path()
	local file = path ~= "" and path or qed.path.join(qed.root(), "untitled")
	local run = cmd:gsub("{file}", function() return qed.shell_quote(file) end)
	local rev = buffer:rev()
	local input = buffer:text()
	local result, err = qed.spawn{cmd = run, stdin = input, cwd = qed.path.dir(file)}
	if not buffer:valid() then
		return
	end
	if not result or result.code ~= 0 or result.stdout == "" then
		if result and result.code == 127 then
			qed.message("Formatter not found: " .. tool, "error")
		else
			qed.message(tool .. " failed", "error")
		end
		qed.log(("%s: %s"):format(tool, result and ("exit " .. result.code .. " " .. result.stderr) or err), "debug")
		return
	end
	qed.log(("ran %s: %dB in, %dB out"):format(tool, #input, #result.stdout), "debug")
	local out = result.stdout:gsub("\r\n", "\n")
	if out == input then
		if not on_save then
			qed.message("No formatting changes")
		end
		return
	end
	local set, applied = pcall(buffer.set_text, buffer, out, {rev = rev})
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

local function lsp(buffer, on_save)
	local rev = buffer:rev()
	local ok, err = qed.lsp.format(buffer)
	if on_save or not buffer:valid() then
		return
	end
	if ok then
		qed.message(buffer:rev() ~= rev and "Formatted" or "No formatting changes")
	elseif err == "stale" then
		qed.message("skipped: buffer changed", "warn")
	elseif LSP_ERRORS[err] then
		qed.message(LSP_ERRORS[err], "error")
	end
end

local function format(buffer, on_save)
	local cmd = commands[buffer:language()]
	if cmd and cmd ~= "" then
		external(buffer, cmd, on_save)
	else
		lsp(buffer, on_save)
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

local function toggle(id, name, knob, label)
	qed.command{id = id, name = name, run = function()
		on[knob] = not on[knob]
		qed.message(("%s: %s"):format(label, on[knob] and "on" or "off"))
	end}
end

return {
	setup = function()
		qed.meta{description = "Formats on save and trims whitespace"}
		qed.options{
			on_save = {type = "bool", default = false, description = "Format on save"},
			trim_whitespace_on_save = {type = "bool", default = false, description = "Trim trailing whitespace on save"},
			final_newline_on_save = {type = "bool", default = false, description = "End the file with a newline on save"},
			commands = {
				type = "map",
				key = {type = "choice", choices = qed.languages},
				value = "string",
				default = {
					python = "ruff format --stdin-filename {file} -",
					go = "gofmt",
					rust = "rustfmt --edition 2021",
					sql = "sql-formatter",
					toml = "taplo fmt --stdin-filepath {file} -",
					json = "prettier --parser json --stdin-filepath {file}",
				},
				description = "Formatter per language: a stdin to stdout command, {file} is the path",
			},
		}
		apply(qed.config())
		qed.command{
			id = "document", name = "Document",
			when = function(ctx) return ctx.buf ~= nil end,
			run = function(ctx) format(ctx.buf, false) end,
		}
		toggle("toggle_on_save", "Toggle on Save", "format", "On save")
		toggle("toggle_trim_whitespace_on_save", "Toggle Trim Whitespace on Save", "trim", "Trim whitespace on save")
		toggle("toggle_final_newline_on_save", "Toggle Final Newline on Save", "newline", "Final newline on save")
		qed:on("config_changed", function(changed) apply(qed.config(), changed) end)
		qed:on("buf_pre_save", function(buffer)
			fixups(buffer)
			if on.format then
				format(buffer, true)
			end
		end)
	end,
}

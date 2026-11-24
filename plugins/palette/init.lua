local ui = qed.ui

local palette

-- runs of matched characters become one bold span each: few spans per row keep typing cheap
local function name_spans(record, positions)
	local name = record.name
	if not positions or #positions == 0 then
		return {name}
	end
	local spans = {}
	local plain_from, run_from, run_to = 1, nil, nil
	local function close_run()
		if run_from then
			spans[#spans + 1] = {fg = "pane_prompt_foreground", bold = true, name:sub(run_from, run_to)}
			plain_from, run_from = run_to + 1, nil
		end
	end
	for _, offset in ipairs(positions) do
		local stop = (utf8.offset(name, 2, offset) or #name + 1) - 1
		if not (run_from and offset == run_to + 1) then
			close_run()
			if offset > plain_from then
				spans[#spans + 1] = name:sub(plain_from, offset - 1)
			end
			run_from = offset
		end
		run_to = stop
	end
	close_run()
	if plain_from <= #name then
		spans[#spans + 1] = name:sub(plain_from)
	end
	return spans
end

local function close_palette()
	if not palette then
		return
	end
	local closing = palette
	palette = nil
	closing.handle:unmount()
	closing.query:close()
end

local function highlighted_key()
	local state = ui.node("palette_results"):state()
	return state and state.highlighted
end

local function run_command(name)
	if not palette or not name then
		return
	end
	local record = palette.commands:get(name)
	close_palette()
	qed.run(name, {scope = record and record.scope ~= "global" and record.scope or nil})
end

local function run_highlighted()
	run_command(highlighted_key())
end

local function command_row(record)
	return ui.row{
		on = {
			double_click = function()
				run_command(record.name)
				return true
			end,
		},
		ui.text{grow = 1, " ", table.unpack(name_spans(record, palette and palette.matches:positions(record.name)))},
		ui.text{fg = "pane_shortcut_foreground", record.shortcut, " "},
	}
end

local function build(matches, query, empty)
	return ui.dismissable{on_dismiss = close_palette,
		ui.pane{id = "palette", place = "center", scope = "list",
			ui.row{
				ui.text{fg = "pane_prompt_foreground", " > "},
				ui.editor{id = "palette_query", buffer = query, height = 1, grow = 1, margin = {right = 1},
					scope = {"palette", "editor"}},
			},
			ui.column{
				empty and ui.text{fg = "pane_shortcut_foreground", " No matching commands"} or false,
				ui.scroll{height = {"fit", max = qed.opt("picker_max_rows")},
					ui.virtual_column{id = "palette_results", data = matches, item = command_row,
						highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}},
			},
		},
	}
end

local function highlight_first(matches)
	local first = matches:at(1)
	ui.node("palette_results"):set_state{highlighted = first and first.name or false}
end

local function open_palette()
	if palette then
		close_palette()
		return
	end
	-- over a focused pane its own commands, else the global ones
	local all = qed.commands()
	-- a pane's scope holds plugin commands; core's own scopes (editor, list, ...) hold only core ones
	local plugin_scopes = {}
	for _, command in ipairs(all) do
		if command.owner then
			plugin_scopes[command.scope] = true
		end
	end
	local wanted = {}
	for _, focus_scope in ipairs(qed.ui.focus_scopes()) do
		if plugin_scopes[focus_scope] then
			wanted[focus_scope] = true
		end
	end
	local scoped = false
	for _, command in ipairs(all) do
		scoped = scoped or wanted[command.scope] == true
	end
	local commands = qed.list.new{key = "name"}
	for _, command in ipairs(all) do
		local listed = scoped and wanted[command.scope] or (not scoped and command.scope == "global")
		if listed and command.available and command.owner ~= "palette" and command.name ~= "Command Palette" then
			commands:append{name = command.name, shortcut = command.shortcut, scope = command.scope}
		end
	end
	local matches = qed.fuzzy.list(commands, {field = "name"})
	local query = qed.buf.create{internal = true}
	local empty = false
	local handle = ui.mount("pane", build(matches, query, empty))
	query:on("change", function()
		matches:set_query(query:text())
		if (matches:count() == 0) ~= empty then
			empty = not empty
			handle:update(build(matches, query, empty))
		end
		highlight_first(matches)
	end)
	palette = {commands = commands, matches = matches, query = query, handle = handle}
	ui.node("palette_query"):focus()
	highlight_first(matches)
end

return {
	setup = function()
		qed.meta{display_name = "Palette", description = "Command palette on qed.ui"}
		qed.command{name = "Open", bind_from = "Command Palette", run = open_palette}
		qed.command{name = "Run", scope = "palette", key = "Enter", run = run_highlighted}
		qed.command{name = "Close", scope = "palette", key = "Esc", run = close_palette}
	end,
}

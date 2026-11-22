local ui = qed.ui

local palette

local function name_spans(record)
	local matched = {}
	for _, offset in ipairs(record.positions or {}) do
		matched[offset] = true
	end
	local spans = {}
	local plain = ""
	for offset = 1, #record.name do
		local character = record.name:sub(offset, offset)
		if matched[offset] then
			if plain ~= "" then
				spans[#spans + 1] = plain
				plain = ""
			end
			spans[#spans + 1] = {fg = "pane_prompt_foreground", bold = true, character}
		else
			plain = plain .. character
		end
	end
	if plain ~= "" then
		spans[#spans + 1] = plain
	end
	return spans
end

local function command_row(record)
	return ui.row{
		ui.text{grow = 1, " ", table.unpack(name_spans(record))},
		ui.text{fg = "pane_shortcut_foreground", record.shortcut, " "},
	}
end

local function close_palette()
	if not palette then
		return
	end
	local closing = palette
	palette = nil
	closing.subscription:remove()
	closing.handle:unmount()
	closing.query:close()
end

local function highlighted_key()
	local state = ui.node("palette_results"):state()
	return state and state.highlighted
end

local function move_highlight(step)
	if not palette then
		return
	end
	local matches = palette.matches
	local count = matches:count()
	if count == 0 then
		return
	end
	local index = matches:index_of(highlighted_key() or "") or 0
	index = math.max(1, math.min(count, index + step))
	ui.node("palette_results"):set_state{highlighted = matches:at(index).name}
end

local function run_highlighted()
	if not palette then
		return
	end
	local name = highlighted_key()
	if not name or not palette.matches:get(name) then
		return
	end
	close_palette()
	qed.run(name)
end

local function build(matches, query)
	local count = matches:count()
	return ui.column{float = "screen", width = "100%", height = "100%",
		on = {click = function()
			close_palette()
			return true
		end},
		ui.box{id = "palette", float = "screen", anchor = "top", width = 64, height = "fit", margin = {3, 2, 2, 2},
			border = true, title = "Command Palette", bg = "pane_background", fg = "pane_foreground",
			on = {click = function() return true end},
			ui.column{
				ui.row{
					ui.text{fg = "pane_prompt_foreground", "> "},
					ui.editor{id = "palette_query", buffer = query, height = 1, grow = 1,
						scope = {"palette", "editor"}, placeholder = "Type a command"},
				},
				count == 0 and ui.text{fg = "pane_dim_foreground", " No matching commands"} or false,
				ui.scroll{height = {"fit", max = 12},
					ui.virtual_column{id = "palette_results", data = matches, item = command_row,
						highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}},
			},
		},
	}
end

local function open_palette()
	if palette then
		close_palette()
		return
	end
	local commands = qed.list.new{key = "name"}
	for _, command in ipairs(qed.commands()) do
		if command.scope == "global" and command.name ~= "Palette: Open" then
			commands:append{name = command.name, shortcut = command.shortcut}
		end
	end
	local matches = qed.fuzzy.list(commands, {field = "name"})
	local query = qed.buf.create{internal = true}
	palette = {commands = commands, matches = matches, query = query}
	palette.handle = ui.mount("pane", build(matches, query))
	ui.node("palette_query"):focus()
	if matches:count() > 0 then
		ui.node("palette_results"):set_state{highlighted = matches:at(1).name}
	end
	palette.subscription = query:on("change", function()
		if not palette then
			return
		end
		matches:set_query(query:text())
		palette.handle:update(build(matches, query))
		local first = matches:at(1)
		ui.node("palette_results"):set_state{highlighted = first and first.name or false}
	end)
end

return {
	setup = function()
		qed.meta{display_name = "Palette", description = "Command palette on qed.ui"}
		qed.command{name = "Open", bind_from = "Command Palette", run = open_palette}
		qed.command{name = "Next", scope = "palette", key = "Down", run = function() move_highlight(1) end}
		qed.command{name = "Previous", scope = "palette", key = "Up", run = function() move_highlight(-1) end}
		qed.command{name = "Run", scope = "palette", key = "Enter", run = run_highlighted}
		qed.command{name = "Close", scope = "palette", key = "Esc", run = close_palette}
	end,
}

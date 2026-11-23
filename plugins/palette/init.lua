local ui = qed.ui

local palette
local options

local function name_spans(record, positions)
	local matched = {}
	for _, offset in ipairs(positions or {}) do
		matched[offset] = true
	end
	local spans = {}
	local plain = {}
	local name = record.name
	for position, code in utf8.codes(name) do
		local character = utf8.char(code)
		local hit = false
		for offset = position, position + #character - 1 do
			hit = hit or matched[offset]
		end
		if hit then
			if #plain > 0 then
				spans[#spans + 1] = table.concat(plain)
				plain = {}
			end
			spans[#spans + 1] = {fg = "pane_prompt_foreground", bold = true, character}
		else
			plain[#plain + 1] = character
		end
	end
	if #plain > 0 then
		spans[#spans + 1] = table.concat(plain)
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

local function run_command(name)
	if not palette or not name then
		return
	end
	close_palette()
	qed.run(name)
end

local function run_highlighted()
	run_command(highlighted_key())
end

local function command_row(record)
	return ui.row{
		on = {
			click = function()
				ui.node("palette_results"):set_state{highlighted = record.name}
				return true
			end,
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
		ui.box{id = "palette", float = "screen", anchor = "top", width = options.width, height = "fit",
			margin = {top = 3, right = 2, bottom = 2, left = 2},
			border = true, title = "Command Palette", bg = "pane_background", fg = "pane_foreground",
			ui.column{
				ui.row{
					ui.text{fg = "pane_prompt_foreground", "> "},
					ui.editor{id = "palette_query", buffer = query, height = 1, grow = 1,
						scope = {"palette", "editor"}, placeholder = "Type a command"},
				},
				empty and ui.text{fg = "pane_dim_foreground", " No matching commands"} or false,
				ui.scroll{height = {"fit", max = qed.opt("palette_max_rows")},
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
	local commands = qed.list.new{key = "name"}
	for _, command in ipairs(qed.commands()) do
		if command.scope == "global" and command.owner ~= "palette" and command.name ~= "Command Palette" then
			commands:append{name = command.name, shortcut = command.shortcut}
		end
	end
	local matches = qed.fuzzy.list(commands, {field = "name"})
	local query = qed.buf.create{internal = true}
	local empty = false
	options = qed.config()
	local handle = ui.mount("pane", build(matches, query, empty))
	query:on("change", function()
		local text = query:text()
		if text:find("\n") then
			query:set_text((text:gsub("\r?\n", " ")))
			return
		end
		matches:set_query(text)
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
		options = qed.options({width = 64}, {width = "Width of the palette box in cells"})
		qed.command{name = "Open", bind_from = "Command Palette", run = open_palette}
		qed.command{name = "Next", scope = "palette", key = "Down", run = function() move_highlight(1) end}
		qed.command{name = "Previous", scope = "palette", key = "Up", run = function() move_highlight(-1) end}
		qed.command{name = "Run", scope = "palette", key = "Enter", run = run_highlighted}
		qed.command{name = "Close", scope = "palette", key = "Esc", run = close_palette}
	end,
}

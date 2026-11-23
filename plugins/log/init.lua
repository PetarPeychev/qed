local ui = qed.ui

local LEVEL_COLORS = {debug = "pane_shortcut_foreground", info = "pane_foreground", warn = "warn_foreground", error = "error_foreground"}
local CHIPS = {
	{key = "debug", label = "debug", command = "Toggle Debug"},
	{key = "info", label = "info", command = "Toggle Info"},
	{key = "warn", label = "warn", command = "Toggle Warn"},
	{key = "error", label = "error", command = "Toggle Error"},
	{key = "history", label = "history", command = "Toggle History"},
}

local filters = {debug = false, info = true, warn = true, error = true, history = false}
local view
local close_all, toggle

local function first_line(text)
	return (text:match("^[^\n]*"))
end

local function message_row(record)
	local style = {fg = LEVEL_COLORS[record.level]}
	return ui.row{
		ui.text{width = 9, fg = "pane_dim_foreground", record.time},
		ui.text{width = 12, fg = style.fg, record.source},
		ui.text{grow = 1, fg = style.fg, first_line(record.text)},
	}
end

local function shortcut(name)
	for _, command in ipairs(qed.commands()) do
		if command.name == "Message Log: " .. name then
			return command.shortcut
		end
	end
	return ""
end

local function chip_row()
	local chips = {ui.text{grow = 1, fg = "pane_dim_foreground", " ↑↓ select  Shift+↑↓ extend  Enter full text  ", shortcut("Copy"), " copy"}}
	for _, chip in ipairs(CHIPS) do
		local on = filters[chip.key]
		chips[#chips + 1] = ui.text{
			on = {click = function() toggle(chip.key) return true end},
			" ", {fg = "pane_shortcut_foreground", shortcut(chip.command)}, " ",
			{fg = on and "pane_prompt_foreground" or "pane_dim_foreground", bold = on, chip.label}}
	end
	chips[#chips + 1] = ui.text{" "}
	return ui.row{height = 1, table.unpack(chips)}
end

local function build()
	local title = view.source and ("Message Log  ·  " .. view.source) or "Message Log"
	return ui.dismissable{on_dismiss = function() close_all() end,
		ui.box{float = "screen", anchor = "center", width = {"100%", max = qed.opt("pane_max_width")}, height = "100%",
			margin = {x = 2, y = 1}, border = true, title = title, bg = "pane_background", fg = "pane_foreground",
			ui.column{
				ui.scroll{id = "log_scroll", grow = 1, follow = true,
					header = ui.row{bold = true, ui.text{width = 9, "Time"}, ui.text{width = 12, "Source"}, ui.text{grow = 1, "Message"}},
					ui.virtual_column{id = "log_rows", scope = {"log", "list", "list_range"}, data = view.messages, item = message_row,
						highlight_style = {bg = "pane_selection_background"}}},
				chip_row(),
			},
		},
		view.detail and ui.box{id = "log_detail", float = "screen", anchor = "center",
			width = {"100%", max = qed.opt("pane_max_width")}, height = "100%", margin = {x = 2, y = 1}, border = true,
			title = "Message Log", bg = "pane_background", fg = "pane_foreground", scope = "log_detail",
			ui.scroll{id = "log_detail_scroll", ui.text{wrap = true, table.unpack(view.detail)}}} or false,
	}
end

local function highlighted()
	local state = ui.node("log_rows"):state()
	return state and state.highlighted
end

local function selected_range()
	local messages = view.messages
	local state = ui.node("log_rows"):state()
	local cursor = state and state.highlighted and messages:index_of(state.highlighted)
	if not cursor then
		return nil
	end
	local from = state.extend_from and messages:index_of(state.extend_from) or cursor
	return math.min(from, cursor), math.max(from, cursor)
end

local function messages_of(source)
	return qed.messages{levels = {debug = filters.debug, info = filters.info, warn = filters.warn, error = filters.error},
		history = filters.history, source = source}
end

local function show_end()
	local last = view.messages:at(view.messages:count())
	ui.node("log_rows"):set_state{highlighted = last and last.seq or false}
end

local function reload()
	view.messages = messages_of(view.source)
	ui.node("log_rows"):set_state{extend_from = false}
	view.handle:update(build())
	show_end()
end

local function open_log(source)
	if view then
		if view.source == source then
			view.handle:unmount()
			view = nil
			return
		end
		view.handle:unmount()
	end
	view = {source = source, messages = messages_of(source)}
	view.handle = ui.mount("pane", build())
	show_end()
	ui.node("log_rows"):focus()
end

local function close_log()
	if view and view.detail then
		view.detail = nil
		view.handle:update(build())
		ui.node("log_rows"):focus()
		return
	end
	if view then
		view.handle:unmount()
		view = nil
	end
end

close_all = function()
	if view then
		view.handle:unmount()
		view = nil
	end
end

local function selected_records()
	local low, high = selected_range()
	local records = {}
	for index = low or 1, high or 0 do
		records[#records + 1] = view.messages:at(index)
	end
	return records
end

local function copy()
	if not view then
		return
	end
	local records = selected_records()
	if #records == 0 then
		return
	end
	local lines = {}
	for _, record in ipairs(records) do
		lines[#lines + 1] = record.source ~= "" and (record.source .. ": " .. record.text) or record.text
	end
	qed.clipboard.set(table.concat(lines, "\n"))
	qed.message(#records > 1 and ("Copied %d entries"):format(#records) or "Copied to clipboard")
end

local function show_full()
	if not view or view.detail then
		return
	end
	local spans = {}
	for index, record in ipairs(selected_records()) do
		if index > 1 then
			spans[#spans + 1] = "\n\n"
		end
		spans[#spans + 1] = {fg = LEVEL_COLORS[record.level], record.time .. (record.source ~= "" and ("  " .. record.source) or "")}
		spans[#spans + 1] = "\n" .. record.text
	end
	if #spans == 0 then
		return
	end
	view.detail = spans
	view.handle:update(build())
	ui.node("log_detail"):focus()
end

function toggle(key)
	filters[key] = not filters[key]
	if view then
		reload()
	end
end

return {
	setup = function()
		qed.meta{display_name = "Message Log", description = "The message log on qed.ui"}
		qed.command{name = "Open", key = "Alt+l", welcome = true, run = function() open_log(nil) end}
		qed.export{show = function(source) open_log(source) end}
		qed.command{name = "Copy", scope = "log", bind_from = "Copy", run = copy}
		qed.command{name = "Full Text", scope = "log", key = "Enter", run = show_full}
		qed.command{name = "Close", scope = "log", key = "Esc", run = close_log}
		qed.command{name = "Back", scope = "log_detail", key = "Esc", run = close_log}
		qed.command{name = "Toggle Debug", scope = "log", key = "d", run = function() toggle("debug") end}
		qed.command{name = "Toggle Info", scope = "log", key = "i", run = function() toggle("info") end}
		qed.command{name = "Toggle Warn", scope = "log", key = "w", run = function() toggle("warn") end}
		qed.command{name = "Toggle Error", scope = "log", key = "e", run = function() toggle("error") end}
		qed.command{name = "Toggle History", scope = "log", key = "h", run = function() toggle("history") end}
	end,
}

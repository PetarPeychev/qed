local ui = qed.ui

local LEVEL_COLORS = {debug = "pane_shortcut_foreground", info = "pane_foreground", warn = "warn_foreground", error = "error_foreground"}
local CHIPS = {
	{key = "debug", label = "debug", cmd = "Message Log: Toggle Debug"},
	{key = "info", label = "info", cmd = "Message Log: Toggle Info"},
	{key = "warn", label = "warn", cmd = "Message Log: Toggle Warn"},
	{key = "error", label = "error", cmd = "Message Log: Toggle Error"},
	{key = "history", label = "history", cmd = "Message Log: Toggle History"},
}
local HINTS = {{label = "↑↓ select"}, {label = "Shift+↑↓ extend"}, {label = "Enter full text"}, {label = "copy", cmd = "Message Log: Copy"}}
local DETAIL_HINTS = {{label = "↑↓ scroll"}, {label = "Esc back"}}
local TIME_WIDTH, SOURCE_WIDTH = 11, 12

local filters = {debug = false, info = true, warn = true, error = true, history = false}
local view
local close_all, toggle

local function first_line(text)
	return (text:match("^[^\n]*"))
end

local function message_row(record)
	local style = {fg = LEVEL_COLORS[record.level]}
	return ui.row{
		ui.text{width = TIME_WIDTH, " ", record.time},
		ui.text{width = SOURCE_WIDTH, fg = style.fg, record.source},
		ui.text{grow = 1, fg = style.fg, first_line(record.text)},
	}
end

local function chip_row()
	local chips = {}
	for index, chip in ipairs(CHIPS) do
		chips[index] = {label = chip.label, cmd = chip.cmd, on = filters[chip.key],
			on_click = function() toggle(chip.key) return true end}
	end
	return ui.footer{hints = HINTS, chips = chips}
end

local function build()
	local title = view.source and ("Message Log  ·  " .. view.source) or "Message Log"
	return ui.dismissable{on_dismiss = function() close_all() end,
		ui.pane{place = "full", max_width = qed.opt("pane_max_width"), title = title,
			ui.row{bold = true, ui.text{width = TIME_WIDTH, " Time"}, ui.text{width = SOURCE_WIDTH, "Source"}, ui.text{grow = 1, "Message"}},
			ui.scroll{id = "log_scroll", grow = 1, follow = true,
				ui.virtual_column{id = "log_rows", scope = {"log", "list", "list_range"}, data = view.messages, item = message_row,
					highlight_style = {bg = "pane_selection_background"}}},
			chip_row(),
		},
		view.detail and ui.pane{id = "log_detail", place = "full", max_width = qed.opt("pane_max_width"), scope = "log_detail",
			title = "Message Log",
			ui.scroll{id = "log_detail_scroll", grow = 1, ui.text{wrap = true, margin = {left = 1, right = 1}, table.unpack(view.detail)}},
			ui.footer{hints = DETAIL_HINTS},
		} or false,
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
		qed.command{id = "open", name = "Open", key = "Alt+l", welcome = true, run = function() open_log(nil) end}
		qed.export{show = function(source) open_log(source) end}
		qed.command{id = "copy", name = "Copy", scope = "log", bind_from = "copy", run = copy}
		qed.command{id = "full_text", name = "Full Text", scope = "log", key = "Enter", run = show_full}
		qed.command{id = "close", name = "Close", scope = "log", key = "Esc", run = close_log}
		qed.command{id = "back", name = "Back", scope = "log_detail", key = "Esc", run = close_log}
		qed.command{id = "toggle_debug", name = "Toggle Debug", scope = "log", key = "d", run = function() toggle("debug") end}
		qed.command{id = "toggle_info", name = "Toggle Info", scope = "log", key = "i", run = function() toggle("info") end}
		qed.command{id = "toggle_warn", name = "Toggle Warn", scope = "log", key = "w", run = function() toggle("warn") end}
		qed.command{id = "toggle_error", name = "Toggle Error", scope = "log", key = "e", run = function() toggle("error") end}
		qed.command{id = "toggle_history", name = "Toggle History", scope = "log", key = "h", run = function() toggle("history") end}
	end,
}

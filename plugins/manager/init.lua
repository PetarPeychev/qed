local ui = qed.ui

local STATUS_COLORS = {disabled = "pane_shortcut_foreground", errored = "error_foreground"}

local view

local function record_of(plugin)
	return {
		id = plugin.id,
		display = plugin.display,
		description = plugin.description,
		source = plugin.bundled and "bundled" or "user",
		status = plugin.state,
		load = plugin.state ~= "disabled" and ("%.2f ms"):format(plugin.load_ms) or "",
		error = plugin.error,
		bundled = plugin.bundled,
		main = plugin.main,
		fork = plugin.fork,
	}
end

local function highlighted()
	local state = ui.node("plugin_rows"):state()
	local key = state and state.highlighted
	return key and view.records:get(key) or nil
end

local function width_of(field, title)
	local width = #title
	for index = 1, view.records:count() do
		width = math.max(width, utf8.len(view.records:at(index)[field]) or 0)
	end
	return width
end

local function close()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.handle:unmount()
	if closing.source_buffer then
		closing.source_buffer:close()
	end
end

local function shortcut(name)
	for _, command in ipairs(qed.commands()) do
		if command.name == "Plugin Manager: " .. name then
			return command.shortcut
		end
	end
	return ""
end

local open_source

local function plugin_row(record)
	local fg = STATUS_COLORS[record.status]
	return ui.row{fg = fg,
		on = {
			double_click = function()
				open_source()
				return true
			end,
		},
		ui.text{width = view.widths.display + 1, " ", record.display},
		ui.text{grow = 1, " ", record.description},
		ui.text{width = view.widths.source + 1, " ", record.source},
		ui.text{width = view.widths.status + 1, " ", record.status},
		ui.text{width = view.widths.load + 2, align = "right", record.load, " "},
	}
end

local function home_short(path)
	local home = os.getenv("HOME")
	if home and home ~= "" and path:sub(1, #home) == home then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

local function source_box()
	local record = view.source
	return ui.box{float = "screen", anchor = "center", width = {"100%", max = qed.opt("pane_max_width")}, height = "100%",
		margin = {x = 2, y = 1}, border = true, title = "plugins/" .. record.main .. "  ·  bundled, read-only",
		bg = "pane_background", fg = "pane_foreground",
		ui.column{
			ui.editor{id = "plugin_source", buffer = view.source_buffer, grow = 1, readonly = true, syntax = true,
				scope = {"plugin_source", "editor"}},
			ui.text{height = 1, fg = "pane_dim_foreground", " Esc back  ·  fork: copy to " .. home_short(record.fork)},
		},
	}
end

local function build()
	local selected = highlighted()
	local footer = selected and selected.error ~= "" and selected.error:gsub("\n", " ") or
		(" ↑↓ select  Enter open  " .. shortcut("Enable/Disable") .. " enable/disable  " .. shortcut("Reload") ..
		" reload  " .. shortcut("Show Log") .. " log  Esc close")
	return ui.dismissable{on_dismiss = close,
		ui.box{float = "screen", anchor = "center", width = {"100%", max = qed.opt("pane_max_width")}, height = "100%",
			margin = {x = 2, y = 1}, border = true, title = "Plugins", bg = "pane_background", fg = "pane_foreground",
			ui.column{
				ui.scroll{id = "plugin_scroll", grow = 1,
					header = ui.row{bold = true,
						ui.text{width = view.widths.display + 1, " Name"},
						ui.text{grow = 1, " Description"},
						ui.text{width = view.widths.source + 1, " Source"},
						ui.text{width = view.widths.status + 1, " Status"},
						ui.text{width = view.widths.load + 2, align = "right", "Load "}},
					ui.virtual_column{id = "plugin_rows", scope = {"plugins", "list"}, data = view.records, item = plugin_row,
						on = {state = function() view.handle:update(view.build()) end},
						highlight_style = {bg = "pane_selection_background"}}},
				ui.text{height = 1, fg = selected and selected.error ~= "" and "error_foreground" or "pane_dim_foreground", footer},
			},
		},
		view.source and source_box() or false,
	}
end

local function refresh()
	if not view then
		return
	end
	local keep = highlighted()
	view.records:clear()
	for _, plugin in ipairs(qed.plugins()) do
		view.records:append(record_of(plugin))
	end
	view.widths = {display = width_of("display", "Name"), source = width_of("source", "Source"),
		status = width_of("status", "Status"), load = width_of("load", "Load")}
	local key = keep and view.records:get(keep.id) and keep.id or (view.records:at(1) or {}).id or false
	ui.node("plugin_rows"):set_state{highlighted = key}
	view.handle:update(build())
end

local function open()
	if view then
		close()
		return
	end
	view = {records = qed.list.new{key = "id"}, widths = {display = 4, source = 6, status = 6, load = 4}, build = build}
	view.handle = ui.mount("pane", build())
	refresh()
	ui.node("plugin_rows"):focus()
end

local function toggle_enabled()
	local selected = view and highlighted()
	if not selected then
		return
	end
	local ok, err = qed.plugin_enable(selected.id, selected.status == "disabled")
	if not ok then
		qed.message(err, "error")
	end
end

local function reload()
	local selected = view and highlighted()
	if not selected then
		return
	end
	local ok, err = qed.plugin_reload(selected.id)
	if err == "disabled" then
		local key = shortcut("Enable/Disable")
		qed.message(("%s is disabled (%s enables it)"):format(selected.display, key ~= "" and key or "Enable/Disable"), "warn")
	elseif not ok then
		qed.message(err, "error")
	end
end

local function show_log()
	local selected = view and highlighted()
	local log = selected and qed.plugin("log")
	if not log then
		return
	end
	close()
	log.show(selected.display)
end

function open_source()
	local selected = view and highlighted()
	if not selected then
		return
	end
	if not selected.bundled then
		close()
		qed.open(selected.main)
		return
	end
	local text = qed.plugin_source(selected.id)
	if not text then
		return
	end
	view.source_buffer = qed.buf.create{internal = true}
	view.source_buffer:set_text(text)
	view.source_buffer:set_language("lua")
	view.source_buffer:set_cursor({row = 1, col = 1})
	for _, plugin in ipairs(qed.plugins()) do
		if plugin.id == selected.id then
			selected = record_of(plugin)
		end
	end
	view.source = selected
	view.handle:update(build())
	ui.node("plugin_source"):focus()
end

local function back()
	if view and view.source then
		view.source = nil
		view.source_buffer:close()
		view.source_buffer = nil
		view.handle:update(build())
		ui.node("plugin_rows"):focus()
	end
end

return {
	setup = function()
		qed.meta{display_name = "Plugin Manager", description = "Lists plugins: enable, disable, reload, source and log"}
		qed.command{name = "Open", welcome = true, run = open}
		qed.command{name = "Enable/Disable", scope = "plugins", key = "e", run = toggle_enabled}
		qed.command{name = "Reload", scope = "plugins", key = "r", run = reload}
		qed.command{name = "Show Log", scope = "plugins", key = "l", run = show_log}
		qed.command{name = "Source", scope = "plugins", key = "Enter", run = open_source}
		qed.command{name = "Close", scope = "plugins", key = "Esc", run = close}
		qed.command{name = "Back", scope = "plugin_source", key = "Esc", run = back}
		for _, event in ipairs({"plugin_loaded", "plugin_unloaded", "config_changed"}) do
			qed:on(event, refresh)
		end
	end,
}

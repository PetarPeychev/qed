local ui = qed.ui

local screen
local message_text = ""
local message_level = "info"

local MESSAGE_COLORS = {info = "foreground", warn = "warn_foreground", error = "error_foreground"}

local function current_buffer()
	if #qed.buf.list() == 0 then
		return nil
	end
	return qed.buf.get(qed.buf.current())
end

local function status_row(buffer)
	local path = buffer:path()
	local shown = path ~= "" and qed.path.rel(path, qed.root()) or "[untitled]"
	local position = buffer:cursor()
	return ui.row{id = "status", height = 1, bg = "pane_background", fg = "pane_foreground",
		ui.text{grow = 1, " ", shown, {fg = "warn_foreground", buffer:modified() and " ●" or ""}},
		ui.outlet{id = "status_right"},
		ui.text{" ", tostring(position.row), ":", tostring(position.col), " "},
		ui.text{drop = 1, fg = "pane_dim_foreground", buffer:language(), " "},
	}
end

local function build(buffer)
	return ui.column{
		ui.editor{id = "main_editor", buffer = buffer, scope = "editor", line_numbers = true, highlight = true,
			current_line_style = {bg = "current_line_background"}},
		status_row(buffer),
		ui.text{id = "message", height = 1, fg = MESSAGE_COLORS[message_level] or "foreground", message_text},
	}
end

local function refresh()
	local buffer = current_buffer()
	if not buffer then
		if screen then
			screen:unmount()
			screen = nil
		end
		return
	end
	if screen then
		screen:update(build(buffer))
		return
	end
	screen = ui.mount("base", build(buffer))
	ui.node("main_editor"):focus()
end

return {
	setup = function()
		qed.meta{display_name = "Layout", description = "The main screen: editor, status bar, message line"}
		qed.on("startup", refresh)
		qed.on("buf_enter", refresh)
		qed.on("buf_open", refresh)
		qed.on("buf_close", refresh)
		qed.on("buf_changed", refresh)
		qed.on("cursor_moved", refresh)
		qed.on("buf_save", refresh)
		qed.on("language_changed", refresh)
		qed.on("message", function(text, level)
			message_text, message_level = text, level
			refresh()
		end)
		refresh()
	end,
}

local ui = qed.ui

local screen
local welcome

local WELCOME_ART = {
	"  .g8\"\"8q. `7MM\"\"YMMM`7MM\"\"\"Yb.   ",
	".dP'    `YM. MM    `7  MM    `Yb. ",
	"dM'      `MM MM   d    MM     `Mb ",
	"MM        MM MMmmMM    MM      MM ",
	"MM.      ,MP MM   Y ,  MM     ,MP ",
	"`Mb.    ,dP' MM    ,M  MM    ,dP' ",
	"  `\"bmmd\"' .JMMmmmMMM.JMMmmmdP'   ",
	"      MMb                          ",
	"       `bmmd'                      ",
}

local WELCOME_HINTS = {
	{command = "File Tree: All", label = "File tree"},
	{command = "Command Palette", label = "Command palette"},
	{command = "Quit", label = "Quit"},
}
local message_text = ""
local message_level = "info"

local MESSAGE_COLORS = {info = "foreground", warn = "warn_foreground", error = "error_foreground"}

local function current_buffer()
	if #qed.buf.list() == 0 then
		return nil
	end
	return qed.buf.current()
end

local function status_row(buffer)
	local path = buffer:path()
	local shown = path ~= "" and qed.path.rel(path, qed.root()) or "[untitled]"
	local position = buffer:cursor()
	return ui.row{id = "status", height = 1, bg = "pane_background", fg = "pane_foreground",
		ui.text{fg = "warn_foreground", buffer:modified() and " ●" or ""},
		ui.text{grow = 1, " ", shown},
		ui.outlet{id = "status_right"},
		ui.text{" ", tostring(position.row), ":", tostring(position.col), " "},
		ui.text{drop = 1, fg = "pane_dim_foreground", buffer:language(), " "},
	}
end

local function build(buffer)
	return ui.column{
		ui.editor{id = "main_editor", buffer = buffer, scope = "editor", line_numbers = true, syntax = true},
		status_row(buffer),
		ui.text{id = "message", height = 1, fg = MESSAGE_COLORS[message_level] or "foreground", message_text},
	}
end

local function welcome_tree()
	local shortcuts = {}
	for _, command in ipairs(qed.commands()) do
		shortcuts[command.name] = command.shortcut
	end
	local art = {}
	for _, line in ipairs(WELCOME_ART) do
		art[#art + 1] = ui.text{line}
	end
	local hints = {}
	for _, hint in ipairs(WELCOME_HINTS) do
		if shortcuts[hint.command] then
			hints[#hints + 1] = ui.text{("%-9s %s"):format(shortcuts[hint.command], hint.label)}
		end
	end
	local root = qed.path.rel(qed.root(), qed.path.dir(qed.root())) or qed.root()
	return ui.column{
		ui.column{grow = 1, align = "center",
			ui.text{grow = 1, ""},
			ui.column{width = "fit", table.unpack(art)},
			ui.text{""},
			ui.column{width = "fit", table.unpack(hints)},
			ui.text{grow = 1, ""},
		},
		ui.row{height = 1, bg = "pane_background", fg = "pane_foreground",
			ui.text{grow = 1, " ", root},
			ui.text{"qed ", qed.version, " "},
		},
		ui.text{id = "welcome_message", height = 1, fg = MESSAGE_COLORS[message_level] or "foreground", message_text},
	}
end

local function refresh()
	local buffer = current_buffer()
	if not buffer then
		if screen then
			screen:unmount()
			screen = nil
		end
		if welcome then
			welcome:update(welcome_tree())
		else
			welcome = ui.mount("background", welcome_tree())
		end
		return
	end
	if welcome then
		welcome:unmount()
		welcome = nil
	end
	if screen then
		screen:update(build(buffer))
		return
	end
	screen = ui.mount("base", build(buffer))
	ui.node("main_editor"):focus()
end

local refresh_due = false

local function refresh_soon()
	if refresh_due then
		return
	end
	refresh_due = true
	qed.defer(0, function()
		refresh_due = false
		refresh()
	end)
end

return {
	setup = function()
		qed.meta{display_name = "Layout", description = "The main screen: editor, status bar, message line"}
		qed:on("buf_enter", refresh_soon)
		qed:on("buf_open", refresh_soon)
		qed:on("buf_close", refresh_soon)
		qed:on("buf_changed", refresh_soon)
		qed:on("cursor_moved", refresh_soon)
		qed:on("buf_save", refresh_soon)
		qed:on("language_changed", refresh_soon)
		qed:on("root_changed", refresh_soon)
		qed:on("config_changed", refresh_soon)
		qed:on("message", function(text, level)
			message_text, message_level = text, level
			refresh_soon()
		end)
		refresh()
	end,
}

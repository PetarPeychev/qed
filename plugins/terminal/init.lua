local ui = qed.ui

local view
local options

local function hide()
	if view then
		view.handle:unmount()
		view = nil
	end
end

local function title_of(session)
	if session == "shell" then
		return nil
	end
	local state = qed.term.state(session)
	if state and state.code and not state.running then
		return ("%s (exited %d)"):format(session, state.code)
	end
	return session
end

local function build(session)
	local state = qed.term.state(session)
	local on
	if not (state and state.running) then
		on = {key = function() hide() return true end}
	end
	return ui.column{float = "screen", width = "100%", height = "100%",
		on = {click = function()
			hide()
			return true
		end},
		ui.box{float = "screen", anchor = "center", width = "100%", height = "100%", margin = {x = 8, y = 3},
			border = true, title = title_of(session), bg = "pane_background", fg = "pane_foreground",
			on = {click = function() return true end},
			ui.terminal{id = "terminal", session = session, grow = 1, scope = "terminal", on = on},
		},
	}
end

local function show(session)
	if view then
		view.session = session
		view.handle:update(build(session))
	else
		view = {session = session}
		view.handle = ui.mount("pane", build(session))
	end
	ui.node("terminal"):focus()
end

local function show_session(session)
	if session == "shell" then
		local ok, err = qed.term.shell()
		if not ok then
			return nil, err
		end
	elseif not qed.term.state(session) then
		return nil, "no such session"
	end
	show(session)
	return true
end

local function close()
	if view and not options.escape_closes then
		qed.term.send(view.session, "\27")
		return
	end
	hide()
end

local function toggle()
	if view then
		hide()
	else
		show_session("shell")
	end
end

return {
	setup = function()
		qed.meta{description = "Terminal pane for qed.term sessions"}
		options = qed.options({escape_closes = true}, {escape_closes = "Esc at a shell prompt closes the terminal pane (a full-screen program always gets Esc)"})
		qed:on("config_changed", function() options = qed.config() end)
		qed.command{name = "Toggle", key = "Alt+t", welcome = true, run = toggle}
		qed.command{name = "Hide", scope = "terminal", keybind = "Toggle", run = hide}
		qed.command{name = "Close", scope = "terminal", key = "Esc", run = close}
		qed.export{show = show_session, hide = hide}
		qed:on("term_exit", function(session)
			if view and view.session == session then
				view.handle:update(build(session))
			end
		end)
		qed:on("term_close", function(session)
			if view and view.session == session then
				hide()
			end
		end)
	end,
}

local ui = qed.ui

local finder
local options

local function selection_query(ctx)
	local text = ctx.selection_text
	if text and not text:find("\n") and text:find("[^ \t]") then
		return text
	end
end

local function flag_text(label, on)
	return {fg = on and "pane_prompt_foreground" or "pane_dim_foreground", bold = on, label}
end

local function status_text()
	if finder.invalid then
		return "invalid"
	end
	if finder.count == 0 then
		return finder.query:text() == "" and "" or "no matches"
	end
	return ("%d/%d"):format(finder.index, finder.count)
end

local function build()
	local rows = {
		ui.row{
			ui.text{fg = "pane_prompt_foreground", "Find "},
			ui.editor{id = "find_query", buffer = finder.query, height = 1, grow = 1, scope = {"find", "editor"}},
			ui.text{" ", flag_text(".*", finder.regex), " ", flag_text("Aa", finder.case_sensitive), " "},
			ui.text{fg = "pane_dim_foreground", width = 11, align = "right", status_text(), " "},
		},
	}
	if finder.replacing then
		rows[2] = ui.row{
			ui.text{fg = "pane_prompt_foreground", "Repl "},
			ui.editor{id = "find_replacement", buffer = finder.replacement, height = 1, grow = 1,
				scope = {"find_replace", "find", "editor"}},
		}
	end
	return ui.box{float = "screen", anchor = "top_right", width = options.width, height = "fit",
		margin = {top = 1, right = 2}, border = true, bg = "pane_background", fg = "pane_foreground",
		on = {click = function() return true end},
		ui.column{table.unpack(rows)}}
end

local function refresh()
	if not finder then
		return
	end
	local index, count = finder.target:find(finder.query:text(), {regex = finder.regex, case_sensitive = finder.case_sensitive})
	finder.invalid = index == nil
	finder.index, finder.count = index or 0, count or 0
	finder.handle:update(build())
end

local function close_finder()
	if not finder then
		return
	end
	local closing = finder
	finder = nil
	if closing.target:valid() then
		closing.target:find_clear()
	end
	closing.handle:unmount()
	closing.query:close()
	closing.replacement:close()
end

local function open_finder(ctx, replacing)
	if finder then
		finder.replacing = replacing or finder.replacing
		finder.handle:update(build())
		ui.node(replacing and "find_replacement" or "find_query"):focus()
		return
	end
	if not ctx.buf then
		return
	end
	options = qed.config()
	local query = qed.buf.create{internal = true}
	local replacement = qed.buf.create{internal = true}
	local initial = selection_query(ctx)
	if initial then
		query:set_text(initial)
		query:set_selection({row = 1, col = 1}, {row = 1, col = #initial + 1})
	end
	finder = {target = ctx.buf, query = query, replacement = replacement, replacing = replacing,
		regex = false, case_sensitive = false, index = 0, count = 0}
	finder.handle = ui.mount("popup", build())
	query:on("change", refresh)
	ui.node("find_query"):focus()
	refresh()
end

local function step(direction)
	if finder then
		finder.index, finder.count = finder.target:find_step(direction)
		finder.handle:update(build())
	end
end

local function toggle(flag)
	if finder then
		finder[flag] = not finder[flag]
		refresh()
	end
end

local function replace(all)
	if not finder then
		return
	end
	local count = finder.target:find_replace(finder.replacement:text(), {all = all})
	refresh()
	if all then
		qed.message(("Replaced %d match%s"):format(count, count == 1 and "" or "es"))
	end
end

return {
	setup = function()
		qed.meta{display_name = "Find", description = "Find and replace in the current buffer"}
		options = qed.options({width = 50}, {width = "Width of the find box in cells"})
		qed.command{name = "In Buffer", key = "Ctrl+f", run = function(ctx) open_finder(ctx, false) end}
		qed.command{name = "Replace", key = "Ctrl+h", run = function(ctx) open_finder(ctx, true) end}
		qed.command{name = "Next", scope = "find", key = "Enter", run = function() step(1) end}
		qed.command{name = "Next Match", scope = "find", key = "Down", run = function() step(1) end}
		qed.command{name = "Previous Match", scope = "find", key = "Up", run = function() step(-1) end}
		qed.command{name = "Close", scope = "find", key = "Esc", run = close_finder}
		qed.command{name = "Toggle Regex", scope = "find", key = "Alt+r", run = function() toggle("regex") end}
		qed.command{name = "Toggle Case", scope = "find", key = "Alt+c", run = function() toggle("case_sensitive") end}
		qed.command{name = "Replace All", scope = "find", key = "Alt+a", run = function() replace(true) end}
		qed.command{name = "Replace Match", scope = "find_replace", key = "Enter", run = function() replace(false) end}
		qed.command{name = "Switch Field", scope = "find", key = "Tab", run = function()
			if finder and finder.replacing then
				ui.node(finder.focus_replacement and "find_query" or "find_replacement"):focus()
				finder.focus_replacement = not finder.focus_replacement
			end
		end}
	end,
}

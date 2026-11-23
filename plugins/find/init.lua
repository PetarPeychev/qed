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
	return ("%d/%d%s"):format(finder.index, finder.count, finder.capped and "+" or "")
end

local function build()
	local rows = {
		ui.row{
			ui.text{fg = "pane_prompt_foreground", "Find "},
			ui.editor{id = "find_query", buffer = finder.query, height = 1, grow = 1, scope = {"find", "editor"}},
			ui.text{" ", flag_text(".*", finder.regex), " ", flag_text("Aa", finder.case_sensitive), " "},
			ui.text{fg = "pane_dim_foreground", width = 12, align = "right", status_text(), " "},
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

local function show(index, count, capped)
	finder.invalid = index == nil
	finder.index, finder.count, finder.capped = index or 0, finder.invalid and 0 or count, capped
	finder.handle:update(build())
end

local function search_options()
	return {regex = finder.regex, case_sensitive = finder.case_sensitive}
end

local function refresh()
	if not finder then
		return
	end
	local text = finder.query:text()
	if text:find("\n") then
		finder.query:set_text((text:gsub("\r?\n", " ")))
		return
	end
	show(finder.search:update(text, search_options()))
end

local function close_finder()
	if not finder then
		return
	end
	local closing = finder
	finder = nil
	closing.search:close()
	closing.handle:unmount()
	closing.query:close()
	closing.replacement:close()
end

local function select_query()
	local text = finder.query:text()
	if text ~= "" then
		finder.query:set_selection({row = 1, col = 1}, {row = 1, col = #text + 1})
	end
end

local function open_finder(ctx, replacing)
	if not ctx.buf then
		return
	end
	if finder and finder.target ~= ctx.buf then
		close_finder()
	end
	if finder then
		if replacing then
			finder.replacing = not finder.replacing
		end
		finder.handle:update(build())
		ui.node(replacing and finder.replacing and "find_replacement" or "find_query"):focus()
		select_query()
		return
	end
	options = qed.config()
	local query = qed.buf.create{internal = true}
	local replacement = qed.buf.create{internal = true}
	local initial = selection_query(ctx)
	if initial then
		query:set_text(initial)
	end
	finder = {target = ctx.buf, query = query, replacement = replacement, replacing = replacing,
		regex = false, case_sensitive = false, index = 0, count = 0}
	finder.search = ctx.buf:find(query:text(), search_options())
	finder.handle = ui.mount("popup", build())
	query:on("change", refresh)
	ui.node("find_query"):focus()
	select_query()
	show(finder.search:result())
end

local function step(direction)
	if finder then
		show(finder.search:step(direction))
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
	local count = finder.search:replace(finder.replacement:text(), {all = all})
	show(finder.search:result())
	if all then
		qed.message(("Replaced %d match%s"):format(count, count == 1 and "" or "es"))
	end
end

local function switch_field()
	if finder and finder.replacing then
		finder.on_replacement = not finder.on_replacement
		ui.node(finder.on_replacement and "find_replacement" or "find_query"):focus()
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
		qed.command{name = "Switch Field", scope = "find", key = "Tab", run = switch_field}
	end,
}

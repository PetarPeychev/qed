local ui = qed.ui

local SELECTED = {bg = "pane_selection_background", fg = "pane_selection_foreground"}

local view
local activate

local function selection_query(ctx)
	local selection = ctx.selection_text
	if selection and not selection:find("\n") and selection:find("[^ \t]") then
		return selection
	end
end

local function close()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.watch:off()
	closing.handle:unmount()
	closing.query:close()
	closing.preview:close()
end

local function highlighted()
	local state = ui.node("goto_rows"):state()
	local key = state and state.highlighted
	-- an edit can remove the highlighted row: the first match stands in
	return key and view.lines:get(key) or view.lines:at(1)
end

local function highlight(key)
	ui.node("goto_rows"):set_state{highlighted = key}
	local record = highlighted()
	if record then
		view.preview:set_cursor({row = math.min(record.row, view.preview:line_count()), col = 1})
	end
end

local function line_row(record)
	return ui.row{
		on = {
			click = function()
				highlight(record.key)
				return true
			end,
			double_click = function()
				highlight(record.key)
				activate()
				return true
			end,
		},
		ui.text{fg = "gutter_foreground", width = view.digits + 1, align = "right", tostring(record.row)},
		ui.text{grow = 1, " ", record.label},
	}
end

local function build()
	return ui.dismissable{on_dismiss = close,
		ui.box{id = "goto", float = "screen", anchor = "center", width = "100%", height = "100%", margin = {x = 2, y = 1},
			border = true, title = "Go to Line", bg = "pane_background", fg = "pane_foreground",
			ui.row{
				ui.column{width = {"40%", min = qed.opt("split_code_min_width"), max = qed.opt("split_code_max_width")},
					ui.row{height = 1,
						ui.text{fg = "pane_prompt_foreground", "> "},
						ui.editor{id = "goto_query", buffer = view.query, height = 1, grow = 1, scope = {"goto", "editor"},
							placeholder = "text, a line number, or :line:column"},
					},
					ui.scroll{grow = 1,
						ui.virtual_column{id = "goto_rows", data = view.lines, item = line_row, highlight_style = SELECTED}},
				},
				ui.editor{id = "goto_preview", buffer = view.preview, grow = 1, readonly = true, syntax = true, line_numbers = true},
			},
		},
	}
end

local function query_sync()
	local text = view.query:text()
	if text == view.applied then
		return
	end
	view.applied = text
	view.lines:set_query(text)
	local first = view.lines:at(1)
	highlight(first and first.key or false)
end

local function move(step)
	if not view then
		return
	end
	query_sync()
	local lines = view.lines
	local count = lines:count()
	if count == 0 then
		return
	end
	local record = highlighted()
	local index = record and lines:index_of(record.key) or 0
	highlight(lines:at(math.max(1, math.min(count, index + step))).key)
end

function activate()
	if not view then
		return
	end
	query_sync()
	local record = highlighted()
	local buffer = view.buffer
	close()
	if record and buffer:valid() then
		qed.jump(buffer, {row = record.row, col = record.col})
	end
end

local function find_line(ctx)
	if view then
		close()
		return
	end
	local buffer = ctx.buf
	if not buffer then
		return
	end
	local path = buffer:path()
	local preview = qed.buf.create{internal = true, from = path ~= "" and path or nil}
	if path == "" then
		preview:set_text(buffer:text())
	end
	local query = qed.buf.create{internal = true}
	view = {buffer = buffer, lines = buffer:line_list(), query = query, preview = preview, applied = "",
		digits = #tostring(buffer:line_count())}
	view.handle = ui.mount("pane", build())
	local current = view
	-- a reload or plugin edit of the buffer shows in the preview copy too
	view.watch = qed:on("buf_changed", function(changed)
		if view == current and changed == buffer then
			preview:set_text(buffer:text())
		end
	end)
	query:on("change", function()
		if view == current then
			query_sync()
		end
	end)
	ui.node("goto_query"):focus()
	local start = selection_query(ctx)
	if start then
		query:set_text(start)
		query:set_selection({row = 1, col = 1}, {row = 1, col = #start + 1})
		query_sync()
	else
		highlight(tostring(buffer:cursor().row))
	end
end

local function state()
	if not view then
		return nil
	end
	query_sync()
	local labels = {}
	for index = 1, view.lines:count() do
		labels[index] = view.lines:at(index).label
	end
	local record = highlighted()
	return {query = view.query:text(), labels = labels, matches = #labels, selected = record and record.label or nil}
end

return {
	setup = function()
		qed.meta{display_name = "Go to", description = "Fuzzy jump to a line"}
		qed.command{name = "Line", key = "Ctrl+g", run = find_line}
		qed.command{name = "Next", scope = "goto", key = "Down", run = function() move(1) end}
		qed.command{name = "Previous", scope = "goto", key = "Up", run = function() move(-1) end}
		qed.command{name = "Jump", scope = "goto", key = "Enter", run = activate}
		qed.command{name = "Close", scope = "goto", key = "Esc", run = close}
		qed.export{state = state}
	end,
}

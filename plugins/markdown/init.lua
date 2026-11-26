local ui = qed.ui

local MIN_WIDTH = 20

-- the overlay pane and the split beside the editor are separate views, each with its own nodes and history
local IDS = {overlay = {scroll = "markdown_scroll", body = "markdown_body"}, split = {scroll = "split_scroll", body = "split_body"}}

local views = {}
local histories = {overlay = {entries = {}, at = 0}, split = {entries = {}, at = 0}}
local follow
local split_on = false
local split_hooks = {}
local synced_top
local expected_enter

local function body(view)
	return ui.node(IDS[view.kind].body)
end

local function scroller(view)
	return ui.node(IDS[view.kind].scroll)
end

local function is_markdown(buffer)
	return buffer ~= nil and buffer:valid() and buffer:language() == "markdown"
end

local function current_buffer()
	if #qed.buf.list() == 0 then
		return nil
	end
	return qed.buf.current()
end

local function close(kind)
	local view = views[kind]
	if not view then
		return
	end
	views[kind] = nil
	view.watch:remove()
	view.handle:unmount()
end

-- the cursor moves to the source line now under its terminal row, unless that line is still the cursor's block
local function sync_back()
	local view = views.overlay
	if not view or view.buffer ~= qed.buf.current() then
		return
	end
	local state, rect = body(view):state(), scroller(view):rect()
	if not state or not rect or not state.sources or #state.sources == 0 then
		return
	end
	local buffer = view.buffer
	local cursor = buffer:cursor().row
	local index = math.max(1, math.min(#state.sources, (buffer:screen_row() or rect.y) - rect.y + 1))
	local src = math.min(state.sources[index], buffer:line_count())
	local same = src <= cursor
	for _, source in ipairs(state.sources) do
		same = same and not (source > src and source <= cursor)
	end
	if same then
		return
	end
	buffer:set_cursor({row = src, col = buffer:line(src):find("%S") or 1})
	buffer:set_screen_row(src, rect.y + index - 1)
end

-- the split's top source line goes to the editor's top row; the cursor stays
local function sync_editor()
	local view = views.split
	if not view or view.buffer ~= qed.buf.current() then
		return
	end
	local state, rect = body(view):state(), scroller(view):rect()
	if not (state and state.source and rect) then
		return
	end
	view.buffer:set_screen_row(state.source, rect.y)
	synced_top = view.buffer:top_row()
end

-- the editor's top line (a fraction for a wrapped sub-row) goes to the split's top, once per editor scroll
local function sync_preview(force)
	local view = views.split
	if not view or view.heading or view.buffer ~= qed.buf.current() then
		return
	end
	local top = view.buffer:top_row()
	if top and (force or top ~= synced_top) then
		body(view):set_state{source = top}
		synced_top = top
	end
end

local HINTS = {{label = "↑↓ PgUp PgDn scroll"}, {label = "click a link to open it"}, {label = "back", cmd = "Markdown: Back"},
	{label = "forward", cmd = "Markdown: Forward"}, {label = "close", cmd = "Markdown: Close"}}

local function document(view)
	local path = view.path
	return qed.markdown.parse(view.buffer:text(), {id = IDS[view.kind].body, margin = {left = 1, right = 1},
		dir = path ~= "" and qed.path.dir(path) or nil,
		on = {link = function(event)
			follow(view.kind, event.target)
			return true
		end}})
end

local function build(view)
	if view.kind == "split" then
		-- sized on both axes: an auto height would measure the document at the whole row's width every layout
		return ui.scroll{id = IDS.split.scroll, width = qed.config().split_width .. "%", height = "100%",
			scope = {"markdown_split", "markdown", "list"},
			on = {
				state = function(event)
					if event.offset then
						sync_editor()
					end
				end,
				click = function()
					scroller(view):focus()
					return true
				end,
			},
			document(view)}
	end
	local path = view.path
	return ui.dismissable{dim = true, on_dismiss = function()
			sync_back()
			close("overlay")
		end,
		ui.pane{id = "markdown", place = "full", max_width = math.max(qed.opt("pane_max_width"), MIN_WIDTH),
			title = path ~= "" and qed.path.base(path) or "untitled",
			ui.scroll{id = IDS.overlay.scroll, grow = 1, scope = {"markdown", "list"}, document(view)},
			ui.footer{hints = HINTS},
		},
	}
end

local function scroll(view)
	local state = view and scroller(view):state()
	return state and state.offset or 0
end

-- offsets clamp at layout; clamp here too so a read right after a key is already right
local function scroll_to(view, offset)
	local state, rect = body(view):state(), scroller(view):rect()
	local rows, height = state and state.rows or 0, rect and rect.height or 0
	scroller(view):set_state{offset = math.max(0, math.min(offset, rows - height))}
end

-- a heading resolves at the first render of its document; fn gets its source row, or nil when the slug is not there
local function after_heading(view, fn)
	-- link handlers cannot wait: settle in a task of our own
	qed.defer(0, function()
		local state = body(view):settled()
		if views[view.kind] == view then
			fn(state and state.heading)
		end
	end)
end

local function preview(kind, buffer, anchor, source)
	local view = views[kind]
	if view and kind == "split" then
		view.watch:remove()
		view.buffer, view.path = buffer, buffer:path()
		view.handle:update(build(view))
	else
		close(kind)
		view = {kind = kind, buffer = buffer, path = buffer:path()}
		views[kind] = view
		view.handle = ui.mount(kind == "split" and "editor_side" or "pane", build(view))
	end
	view.watch = qed:on("buf_changed", function(changed)
		if views[kind] == view and changed == buffer then
			-- the split keeps its own top line: preview to editor is many-to-one, so the editor's top would snap it
			local state = kind == "split" and body(view):state()
			view.handle:update(build(view))
			if state and state.source then
				body(view):set_state{source = state.source}
			end
		end
	end)
	if kind == "overlay" then
		scroller(view):focus()
	end
	if anchor and anchor ~= "" and kind == "split" then
		view.heading = true
		body(view):set_state{heading = anchor}
		after_heading(view, function()
			view.heading = nil
			sync_editor()
		end)
	elseif anchor and anchor ~= "" then
		body(view):set_state{heading = anchor}
		after_heading(view, function(heading)
			if not heading then
				return
			end
			local row = math.min(heading, buffer:line_count())
			buffer:set_cursor({row = row, col = buffer:line(row):find("%S") or 1})
		end)
	elseif kind == "split" and source then
		body(view):set_state{source = source}
		buffer:set_screen_row(source, (scroller(view):rect() or {y = 1}).y)
		synced_top = buffer:top_row()
	elseif kind == "split" then
		sync_preview(true)
	else
		body(view):set_state{source = buffer:cursor().row, at = buffer:screen_row() or 1}
	end
end

local function remember(kind)
	local view, history = views[kind], histories[kind]
	local entry = history.entries[history.at]
	if view and entry and entry.buf == view.buffer then
		local state = body(view):state()
		entry.scroll, entry.source = scroll(view), state and state.source
	end
end

local function push(kind)
	local view, history = views[kind], histories[kind]
	for i = #history.entries, history.at + 1, -1 do
		history.entries[i] = nil
	end
	history.at = history.at + 1
	local state = body(view):state()
	history.entries[history.at] = {path = view.path, buf = view.buffer, scroll = scroll(view), source = state and state.source}
end

local function show(kind, entry)
	local view = views[kind]
	if not view or entry.buf ~= view.buffer then
		if not entry.buf:valid() then
			if entry.path == "" or not qed.fs.exists(entry.path) then
				return false
			end
			local buffer, err = qed.open(entry.path)
			if not buffer then
				qed.message(err, "error")
				return false
			end
			entry.buf = buffer
		end
		expected_enter = kind == "split" and entry.buf ~= qed.buf.current() and entry.buf or nil
		local _, err = qed.jump(entry.buf, entry.buf:cursor())
		if err then
			expected_enter = nil
			qed.message(err, "error")
			return false
		end
		if kind == "split" then
			preview(kind, entry.buf, nil, entry.source)
			return true
		end
		preview(kind, entry.buf)
		view = views[kind]
	end
	if kind == "split" and entry.source then
		body(view):set_state{source = entry.source}
		view.buffer:set_screen_row(entry.source, (scroller(view):rect() or {y = 1}).y)
		synced_top = view.buffer:top_row()
	else
		scroll_to(view, entry.scroll)
		if kind == "split" then
			sync_editor()
		end
	end
	return true
end

-- a step that cannot show its entry stays where it was
local function step(direction)
	local kind = views.overlay and "overlay" or "split"
	local history = histories[kind]
	if not views[kind] or not history.entries[history.at + direction] then
		return
	end
	remember(kind)
	if show(kind, history.entries[history.at + direction]) then
		history.at = history.at + direction
	end
end

local function target_pos(path)
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:path() == path then
			return buffer:cursor()
		end
	end
	return {row = 1, col = 1}
end

follow = function(kind, target)
	local view = views[kind]
	if not view then
		return
	end
	if target:sub(1, 1) == "#" then
		remember(kind)
		body(view):set_state{heading = target:sub(2)}
		push(kind)
		if kind == "split" then
			view.heading = true
			after_heading(view, function()
				view.heading = nil
				sync_editor()
				remember(kind)
			end)
		end
		return
	end
	if target:match("^%a[%w+.-]*:") then
		local ok, err = qed.open_url(target)
		if not ok then
			qed.message(err, "error")
		end
		return
	end
	local file, anchor = target:match("^([^#]*)#?(.*)$")
	file = file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	local base = view.path
	local dir = base ~= "" and qed.path.dir(base) or qed.root()
	local path = file:sub(1, 1) == "/" and file or qed.path.join(dir, file)
	if not qed.fs.exists(path) then
		qed.message("Not found: " .. file, "error")
		return
	end
	local markdown = path:lower():match("%.md$") or path:lower():match("%.markdown$")
	if not markdown and kind == "overlay" then
		close(kind)
	end
	local from = qed.buf.current()
	local _, err = qed.jump(path, target_pos(path))
	if err then
		qed.message(err, "error")
		return
	end
	if markdown then
		remember(kind)
		expected_enter = kind == "split" and qed.buf.current() ~= from and qed.buf.current() or nil
		preview(kind, qed.buf.current(), anchor)
		push(kind)
	end
end

local function split_refresh()
	local buffer = current_buffer()
	if not (split_on and is_markdown(buffer)) then
		if views.split then
			remember("split")
			close("split")
		end
		return
	end
	if not views.split or views.split.buffer ~= buffer then
		preview("split", buffer)
	end
end

local function split_hook(event, fn)
	split_hooks[#split_hooks + 1] = qed:on(event, fn)
end

local function split_start()
	split_on = true
	histories.split = {entries = {}, at = 0}
	expected_enter = nil
	split_hook("buf_enter", function(buffer)
		local history = histories.split
		local entry = history.entries[history.at]
		local recorded = buffer == expected_enter or not is_markdown(buffer) or (entry and entry.buf == buffer)
		expected_enter = nil
		if not recorded then
			remember("split")
		end
		split_refresh()
		if not recorded and views.split then
			push("split")
		end
	end)
	split_hook("buf_close", split_refresh)
	split_hook("language_changed", split_refresh)
	split_hook("cursor_moved", function(buffer)
		if views.split and views.split.buffer == buffer then
			sync_preview()
		end
	end)
	split_hook("view_scrolled", function(buffer)
		if views.split and views.split.buffer == buffer then
			sync_preview()
		end
	end)
	split_refresh()
	if views.split then
		push("split")
	end
end

local function split_stop()
	split_on = false
	for _, hook in ipairs(split_hooks) do
		hook:remove()
	end
	split_hooks = {}
	close("split")
end

local function split_set(on)
	if on and not split_on then
		split_start()
	elseif not on and split_on then
		split_stop()
	end
end

local function toggle_overlay(ctx)
	if views.overlay then
		sync_back()
		close("overlay")
		return
	end
	preview("overlay", ctx.buf)
	histories.overlay = {entries = {}, at = 0}
	push("overlay")
end

local function config_changed(changed)
	if changed.split then
		split_set(qed.config().split)
	end
	for _, view in pairs(views) do
		view.handle:update(build(view))
	end
end

local function state(kind)
	local view = views[kind or (views.overlay and "overlay" or "split")]
	if not view then
		return nil
	end
	local body_state, rect = body(view):state(), scroller(view):rect()
	local box = view.kind == "split" and rect or ui.node("markdown"):rect()
	return {kind = view.kind == "split" and "split" or "pane", width = box and box.width or 0, offset = scroll(view),
		rows = body_state and body_state.rows or 0, body_y = rect and rect.y - 1 or 0, body_h = rect and rect.height or 0,
		body_x = rect and rect.x - 1 or 0, sources = body_state and body_state.sources or {}, source = body_state and body_state.source}
end

return {
	setup = function()
		qed.meta{description = "Rendered markdown preview"}
		qed.options{
			split = {type = "bool", default = false, description = "Show the side-by-side preview at launch (Markdown: Toggle Split changes it for the session)"},
			split_width = {type = "int", default = 50, min = 1, max = 99, description = "Width of the side-by-side preview in percent of the editor row"},
		}
		qed.command{
			id = "preview", name = "Preview",
			key = "Alt+p",
			when = function(ctx) return views.overlay ~= nil or ctx.language == "markdown" end,
			run = toggle_overlay,
		}
		qed.command{id = "toggle_split", name = "Toggle Split", run = function() split_set(not split_on) end}
		qed.command{id = "back", name = "Back", scope = "markdown", bind_from = "jump_back", run = function() step(-1) end}
		qed.command{id = "forward", name = "Forward", scope = "markdown", bind_from = "jump_forward", run = function() step(1) end}
		qed.command{id = "close", name = "Close", scope = "markdown", key = "Esc",
			when = function() return views.overlay ~= nil end,
			run = function()
				sync_back()
				close("overlay")
			end}
		qed.command{id = "focus_editor", name = "Focus Editor", scope = "markdown_split", key = "Esc", run = function()
			if views.split then
				views.split.buffer:focus()
			end
		end}
		qed:on("startup", function()
			if qed.config().split then
				split_set(true)
			end
		end)
		qed:on("config_changed", config_changed)
		qed.export{state = state}
	end,
}

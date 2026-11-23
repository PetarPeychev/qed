local ui = qed.ui

local MIN_WIDTH = 20

local cfg
local view
local history, at = {}, 0
local follow

local function body()
	return ui.node("markdown_body")
end

local function scroller()
	return ui.node("markdown_scroll")
end

local function close()
	if not view then
		return
	end
	local closing = view
	view = nil
	closing.watch:remove()
	closing.handle:unmount()
end

-- the cursor moves to the source line now under its terminal row, unless that line is still the cursor's block
local function sync_back()
	if not view or view.buffer ~= qed.buf.current() then
		return
	end
	local state, rect = body():state(), scroller():rect()
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

local function shortcut(name)
	for _, command in ipairs(qed.commands()) do
		if command.name == name then
			return command.shortcut
		end
	end
	return ""
end

local function footer()
	local parts = {"↑↓ PgUp PgDn scroll  click a link to open it"}
	for _, hint in ipairs({{"Markdown: Back", "back"}, {"Markdown: Forward", "forward"}, {"Markdown: Close", "close"}}) do
		local keys = shortcut(hint[1])
		if keys ~= "" then
			parts[#parts + 1] = keys .. " " .. hint[2]
		end
	end
	return table.concat(parts, "  ")
end

local function build()
	local path = view.path
	return ui.dismissable{on_dismiss = function()
			sync_back()
			close()
		end,
		ui.box{id = "markdown", float = "screen", anchor = "center", width = {"100%", max = math.max(cfg.max_width, MIN_WIDTH)}, height = "100%",
			margin = {x = 2, y = 1}, border = true, title = path ~= "" and qed.path.base(path) or "untitled",
			bg = "pane_background", fg = "pane_foreground",
			ui.column{separator = true,
				ui.scroll{id = "markdown_scroll", grow = 1, scope = {"markdown"},
					qed.markdown.parse(view.buffer:text(), {id = "markdown_body", margin = {left = 1, right = 1},
						dir = path ~= "" and qed.path.dir(path) or nil,
						on = {link = function(event)
							follow(event.target)
							return true
						end}})},
				ui.text{fg = "pane_dim_foreground", height = 1, " ", footer()},
			},
		},
	}
end

local function preview(buffer, anchor)
	close()
	view = {buffer = buffer, path = buffer:path()}
	view.handle = ui.mount("pane", build())
	local current = view
	view.watch = qed:on("buf_changed", function(changed)
		if view == current and changed == buffer then
			view.handle:update(build())
		end
	end)
	scroller():focus()
	if anchor and anchor ~= "" then
		body():set_state{heading = anchor}
	else
		body():set_state{source = buffer:cursor().row, at = buffer:screen_row() or 1}
	end
	if anchor and anchor ~= "" then
		-- the heading resolves at the first render: then the editor moves to it
		local tries = 0
		local function heading_cursor()
			if view ~= current then
				return
			end
			local state = body():state()
			if not (state and state.heading) then
				tries = tries + 1
				if tries < 50 then
					qed.defer(10, heading_cursor)
				end
				return
			end
			local row = math.min(state.heading, buffer:line_count())
			buffer:set_cursor({row = row, col = buffer:line(row):find("%S") or 1})
		end
		qed.defer(0, heading_cursor)
	end
end

local function scroll()
	local state = view and scroller():state()
	return state and state.offset or 0
end

-- offsets clamp at layout; clamp here too so a read right after a key is already right
local function scroll_to(offset)
	local state, rect = body():state(), scroller():rect()
	local rows, height = state and state.rows or 0, rect and rect.height or 0
	scroller():set_state{offset = math.max(0, math.min(offset, rows - height))}
end

local function scroll_by(step)
	if view then
		scroll_to(scroll() + step)
	end
end

local function page()
	local rect = scroller():rect()
	return math.max((rect and rect.height or 2) - 1, 1)
end

local function remember()
	if view and history[at] then
		history[at].scroll = scroll()
	end
end

local function push()
	for i = #history, at + 1, -1 do
		history[i] = nil
	end
	at = at + 1
	history[at] = {path = view.path, buf = view.buffer, scroll = scroll()}
end

local function show(entry)
	if not view or entry.buf ~= view.buffer then
		if not entry.buf:valid() then
			if entry.path == "" or not qed.fs.exists(entry.path) then
				return
			end
			local buffer, err = qed.open(entry.path)
			if not buffer then
				qed.message(err, "error")
				return
			end
			entry.buf = buffer
		end
		local _, err = qed.jump(entry.buf, entry.buf:cursor())
		if err then
			qed.message(err, "error")
			return
		end
		preview(entry.buf)
	end
	if view then
		scroll_to(entry.scroll)
	end
end

local function step(direction)
	if not history[at + direction] then
		return
	end
	remember()
	at = at + direction
	show(history[at])
end

local function target_pos(path)
	for _, buffer in ipairs(qed.buf.list()) do
		if buffer:path() == path then
			return buffer:cursor()
		end
	end
	return {row = 1, col = 1}
end

follow = function(target)
	if target:sub(1, 1) == "#" then
		if history[at] then
			history[at].scroll = scroll()
		end
		body():set_state{heading = target:sub(2)}
		push()
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
	local base = view and view.path or ""
	local dir = base ~= "" and qed.path.dir(base) or qed.root()
	local path = file:sub(1, 1) == "/" and file or qed.path.join(dir, file)
	if not qed.fs.exists(path) then
		qed.message("Not found: " .. file, "error")
		return
	end
	local markdown = path:lower():match("%.md$") or path:lower():match("%.markdown$")
	if not markdown then
		close()
	end
	local _, err = qed.jump(path, target_pos(path))
	if err then
		qed.message(err, "error")
		return
	end
	if markdown then
		remember()
		preview(qed.buf.current(), anchor)
		push()
	end
end

local function toggle(ctx)
	if view then
		sync_back()
		close()
		return
	end
	preview(ctx.buf)
	history, at = {}, 0
	push()
end

local function state()
	if not view then
		return nil
	end
	local body_state, rect, box = body():state(), scroller():rect(), ui.node("markdown"):rect()
	return {kind = "pane", width = box and box.width or 0, scroll = scroll(), rows = body_state and body_state.rows or 0,
		body_y = rect and rect.y - 1 or 0, body_h = rect and rect.height or 0}
end

return {
	setup = function()
		qed.meta{description = "Rendered markdown preview"}
		cfg = qed.options({max_width = 120}, {max_width = "Max width of the preview pane"})
		qed.command{
			name = "Preview",
			key = "Alt+p",
			when = function(ctx) return view ~= nil or ctx.language == "markdown" end,
			run = toggle,
		}
		qed.command{name = "Line Up", scope = "markdown", key = "Up", run = function() scroll_by(-1) end}
		qed.command{name = "Line Down", scope = "markdown", key = "Down", run = function() scroll_by(1) end}
		qed.command{name = "Page Up", scope = "markdown", key = "PgUp", run = function() scroll_by(-page()) end}
		qed.command{name = "Page Down", scope = "markdown", key = "PgDn", run = function() scroll_by(page()) end}
		qed.command{name = "Top", scope = "markdown", key = "Home", run = function() scroll_to(0) end}
		qed.command{name = "Bottom", scope = "markdown", key = "End", run = function() scroll_to(math.huge) end}
		qed.command{name = "Back", scope = "markdown", bind_from = "Jump Back", run = function() step(-1) end}
		qed.command{name = "Forward", scope = "markdown", bind_from = "Jump Forward", run = function() step(1) end}
		qed.command{name = "Close", scope = "markdown", key = "Esc", run = function()
			sync_back()
			close()
		end}
		qed:on("config_changed", function()
			cfg = qed.config()
			if view then
				view.handle:update(build())
			end
		end)
		qed.export{state = state}
	end,
}

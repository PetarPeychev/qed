local cfg
local view, watch, current
local synced
local history, at = {}, 0
local follow

local function stop(v)
	if view == v then
		watch:off()
		view, watch, current, synced = nil, nil, nil, nil
	end
end

local function sync_back(v)
	if not current or current.buf ~= qed.buf.current() or v:scroll() == synced then
		return
	end
	local b = current.buf
	local src, row = v:source_line(qed.buf.screen_row(b))
	if not src then
		return
	end
	qed.buf.set_cursor(b, {row = src, col = qed.buf.line(b, src):find("%S") or 1})
	qed.buf.set_screen_row(b, src, row)
end

local function preview(b, anchor)
	local path = qed.buf.path(b)
	local v = qed.ui.open{
		place = "full",
		scope = "markdown",
		toggle = "Markdown: Preview",
		max_width = cfg.max_width,
		backdrop = cfg.backdrop,
		title = path ~= "" and qed.path.base(path) or "untitled",
		markdown = qed.buf.text(b),
		footer = {hints = {{label = "↑↓ PgUp PgDn scroll  click a link to open it"}, {label = "back", cmd = "Markdown: Back"}, {label = "forward", cmd = "Markdown: Forward"}, {label = "close", cmd = "Markdown: Preview"}}},
		on = {
			close = function(cv)
				if view == cv then
					sync_back(cv)
				end
				stop(cv)
			end,
			link = function(lv, target) follow(lv, target) end,
		},
	}
	if not v then
		return
	end
	if view then
		stop(view)
	end
	v:source_scroll(qed.buf.cursor(b).row, qed.buf.screen_row(b))
	if anchor and anchor ~= "" then
		local found, src = v:anchor(anchor)
		if found then
			qed.buf.set_cursor(b, {row = src, col = 1})
		end
	end
	synced = v:scroll()
	current = {path = path, buf = b}
	view, watch = v, qed.on("buf_changed", function(changed)
		if changed == b then
			v:markdown(qed.buf.text(b))
		end
	end)
end

local function remember()
	if view and history[at] then
		history[at].scroll = view:scroll() or history[at].scroll
	end
end

local function push()
	for i = #history, at + 1, -1 do
		history[i] = nil
	end
	at = at + 1
	history[at] = {path = current.path, buf = current.buf, scroll = view:scroll()}
end

local function show(entry)
	if not current or entry.buf ~= current.buf then
		if not qed.buf.valid(entry.buf) then
			if entry.path == "" or not qed.fs.exists(entry.path) then
				return
			end
			local b, err = qed.open(entry.path)
			if not b then
				qed.message(err, "error")
				return
			end
			entry.buf = b
		end
		local _, err = qed.jump(entry.buf, qed.buf.cursor(entry.buf))
		if err then
			qed.message(err, "error")
			return
		end
		preview(entry.buf)
	end
	if view then
		view:scroll(entry.scroll)
	end
end

local function step(d)
	if not history[at + d] then
		return
	end
	remember()
	at = at + d
	show(history[at])
end

local function target_pos(path)
	for _, b in ipairs(qed.buf.list()) do
		if qed.buf.path(b) == path then
			return qed.buf.cursor(b)
		end
	end
	return {row = 1, col = 1}
end

follow = function(v, target)
	if target:sub(1, 1) == "#" then
		local before = v:scroll()
		if v:anchor(target:sub(2)) then
			if history[at] then
				history[at].scroll = before
			end
			push()
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
	file = file:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	local base = current and current.path or ""
	local dir = base ~= "" and qed.path.dir(base) or qed.root()
	local path = file:sub(1, 1) == "/" and file or qed.path.join(dir, file)
	if not qed.fs.exists(path) then
		qed.message("Not found: " .. file, "error")
		return
	end
	local markdown = path:lower():match("%.md$") or path:lower():match("%.markdown$")
	if not markdown then
		stop(v)
		v:close()
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

local function reopen()
	if current and qed.buf.valid(current.buf) then
		preview(current.buf)
	end
end

return {
	setup = function()
		qed.meta{description = "Rendered markdown preview"}
		cfg = qed.options{max_width = 120, backdrop = "dim"}
		qed.command{
			name = "Preview",
			key = "Alt+p",
			when = function(ctx) return ctx.language == "markdown" end,
			run = function(ctx)
				preview(ctx.buf)
				if view then
					history, at = {}, 0
					push()
				end
			end,
		}
		qed.command{name = "Back", scope = "markdown", bind_from = "Jump Back", run = function() step(-1) end}
		qed.command{name = "Forward", scope = "markdown", bind_from = "Jump Forward", run = function() step(1) end}
		qed.on("config_changed", function()
			cfg = qed.config()
			reopen()
		end)
	end,
}

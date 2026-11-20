local cfg
-- the shown document; a back/forward history would be a list of these plus a scroll each
local view, watch, current
local follow

local function stop(v)
	if view == v then
		watch:off()
		view, watch, current = nil, nil, nil
	end
end

-- must match md_slug in core so file#anchor links land on the heading the preview shows
local function slug(text, seen)
	local s = text:gsub("%[([^%]]*)%]%b()", "%1"):gsub("[*`~]", ""):lower()
	s = s:gsub("[^%w%s%-_\128-\255]", ""):gsub("%s", "-")
	local n = seen[s] or 0
	seen[s] = n + 1
	return n == 0 and s or ("%s-%d"):format(s, n)
end

local function heading_row(text, anchor)
	local seen, fence, row = {}, nil, 0
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		row = row + 1
		local f = line:match("^%s*(```)") or line:match("^%s*(~~~)")
		if f then
			fence = fence == nil and f or (fence == f and nil or fence)
		elseif not fence then
			local h = line:match("^ ? ? ?#+%s+(.-)%s*#*%s*$")
			if h and slug(h, seen) == anchor then
				return row
			end
		end
	end
end

local function preview(b, anchor)
	local path = qed.buf.path(b)
	local v = qed.ui.open{
		id = "markdown:" .. (path ~= "" and path or tostring(b)),
		place = "full",
		toggle = "Markdown: Preview",
		max_width = cfg.max_width,
		backdrop = cfg.backdrop,
		title = path ~= "" and qed.path.base(path) or "untitled",
		markdown = qed.buf.text(b),
		footer = {hints = {{label = "↑↓ PgUp PgDn Home End scroll  click a link to open it"}, {label = "close", cmd = "Markdown: Preview"}}},
		on = {close = stop, link = function(lv, target) follow(lv, target) end},
	}
	if not v then
		return
	end
	if view then
		stop(view)
	end
	if anchor and anchor ~= "" then
		v:anchor(anchor)
	end
	current = {path = path, buf = b}
	-- subscribed only while open, so typing elsewhere runs no Lua
	view, watch = v, qed.on("buf_changed", function(changed)
		if changed == b then
			v:markdown(qed.buf.text(b))
		end
	end)
end

local function target_pos(path, anchor)
	for _, b in ipairs(qed.buf.list()) do
		if qed.buf.path(b) == path then
			local row = anchor ~= "" and heading_row(qed.buf.text(b), anchor)
			return row and {row = row, col = 1} or qed.buf.cursor(b)
		end
	end
	local row = anchor ~= "" and heading_row(qed.fs.read(path) or "", anchor)
	return {row = row or 1, col = 1}
end

follow = function(v, target)
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
		v:close()
	end
	local _, err = qed.jump(path, target_pos(path, anchor))
	if err then
		qed.message(err, "error")
		return
	end
	if markdown then
		preview(qed.buf.current(), anchor)
	end
end

local function reopen()
	if current and qed.buf.valid(current.buf) then
		preview(current.buf)
	end
end

return {
	setup = function()
		cfg = qed.options{max_width = 120, backdrop = "dim"}
		qed.command{
			name = "Preview",
			key = "Alt+p",
			when = function(ctx) return ctx.language == "markdown" end,
			run = function(ctx) preview(ctx.buf) end,
		}
		qed.on("config_changed", function()
			cfg = qed.config()
			reopen()
		end)
	end,
}

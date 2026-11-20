local cfg
local view, watch

local function stop(v)
	if view == v then
		watch:off()
		view, watch = nil, nil
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

local function heading_row(b, anchor)
	local seen, fence = {}, nil
	for row, line in ipairs(qed.buf.lines(b)) do
		local f = line:match("^%s*(```)") or line:match("^%s*(~~~)")
		if f then
			fence = fence == nil and f or (fence == f and nil or fence)
		elseif not fence then
			local text = line:match("^ ? ? ?#+%s+(.-)%s*#*%s*$")
			if text and slug(text, seen) == anchor then
				return row
			end
		end
	end
end

local function open_file(v, b, target)
	local file, anchor = target:match("^([^#]*)#?(.*)$")
	file = file:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	local base = qed.buf.path(b)
	local dir = base ~= "" and qed.path.dir(base) or qed.root()
	local path = file:sub(1, 1) == "/" and file or qed.path.join(dir, file)
	if not qed.fs.exists(path) then
		qed.message("Not found: " .. file, "error")
		return
	end
	v:close()
	local nb, err = qed.open(path)
	if not nb then
		qed.message(err, "error")
		return
	end
	local row = anchor ~= "" and heading_row(nb, anchor)
	qed.jump(nb, row and {row = row, col = 1} or qed.buf.cursor(nb))
end

local function follow(v, b, target)
	if target:match("^%a[%w+.-]*:") then
		local ok, err = qed.open_url(target)
		if not ok then
			qed.message(err, "error")
		end
		return
	end
	open_file(v, b, target)
end

local function preview(ctx)
	local b = ctx.buf
	local path = qed.buf.path(b)
	local v = qed.ui.open{
		id = "markdown:" .. b,
		place = "full",
		max_width = cfg.max_width,
		backdrop = cfg.backdrop,
		title = path ~= "" and qed.path.base(path) or "untitled",
		markdown = qed.buf.text(b),
		footer = {hints = {{label = "↑↓ PgUp PgDn Home End scroll  click a link to open it"}, {label = "close", cmd = "Markdown: Preview"}}},
		on = {close = stop, link = function(lv, target) follow(lv, b, target) end},
	}
	if not v then
		return
	end
	if view then
		stop(view)
	end
	-- subscribed only while open, so typing elsewhere runs no Lua
	view, watch = v, qed.on("buf_changed", function(changed)
		if changed == b then
			v:markdown(qed.buf.text(b))
		end
	end)
end

return {
	setup = function()
		cfg = qed.options{max_width = 100, backdrop = "dim"}
		qed.command{
			name = "Preview",
			key = "Alt+p",
			when = function(ctx) return ctx.language == "markdown" end,
			run = preview,
		}
		qed.on("config_changed", function() cfg = qed.config() end)
	end,
}

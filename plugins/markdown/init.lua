local max_width
local view, watch

local function stop(v)
	if view == v then
		watch:off()
		view, watch = nil, nil
	end
end

local function preview(ctx)
	local b = ctx.buf
	local path = qed.buf.path(b)
	local v = qed.ui.open{
		id = "markdown:" .. b,
		place = "full",
		max_width = max_width,
		title = path ~= "" and qed.path.base(path) or "untitled",
		markdown = qed.buf.text(b),
		footer = {hints = {{label = "↑↓ PgUp PgDn Home End scroll"}, {label = "close", cmd = "Markdown: Preview"}}},
		on = {close = stop},
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
		max_width = qed.options{max_width = 100}.max_width
		qed.command{
			name = "Preview",
			key = "Alt+p",
			when = function(ctx) return ctx.language == "markdown" end,
			run = preview,
		}
		qed.on("config_changed", function() max_width = qed.config().max_width end)
	end,
}

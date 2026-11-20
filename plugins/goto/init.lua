local function selection_query(ctx)
	local s = ctx.selection_text
	if s and not s:find("\n") and s:find("[^ \t]") then
		return s
	end
end

local function find_line(ctx)
	local buf = ctx.buf
	if not buf then
		return
	end
	qed.ui.open{
		id = "goto",
		place = "split",
		fields = {{text = selection_query(ctx)}},
		list = {items = qed.buf.line_list(buf)},
		preview = "auto",
		on = {
			activate = function(v, items)
				v:close()
				if items[1] and qed.buf.valid(buf) then
					qed.jump(buf, items[1].pos)
				end
			end,
		},
	}
end

return {
	setup = function()
		qed.meta{display_name = "Go To"}
		qed.command{name = "Line", key = "Ctrl+g", run = find_line}
	end,
}

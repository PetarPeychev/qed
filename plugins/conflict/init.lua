local ns, hook
local state = {}
local armed = {}

local MARKERS = {"<<<<<<<", "=======", "|||||||", ">>>>>>>"}
local START, SEP, BASE, FINISH = 1, 2, 3, 4

local function scan(b)
	local rows, kinds = qed.buf.find_lines(b, MARKERS, {word = true})
	local blocks = {}
	local i, n = 1, #rows
	while i <= n do
		local next_i = i + 1
		if kinds[i] == START then
			local c = {start = rows[i]}
			local last
			for j = i + 1, n do
				local k = kinds[j]
				if k == START then
					break
				elseif k == FINISH then
					c.finish, last = rows[j], j
					break
				elseif not c.sep and not c.base and k == BASE then
					c.base = rows[j]
				elseif not c.sep and k == SEP then
					c.sep = rows[j]
				end
			end
			if c.sep and c.finish then
				blocks[#blocks + 1] = c
				next_i = last + 1
			end
		end
		i = next_i
	end
	return blocks
end

local function decorate_marker(b, row, color)
	qed.deco.tint(b, ns, row, row, color, "conflict_marker")
	qed.deco.span(b, ns, {row = row, col = 1}, {row = row, col = #qed.buf.line(b, row) + 1}, {fg = color})
end

local function decorate_body(b, lo, hi, color)
	if lo <= hi then
		qed.deco.tint(b, ns, lo, hi, color, "conflict")
	end
end

local function decorate_words(b, c)
	local hunks = qed.text.diff_rows(b, c.start + 1, (c.base or c.sep) - 1, c.sep + 1, c.finish - 1, {words = true})
	for _, h in ipairs(hunks or {}) do
		for k, s in ipairs(h.spans) do
			if s[1] ~= s[2] then
				local row = h.a + k - 1
				qed.deco.span(b, ns, {row = row, col = s[1]}, {row = row, col = s[2]}, {bg = "conflict_ours", alpha = "conflict_word"})
			end
			if s[3] ~= s[4] then
				local row = h.b + k - 1
				qed.deco.span(b, ns, {row = row, col = s[3]}, {row = row, col = s[4]}, {bg = "conflict_theirs", alpha = "conflict_word"})
			end
		end
	end
end

local function decorate(b, c)
	decorate_marker(b, c.start, "conflict_ours")
	decorate_body(b, c.start + 1, (c.base or c.sep) - 1, "conflict_ours")
	if c.base then
		decorate_marker(b, c.base, "conflict_base")
		decorate_body(b, c.base + 1, c.sep - 1, "conflict_base")
	end
	decorate_marker(b, c.sep, "conflict_theirs")
	decorate_body(b, c.sep + 1, c.finish - 1, "conflict_theirs")
	decorate_marker(b, c.finish, "conflict_theirs")
	decorate_words(b, c)
end

local changed

-- buf_changed is held only while a buffer has had conflicts, so a plain edit session runs no Lua per keystroke.
local function sync_hook()
	if next(armed) and not hook then
		hook = qed.on("buf_changed", changed)
	elseif not next(armed) and hook then
		hook:off()
		hook = nil
	end
end

local function full(b, force)
	if not qed.buf.valid(b) then
		return
	end
	local rev = qed.buf.rev(b)
	local st = state[b]
	if st and st.rev == rev and not force then
		return
	end
	local blocks = scan(b)
	if st and #st.blocks > 0 then
		qed.deco.clear(b, ns)
	end
	for _, c in ipairs(blocks) do
		decorate(b, c)
	end
	state[b] = {rev = rev, lines = qed.buf.line_count(b), blocks = blocks}
	if #blocks > 0 then
		armed[b] = true
	elseif force then
		armed[b] = nil
	end
	sync_hook()
end

local function same(o, d, c)
	return o.start + d == c.start and o.sep + d == c.sep and o.finish + d == c.finish and (o.base and o.base + d) == c.base
end

-- Rows above lo are untouched and rows below hi only shifted, so a block outside the
-- dirty rows keeps its decorations when the new parse has it at the shifted rows.
changed = function(b, rev, _, lo, hi)
	local st = state[b]
	if not armed[b] or not st or st.rev == rev or not qed.buf.valid(b) then
		return
	end
	local blocks = scan(b)
	local lines = qed.buf.line_count(b)
	local delta = lines - st.lines
	local old_hi = hi - delta
	local kept = {}
	local j = 1
	for _, o in ipairs(st.blocks) do
		local d
		if o.finish < lo then
			d = 0
		elseif o.start > old_hi then
			d = delta
		end
		if not d then
			qed.deco.clear(b, ns, math.min(o.start, lo), o.finish > old_hi and o.finish + delta or hi)
		else
			local s = o.start + d
			while blocks[j] and blocks[j].start < s do
				j = j + 1
			end
			if blocks[j] and same(o, d, blocks[j]) then
				kept[j] = true
			else
				qed.deco.clear(b, ns, s, o.finish + d)
			end
		end
	end
	for i, c in ipairs(blocks) do
		if not kept[i] then
			qed.deco.clear(b, ns, c.start, c.finish)
			decorate(b, c)
		end
	end
	st.rev, st.lines, st.blocks = rev, lines, blocks
end

local function block_at(blocks, row)
	for _, c in ipairs(blocks) do
		if row >= c.start and row <= c.finish then
			return c
		end
	end
end

local function delete_rows(b, lo, hi)
	local n = qed.buf.line_count(b)
	local from, to = {row = lo, col = 1}, nil
	if hi < n then
		to = {row = hi + 1, col = 1}
	elseif lo > 1 then
		from = {row = lo - 1, col = #qed.buf.line(b, lo - 1) + 1}
		to = {row = hi, col = #qed.buf.line(b, hi) + 1}
	else
		to = {row = hi, col = #qed.buf.line(b, hi) + 1}
	end
	qed.buf.delete(b, from, to)
end

local KEEP = {"Keep Ours", "Keep Theirs", "Keep Both"}

local function resolve(b, c, keep)
	qed.edit(b, function()
		if keep == 1 then
			delete_rows(b, c.base or c.sep, c.finish)
			delete_rows(b, c.start, c.start)
		elseif keep == 2 then
			delete_rows(b, c.finish, c.finish)
			delete_rows(b, c.start, c.sep)
		else
			delete_rows(b, c.finish, c.finish)
			delete_rows(b, c.base or c.sep, c.sep)
			delete_rows(b, c.start, c.start)
		end
	end)
	qed.buf.set_cursor(b, {row = math.min(c.start, qed.buf.line_count(b)), col = 1})
end

local function run(ctx)
	local b = ctx.buf
	if not b then
		return
	end
	local blocks = scan(b)
	if #blocks == 0 then
		qed.message("No merge conflicts")
		return
	end
	local row = qed.buf.cursor(b).row
	if block_at(blocks, row) then
		local keep, err = qed.confirm("Resolve merge conflict:", KEEP)
		if err then
			qed.message(err, "warn")
		end
		if not keep or not qed.buf.valid(b) then
			return
		end
		local c = block_at(scan(b), qed.buf.cursor(b).row)
		if c then
			resolve(b, c, keep)
		end
		return
	end
	local target = blocks[1].start
	for _, c in ipairs(blocks) do
		if c.start > row then
			target = c.start
			break
		end
	end
	qed.buf.set_cursor(b, {row = target, col = 1})
end

return {
	setup = function()
		qed.meta{display_name = "Conflict"}
		ns = qed.deco.ns("conflict")
		qed.command{name = "Resolve", key = "Alt+m", run = run}
		qed.on("startup", function()
			for _, b in ipairs(qed.buf.list()) do
				full(b)
			end
		end)
		qed.on("buf_open", full)
		qed.on("buf_reload", function(b) full(b, true) end)
		qed.on("buf_save", function(b) full(b, armed[b]) end)
		qed.on("buf_close", function(b)
			state[b], armed[b] = nil, nil
			sync_hook()
		end)
	end,
}

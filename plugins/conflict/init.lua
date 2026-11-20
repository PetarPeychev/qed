local ns
local shown = {}

local byte = string.byte

local MARKERS = {{"<<<<<<<", 60}, {"=======", 61}, {"|||||||", 124}, {">>>>>>>", 62}}

local function marker_rows(b)
	local found = {}
	for _, m in ipairs(MARKERS) do
		for _, row in ipairs(qed.buf.find_lines(b, m[1])) do
			local after = byte(qed.buf.line(b, row), 8)
			if after == nil or after == 32 then
				found[#found + 1] = {row, m[2]}
			end
		end
	end
	table.sort(found, function(x, y) return x[1] < y[1] end)
	return found
end

local function scan(b)
	if #qed.buf.find_lines(b, "<<<<<<<") == 0 then
		return {}
	end
	local marks = marker_rows(b)
	local blocks = {}
	local i = 1
	while i <= #marks do
		local next_i = i + 1
		if marks[i][2] == 60 then
			local c = {start = marks[i][1]}
			local last
			for j = i + 1, #marks do
				local row, k = marks[j][1], marks[j][2]
				if k == 60 then
					break
				elseif k == 62 then
					c.finish, last = row, j
					break
				elseif not c.sep and not c.base and k == 124 then
					c.base = row
				elseif not c.sep and k == 61 then
					c.sep = row
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

local function cont(ch)
	return ch >= 128 and ch < 192
end

local function word_span(o, t)
	local lo, lt = #o, #t
	local p = 0
	while p < lo and p < lt and byte(o, p + 1) == byte(t, p + 1) do
		p = p + 1
	end
	while p > 0 and p < lo and p < lt and (cont(byte(o, p + 1)) or cont(byte(t, p + 1))) do
		p = p - 1
	end
	local so, st = lo, lt
	while so > p and st > p and byte(o, so) == byte(t, st) do
		so, st = so - 1, st - 1
	end
	while so < lo and cont(byte(o, so + 1)) do
		so = so + 1
	end
	while st < lt and cont(byte(t, st + 1)) do
		st = st + 1
	end
	return p, so, st
end

local function decorate_words(b, c, lines)
	local ours_hi = c.base or c.sep
	local ours, theirs = {}, {}
	for r = c.start + 1, ours_hi - 1 do
		ours[#ours + 1] = lines[r - c.start + 1]
	end
	for r = c.sep + 1, c.finish - 1 do
		theirs[#theirs + 1] = lines[r - c.start + 1]
	end
	if #ours == 0 or #theirs == 0 then
		return
	end
	for _, h in ipairs(qed.text.diff(ours, theirs) or {}) do
		for k = 0, math.min(h.a_count, h.b_count) - 1 do
			local o, t = ours[h.a + k], theirs[h.b + k]
			local p, so, st = word_span(o, t)
			if p ~= so then
				local row = c.start + h.a + k
				qed.deco.span(b, ns, {row = row, col = p + 1}, {row = row, col = so + 1}, {bg = "conflict_ours", alpha = "conflict_word"})
			end
			if p ~= st then
				local row = c.sep + h.b + k
				qed.deco.span(b, ns, {row = row, col = p + 1}, {row = row, col = st + 1}, {bg = "conflict_theirs", alpha = "conflict_word"})
			end
		end
	end
end

local function decorate_marker(b, row, line, color)
	qed.deco.tint(b, ns, row, row, color, "conflict_marker")
	qed.deco.span(b, ns, {row = row, col = 1}, {row = row, col = #line + 1}, {fg = color})
end

local function decorate_body(b, lo, hi, color)
	if lo <= hi then
		qed.deco.tint(b, ns, lo, hi, color, "conflict")
	end
end

local function decorate(b)
	if not qed.buf.valid(b) then
		shown[b] = nil
		return
	end
	local blocks = scan(b)
	if #blocks == 0 and not shown[b] then
		return
	end
	qed.deco.clear(b, ns)
	shown[b] = #blocks > 0 or nil
	for _, c in ipairs(blocks) do
		local lines = qed.buf.lines(b, c.start, c.finish)
		local function line(r)
			return lines[r - c.start + 1]
		end
		local ours_hi = c.base or c.sep
		decorate_marker(b, c.start, line(c.start), "conflict_ours")
		decorate_body(b, c.start + 1, ours_hi - 1, "conflict_ours")
		if c.base then
			decorate_marker(b, c.base, line(c.base), "conflict_base")
			decorate_body(b, c.base + 1, c.sep - 1, "conflict_base")
		end
		decorate_marker(b, c.sep, line(c.sep), "conflict_theirs")
		decorate_body(b, c.sep + 1, c.finish - 1, "conflict_theirs")
		decorate_marker(b, c.finish, line(c.finish), "conflict_theirs")
		decorate_words(b, c, lines)
	end
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
	-- the edit lands after this flush's change check, so buf_changed would come a frame late
	decorate(b)
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
				decorate(b)
			end
		end)
		qed.on("buf_open", decorate)
		qed.on("buf_reload", decorate)
		qed.on("buf_changed", decorate)
		qed.on("buf_close", function(b) shown[b] = nil end)
	end,
}

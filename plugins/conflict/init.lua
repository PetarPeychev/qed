local ns, hook
local state = {}
local armed = {}

local MARKERS = {"<<<<<<<", "=======", "|||||||", ">>>>>>>"}
local START, SEP, BASE, FINISH = 1, 2, 3, 4

local function scan(buffer)
	local rows, kinds = buffer:find_lines(MARKERS, {word = true})
	local blocks = {}
	local i, count = 1, #rows
	while i <= count do
		local next_i = i + 1
		if kinds[i] == START then
			local block = {start = rows[i]}
			local last
			for next_index = i + 1, count do
				local kind = kinds[next_index]
				if kind == START then
					break
				elseif kind == FINISH then
					block.finish, last = rows[next_index], next_index
					break
				elseif not block.sep and not block.base and kind == BASE then
					block.base = rows[next_index]
				elseif not block.sep and kind == SEP then
					block.sep = rows[next_index]
				end
			end
			if block.sep and block.finish then
				blocks[#blocks + 1] = block
				next_i = last + 1
			end
		end
		i = next_i
	end
	return blocks
end

local function decorate_marker(buffer, row, color)
	qed.deco.tint(buffer, ns, row, row, {color = color, alpha = "conflict_marker"})
	qed.deco.span(buffer, ns, {row = row, col = 1}, {row = row, col = #buffer:line(row) + 1}, {fg = color})
end

local function decorate_body(buffer, lo, hi, color)
	if lo <= hi then
		qed.deco.tint(buffer, ns, lo, hi, {color = color, alpha = "conflict"})
	end
end

local function decorate_words(buffer, block)
	local hunks = qed.text.diff_rows(buffer, block.start + 1, (block.base or block.sep) - 1, block.sep + 1, block.finish - 1, {words = true})
	for _, hunk in ipairs(hunks or {}) do
		for kind, span in ipairs(hunk.spans) do
			if span[1] ~= span[2] then
				local row = hunk.a + kind - 1
				qed.deco.span(buffer, ns, {row = row, col = span[1]}, {row = row, col = span[2]}, {bg = "conflict_ours", alpha = "conflict_word"})
			end
			if span[3] ~= span[4] then
				local row = hunk.b + kind - 1
				qed.deco.span(buffer, ns, {row = row, col = span[3]}, {row = row, col = span[4]}, {bg = "conflict_theirs", alpha = "conflict_word"})
			end
		end
	end
end

local function decorate(buffer, block)
	decorate_marker(buffer, block.start, "conflict_ours")
	decorate_body(buffer, block.start + 1, (block.base or block.sep) - 1, "conflict_ours")
	if block.base then
		decorate_marker(buffer, block.base, "conflict_base")
		decorate_body(buffer, block.base + 1, block.sep - 1, "conflict_base")
	end
	decorate_marker(buffer, block.sep, "conflict_theirs")
	decorate_body(buffer, block.sep + 1, block.finish - 1, "conflict_theirs")
	decorate_marker(buffer, block.finish, "conflict_theirs")
	decorate_words(buffer, block)
end

local changed

local function sync_hook()
	if next(armed) and not hook then
		hook = qed:on("buf_changed", changed)
	elseif not next(armed) and hook then
		hook:remove()
		hook = nil
	end
end

local function full(buffer, force)
	if not buffer:valid() then
		return
	end
	local rev = buffer:rev()
	local st = state[buffer]
	if st and st.rev == rev and not force then
		return
	end
	local blocks = scan(buffer)
	if st and #st.blocks > 0 then
		qed.deco.clear(buffer, ns)
	end
	for _, block in ipairs(blocks) do
		decorate(buffer, block)
	end
	state[buffer] = {rev = rev, lines = buffer:line_count(), blocks = blocks}
	if #blocks > 0 then
		armed[buffer] = true
	elseif force then
		armed[buffer] = nil
	end
	sync_hook()
end

local function same(other, shift, block)
	return other.start + shift == block.start and other.sep + shift == block.sep and other.finish + shift == block.finish and (other.base and other.base + shift) == block.base
end

changed = function(buffer, rev, _, lo, hi)
	local st = state[buffer]
	if not armed[buffer] or not st or st.rev == rev or not buffer:valid() then
		return
	end
	local blocks = scan(buffer)
	local lines = buffer:line_count()
	local delta = lines - st.lines
	local old_hi = hi - delta
	local kept = {}
	local next_index = 1
	for _, other in ipairs(st.blocks) do
		local shift
		if other.finish < lo then
			shift = 0
		elseif other.start > old_hi then
			shift = delta
		end
		if not shift then
			qed.deco.clear(buffer, ns, math.min(other.start, lo), other.finish > old_hi and other.finish + delta or hi)
		else
			local start_row = other.start + shift
			while blocks[next_index] and blocks[next_index].start < start_row do
				next_index = next_index + 1
			end
			if blocks[next_index] and same(other, shift, blocks[next_index]) then
				kept[next_index] = true
			else
				qed.deco.clear(buffer, ns, start_row, other.finish + shift)
			end
		end
	end
	for i, block in ipairs(blocks) do
		if not kept[i] then
			qed.deco.clear(buffer, ns, block.start, block.finish)
			decorate(buffer, block)
		end
	end
	st.rev, st.lines, st.blocks = rev, lines, blocks
end

local function block_at(blocks, row)
	for _, block in ipairs(blocks) do
		if row >= block.start and row <= block.finish then
			return block
		end
	end
end

local function delete_rows(buffer, lo, hi)
	local count = buffer:line_count()
	local from, to = {row = lo, col = 1}, nil
	if hi < count then
		to = {row = hi + 1, col = 1}
	elseif lo > 1 then
		from = {row = lo - 1, col = #buffer:line(lo - 1) + 1}
		to = {row = hi, col = #buffer:line(hi) + 1}
	else
		to = {row = hi, col = #buffer:line(hi) + 1}
	end
	buffer:delete(from, to)
end

local KEEP = {"Keep Ours", "Keep Theirs", "Keep Both"}

local function resolve(buffer, block, keep)
	qed.edit(buffer, function()
		if keep == 1 then
			delete_rows(buffer, block.base or block.sep, block.finish)
			delete_rows(buffer, block.start, block.start)
		elseif keep == 2 then
			delete_rows(buffer, block.finish, block.finish)
			delete_rows(buffer, block.start, block.sep)
		else
			delete_rows(buffer, block.finish, block.finish)
			delete_rows(buffer, block.base or block.sep, block.sep)
			delete_rows(buffer, block.start, block.start)
		end
	end)
	buffer:set_cursor({row = math.min(block.start, buffer:line_count()), col = 1})
end

local function run(ctx)
	local buffer = ctx.buf
	if not buffer then
		return
	end
	local blocks = scan(buffer)
	if #blocks == 0 then
		qed.message("No merge conflicts")
		return
	end
	local row = buffer:cursor().row
	if block_at(blocks, row) then
		local keep, err = qed.confirm{question = "Resolve merge conflict:", choices = KEEP}
		if err then
			qed.message("Cannot resolve while another dialog is open", "warn")
		end
		if not keep or not buffer:valid() then
			return
		end
		local block = block_at(scan(buffer), buffer:cursor().row)
		if block then
			resolve(buffer, block, keep)
		end
		return
	end
	local target = blocks[1].start
	for _, block in ipairs(blocks) do
		if block.start > row then
			target = block.start
			break
		end
	end
	buffer:set_cursor({row = target, col = 1})
end

return {
	setup = function()
		qed.meta{description = "Highlights and resolves merge conflict blocks"}
		ns = qed.deco.ns("conflict")
		qed.command{id = "resolve", name = "Resolve", key = "Alt+m", run = run}
		qed:on("startup", function()
			for _, buffer in ipairs(qed.buf.list()) do
				full(buffer)
			end
		end)
		qed:on("buf_open", full)
		qed:on("buf_reload", function(buffer) full(buffer, true) end)
		qed:on("buf_save", function(buffer) full(buffer, armed[buffer]) end)
		qed:on("buf_close", function(buffer)
			state[buffer], armed[buffer] = nil, nil
			sync_hook()
		end)
	end,
}

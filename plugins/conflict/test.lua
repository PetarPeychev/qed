local T = {}

local RESOLVE = "Conflict: Resolve"

local TWO_WAY = "top\n<<<<<<< HEAD\nkeep a\n=======\nkeep b\n>>>>>>> branch\ntail"
local DIFF3 = "<<<<<<< HEAD\nours\n||||||| base\norig\n=======\ntheirs\n>>>>>>> branch"

local seq = 0

local function open(t, text)
	seq = seq + 1
	local b = t.open(("m%d.txt"):format(seq), text)
	t.step()
	return b
end

local function screen_has(t, needle)
	for y = 0, 23 do
		if t.screen(y):find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function decos(t, b)
	return table.concat(t.deco(b), "\n")
end

local function resolve(t, b, row, choice)
	qed.buf.set_cursor(b, {row = row, col = 1})
	qed.run(RESOLVE)
	t.wait(function() return t.ui() ~= nil end)
	for _ = 2, choice do
		t.key("Down")
	end
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	return qed.buf.text(b)
end

function T.detects_two_way(t)
	local b = open(t, TWO_WAY)
	t.eq(decos(t, b), table.concat({
		"tint 2-2 conflict_ours conflict_marker",
		"span 2:1-2:13 fg=conflict_ours bg=-",
		"tint 3-3 conflict_ours conflict",
		"tint 4-4 conflict_theirs conflict_marker",
		"span 4:1-4:8 fg=conflict_theirs bg=-",
		"tint 5-5 conflict_theirs conflict",
		"tint 6-6 conflict_theirs conflict_marker",
		"span 6:1-6:15 fg=conflict_theirs bg=-",
		"span 3:6-3:7 fg=- bg=conflict_ours conflict_word",
		"span 5:6-5:7 fg=- bg=conflict_theirs conflict_word",
	}, "\n"))
end

function T.detects_diff3(t)
	local b = open(t, DIFF3)
	t.eq(decos(t, b), table.concat({
		"tint 1-1 conflict_ours conflict_marker",
		"span 1:1-1:13 fg=conflict_ours bg=-",
		"tint 2-2 conflict_ours conflict",
		"tint 3-3 conflict_base conflict_marker",
		"span 3:1-3:13 fg=conflict_base bg=-",
		"tint 4-4 conflict_base conflict",
		"tint 5-5 conflict_theirs conflict_marker",
		"span 5:1-5:8 fg=conflict_theirs bg=-",
		"tint 6-6 conflict_theirs conflict",
		"tint 7-7 conflict_theirs conflict_marker",
		"span 7:1-7:15 fg=conflict_theirs bg=-",
		"span 2:1-2:3 fg=- bg=conflict_ours conflict_word",
		"span 6:1-6:5 fg=- bg=conflict_theirs conflict_word",
	}, "\n"))
end

function T.ignores_incomplete_and_lookalikes(t)
	local b = open(t, "<<<<<<< HEAD\nours\nno closing marker\n<<<<<<<<\n=======x\n>>>>>>>")
	t.eq(decos(t, b), "")
	b = open(t, "<<<<<<< a\n<<<<<<< b\nx\n=======\ny\n>>>>>>>")
	t.eq(t.deco(b)[1], "tint 2-2 conflict_ours conflict_marker", "a second start restarts the block")
end

function T.word_pairs_follow_the_line_diff(t)
	local b = open(t, "<<<<<<<\nsame\nold one\n=======\nsame\nnew one\nextra\n>>>>>>>")
	local spans = {}
	for _, d in ipairs(t.deco(b)) do
		if d:find("conflict_word") then
			spans[#spans + 1] = d
		end
	end
	t.eq(table.concat(spans, "\n"), "span 3:1-3:4 fg=- bg=conflict_ours conflict_word\nspan 6:1-6:4 fg=- bg=conflict_theirs conflict_word")
end

function T.rescans_as_the_buffer_changes(t)
	local b = open(t, TWO_WAY)
	qed.buf.set_cursor(b, {row = 1, col = 1})
	t.type("x\n")
	t.eq(t.deco(b)[1], "tint 3-3 conflict_ours conflict_marker", "decorations move down with the block")
	t.eq(#t.deco(b), 10)
	qed.buf.set_cursor(b, {row = 6, col = 7})
	t.type("!")
	t.eq(t.deco(b)[#t.deco(b)], "span 6:6-6:8 fg=- bg=conflict_theirs conflict_word", "the word span is recomputed on the edited row")
	qed.buf.set_cursor(b, {row = 5, col = 1})
	t.key("Backspace")
	t.eq(decos(t, b), "", "breaking the separator clears the block")
	t.key("Ctrl+z")
	t.eq(#t.deco(b), 10, "undo brings it back")
end

function T.tints_follow_edits_before_the_rescan(t)
	local b = open(t, TWO_WAY)
	qed.edit(b, function()
		qed.buf.insert(b, {row = 1, col = 1}, "a\nb\n")
	end)
	t.eq(t.deco(b)[1], "tint 4-4 conflict_ours conflict_marker", "core shifts the anchors")
end

function T.resolve_each_choice(t)
	local b = open(t, TWO_WAY)
	t.eq(resolve(t, b, 3, 1), "top\nkeep a\ntail")
	t.eq(decos(t, b), "", "decorations go with the block")
	t.eq(qed.buf.cursor(b).row, 2)
	b = open(t, TWO_WAY)
	t.eq(resolve(t, b, 2, 2), "top\nkeep b\ntail")
	b = open(t, TWO_WAY)
	t.eq(resolve(t, b, 6, 3), "top\nkeep a\nkeep b\ntail")
	t.eq(decos(t, b), "", "decorations go in the same flush as the edit")
	t.key("Ctrl+z")
	t.eq(qed.buf.text(b), TWO_WAY, "one undo step")
	t.eq(#t.deco(b), 10, "undo brings the highlight back")
end

function T.typed_conflict_highlights_on_save(t)
	local b = open(t, "plain")
	qed.buf.set_cursor(b, {row = 1, col = 6})
	t.type("\n<<<<<<< a\nx\n=======\ny\n>>>>>>> b")
	t.eq(decos(t, b), "", "a never-conflicted buffer runs no rescan while typing")
	t.key("Ctrl+s")
	t.eq(#t.deco(b), 10, "a save rescans")
	qed.buf.set_cursor(b, {row = 3, col = 1})
	t.type("!")
	local d = t.deco(b)
	t.eq(d[#d - 1], "span 3:1-3:3 fg=- bg=conflict_ours conflict_word", "armed now, edits rescan")
end

function T.reload_without_blocks_clears(t)
	local b = open(t, TWO_WAY)
	t.eq(#t.deco(b), 10)
	qed.fs.write(qed.buf.path(b), "top\nresolved\ntail")
	t.poll_disk()
	t.step()
	t.eq(qed.buf.text(b), "top\nresolved\ntail")
	t.eq(decos(t, b), "", "the reload clears the namespace")
end

function T.resolve_diff3(t)
	local b = open(t, DIFF3)
	t.eq(resolve(t, b, 1, 1), "ours")
	b = open(t, DIFF3)
	t.eq(resolve(t, b, 4, 2), "theirs")
	b = open(t, DIFF3)
	t.eq(resolve(t, b, 7, 3), "ours\ntheirs")
end

function T.resolve_esc_keeps_the_block(t)
	local b = open(t, TWO_WAY)
	qed.buf.set_cursor(b, {row = 3, col = 1})
	qed.run(RESOLVE)
	t.wait(function() return t.ui() ~= nil end)
	t.eq(t.ui().kind, "confirm")
	t.ok(screen_has(t, "Resolve merge conflict:"), "the dialog asks")
	t.eq(table.concat(t.ui().labels, ","), "Keep Ours,Keep Theirs,Keep Both")
	t.key("Esc")
	t.eq(qed.buf.text(b), TWO_WAY)
end

function T.outside_jumps_to_the_next_block(t)
	local b = open(t, "a\n<<<<<<<\nx\n=======\ny\n>>>>>>>\nb\n<<<<<<<\nx\n=======\ny\n>>>>>>>\nc")
	qed.buf.set_cursor(b, {row = 1, col = 1})
	t.key("Alt+m")
	t.eq(qed.buf.cursor(b).row, 2)
	qed.buf.set_cursor(b, {row = 7, col = 1})
	t.key("Alt+m")
	t.eq(qed.buf.cursor(b).row, 8)
	qed.buf.set_cursor(b, {row = 13, col = 1})
	t.key("Alt+m")
	t.eq(qed.buf.cursor(b).row, 2, "wraps to the first")
	t.ok(t.ui() == nil, "no dialog outside a block")
end

function T.no_conflicts_message(t)
	open(t, "plain")
	qed.run(RESOLVE)
	local text, level, source = t.message()
	t.eq(text, "No merge conflicts")
	t.eq(level, "info")
	t.eq(source, "Conflict")
end

function T.many_blocks(t)
	local parts = {}
	for i = 1, 200 do
		parts[#parts + 1] = ("<<<<<<< HEAD\nlocal v%d = %d\nshared\n=======\nlocal v%d = %d + 1\nshared\n>>>>>>> branch"):format(i, i, i, i)
		for k = 1, 93 do
			parts[#parts + 1] = ("line %d of %d"):format(k, i)
		end
	end
	local b = open(t, table.concat(parts, "\n"))
	t.eq(qed.buf.line_count(b), 20000)
	t.eq(#t.deco(b), 200 * 9)
	local before = decos(t, b)
	qed.buf.set_cursor(b, {row = 10000, col = 1})
	for _ = 1, 20 do
		t.type("z")
	end
	t.eq(decos(t, b), before, "typing outside the blocks re-pushes nothing")
	qed.buf.set_cursor(b, {row = 10002, col = 1})
	t.type("z")
	t.eq(#t.deco(b), 200 * 9 + 1, "typing in a block adds its ours span")
	qed.buf.set_cursor(b, {row = 10000, col = 1})
	t.type("<<<<<<< x\n")
	t.eq(#t.deco(b), 200 * 9 + 1, "an unmatched start inside filler changes nothing")
end

return T

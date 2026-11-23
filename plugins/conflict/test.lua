local tests = {}

local RESOLVE = "Conflict: Resolve"

local TWO_WAY = "top\n<<<<<<< HEAD\nkeep a\n=======\nkeep b\n>>>>>>> branch\ntail"
local DIFF3 = "<<<<<<< HEAD\nours\n||||||| base\norig\n=======\ntheirs\n>>>>>>> branch"

local seq = 0

local function open(test, text)
	seq = seq + 1
	local buffer = test.open(("m%d.txt"):format(seq), text)
	test.step()
	return buffer
end

local function screen_has(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function decos(test, buffer)
	return table.concat(test.deco(buffer), "\n")
end

local function resolve(test, buffer, row, choice)
	buffer:set_cursor({row = row, col = 1})
	qed.run(RESOLVE)
	test.wait(function() return test.ui() ~= nil end)
	for _ = 2, choice do
		test.key("Down")
	end
	test.key("Enter")
	test.wait(function() return test.ui() == nil end)
	return buffer:text()
end

function tests.detects_two_way(test)
	local buffer = open(test, TWO_WAY)
	test.eq(decos(test, buffer), table.concat({
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

function tests.detects_diff3(test)
	local buffer = open(test, DIFF3)
	test.eq(decos(test, buffer), table.concat({
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

function tests.ignores_incomplete_and_lookalikes(test)
	local buffer = open(test, "<<<<<<< HEAD\nours\nno closing marker\n<<<<<<<<\n=======x\n>>>>>>>")
	test.eq(decos(test, buffer), "")
	buffer = open(test, "<<<<<<< a\n<<<<<<< b\nx\n=======\ny\n>>>>>>>")
	test.eq(test.deco(buffer)[1], "tint 2-2 conflict_ours conflict_marker", "a second start restarts the block")
end

function tests.word_pairs_follow_the_line_diff(test)
	local buffer = open(test, "<<<<<<<\nsame\nold one\n=======\nsame\nnew one\nextra\n>>>>>>>")
	local spans = {}
	for _, decorations in ipairs(test.deco(buffer)) do
		if decorations:find("conflict_word") then
			spans[#spans + 1] = decorations
		end
	end
	test.eq(table.concat(spans, "\n"), "span 3:1-3:4 fg=- bg=conflict_ours conflict_word\nspan 6:1-6:4 fg=- bg=conflict_theirs conflict_word")
end

function tests.rescans_as_the_buffer_changes(test)
	local buffer = open(test, TWO_WAY)
	buffer:set_cursor({row = 1, col = 1})
	test.type("x\n")
	test.eq(test.deco(buffer)[1], "tint 3-3 conflict_ours conflict_marker", "decorations move down with the block")
	test.eq(#test.deco(buffer), 10)
	buffer:set_cursor({row = 6, col = 7})
	test.type("!")
	test.eq(test.deco(buffer)[#test.deco(buffer)], "span 6:6-6:8 fg=- bg=conflict_theirs conflict_word", "the word span is recomputed on the edited row")
	buffer:set_cursor({row = 5, col = 1})
	test.key("Backspace")
	test.eq(decos(test, buffer), "", "breaking the separator clears the block")
	test.key("Ctrl+z")
	test.eq(#test.deco(buffer), 10, "undo brings it back")
end

function tests.tints_follow_edits_before_the_rescan(test)
	local buffer = open(test, TWO_WAY)
	qed.edit(buffer, function()
		buffer:insert({row = 1, col = 1}, "a\nb\n")
	end)
	test.eq(test.deco(buffer)[1], "tint 4-4 conflict_ours conflict_marker", "core shifts the anchors")
end

function tests.resolve_each_choice(test)
	local buffer = open(test, TWO_WAY)
	test.eq(resolve(test, buffer, 3, 1), "top\nkeep a\ntail")
	test.eq(decos(test, buffer), "", "decorations go with the block")
	test.eq(buffer:cursor().row, 2)
	buffer = open(test, TWO_WAY)
	test.eq(resolve(test, buffer, 2, 2), "top\nkeep b\ntail")
	buffer = open(test, TWO_WAY)
	test.eq(resolve(test, buffer, 6, 3), "top\nkeep a\nkeep b\ntail")
	test.eq(decos(test, buffer), "", "decorations go in the same flush as the edit")
	test.key("Ctrl+z")
	test.eq(buffer:text(), TWO_WAY, "one undo step")
	test.eq(#test.deco(buffer), 10, "undo brings the highlight back")
end

function tests.typed_conflict_highlights_on_save(test)
	local buffer = open(test, "plain")
	buffer:set_cursor({row = 1, col = 6})
	test.type("\n<<<<<<< a\nx\n=======\ny\n>>>>>>> b")
	test.eq(decos(test, buffer), "", "a never-conflicted buffer runs no rescan while typing")
	test.key("Ctrl+s")
	test.eq(#test.deco(buffer), 10, "a save rescans")
	buffer:set_cursor({row = 3, col = 1})
	test.type("!")
	local decorations = test.deco(buffer)
	test.eq(decorations[#decorations - 1], "span 3:1-3:3 fg=- bg=conflict_ours conflict_word", "armed now, edits rescan")
end

function tests.save_after_resolving_disarms(test)
	local buffer = open(test, TWO_WAY)
	resolve(test, buffer, 3, 1)
	test.key("Ctrl+s")
	buffer:set_cursor({row = 3, col = 5})
	test.type("\n<<<<<<< a\nx\n=======\ny\n>>>>>>> b")
	test.eq(decos(test, buffer), "", "a save with no blocks left disarms the buffer")
	test.key("Ctrl+s")
	test.eq(#test.deco(buffer), 10, "the next save finds the new block")
end

function tests.reload_without_blocks_clears(test)
	local buffer = open(test, TWO_WAY)
	test.eq(#test.deco(buffer), 10)
	qed.fs.write(buffer:path(), "top\nresolved\ntail")
	test.poll_disk()
	test.step()
	test.eq(buffer:text(), "top\nresolved\ntail")
	test.eq(decos(test, buffer), "", "the reload clears the namespace")
end

function tests.resolve_diff3(test)
	local buffer = open(test, DIFF3)
	test.eq(resolve(test, buffer, 1, 1), "ours")
	buffer = open(test, DIFF3)
	test.eq(resolve(test, buffer, 4, 2), "theirs")
	buffer = open(test, DIFF3)
	test.eq(resolve(test, buffer, 7, 3), "ours\ntheirs")
end

function tests.resolve_esc_keeps_the_block(test)
	local buffer = open(test, TWO_WAY)
	buffer:set_cursor({row = 3, col = 1})
	qed.run(RESOLVE)
	test.wait(function() return test.ui() ~= nil end)
	test.eq(test.ui().kind, "confirm")
	test.ok(screen_has(test, "Resolve merge conflict:"), "the dialog asks")
	test.eq(table.concat(test.ui().labels, ","), "Keep Ours,Keep Theirs,Keep Both")
	test.key("Esc")
	test.eq(buffer:text(), TWO_WAY)
end

function tests.outside_jumps_to_the_next_block(test)
	local buffer = open(test, "a\n<<<<<<<\nx\n=======\ny\n>>>>>>>\nb\n<<<<<<<\nx\n=======\ny\n>>>>>>>\nc")
	buffer:set_cursor({row = 1, col = 1})
	test.key("Alt+m")
	test.eq(buffer:cursor().row, 2)
	buffer:set_cursor({row = 7, col = 1})
	test.key("Alt+m")
	test.eq(buffer:cursor().row, 8)
	buffer:set_cursor({row = 13, col = 1})
	test.key("Alt+m")
	test.eq(buffer:cursor().row, 2, "wraps to the first")
	test.ok(test.ui() == nil, "no dialog outside a block")
end

function tests.no_conflicts_message(test)
	open(test, "plain")
	qed.run(RESOLVE)
	local text, level, source = test.message()
	test.eq(text, "No merge conflicts")
	test.eq(level, "info")
	test.eq(source, "Conflict")
end

function tests.many_blocks(test)
	local parts = {}
	for i = 1, 200 do
		parts[#parts + 1] = ("<<<<<<< HEAD\nlocal v%d = %d\nshared\n=======\nlocal v%d = %d + 1\nshared\n>>>>>>> branch"):format(i, i, i, i)
		for key = 1, 93 do
			parts[#parts + 1] = ("line %d of %d"):format(key, i)
		end
	end
	local buffer = open(test, table.concat(parts, "\n"))
	test.eq(buffer:line_count(), 20000)
	test.eq(#test.deco(buffer), 200 * 9)
	local before = decos(test, buffer)
	buffer:set_cursor({row = 10000, col = 1})
	for _ = 1, 20 do
		test.type("z")
	end
	test.eq(decos(test, buffer), before, "typing outside the blocks re-pushes nothing")
	buffer:set_cursor({row = 10002, col = 1})
	test.type("z")
	test.eq(#test.deco(buffer), 200 * 9 + 1, "typing in a block adds its ours span")
	buffer:set_cursor({row = 10000, col = 1})
	test.type("<<<<<<< x\n")
	test.eq(#test.deco(buffer), 200 * 9 + 1, "an unmatched start inside filler changes nothing")
end

return tests

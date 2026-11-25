local tests = {}

local function on_screen(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function current(test)
	return qed.plugin("markdown").state()
end

local function long_doc()
	local parts = {"# Title", ""}
	for i = 1, 80 do
		parts[#parts + 1] = ("para %d with **bold**"):format(i)
		parts[#parts + 1] = ""
	end
	return table.concat(parts, "\n")
end

local function open(test)
	test.key("Alt+p")
	test.wait(function() local ui = current(test); return ui ~= nil and ui.rows > 0 and ui.body_h > 0 end)
	return current(test)
end

function tests.toggle_renders(test)
	test.open("doc.md", "# Title\n\nsome **bold** text\n\n- item")
	local ui = open(test)
	test.eq(ui.kind, "pane")
	test.ok(on_screen(test, "Title"), "the heading renders")
	test.ok(on_screen(test, "━━━"), "H1 gets a rule")
	test.ok(on_screen(test, "some bold text"), "bold markers hidden")
	test.ok(on_screen(test, "• item"), "bullet")
	test.ok(on_screen(test, "doc.md"), "title")
	test.key("Alt+p")
	test.wait(function() return current(test) == nil end)
end

function tests.not_for_other_languages(test)
	test.open("notes.txt", "# not markdown")
	test.key("Alt+p")
	test.pump(50)
	test.eq(current(test), nil, "no preview for a plain text buffer")
	test.open("yes.md", "# md")
	open(test)
	test.key("Esc")
end

function tests.scroll_keys(test)
	test.open("long.md", long_doc())
	local ui = open(test)
	test.ok(ui.rows > 100, "many rendered rows")
	test.key("PgDn")
	test.ok(current(test).offset > 0, "PgDn scrolls")
	test.key("End")
	local bottom = current(test).offset
	test.ok(bottom > 20, "End jumps to the bottom")
	test.ok(on_screen(test, "para 80 with bold"), "End shows the last line")
	test.key("Up")
	test.eq(current(test).offset, bottom - 1, "Up scrolls one row")
	test.key("Home")
	test.eq(current(test).offset, 0, "Home")
	test.key("Esc")
end

function tests.live_update_keeps_scroll(test)
	local buffer = test.open("live.md", long_doc())
	local ui = open(test)
	test.key("PgDn")
	test.key("PgDn")
	local scroll = current(test).offset
	test.ok(scroll > 0, "scrolled")
	buffer:insert({row = 1, col = 1}, "Intro line\n\n")
	test.wait(function() return current(test).rows == ui.rows + 2 end)
	test.eq(current(test).offset, scroll, "the scroll position is kept")
	test.key("Home")
	test.ok(on_screen(test, "Intro line"), "the new text renders")
	test.key("Esc")
end

local function body_y(test, needle)
	local ui = current(test)
	for screen_row = ui.body_y, ui.body_y + ui.body_h - 1 do
		if test.screen(screen_row):find(needle, 1, true) then
			return screen_row
		end
	end
end

local function para_row(i)
	return 2 * i + 1
end

local function expect_synced(test, buffer, i, why)
	local ui = open(test)
	local screen_row = body_y(test, ("para %d with"):format(i))
	test.ok(screen_row ~= nil, why .. ": the cursor's block is shown")
	test.eq(screen_row + 1, math.max(buffer:screen_row(), ui.body_y + 1), why .. ": on the cursor line's terminal row, or the body top")
	test.key("Esc")
end

function tests.open_syncs_to_cursor(test)
	local buffer = test.open("sync.md", long_doc())
	buffer:set_cursor({row = para_row(3), col = 1})
	expect_synced(test, buffer, 3, "near the top")
	buffer:set_cursor({row = para_row(40), col = 1})
	buffer:set_screen_row(para_row(40), 8)
	expect_synced(test, buffer, 40, "middle")
	buffer:set_cursor({row = para_row(40), col = 5})
	buffer:set_screen_row(para_row(40), 1)
	expect_synced(test, buffer, 40, "editor top")
	buffer:set_cursor({row = para_row(80), col = 1})
	local ui = open(test)
	test.eq(ui.offset, ui.rows - ui.body_h, "near the end the preview stops at the bottom")
	test.ok(on_screen(test, "para 80 with"), "the last block is shown")
	test.key("Esc")
end

function tests.sync_keeps_the_terminal_row(test)
	local buffer = test.open("rows.md", long_doc())
	buffer:set_cursor({row = para_row(40), col = 1})
	buffer:set_screen_row(para_row(40), 12)
	local ui = open(test)
	test.ok(ui.body_y > 0, "the body starts below the box top")
	test.eq(body_y(test, "para 40 with"), 11, "the block is on the cursor line's terminal row")
	test.key("Down")
	test.key("Down")
	test.eq(body_y(test, "para 41 with"), 11, "two rows down, the next block is there")
	test.key("Esc")
	test.wait(function() return buffer:cursor().row ~= para_row(40) end)
	test.eq(buffer:cursor().row, para_row(41), "the cursor is on the line now under that terminal row")
	test.eq(test.caret_row(), 12, "on the same terminal row")
end

function tests.open_clamps_at_start(test)
	local parts = {}
	for i = 1, 10 do
		parts[#parts + 1] = ("[r%d]: https://x.y/%d"):format(i, i)
	end
	parts[#parts + 1] = ""
	parts[#parts + 1] = "first para"
	local buffer = test.open("refs.md", table.concat(parts, "\n") .. "\n\n" .. long_doc())
	buffer:set_cursor({row = 12, col = 1})
	test.eq(test.caret_row(), 12, "the cursor is low on screen")
	local ui = open(test)
	test.eq(ui.offset, 0, "the preview cannot scroll above the document")
	test.eq(body_y(test, "first para"), ui.body_y, "the block is at the top")
	test.key("Esc")
end

function tests.code_block_lines_sync_exactly(test)
	local parts = {"# Code", "", "```"}
	for i = 1, 60 do
		parts[#parts + 1] = ("  code line %d;"):format(i)
	end
	parts[#parts + 1] = "```"
	parts[#parts + 1] = ""
	parts[#parts + 1] = "tail"
	local buffer = test.open("code.md", table.concat(parts, "\n"))
	buffer:set_cursor({row = 33, col = 1})
	buffer:set_screen_row(33, 10)
	local ui = open(test)
	test.eq(body_y(test, "code line 30;"), 9, "the cursor's code line, not the block start, is on the cursor's terminal row")
	test.key("PgDn")
	local number = test.screen(9):match("code line (%d+);")
	test.ok(number ~= nil, "a code line on the cursor's row")
	test.key("Esc")
	test.wait(function() return buffer:cursor().row ~= 33 end)
	test.eq(buffer:cursor().row, 3 + tonumber(number), "the cursor is on that code line")
	test.eq(buffer:cursor().col, 3, "at its first non-blank column")
	test.eq(test.caret_row(), 10, "at the same screen row")
end

function tests.close_without_scroll_keeps_cursor(test)
	local buffer = test.open("keep.md", long_doc())
	buffer:set_cursor({row = para_row(30), col = 4})
	buffer:set_screen_row(para_row(30), 6)
	open(test)
	test.key("Esc")
	test.wait(function() return current(test) == nil end)
	test.pump(20)
	test.eq(buffer:cursor().row, para_row(30), "the cursor row is untouched")
	test.eq(buffer:cursor().col, 4, "the cursor col is untouched")
	test.eq(test.caret_row(), 6, "the editor view is untouched")
end

function tests.close_after_scroll_moves_cursor(test)
	local buffer = test.open("move.md", long_doc())
	buffer:set_cursor({row = para_row(10), col = 4})
	buffer:set_screen_row(para_row(10), 8)
	local ui = open(test)
	local before = ui.offset
	test.key("PgDn")
	test.ok(current(test).offset > before, "scrolled")
	local number
	for screen_row = 7, ui.body_y, -1 do
		number = test.screen(screen_row):match("para (%d+) with")
		if number then
			break
		end
	end
	test.ok(number ~= nil, "a block at or above the cursor's screen row")
	test.key("Esc")
	test.wait(function() return current(test) == nil end)
	test.wait(function() return buffer:cursor().row ~= para_row(10) end)
	test.eq(buffer:cursor().row, para_row(tonumber(number)), "the cursor is on that block's source line")
	test.eq(buffer:cursor().col, 1, "at its first non-blank column")
	test.eq(test.caret_row(), 8, "at the same screen row")
end

function tests.max_width(test)
	test.open("w.md", "# W\n\ntext")
	test.eq(open(test).width, 80 - 2 * 8, "the default cap is wider than the screen")
	test.key("Esc")
end

local function pad(body)
	return "\n\n\n\n\n\n" .. body
end

function tests.close_after_anchor_goes_to_first_non_blank(test)
	local parts = {"[go-there](#target)", ""}
	for i = 1, 60 do
		parts[#parts + 1] = "filler " .. i
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = "  ## Target"
	for i = 1, 30 do
		parts[#parts + 1] = ""
		parts[#parts + 1] = "body " .. i
	end
	local buffer = test.open("anchor-sync.md", pad(table.concat(parts, "\n")))
	local top = open(test).body_y
	test.click("go-there")
	test.ok(current(test).offset > 0, "the anchor scrolls")
	test.key("Esc")
	test.wait(function() return buffer:cursor().row ~= 1 end)
	test.eq(buffer:cursor().row, 129, "the cursor is on the heading")
	test.eq(buffer:cursor().col, 3, "at its first non-blank column")
	test.eq(test.caret_row(), top + 1, "on the terminal row it showed on, the body top")
end

function tests.anchor_link_scrolls(test)
	local parts = {"intro [jump-to-second](#second-part)", ""}
	for i = 1, 60 do
		parts[#parts + 1] = "filler " .. i
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = "## Second part"
	parts[#parts + 1] = ""
	parts[#parts + 1] = "tail text"
	test.open("anchors.md", pad(table.concat(parts, "\n")))
	open(test)
	test.click("jump-to-second")
	test.ok(current(test).offset > 0, "the anchor scrolls the preview")
	test.ok(on_screen(test, "tail text"), "the heading is in view")
	test.key("Esc")
end

function tests.file_link_opens_heading(test)
	local other = qed.path.join(qed.root(), "docs/other.md")
	qed.fs.write(other, "# Top\n\ntext\n\n## Deep Dive\n\nbody\n\n## Deep Dive\n\nsecond")
	test.open("links.md", pad("see [the-other-doc](docs/other.md#deep-dive-1) here"))
	open(test)
	local from = qed.buf.current()
	test.click("the-other-doc")
	test.wait(function() return qed.buf.current():path() == other end)
	test.wait(function() return qed.buf.current():cursor().row == 9 end)
	test.eq(qed.buf.current():cursor().row, 9, "the editor is on the second Deep Dive heading once it renders")
	test.ok(current(test) ~= nil, "a markdown link keeps the preview open")
	test.ok(on_screen(test, "other.md"), "the preview shows the linked file")
	test.ok(on_screen(test, "second"), "the anchor's section is in view")
	test.key("Esc")
	test.key("Alt+,")
	test.eq(qed.buf.current(), from, "the switch is in the jump list")
end

function tests.other_file_link_closes(test)
	qed.fs.write(qed.path.join(qed.root(), "notes.txt"), "one\ntwo\n")
	test.open("tx.md", pad("see [the-notes](notes.txt) here"))
	open(test)
	test.click("the-notes")
	test.wait(function() return current(test) == nil end)
	test.eq(qed.path.base(qed.buf.current():path()), "notes.txt", "a non-markdown file opens in the editor")
end

function tests.url_link_opens_url(test)
	test.open("urls.md", pad("visit [the-site](https://example.com/x) now"))
	open(test)
	test.click("the-site")
	test.wait(function() return test.log_has("debug", "", "Open URL: https://example.com/x") end)
	test.ok(current(test) ~= nil, "the preview stays open")
	test.key("Esc")
end

function tests.back_forward_anchor(test)
	local parts = {"intro [jump-to-second](#second-part)", ""}
	for i = 1, 60 do
		parts[#parts + 1] = "filler " .. i
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = "## Second part"
	test.open("hist.md", pad(table.concat(parts, "\n")))
	open(test)
	test.click("jump-to-second")
	local deep = current(test).offset
	test.ok(deep > 0, "the anchor scrolls")
	test.key("Alt+,")
	test.eq(current(test).offset, 0, "Back returns to where the jump started")
	test.key("Alt+.")
	test.eq(current(test).offset, deep, "Forward goes to the anchor again")
	test.key("Alt+.")
	test.eq(current(test).offset, deep, "Forward past the end does nothing")
	test.key("Esc")
end

function tests.back_forward_files(test)
	local other = qed.path.join(qed.root(), "other.md")
	qed.fs.write(other, "# Other doc\n\nbody")
	local from = test.open("first.md", pad("see [the-other-doc](other.md) here"))
	open(test)
	test.click("the-other-doc")
	test.wait(function() return qed.buf.current():path() == other end)
	test.ok(on_screen(test, "Other doc"), "the linked doc shows")
	test.key("Alt+,")
	test.wait(function() return qed.buf.current() == from end)
	test.ok(current(test) ~= nil and on_screen(test, "first.md"), "Back shows the first doc again")
	test.key("Alt+.")
	test.wait(function() return qed.buf.current():path() == other end)
	test.ok(on_screen(test, "Other doc"), "Forward shows the linked doc")
	test.key("Esc")
	test.key("Alt+,")
	test.eq(qed.buf.current(), from, "the file switches are in the editor jump list")
end

function tests.back_forward_scoped(test)
	test.open("sc.md", "# Doc")
	local ui = open(test)
	test.eq(ui.kind, "pane")
	test.key("Ctrl+p")
	test.type("markdown: back")
	test.ok(on_screen(test, "Markdown: Back"), "Ctrl+P opens the scoped palette over the preview")
	test.key("Enter")
	test.ok(current(test) ~= nil, "running Back from it returns to the preview")
	test.key("Esc")
end

local function prose_doc()
	local parts = {"# Prose", ""}
	for i = 1, 30 do
		parts[#parts + 1] = ("## Part %d"):format(i)
		parts[#parts + 1] = ""
		parts[#parts + 1] = ("Part %d opens a paragraph that runs"):format(i)
		parts[#parts + 1] = "over three source lines and wraps"
		parts[#parts + 1] = ("in the preview, closing part %d."):format(i)
		parts[#parts + 1] = ""
	end
	return table.concat(parts, "\n")
end

local function focused_preview()
	for _, scope in ipairs(qed.ui.focus_scopes()) do
		if scope == "markdown" then
			return true
		end
	end
	return false
end

local function toggle_split(test)
	qed.run("Markdown: Toggle Split")
	test.screen(0)
end

local function open_split(test)
	toggle_split(test)
	test.wait(function() local ui = current(test); return ui ~= nil and ui.rows > 0 and ui.source ~= nil end)
	return current(test)
end

local function preview_row(test, row)
	return test.screen(row):match("│ *(.*)$") or ""
end

-- editor to preview rounds to a whole rendered row (at most half a row, under a source line in these docs), preview
-- to editor floors to a whole sub-row of an unwrapped line (under one source line): either way under a line apart
local function expect_aligned(test, buffer, why)
	test.pump(20)
	local ui = current(test)
	test.ok(ui ~= nil and ui.source ~= nil, why .. ": rendered")
	local top = buffer:top_row()
	test.ok(math.abs(ui.source - top) < 1, ("%s: preview top %.2f, editor top %.2f"):format(why, ui.source, top))
	return top, ui.offset
end

local function expect_still(test, buffer, why)
	local top, offset = buffer:top_row(), current(test).offset
	for _ = 1, 5 do
		test.pump(10)
		test.screen(0)
	end
	test.eq(buffer:top_row(), top, why .. ": the editor stays")
	test.eq(current(test).offset, offset, why .. ": the preview stays")
end

function tests.split_toggles_and_follows_markdown_buffers(test)
	local doc = test.open("split.md", "# Split\n\nsome **bold** text")
	local ui = open_split(test)
	test.eq(ui.kind, "split")
	test.eq(ui.width, 40, "half the editor row")
	test.eq(ui.body_x, 40, "right of the editor and its rule")
	test.ok(test.screen(0):find("│ Split", 1, true) ~= nil, "a rule between the editor and the preview")
	test.ok(on_screen(test, "some bold text"), "rendered")
	test.type("x")
	test.eq(doc:line(1), "x# Split", "typing goes to the editor")
	test.wait(function() return preview_row(test, 0):find("x# Split", 1, true) ~= nil end)
	local notes = test.open("notes.txt", "plain text")
	test.wait(function() return current(test) == nil end)
	test.ok(test.screen(0):find("│", 1, true) == nil, "a plain buffer gets the full width")
	qed.jump(doc, {row = 1, col = 1})
	test.wait(function() return current(test) ~= nil end)
	test.eq(current(test).kind, "split", "back on a markdown buffer the split returns")
	qed.jump(notes, {row = 1, col = 1})
	test.wait(function() return current(test) == nil end)
	toggle_split(test)
	qed.jump(doc, {row = 1, col = 1})
	test.pump(30)
	test.eq(current(test), nil, "toggled off from the plain buffer, it stays off")
	toggle_split(test)
	test.wait(function() return current(test) ~= nil end)
	toggle_split(test)
	test.wait(function() return current(test) == nil end)
	test.ok(test.screen(0):find("│", 1, true) == nil, "toggled off, the editor is full width again")
end

function tests.split_syncs_both_ways(test)
	local buffer = test.open("sync-split.md", prose_doc())
	open_split(test)
	expect_aligned(test, buffer, "opened")
	local cursor = buffer:cursor()
	local last_top, last_offset = buffer:top_row(), current(test).offset
	for round = 1, 3 do
		test.wheel(5, 5, "down")
		local top, offset = expect_aligned(test, buffer, "editor wheel " .. round)
		test.ok(top > last_top and offset > last_offset, "editor wheel " .. round .. ": both move down")
		-- three source lines span at most a heading (3 rows for 2 lines) and a paragraph line, plus a rounding row
		test.ok(offset - last_offset <= 5, ("editor wheel %d: no lurch (%d rows)"):format(round, offset - last_offset))
		expect_still(test, buffer, "editor wheel " .. round)
		last_top, last_offset = top, offset
		test.wheel(60, 5, "down")
		top, offset = expect_aligned(test, buffer, "preview wheel " .. round)
		test.ok(top > last_top and offset > last_offset, "preview wheel " .. round .. ": both move down")
		test.eq(offset - last_offset, 3, "preview wheel " .. round .. ": the preview moves by the wheel")
		expect_still(test, buffer, "preview wheel " .. round)
		last_top, last_offset = top, offset
	end
	test.click(60, 5)
	for round = 1, 3 do
		test.key("Down")
		local top, offset = expect_aligned(test, buffer, "preview key " .. round)
		test.eq(offset, last_offset + 1, "preview key " .. round .. ": one row")
		test.ok(top >= last_top, "preview key " .. round .. ": the editor never moves back")
		last_top, last_offset = top, offset
		test.wheel(5, 5, "up")
		top, offset = expect_aligned(test, buffer, "editor wheel up " .. round)
		test.ok(top < last_top and offset < last_offset, "editor wheel up " .. round .. ": both move up")
		last_top, last_offset = top, offset
	end
	expect_still(test, buffer, "settled")
	test.eq(buffer:cursor().row, cursor.row, "the cursor never moves")
	test.eq(buffer:cursor().col, cursor.col, "the cursor col never moves")
end

function tests.split_cursor_moves_sync_only_when_they_scroll(test)
	local buffer = test.open("cursor-split.md", prose_doc())
	open_split(test)
	local offset = current(test).offset
	test.key("Down")
	test.key("Down")
	expect_still(test, buffer, "a move inside the view")
	test.eq(current(test).offset, offset, "the preview does not follow the cursor")
	buffer:set_cursor({row = 120, col = 1})
	test.wait(function() return buffer:top_row() > 50 end)
	expect_aligned(test, buffer, "a jump that scrolls")
end

function tests.split_wrapped_top_row(test)
	local long = {}
	for i = 1, 40 do
		long[#long + 1] = "word" .. i
	end
	local parts = {"# Wrapped", ""}
	for i = 1, 20 do
		parts[#parts + 1] = ("Para %d "):format(i) .. table.concat(long, " ")
		parts[#parts + 1] = ""
	end
	local buffer = test.open("wrap-split.md", table.concat(parts, "\n"))
	open_split(test)
	test.wheel(5, 5, "down")
	local top = buffer:top_row()
	test.ok(top % 1 ~= 0, ("the editor top is inside a wrapped line (%.2f)"):format(top))
	expect_aligned(test, buffer, "wrapped editor top")
	test.wheel(60, 5, "down")
	expect_aligned(test, buffer, "wrapped preview scroll")
end

function tests.split_resize_reanchors(test)
	local parts = {}
	for i = 1, 40 do
		parts[#parts + 1] = ("## Short %d"):format(i)
		parts[#parts + 1] = ""
		for _ = 1, 4 do
			parts[#parts + 1] = "short words that"
		end
		parts[#parts + 1] = ""
	end
	-- source lines too short to wrap in the editor: only the preview re-wraps
	local buffer = test.open("resize-split.md", table.concat(parts, "\n"))
	open_split(test)
	buffer:set_cursor({row = 150, col = 1})
	test.wait(function() return buffer:top_row() > 100 end)
	local top = expect_aligned(test, buffer, "before")
	test.resize(60, 24)
	test.wait(function() return current(test).width == 30 end)
	test.screen(0)
	test.eq(buffer:top_row(), top, "the editor keeps its top")
	expect_aligned(test, buffer, "narrower")
	test.resize(80, 24)
	test.wait(function() return current(test).width == 40 end)
	test.screen(0)
	expect_aligned(test, buffer, "back")
end

function tests.split_focus_keys_and_esc(test)
	local buffer = test.open("focus-split.md", prose_doc())
	open_split(test)
	test.ok(not focused_preview(), "the editor keeps the focus")
	local rev = buffer:rev()
	test.click(60, 5)
	test.ok(focused_preview(), "a click on the preview focuses it")
	local offset = current(test).offset
	test.key("Down")
	test.eq(current(test).offset, offset + 1, "Down scrolls the preview")
	test.type("x")
	test.eq(buffer:rev(), rev, "typing does not reach the editor")
	test.key("Esc")
	test.ok(not focused_preview(), "Esc returns the focus to the editor")
	test.ok(current(test) ~= nil, "the split stays")
	test.type("y")
	test.ok(buffer:rev() ~= rev, "typing edits again")
	test.click(60, 5)
	test.ok(focused_preview(), "focused again")
	test.click(5, 5)
	test.ok(not focused_preview(), "a click on the editor takes the focus back")
end

function tests.split_launch_option_and_hot_reload(test)
	test.config{split = true}
	local buffer = test.open("hot.md", prose_doc())
	test.wait(function() local ui = current(test); return ui ~= nil and ui.kind == "split" and ui.width == 40 end)
	test.eq(current(test).kind, "split", "split = true opens the split at launch")
	test.config({split = true, split_width = 30}, {hot = true})
	test.wait(function() return current(test).width == 24 end)
	test.eq(current(test).body_x, 56, "30% of the row")
	expect_aligned(test, buffer, "after the width change")
	toggle_split(test)
	test.wait(function() return current(test) == nil end)
	test.config({split = true, split_width = 40}, {hot = true})
	test.pump(30)
	test.screen(0)
	test.eq(current(test), nil, "a reload that leaves split alone keeps the session's toggle")
	test.config({split = false, split_width = 40}, {hot = true})
	test.pump(30)
	test.eq(current(test), nil, "split turned off: still off")
	test.config({split = true, split_width = 40}, {hot = true})
	test.wait(function() local ui = current(test); return ui ~= nil and ui.width == 32 end)
	test.eq(current(test).kind, "split", "split turned on in the config: on")
end

function tests.split_toggle_does_not_write_config(test)
	local buffer = test.open("nowrite.md", "# No write")
	toggle_split(test)
	test.wait(function() return current(test) ~= nil end)
	local path = test.config_path()
	test.ok(not qed.fs.exists(path) or not qed.fs.read(path):find("split"), "the session toggle writes no config")
	toggle_split(test)
	test.wait(function() return current(test) == nil end)
	test.ok(buffer:valid(), "the buffer stays")
end

function tests.overlay_over_split(test)
	local buffer = test.open("both.md", prose_doc())
	open_split(test)
	buffer:set_cursor({row = 60, col = 1})
	test.wait(function() return buffer:top_row() > 20 end)
	expect_aligned(test, buffer, "split before the overlay")
	local split_offset = qed.plugin("markdown").state("split").offset
	test.key("Alt+p")
	test.wait(function() local ui = qed.plugin("markdown").state("overlay"); return ui ~= nil and ui.rows > 0 end)
	test.eq(current(test).kind, "pane", "Alt+p opens the overlay")
	test.ok(qed.plugin("markdown").state("split") ~= nil, "the split stays mounted behind it")
	test.ok(focused_preview(), "the overlay takes the focus")
	local overlay_offset = current(test).offset
	test.key("PgDn")
	test.ok(current(test).offset > overlay_offset, "keys scroll the overlay")
	test.eq(qed.plugin("markdown").state("split").offset, split_offset, "not the split")
	test.key("Esc")
	test.wait(function() return qed.plugin("markdown").state("overlay") == nil end)
	test.ok(not focused_preview(), "focus is back in the editor")
	test.wait(function() return buffer:cursor().row ~= 60 end)
	test.ok(buffer:cursor().row > 60, "closing after a scroll syncs the editor")
	expect_aligned(test, buffer, "the split follows the editor")
	test.click(60, 5)
	test.key("Alt+p")
	test.wait(function() return qed.plugin("markdown").state("overlay") ~= nil end)
	test.key("Esc")
	test.wait(function() return qed.plugin("markdown").state("overlay") == nil end)
	test.ok(focused_preview(), "focus goes back to the split it came from")
end

function tests.split_close_buffers(test)
	local plain = test.open("keep.txt", "plain")
	local doc = test.open("closing.md", prose_doc())
	open_split(test)
	qed.close(doc)
	test.wait(function() return current(test) == nil end)
	test.eq(qed.buf.current(), plain, "the plain buffer shows")
	local other = test.open("again.md", "# Again")
	test.wait(function() return current(test) ~= nil end)
	test.ok(on_screen(test, "│ Again"), "still toggled on: the next markdown buffer previews")
	qed.close(other)
	qed.close(plain)
	test.wait(function() return #qed.buf.list() == 0 or current(test) == nil end)
	test.eq(current(test), nil, "no split on the welcome screen")
end

function tests.split_history(test)
	local other = qed.path.join(qed.root(), "other.md")
	qed.fs.write(other, "# Other doc\n\nbody")
	local third = test.open("third.md", "# Third doc")
	local first = test.open("first.md", "see [the-other-doc](other.md) here")
	open_split(test)
	test.click("the-other-doc here")
	test.wait(function() return qed.buf.current():path() == other end)
	test.wait(function() return on_screen(test, "Other doc") end)
	test.ok(focused_preview(), "a markdown link keeps the focus in the preview")
	test.key("Alt+,")
	test.wait(function() return qed.buf.current() == first end)
	test.key("Alt+.")
	test.wait(function() return qed.buf.current():path() == other end)
	qed.jump(third, {row = 1, col = 1})
	test.wait(function() return on_screen(test, "Third doc") end)
	test.click(60, 5)
	test.key("Alt+,")
	test.wait(function() return qed.buf.current():path() == other end)
	test.ok(on_screen(test, "Other doc"), "Back undoes a switch made in the editor")
	test.key("Alt+.")
	test.wait(function() return qed.buf.current() == third end)
end

function tests.split_back_when_the_jump_fails(test)
	qed.fs.mkdir(qed.path.join(qed.root(), "dir.md"))
	local first = test.open("from.md", "see [the-dir-link](dir.md) here")
	open_split(test)
	test.click("the-dir-link here")
	test.pump(30)
	test.eq(qed.buf.current(), first, "a link that cannot open stays put")
	test.ok(current(test) ~= nil, "the split stays")
	local nxt = test.open("next.md", "# Next doc")
	test.wait(function() return on_screen(test, "Next doc") end)
	test.click(60, 5)
	test.key("Alt+,")
	test.wait(function() return qed.buf.current() == first end)
	test.key("Alt+.")
	test.wait(function() return qed.buf.current() == nxt end)
end

function tests.split_top_row_round_trip(test)
	local long = {}
	for i = 1, 30 do
		long[#long + 1] = "word" .. i
	end
	local parts = {}
	for i = 1, 30 do
		parts[#parts + 1] = ("Para %d "):format(i) .. table.concat(long, " ")
	end
	local buffer = test.open("trip.md", table.concat(parts, "\n\n"))
	open_split(test)
	local subs = 0
	for _ = 1, 12 do
		test.wheel(5, 5, "down")
		local top = buffer:top_row()
		subs = subs + (top % 1 ~= 0 and 1 or 0)
		buffer:set_screen_row(top, 1)
		test.eq(buffer:top_row(), top, ("set_screen_row(top_row()) keeps %.4f"):format(top))
	end
	test.ok(subs >= 4, "several tops inside wrapped lines")
end

function tests.split_typing_keeps_the_preview(test)
	local long = {}
	for i = 1, 120 do
		long[#long + 1] = "word" .. i
	end
	local text = "# Long\n\n" .. table.concat(long, " ") .. "\n\nafter the long block\n\n" .. prose_doc()
	local buffer = test.open("long-block.md", text)
	qed.run("Toggle Line Wrap")
	open_split(test)
	buffer:set_cursor({row = 11, col = 1})
	test.wheel(60, 5, "down")
	test.wheel(60, 5, "down")
	local offset = current(test).offset
	test.eq(offset, 6, "the preview is inside the long block")
	test.ok(buffer:top_row() == 3, "the editor top is the block's line")
	test.ok(test.caret_row() ~= nil, "the caret is in view")
	local before = buffer:top_row()
	test.type("x")
	test.wait(function() return on_screen(test, "xPart 1 opens") end)
	test.ok(buffer:top_row() == before, "the keystroke does not scroll the editor")
	for _ = 1, 5 do
		test.pump(10)
		test.screen(0)
	end
	test.eq(current(test).offset, offset, "a keystroke does not snap the preview to the block start")
end

function tests.split_leading_lines_render_nothing(test)
	local text = "\n\n[ref]: https://x.y\n<!-- note -->\n\n# Title\n\n" .. prose_doc()
	local buffer = test.open("leading.md", text)
	open_split(test)
	test.ok(buffer:top_row() == 1, "the editor starts at row 1")
	test.ok(current(test).source == 1, "the preview top is source row 1")
	test.wheel(5, 5, "down")
	test.wheel(5, 5, "down")
	test.click(60, 5)
	test.key("Home")
	test.eq(current(test).offset, 0, "Home tops the preview")
	test.ok(buffer:top_row() == 1, "and shows the editor's leading rows again")
end

function tests.split_empty_doc(test)
	local buffer = test.open("empty.md", "")
	toggle_split(test)
	test.wait(function() return current(test) ~= nil end)
	test.wheel(5, 5, "down")
	test.wheel(60, 5, "down")
	test.click(60, 5)
	test.key("Down")
	test.key("Esc")
	test.eq(current(test).offset, 0, "nothing to scroll in the preview")
	test.ok(buffer:top_row() == 1, "nor in the editor")
	test.type("# Now")
	test.wait(function() return on_screen(test, "│ Now") end)
	test.eq(buffer:line(1), "# Now", "typing into the empty doc renders")
	test.wait(function() return current(test).source ~= nil end)
	test.ok(current(test).source == 1 and buffer:top_row() == 1, "both tops on the first line")
end

function tests.split_delete_under_the_view(test)
	local buffer = test.open("delete-split.md", prose_doc())
	open_split(test)
	for _ = 1, 30 do
		test.wheel(5, 5, "down")
	end
	expect_aligned(test, buffer, "scrolled far")
	buffer:delete({row = 3, col = 1}, {row = buffer:line_count(), col = 1})
	test.wait(function() return current(test).rows < 10 end)
	test.ok(buffer:top_row() <= buffer:line_count(), "the editor top is back inside the buffer")
	test.ok(current(test).source <= buffer:line_count(), "and the preview's")
end

function tests.split_back_fails_to_open(test)
	local other = qed.path.join(qed.root(), "other.md")
	qed.fs.write(other, "# Other doc")
	local first = test.open("first.md", "see [the-other-doc](other.md) here")
	open_split(test)
	test.click("the-other-doc here")
	test.wait(function() return qed.buf.current():path() == other end)
	local other_buffer = qed.buf.current()
	test.key("Alt+,")
	test.wait(function() return qed.buf.current() == first end)
	qed.close(other_buffer)
	qed.fs.remove(other)
	qed.fs.mkdir(other)
	test.key("Alt+.")
	test.pump(30)
	test.eq(qed.buf.current(), first, "a Forward that cannot open stays put")
	local nxt = test.open("next.md", "# Next doc")
	test.wait(function() return on_screen(test, "Next doc") end)
	test.click(60, 5)
	test.key("Alt+,")
	test.wait(function() return qed.buf.current() == first end)
	test.eq(qed.buf.current(), first, "the editor switch after the failed Forward is recorded")
	test.key("Alt+.")
	test.wait(function() return qed.buf.current() == nxt end)
end

return tests

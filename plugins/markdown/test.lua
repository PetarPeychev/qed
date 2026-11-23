local tests = {}

local function on_screen(test, needle)
	for screen_row = 0, 23 do
		if test.screen(screen_row):find(needle, 1, true) then
			return true
		end
	end
	return false
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
	test.wait(function() return test.ui() ~= nil end)
	return test.ui()
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
	test.wait(function() return test.ui() == nil end)
end

function tests.not_for_other_languages(test)
	test.open("notes.txt", "# not markdown")
	test.key("Alt+p")
	test.pump(50)
	test.eq(test.ui(), nil, "no preview for a plain text buffer")
	test.open("yes.md", "# md")
	open(test)
	test.key("Esc")
end

function tests.scroll_keys(test)
	test.open("long.md", long_doc())
	local ui = open(test)
	test.ok(ui.rows > 100, "many rendered rows")
	test.key("PgDn")
	test.ok(test.ui().scroll > 0, "PgDn scrolls")
	test.key("End")
	local bottom = test.ui().scroll
	test.ok(bottom > 20, "End jumps to the bottom")
	test.ok(on_screen(test, "para 80 with bold"), "End shows the last line")
	test.key("Up")
	test.eq(test.ui().scroll, bottom - 1, "Up scrolls one row")
	test.key("Home")
	test.eq(test.ui().scroll, 0, "Home")
	test.key("Esc")
end

function tests.live_update_keeps_scroll(test)
	local buffer = test.open("live.md", long_doc())
	local ui = open(test)
	test.key("PgDn")
	test.key("PgDn")
	local scroll = test.ui().scroll
	test.ok(scroll > 0, "scrolled")
	buffer:insert({row = 1, col = 1}, "Intro line\n\n")
	test.wait(function() return test.ui().rows == ui.rows + 2 end)
	test.eq(test.ui().scroll, scroll, "the scroll position is kept")
	test.key("Home")
	test.ok(on_screen(test, "Intro line"), "the new text renders")
	test.key("Esc")
end

local function body_y(test, needle)
	local ui = test.ui()
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
	test.eq(ui.scroll, ui.rows - ui.body_h, "near the end the preview stops at the bottom")
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
	test.eq(buffer:screen_row(), 12, "on the same terminal row")
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
	test.eq(buffer:screen_row(), 12, "the cursor is low on screen")
	local ui = open(test)
	test.eq(ui.scroll, 0, "the preview cannot scroll above the document")
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
	test.eq(buffer:screen_row(), 10, "at the same screen row")
end

function tests.close_without_scroll_keeps_cursor(test)
	local buffer = test.open("keep.md", long_doc())
	buffer:set_cursor({row = para_row(30), col = 4})
	buffer:set_screen_row(para_row(30), 6)
	open(test)
	test.key("Esc")
	test.wait(function() return test.ui() == nil end)
	test.pump(20)
	test.eq(buffer:cursor().row, para_row(30), "the cursor row is untouched")
	test.eq(buffer:cursor().col, 4, "the cursor col is untouched")
	test.eq(buffer:screen_row(), 6, "the editor view is untouched")
end

function tests.close_after_scroll_moves_cursor(test)
	local buffer = test.open("move.md", long_doc())
	buffer:set_cursor({row = para_row(10), col = 4})
	buffer:set_screen_row(para_row(10), 8)
	local ui = open(test)
	local before = ui.scroll
	test.key("PgDn")
	test.ok(test.ui().scroll > before, "scrolled")
	local number
	for screen_row = 7, ui.body_y, -1 do
		number = test.screen(screen_row):match("para (%d+) with")
		if number then
			break
		end
	end
	test.ok(number ~= nil, "a block at or above the cursor's screen row")
	test.key("Esc")
	test.wait(function() return test.ui() == nil end)
	test.wait(function() return buffer:cursor().row ~= para_row(10) end)
	test.eq(buffer:cursor().row, para_row(tonumber(number)), "the cursor is on that block's source line")
	test.eq(buffer:cursor().col, 1, "at its first non-blank column")
	test.eq(buffer:screen_row(), 8, "at the same screen row")
end

function tests.max_width(test)
	test.open("w.md", "# W\n\ntext")
	test.eq(open(test).width, 80 - 2 * 8, "the default cap is wider than the screen")
	test.key("Esc")
	open(test)
	test.config({max_width = 40}, {hot = true})
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.width == 40 end)
	test.key("Esc")
	test.eq(open(test).width, 40, "capped by plugins.markdown.max_width")
	test.key("Esc")
	test.config({max_width = 3}, {hot = true})
	test.eq(open(test).width, 20, "clamped to a usable minimum")
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
	test.ok(test.ui().scroll > 0, "the anchor scrolls")
	test.key("Esc")
	test.wait(function() return buffer:cursor().row ~= 1 end)
	test.eq(buffer:cursor().row, 129, "the cursor is on the heading")
	test.eq(buffer:cursor().col, 3, "at its first non-blank column")
	test.eq(buffer:screen_row(), top + 1, "on the terminal row it showed on, the body top")
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
	test.ok(test.ui().scroll > 0, "the anchor scrolls the preview")
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
	test.eq(qed.buf.current():cursor().row, 9, "the editor is on the second Deep Dive heading")
	test.ok(test.ui() ~= nil, "a markdown link keeps the preview open")
	test.ok(on_screen(test, "other.md"), "the preview shows the linked file")
	test.ok(test.ui().scroll > 0 and on_screen(test, "second"), "scrolled to the anchor")
	test.key("Esc")
	test.key("Alt+,")
	test.eq(qed.buf.current(), from, "the switch is in the jump list")
end

function tests.other_file_link_closes(test)
	qed.fs.write(qed.path.join(qed.root(), "notes.txt"), "one\ntwo\n")
	test.open("tx.md", pad("see [the-notes](notes.txt) here"))
	open(test)
	test.click("the-notes")
	test.wait(function() return test.ui() == nil end)
	test.eq(qed.path.base(qed.buf.current():path()), "notes.txt", "a non-markdown file opens in the editor")
end

function tests.url_link_opens_url(test)
	test.open("urls.md", pad("visit [the-site](https://example.com/x) now"))
	open(test)
	test.click("the-site")
	test.wait(function() return test.log_has("debug", "", "Open URL: https://example.com/x") end)
	test.ok(test.ui() ~= nil, "the preview stays open")
	test.key("Esc")
end

function tests.backdrop(test)
	test.open("bd.md", "raw markdown text here\n\n\n\n\n\n# Doc")
	open(test)
	test.ok(test.screen(0):find("raw markdown", 1, true) ~= nil, "dim keeps the text, only its color changes")
	test.key("Esc")
	test.config({backdrop = "blank"}, {hot = true})
	open(test)
	test.ok(test.screen(0):find("raw markdown", 1, true) == nil, "blank clears the editor text")
	test.ok(test.screen(22):find("bd.md", 1, true) ~= nil, "the status bar stays")
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
	local deep = test.ui().scroll
	test.ok(deep > 0, "the anchor scrolls")
	test.key("Alt+,")
	test.eq(test.ui().scroll, 0, "Back returns to where the jump started")
	test.key("Alt+.")
	test.eq(test.ui().scroll, deep, "Forward goes to the anchor again")
	test.key("Alt+.")
	test.eq(test.ui().scroll, deep, "Forward past the end does nothing")
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
	test.ok(test.ui() ~= nil and on_screen(test, "first.md"), "Back shows the first doc again")
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
	test.eq(test.ui(), nil, "Ctrl+P opens the core scoped palette over the preview")
	test.type("markdown: back")
	test.key("Enter")
	test.ok(test.ui() ~= nil, "running Back from it returns to the preview")
	test.key("Esc")
end

return tests

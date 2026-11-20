local T = {}

local function on_screen(t, needle)
	for y = 0, 23 do
		if t.screen(y):find(needle, 1, true) then
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

local function open(t)
	t.key("Alt+p")
	t.wait(function() return t.ui() ~= nil end)
	return t.ui()
end

function T.toggle_renders(t)
	t.open("doc.md", "# Title\n\nsome **bold** text\n\n- item")
	local ui = open(t)
	t.eq(ui.kind, "pane")
	t.ok(on_screen(t, "Title"), "the heading renders")
	t.ok(on_screen(t, "━━━"), "H1 gets a rule")
	t.ok(on_screen(t, "some bold text"), "bold markers hidden")
	t.ok(on_screen(t, "• item"), "bullet")
	t.ok(on_screen(t, "doc.md"), "title")
	t.key("Alt+p")
	t.wait(function() return t.ui() == nil end)
end

function T.not_for_other_languages(t)
	t.open("notes.txt", "# not markdown")
	t.key("Alt+p")
	t.pump(50)
	t.eq(t.ui(), nil, "no preview for a plain text buffer")
	t.open("yes.md", "# md")
	open(t)
	t.key("Esc")
end

function T.scroll_keys(t)
	t.open("long.md", long_doc())
	local ui = open(t)
	t.ok(ui.rows > 100, "many rendered rows")
	t.key("PgDn")
	t.ok(t.ui().scroll > 0, "PgDn scrolls")
	t.key("End")
	local bottom = t.ui().scroll
	t.ok(bottom > 20, "End jumps to the bottom")
	t.ok(on_screen(t, "para 80 with bold"), "End shows the last line")
	t.key("Up")
	t.eq(t.ui().scroll, bottom - 1, "Up scrolls one row")
	t.key("Home")
	t.eq(t.ui().scroll, 0, "Home")
	t.key("Esc")
end

function T.live_update_keeps_scroll(t)
	local b = t.open("live.md", long_doc())
	local ui = open(t)
	t.key("PgDn")
	t.key("PgDn")
	local scroll = t.ui().scroll
	t.ok(scroll > 0, "scrolled")
	qed.buf.insert(b, {row = 1, col = 1}, "Intro line\n\n")
	t.wait(function() return t.ui().rows == ui.rows + 2 end)
	t.eq(t.ui().scroll, scroll, "the scroll position is kept")
	t.key("Home")
	t.ok(on_screen(t, "Intro line"), "the new text renders")
	t.key("Esc")
end

local function body_y(t, needle)
	local ui = t.ui()
	for y = ui.body_y, ui.body_y + ui.body_h - 1 do
		if t.screen(y):find(needle, 1, true) then
			return y
		end
	end
end

local function para_row(i)
	return 2 * i + 1
end

local function expect_synced(t, b, i, why)
	local ui = open(t)
	local y = body_y(t, ("para %d with"):format(i))
	t.ok(y ~= nil, why .. ": the cursor's block is shown")
	t.eq(y + 1, math.max(qed.buf.screen_row(b), ui.body_y + 1), why .. ": on the cursor line's terminal row, or the body top")
	t.key("Esc")
end

function T.open_syncs_to_cursor(t)
	local b = t.open("sync.md", long_doc())
	qed.buf.set_cursor(b, {row = para_row(3), col = 1})
	expect_synced(t, b, 3, "near the top")
	qed.buf.set_cursor(b, {row = para_row(40), col = 1})
	qed.buf.set_screen_row(b, para_row(40), 8)
	expect_synced(t, b, 40, "middle")
	qed.buf.set_cursor(b, {row = para_row(40), col = 5})
	qed.buf.set_screen_row(b, para_row(40), 1)
	expect_synced(t, b, 40, "editor top")
	qed.buf.set_cursor(b, {row = para_row(80), col = 1})
	local ui = open(t)
	t.eq(ui.scroll, ui.rows - ui.body_h, "near the end the preview stops at the bottom")
	t.ok(on_screen(t, "para 80 with"), "the last block is shown")
	t.key("Esc")
end

function T.sync_keeps_the_terminal_row(t)
	local b = t.open("rows.md", long_doc())
	qed.buf.set_cursor(b, {row = para_row(40), col = 1})
	qed.buf.set_screen_row(b, para_row(40), 12)
	local ui = open(t)
	t.ok(ui.body_y > 0, "the body starts below the box top")
	t.eq(body_y(t, "para 40 with"), 11, "the block is on the cursor line's terminal row")
	t.key("Down")
	t.key("Down")
	t.eq(body_y(t, "para 41 with"), 11, "two rows down, the next block is there")
	t.key("Esc")
	t.wait(function() return qed.buf.cursor(b).row ~= para_row(40) end)
	t.eq(qed.buf.cursor(b).row, para_row(41), "the cursor is on the line now under that terminal row")
	t.eq(qed.buf.screen_row(b), 12, "on the same terminal row")
end

function T.open_clamps_at_start(t)
	local parts = {}
	for i = 1, 10 do
		parts[#parts + 1] = ("[r%d]: https://x.y/%d"):format(i, i)
	end
	parts[#parts + 1] = ""
	parts[#parts + 1] = "first para"
	local b = t.open("refs.md", table.concat(parts, "\n") .. "\n\n" .. long_doc())
	qed.buf.set_cursor(b, {row = 12, col = 1})
	t.eq(qed.buf.screen_row(b), 12, "the cursor is low on screen")
	local ui = open(t)
	t.eq(ui.scroll, 0, "the preview cannot scroll above the document")
	t.eq(body_y(t, "first para"), ui.body_y, "the block is at the top")
	t.key("Esc")
end

function T.code_block_lines_sync_exactly(t)
	local parts = {"# Code", "", "```"}
	for i = 1, 60 do
		parts[#parts + 1] = ("  code line %d;"):format(i)
	end
	parts[#parts + 1] = "```"
	parts[#parts + 1] = ""
	parts[#parts + 1] = "tail"
	local b = t.open("code.md", table.concat(parts, "\n"))
	qed.buf.set_cursor(b, {row = 33, col = 1})
	qed.buf.set_screen_row(b, 33, 10)
	local ui = open(t)
	t.eq(body_y(t, "code line 30;"), 9, "the cursor's code line, not the block start, is on the cursor's terminal row")
	t.key("PgDn")
	local n = t.screen(9):match("code line (%d+);")
	t.ok(n ~= nil, "a code line on the cursor's row")
	t.key("Esc")
	t.wait(function() return qed.buf.cursor(b).row ~= 33 end)
	t.eq(qed.buf.cursor(b).row, 3 + tonumber(n), "the cursor is on that code line")
	t.eq(qed.buf.cursor(b).col, 3, "at its first non-blank column")
	t.eq(qed.buf.screen_row(b), 10, "at the same screen row")
end

function T.close_without_scroll_keeps_cursor(t)
	local b = t.open("keep.md", long_doc())
	qed.buf.set_cursor(b, {row = para_row(30), col = 4})
	qed.buf.set_screen_row(b, para_row(30), 6)
	open(t)
	t.key("Esc")
	t.wait(function() return t.ui() == nil end)
	t.pump(20)
	t.eq(qed.buf.cursor(b).row, para_row(30), "the cursor row is untouched")
	t.eq(qed.buf.cursor(b).col, 4, "the cursor col is untouched")
	t.eq(qed.buf.screen_row(b), 6, "the editor view is untouched")
end

function T.close_after_scroll_moves_cursor(t)
	local b = t.open("move.md", long_doc())
	qed.buf.set_cursor(b, {row = para_row(10), col = 4})
	qed.buf.set_screen_row(b, para_row(10), 8)
	local ui = open(t)
	local before = ui.scroll
	t.key("PgDn")
	t.ok(t.ui().scroll > before, "scrolled")
	local n
	for y = 7, ui.body_y, -1 do
		n = t.screen(y):match("para (%d+) with")
		if n then
			break
		end
	end
	t.ok(n ~= nil, "a block at or above the cursor's screen row")
	t.key("Esc")
	t.wait(function() return t.ui() == nil end)
	t.wait(function() return qed.buf.cursor(b).row ~= para_row(10) end)
	t.eq(qed.buf.cursor(b).row, para_row(tonumber(n)), "the cursor is on that block's source line")
	t.eq(qed.buf.cursor(b).col, 1, "at its first non-blank column")
	t.eq(qed.buf.screen_row(b), 8, "at the same screen row")
end

function T.max_width(t)
	t.open("w.md", "# W\n\ntext")
	t.eq(open(t).width, 80 - 2 * 8, "the default cap is wider than the screen")
	t.key("Esc")
	open(t)
	t.config({max_width = 40}, {hot = true})
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.width == 40 end)
	t.key("Esc")
	t.eq(open(t).width, 40, "capped by plugins.markdown.max_width")
	t.key("Esc")
	t.config({max_width = 3}, {hot = true})
	t.eq(open(t).width, 20, "clamped to a usable minimum")
	t.key("Esc")
end

local function pad(body)
	return "\n\n\n\n\n\n" .. body
end

function T.close_after_anchor_goes_to_first_non_blank(t)
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
	local b = t.open("anchor-sync.md", pad(table.concat(parts, "\n")))
	local top = open(t).body_y
	t.click("go-there")
	t.ok(t.ui().scroll > 0, "the anchor scrolls")
	t.key("Esc")
	t.wait(function() return qed.buf.cursor(b).row ~= 1 end)
	t.eq(qed.buf.cursor(b).row, 129, "the cursor is on the heading")
	t.eq(qed.buf.cursor(b).col, 3, "at its first non-blank column")
	t.eq(qed.buf.screen_row(b), top + 1, "on the terminal row it showed on, the body top")
end

function T.anchor_link_scrolls(t)
	local parts = {"intro [jump-to-second](#second-part)", ""}
	for i = 1, 60 do
		parts[#parts + 1] = "filler " .. i
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = "## Second part"
	parts[#parts + 1] = ""
	parts[#parts + 1] = "tail text"
	t.open("anchors.md", pad(table.concat(parts, "\n")))
	open(t)
	t.click("jump-to-second")
	t.ok(t.ui().scroll > 0, "the anchor scrolls the preview")
	t.ok(on_screen(t, "tail text"), "the heading is in view")
	t.key("Esc")
end

function T.file_link_opens_heading(t)
	local other = qed.path.join(qed.root(), "docs/other.md")
	qed.fs.write(other, "# Top\n\ntext\n\n## Deep Dive\n\nbody\n\n## Deep Dive\n\nsecond")
	t.open("links.md", pad("see [the-other-doc](docs/other.md#deep-dive-1) here"))
	open(t)
	local from = qed.buf.current()
	t.click("the-other-doc")
	t.wait(function() return qed.buf.path() == other end)
	t.eq(qed.buf.cursor().row, 9, "the editor is on the second Deep Dive heading")
	t.ok(t.ui() ~= nil, "a markdown link keeps the preview open")
	t.ok(on_screen(t, "other.md"), "the preview shows the linked file")
	t.ok(t.ui().scroll > 0 and on_screen(t, "second"), "scrolled to the anchor")
	t.key("Esc")
	t.key("Alt+,")
	t.eq(qed.buf.current(), from, "the switch is in the jump list")
end

function T.other_file_link_closes(t)
	qed.fs.write(qed.path.join(qed.root(), "notes.txt"), "one\ntwo\n")
	t.open("tx.md", pad("see [the-notes](notes.txt) here"))
	open(t)
	t.click("the-notes")
	t.wait(function() return t.ui() == nil end)
	t.eq(qed.path.base(qed.buf.path()), "notes.txt", "a non-markdown file opens in the editor")
end

function T.url_link_opens_url(t)
	t.open("urls.md", pad("visit [the-site](https://example.com/x) now"))
	open(t)
	t.click("the-site")
	t.wait(function() return t.log_has("debug", "", "Open URL: https://example.com/x") end)
	t.ok(t.ui() ~= nil, "the preview stays open")
	t.click("[1] https")
	t.wait(function() return t.log_has("debug", "", "Open URL: https://example.com/x") end)
	t.key("Esc")
end

function T.backdrop(t)
	t.open("bd.md", "raw markdown text here\n\n\n\n\n\n# Doc")
	open(t)
	t.ok(t.screen(0):find("raw markdown", 1, true) ~= nil, "dim keeps the text, only its color changes")
	t.key("Esc")
	t.config({backdrop = "blank"}, {hot = true})
	open(t)
	t.ok(t.screen(0):find("raw markdown", 1, true) == nil, "blank clears the editor text")
	t.ok(t.screen(22):find("bd.md", 1, true) ~= nil, "the status bar stays")
	t.key("Esc")
end

function T.back_forward_anchor(t)
	local parts = {"intro [jump-to-second](#second-part)", ""}
	for i = 1, 60 do
		parts[#parts + 1] = "filler " .. i
		parts[#parts + 1] = ""
	end
	parts[#parts + 1] = "## Second part"
	t.open("hist.md", pad(table.concat(parts, "\n")))
	open(t)
	t.click("jump-to-second")
	local deep = t.ui().scroll
	t.ok(deep > 0, "the anchor scrolls")
	t.key("Alt+,")
	t.eq(t.ui().scroll, 0, "Back returns to where the jump started")
	t.key("Alt+.")
	t.eq(t.ui().scroll, deep, "Forward goes to the anchor again")
	t.key("Alt+.")
	t.eq(t.ui().scroll, deep, "Forward past the end does nothing")
	t.key("Esc")
end

function T.back_forward_files(t)
	local other = qed.path.join(qed.root(), "other.md")
	qed.fs.write(other, "# Other doc\n\nbody")
	local from = t.open("first.md", pad("see [the-other-doc](other.md) here"))
	open(t)
	t.click("the-other-doc")
	t.wait(function() return qed.buf.path() == other end)
	t.ok(on_screen(t, "Other doc"), "the linked doc shows")
	t.key("Alt+,")
	t.wait(function() return qed.buf.current() == from end)
	t.ok(t.ui() ~= nil and on_screen(t, "first.md"), "Back shows the first doc again")
	t.key("Alt+.")
	t.wait(function() return qed.buf.path() == other end)
	t.ok(on_screen(t, "Other doc"), "Forward shows the linked doc")
	t.key("Esc")
	t.key("Alt+,")
	t.eq(qed.buf.current(), from, "the file switches are in the editor jump list")
end

function T.back_forward_scoped(t)
	t.open("sc.md", "# Doc")
	local ui = open(t)
	t.eq(ui.kind, "pane")
	t.key("Ctrl+p")
	t.eq(t.ui(), nil, "Ctrl+P opens the core scoped palette over the preview")
	t.type("markdown: back")
	t.key("Enter")
	t.ok(t.ui() ~= nil, "running Back from it returns to the preview")
	t.key("Esc")
end

return T

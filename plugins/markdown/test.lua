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

function T.reopen_restores_scroll(t)
	t.open("re.md", long_doc())
	open(t)
	t.key("PgDn")
	local scroll = t.ui().scroll
	t.key("Alt+p")
	t.wait(function() return t.ui() == nil end)
	t.eq(open(t).scroll, scroll, "same buffer reopens at the same place")
	t.key("Esc")
	t.open("other.md", long_doc())
	t.eq(open(t).scroll, 0, "another buffer starts at the top")
	t.key("Esc")
end

function T.max_width(t)
	t.open("w.md", "# W\n\ntext")
	t.eq(open(t).width, 80 - 2 * 8, "the default cap is wider than the screen")
	t.key("Esc")
	t.config({max_width = 40}, {hot = true})
	t.eq(open(t).width, 40, "capped by plugins.markdown.max_width")
	t.key("Esc")
end

return T

local T = {}

local FIND = "Go to: Line"

local function rows(ui)
	return table.concat(ui.labels, ",")
end

function T.filter_keeps_buffer_order(t)
	local b = t.open("a.txt", "alpha\nbeta\ngamma\nalpha2\ndelta\nalpha3")
	qed.buf.set_cursor(b, {row = 5, col = 1})
	qed.run(FIND)
	local ui = t.ui()
	t.ok(ui and ui.kind == "pick", "the line list opens")
	t.eq(ui.selected, "delta", "opens on the cursor line")
	t.type("alph")
	t.eq(rows(t.ui()), "alpha,alpha2,alpha3", "matches in buffer order")
	t.key("Down")
	t.key("Enter")
	t.ok(t.ui() == nil, "Enter closes")
	t.eq(qed.buf.cursor(b).row, 4, "jumps to the picked line")
end

function T.exact_jump_with_column(t)
	local b = t.open("a.txt", "one\n  two\nthree")
	qed.run(FIND)
	t.type(":2")
	t.eq(rows(t.ui()), "  two", ":N selects that row")
	t.key("Enter")
	local c = qed.buf.cursor(b)
	t.eq(c.row, 2)
	t.eq(c.col, 3, "first non-blank")
	qed.run(FIND)
	t.key("Ctrl+a")
	t.type(":3:4")
	t.key("Enter")
	c = qed.buf.cursor(b)
	t.eq(c.row, 3)
	t.eq(c.col, 4, ":N:M sets the column")
end

function T.query_persists_fully_selected(t)
	t.open("a.txt", "xa\nxb\nyc")
	qed.run(FIND)
	t.type("x")
	t.key("Esc")
	qed.run(FIND)
	local ui = t.ui()
	t.eq(ui.query, "x", "the query comes back")
	t.eq(ui.matches, 2)
	t.type("y")
	t.eq(t.ui().query, "y", "a keystroke replaces it")
	t.key("Esc")
end

function T.chord_closes(t)
	t.open("a.txt", "x")
	t.key("Ctrl+g")
	t.ok(t.ui() ~= nil, "Ctrl+g opens")
	t.key("Ctrl+g")
	t.ok(t.ui() == nil, "Ctrl+g closes")
end

return T

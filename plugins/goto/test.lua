local tests = {}

local FIND = "Go to: Line"

local function view()
	return qed.plugin("goto").state()
end

local function rows(ui)
	return table.concat(ui.labels, ",")
end

function tests.filter_keeps_buffer_order(test)
	local buffer = test.open("a.txt", "alpha\nbeta\ngamma\nalpha2\ndelta\nalpha3")
	buffer:set_cursor({row = 5, col = 1})
	qed.run(FIND)
	local ui = view()
	test.ok(ui ~= nil, "the line list opens")
	test.eq(ui.selected, "delta", "opens on the cursor line")
	test.type("alph")
	test.eq(rows(view()), "alpha,alpha2,alpha3", "matches in buffer order")
	test.key("Down")
	test.key("Enter")
	test.ok(view() == nil, "Enter closes")
	test.eq(buffer:cursor().row, 4, "jumps to the picked line")
end

function tests.exact_jump_with_column(test)
	local buffer = test.open("a.txt", "one\n  two\nthree")
	qed.run(FIND)
	test.type(":2")
	test.eq(rows(view()), "  two", ":N selects that row")
	test.key("Enter")
	local cursor = buffer:cursor()
	test.eq(cursor.row, 2)
	test.eq(cursor.col, 3, "first non-blank")
	qed.run(FIND)
	test.key("Ctrl+a")
	test.type(":3:4")
	test.key("Enter")
	cursor = buffer:cursor()
	test.eq(cursor.row, 3)
	test.eq(cursor.col, 4, ":N:M sets the column")
end

function tests.bare_number_leads(test)
	local lines = {}
	for i = 1, 1200 do
		lines[i] = ("v%d"):format(i + 100)
	end
	local buffer = test.open("a.txt", table.concat(lines, "\n"))
	qed.run(FIND)
	test.type("1004")
	local ui = view()
	test.eq(rows(ui), "v1104,v1004", "the line-number row comes first, fuzzy text matches follow")
	test.key("Enter")
	test.eq(buffer:cursor().row, 1004, "Enter goes to the line")
	qed.run(FIND)
	test.key("Ctrl+a")
	test.type("99999")
	test.key("Enter")
	test.eq(buffer:cursor().row, 1200, "past the end clamps to the last line")
	qed.run(FIND)
	test.key("Ctrl+a")
	test.type("v120")
	test.eq(view().labels[1], "v120", "other input stays a fuzzy filter in buffer order")
	test.key("Esc")
end

function tests.query_not_persisted(test)
	test.open("a.txt", "xa\nxb\nyc")
	qed.run(FIND)
	test.type("x")
	test.key("Esc")
	qed.run(FIND)
	local ui = view()
	test.eq(ui.query, "", "the filter does not come back")
	test.eq(ui.matches, 3)
	test.key("Esc")
end

function tests.chord_closes(test)
	test.open("a.txt", "x")
	test.key("Ctrl+g")
	test.ok(view() ~= nil, "Ctrl+g opens")
	test.key("Ctrl+g")
	test.ok(view() == nil, "Ctrl+g closes")
end

return tests

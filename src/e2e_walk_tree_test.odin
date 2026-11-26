package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
e2e_walk_tree_expands_filters_and_reveals :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	root := e.ed.working_root
	os.make_directory(fmt.tprintf("%s/alpha", root))
	os.make_directory(fmt.tprintf("%s/alpha/inner", root))
	nav_write(fmt.tprintf("%s/alpha/one.txt", root), "1")
	nav_write(fmt.tprintf("%s/alpha/inner/deep.txt", root), "2")
	nav_write(fmt.tprintf("%s/beta.txt", root), "3")
	e2e_plugin(&e, "uitest", `return {setup = function()
	qed.command{id = "run", name = "Run", run = function()
		local tree = qed.fs.walk():tree()
		local function names()
			local out = {}
			for index = 1, tree:count() do
				local row = tree:at(index)
				out[#out + 1] = string.rep(".", row.depth) .. row.name .. (row.dir and "/" or "")
			end
			return table.concat(out, " ")
		end
		local steps = {names()}
		tree:expand("alpha")
		steps[#steps + 1] = names()
		steps[#steps + 1] = tostring(tree:toggle("alpha"))
		steps[#steps + 1] = tostring(tree:reveal("alpha/inner/deep.txt"))
		steps[#steps + 1] = names()
		tree:set_query("deep")
		for _ = 1, 300 do
			if not tree:loading() then
				break
			end
			qed.sleep(10)
		end
		steps[#steps + 1] = names()
		tree:set_query("")
		steps[#steps + 1] = tostring(tree:index_of(qed.path.join(qed.root(), "beta.txt")))
		qed.message(table.concat(steps, " | "))
	end}
end}`)
	ut_run(&e, "Run")
	for _ in 0 ..< 400 {
		if strings.count(e.ed.message, " | ") == 6 {
			break
		}
		walk_pump(&e.ed)
		e2e_ui_settle(&e)
		time.sleep(5 * time.Millisecond)
	}
	message := e.ed.message
	parts := strings.split(message, " | ", context.temp_allocator)
	if !testing.expectf(t, len(parts) == 7, "seven steps: %s", message) {
		return
	}
	testing.expect_value(t, parts[0], "alpha/ beta.txt main.txt")
	testing.expect_value(t, parts[1], "alpha/ .inner/ .one.txt beta.txt main.txt")
	testing.expect_value(t, parts[2], "false")
	testing.expect_value(t, parts[3], "true")
	testing.expect_value(t, parts[4], "alpha/ .inner/ ..deep.txt .one.txt beta.txt main.txt")
	testing.expect(t, strings.contains(parts[5], "deep.txt"), "the filter narrows to the match")
	testing.expect_value(t, parts[6], "5")
}

@(test)
e2e_walk_tree_feeds_a_virtual_column :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	root := e.ed.working_root
	os.make_directory(fmt.tprintf("%s/alpha", root))
	nav_write(fmt.tprintf("%s/alpha/one.txt", root), "1")
	e2e_plugin(&e, "uitest", `local tree
return {setup = function()
	qed.command{id = "run", name = "Run", run = function()
		tree = qed.fs.walk():tree()
		qed.ui.mount("pane", qed.ui.box{float = "screen", width = 40, height = 8, border = true,
			qed.ui.virtual_column{id = "rows", data = tree, item = function(row)
				return qed.ui.text{string.rep("  ", row.depth), row.name, row.dir and "/" or ""}
			end}})
	end}
	qed.command{id = "open", name = "Open", run = function() tree:expand("alpha") end}
end}`)
	ut_run(&e, "Run")
	testing.expect(t, e2e_ui_find_row(&e, "alpha/") >= 0, "the tree rows render")
	testing.expect(t, e2e_ui_find_row(&e, "one.txt") < 0, "collapsed dirs hide their rows")
	ut_run(&e, "Open")
	testing.expect(t, e2e_ui_find_row(&e, "  one.txt") >= 0, "expanding shows them")
}

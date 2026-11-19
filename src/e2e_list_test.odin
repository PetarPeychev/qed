package main

import "core:fmt"
import "core:testing"
import lua "lib:lua"

@(private = "file")
LIST_PLUGIN :: `
local h
local function note(s) qed.log("info", s) end
local function show(it) return it.label .. "=" .. (it.path or "") end
return {setup = function()
	qed.meta{display_name = "L"}
	qed.command{name = "Dirs", run = function()
		h = qed.fs.dirs()
		local v = qed.ui.open{fields = {{}}, list = {items = h}, on = {
			change = function(_, item) note("chg " .. show(item)) end,
			activate = function(_, items) note("act " .. #items .. " " .. show(items[1])) end,
		}}
		local items, i = v:wait()
		note(("wait %d %s %d"):format(#items, show(items[1]), i))
		v:close()
	end}
	qed.command{name = "Path", run = function()
		local v = qed.ui.open{fields = {{mode = "path", text = "al"}}, list = {items = qed.fs.dirs()}}
		local items, i, text = v:wait()
		v:close()
		note(("path %d %s %s"):format(#items, tostring(i), text))
	end}
	qed.command{name = "Make", run = function() h = qed.fs.dirs("alpha") end}
	qed.command{name = "Drop", run = function() h = nil collectgarbage() collectgarbage() end}
	qed.command{name = "Root", run = function()
		local ok, err = qed.set_root("nope")
		note(("bad %s %s"):format(tostring(ok), tostring(err)))
		note(("same %s"):format(tostring(qed.set_root(qed.root()))))
		note(("rel %s %s"):format(tostring(qed.set_root("alpha")), qed.root()))
	end}
end}`

@(private = "file")
list_start :: proc(t: ^testing.T) -> (E2E, ^Plugin) {
	e := e2e_root_start("main body")
	cwd_fixture(&e)
	pl := e2e_plugin(&e, "l", LIST_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	return e, pl
}

@(private = "file")
list_run :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(&e.ed, name)
	testing.expectf(t, ok, "%s registered", name, loc = loc)
	command_run(&e.ed, cmd)
}

@(private = "file")
list_logged :: proc(e: ^E2E, text: string) -> bool {
	for l in e.ed.log {
		if l.source == "L" && l.text == text {
			return true
		}
	}
	return false
}

@(private = "file")
list_labels :: proc(p: ^Pane) -> string {
	s := ""
	for i in 0 ..< pane_count(p) {
		s = fmt.tprintf("%s%s%s", s, "," if i > 0 else "", p.list.items[pane_item_index(p, i)].label)
	}
	return s
}

@(private = "file")
list_items_len :: proc(e: ^E2E, handle: u64) -> int {
	p := &e.ed.plugins
	vi := plugin_view_index(p, handle)
	if vi < 0 {
		return -1
	}
	lua.rawgeti(p.L, lua.REGISTRYINDEX, lua.Integer(p.views[vi].items_ref))
	n := int(lua.rawlen(p.L, -1))
	lua.pop(p.L, 1)
	return n
}

@(test)
e2e_list_handle_virtual :: proc(t: ^testing.T) {
	e, _ := list_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	list_run(t, &e, "L: Dirs")
	p := pane_focus(&e.ed)
	testing.expect(t, p != nil && p.owner == "l", "a view over the handle opens")
	testing.expect_value(t, p.list.source.kind, ListSourceKind.Dirs)
	testing.expect_value(t, list_labels(p), "Beta,alpha,apple,link")
	testing.expect_value(t, p.list.items[1].path, fmt.tprintf("%s/alpha", root))
	testing.expect_value(t, len(e.ed.plugins.lists), 1)
	testing.expect_value(t, list_items_len(&e, p.handle), 0)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "apple"), "core items render")

	e2e_type(&e, "ppl")
	plugin_flush(&e.ed)
	testing.expect_value(t, list_labels(p), "apple")
	testing.expect(t, list_logged(&e, fmt.tprintf("chg apple=%s/apple", root)), "change materializes the highlighted item")
	testing.expect_value(t, list_items_len(&e, p.handle), 0)

	e2e_key(&e, .Enter)
	testing.expect(t, list_logged(&e, fmt.tprintf("act 1 apple=%s/apple", root)), "activate gets the item as a table")
	testing.expect(t, list_logged(&e, fmt.tprintf("wait 1 apple=%s/apple 3", root)), "wait returns it with its index")
	testing.expect(t, pane_focus(&e.ed) == nil, "closed")
	testing.expect_value(t, len(e.ed.plugins.view_events), 0)
}

@(test)
e2e_list_handle_lifetime :: proc(t: ^testing.T) {
	e, pl := list_start(t)
	defer e2e_stop(&e)
	lists := &e.ed.plugins.lists
	list_run(t, &e, "L: Make")
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, lists[0].src.path, fmt.tprintf("%s/alpha", e.ed.working_root))
	list_run(t, &e, "L: Drop")
	testing.expect_value(t, len(lists), 0)

	list_run(t, &e, "L: Dirs")
	p := pane_focus(&e.ed)
	list_run(t, &e, "L: Drop")
	testing.expect_value(t, len(lists), 0)
	e2e_type(&e, "be")
	testing.expect_value(t, list_labels(p), "Beta")

	list_run(t, &e, "L: Make")
	testing.expect_value(t, len(lists), 1)
	plugin_unload(&e.ed, pl)
	testing.expect_value(t, len(lists), 0)
	pane_stack_sync(&e.ed)
	testing.expect(t, pane_focus(&e.ed) == nil, "unload closes the view")
}

@(test)
e2e_list_path_field :: proc(t: ^testing.T) {
	e, _ := list_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	list_run(t, &e, "L: Path")
	p := pane_focus(&e.ed)
	f := pane_path(p)
	testing.expect(t, f != nil, "a path field")
	testing.expect_value(t, f.caret, 2)
	_, _, sel := textfield_selection(&f.field)
	testing.expect(t, !sel, "a path field's text is not selected")
	testing.expect_value(t, list_labels(p), "alpha")
	e2e_key(&e, .Enter)
	testing.expect(t, list_logged(&e, fmt.tprintf("path 0 nil %s/al", root)), "Enter submits the written path, resolved")

	list_run(t, &e, "L: Path")
	e2e_key(&e, .Tab)
	testing.expect_value(t, textfield_str(&pane_path(pane_focus(&e.ed)).field), "alpha/")
	testing.expect_value(t, list_labels(pane_focus(&e.ed)), "Zed,inner")
	e2e_key(&e, .Enter)
	testing.expect(t, list_logged(&e, fmt.tprintf("path 0 nil %s/alpha", root)), "a relative path resolves against the root")
}

@(test)
e2e_list_set_root :: proc(t: ^testing.T) {
	e, _ := list_start(t)
	defer e2e_stop(&e)
	root := fmt.tprintf("%s", e.ed.working_root)
	list_run(t, &e, "L: Root")
	testing.expect(t, list_logged(&e, fmt.tprintf("bad nil not a directory: %s/nope", root)), "a missing dir fails")
	testing.expect(t, list_logged(&e, "same true"), "the current root is a no-op")
	testing.expect(t, list_logged(&e, fmt.tprintf("rel true %s/alpha", root)), "relative to the root")
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, e.ed.welcome, "the clean outside buffer closed")
}

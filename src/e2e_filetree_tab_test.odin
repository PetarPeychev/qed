package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
PROVIDER :: `
local ft
local function tab(paths)
	local root = qed.root()
	ft.set_tab{
		label = "Prov",
		cmd = "Prov: Show",
		paths = paths or {root .. "/a.txt", root .. "/new.txt", root .. "/sub/gone.txt"},
		virtual = {root .. "/sub/gone.txt"},
		detail = true,
		preview = function(path)
			qed.log("preview " .. qed.path.rel(path))
			if path:find("gone", 1, true) then
				return "x\ny\n"
			elseif path:find("a.txt", 1, true) then
				return "one\n"
			end
		end,
		missing = function(path) qed.message("missing " .. qed.path.rel(path)) end,
	}
end
local function marks()
	local root = qed.root()
	ft.set_marks{
		[root .. "/a.txt"] = {bar = "git_modified", added = 3, removed = 1},
		[root .. "/new.txt"] = {bar = "git_added", suffix = "<- orig.txt", added = 2, removed = 0},
		[root .. "/sub"] = {bar = "git_modified"},
		[root .. "/sub/gone.txt"] = {bar = "git_deleted", fg = "git_deleted"},
		[root .. "/junk"] = {dim = true},
	}
end
return {setup = function()
	qed.command{name = "Attach", run = function()
		ft = qed.plugin("filetree")
		tab()
		marks()
		ft.set_ignored{qed.root() .. "/junk"}
	end}
	qed.command{name = "Hold", run = function()
		ft = qed.plugin("filetree")
		ft.set_ignored(false)
	end}
	qed.command{name = "Show", run = function() ft.open("Prov") end}
	qed.command{name = "Remove", run = function() ft.remove_tab("Prov") end}
	qed.command{name = "Bad", run = function()
		local ok, err = pcall(ft.set_tab, {label = "All", paths = {}})
		qed.message(err)
	end}
end}`

@(private = "file")
OTHER :: `return {setup = function()
	qed.command{name = "Steal", run = function()
		local ok, err = pcall(qed.plugin("filetree").set_tab, {label = "Prov", paths = {}})
		qed.message(err)
	end}
	qed.command{name = "Direct", run = function()
		local ok, err = pcall(qed.plugin("filetree").open, "Nope")
		qed.message(err)
	end}
end}`

@(private = "file")
fttab_logged :: proc(e: ^E2E, text: string) -> bool {
	for l in e.ed.log {
		if l.source == "Prov" && l.text == text {
			return true
		}
	}
	return false
}

@(private = "file")
fttab_run :: proc(e: ^E2E, name: string) {
	cmd, ok := plugin_test_command(&e.ed, name)
	assert(ok, name)
	plugin_command_run(&e.ed, cmd)
	e2e_git_settle(e)
}

@(private = "file")
fttab_start :: proc() -> (E2E, ^Plugin) {
	e := e2e_root_start("x")
	e2e_plugin_config(&e, "git", `{"enabled": false}`)
	e2e_resize(&e, 200, E2E_H)
	nav_write(fmt.tprintf("%s/a.txt", e.dir), "one\ntwo\n")
	nav_write(fmt.tprintf("%s/new.txt", e.dir), "fresh\nlines\n")
	os.make_directory(fmt.tprintf("%s/junk", e.dir))
	nav_write(fmt.tprintf("%s/junk/j.txt", e.dir), "j")
	pl := e2e_plugin(&e, "prov", PROVIDER)
	e2e_git_settle(&e)
	return e, pl
}

@(test)
e2e_filetree_added_tab :: proc(t: ^testing.T) {
	e, _ := fttab_start()
	defer e2e_stop(&e)
	ed := &e.ed

	nav_alt(&e, 'f')
	nav_scan(&e)
	testing.expect_value(t, ft_tabs(ed), "All|Open|Unsaved")
	cmd, _ := plugin_test_command(ed, "File Tree: Toggle Diff")
	testing.expect(t, !plugin_command_when(ed, cmd), "no Toggle Diff without a previewing tab")

	fttab_run(&e, "Prov: Attach")
	testing.expect_value(t, ft_tabs(ed), "All|Open|Prov|Unsaved")
	testing.expect_value(t, ft_scope(ed), "All")
	testing.expect(t, plugin_command_when(ed, cmd), "a previewing tab offers Toggle Diff")
	testing.expect(t, !nav_select(ed, "junk"), "ignored dirs hide")
	testing.expect_value(t, ft_mark(ed, fmt.tprintf("%s/a.txt", e.dir)).bar, "git_modified")
	testing.expect_value(t, ft_mark(ed, fmt.tprintf("%s/sub", e.dir)).bar, "git_modified")
	filetree_toggle_ignored(ed)
	testing.expect(t, nav_select(ed, "junk"), "Toggle Ignored shows them")
	e2e_render(&e)
	_, _, sized := nav_screen_find(&e, "+3  -1")
	testing.expect(t, !sized, "no sizes on a tab without detail")

	fttab_run(&e, "Prov: Show")
	testing.expect_value(t, ft_scope(ed), "Prov")
	e2e_render(&e)
	_, _, row := nav_screen_find(&e, "All │ Open │ Prov │ Unsaved")
	testing.expect(t, row, "the tab row")
	_, _, renamed := nav_screen_find(&e, "new.txt  <- orig.txt")
	testing.expect(t, renamed, "suffix on a detail tab")
	_, _, sized = nav_screen_find(&e, "+3  -1")
	testing.expect(t, sized, "sizes on a detail tab")
	testing.expect(t, ft_chip(ed, "diff"), "the diff chip starts from diff_only")
	testing.expect(t, nav_select(ed, "sub"), "a vanished dir is listed virtually")
	testing.expect(t, nav_select(ed, "gone.txt"), "the virtual file is listed")
	sel, _ := ft_selected(ed)
	testing.expect_value(t, ft_mark(ed, sel.path).fg, "git_deleted")

	nav_preview(&e)
	testing.expect(t, fttab_logged(&e, "preview sub/gone.txt"), "the preview asks the tab's plugin")
	testing.expect_value(t, ft_preview_line(ed, 0), "x")
	testing.expect_value(t, ft_preview_line(ed, 1), "y")

	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	testing.expect_value(t, e.ed.message, "missing sub/gone.txt")
	testing.expect(t, filetree_active(ed), "missing runs over the tree")

	testing.expect(t, nav_select(ed, "a.txt"))
	nav_preview(&e)
	preview := ft_preview(ed)
	testing.expect(t, preview != nil && len(preview.base.slots) > 0, "a base gives a diff preview")
	if preview != nil {
		diffbase_update(preview)
		testing.expect(t, len(preview.base.marks) > 1 && preview.base.marks[1] == .Added, "the added line against the base")
	}

	testing.expect(t, nav_select(ed, "new.txt"))
	nav_preview(&e)
	preview = ft_preview(ed)
	testing.expect(t, preview != nil && len(preview.base.slots) == 0, "a nil base previews the file plainly")
	testing.expect_value(t, ft_preview_line(ed, 0), "fresh")

	fttab_run(&e, "Prov: Bad")
	testing.expect(t, strings.contains(e.ed.message, `"All" is a built-in tab`), e.ed.message)
	other := e2e_plugin(&e, "other", OTHER)
	testing.expect_value(t, other.state, PluginState.Enabled)
	fttab_run(&e, "Other: Steal")
	testing.expect(t, strings.contains(e.ed.message, `"Prov" belongs to prov`), e.ed.message)
	fttab_run(&e, "Other: Direct")
	testing.expect(t, strings.contains(e.ed.message, `no tab "Nope"`), e.ed.message)

	fttab_run(&e, "Prov: Remove")
	testing.expect_value(t, ft_tabs(ed), "All|Open|Unsaved")
	testing.expect_value(t, ft_scope(ed), "All")
	e2e_key(&e, .Esc)
}

@(test)
e2e_filetree_added_tab_unload :: proc(t: ^testing.T) {
	e, pl := fttab_start()
	defer e2e_stop(&e)
	ed := &e.ed
	fttab_run(&e, "Prov: Hold")
	editor_dispatch(ed, tb2.Event{type = .Key, ch = 'f', mod = .Alt})
	plugin_flush(ed)
	testing.expect(t, !ft_walk(ed).ignore_ready, "an ignore set not sent yet holds the prewarm back")
	fttab_run(&e, "Prov: Attach")
	testing.expect(t, ft_walk(ed).ignore_ready)
	a_txt := fmt.tprintf("%s/a.txt", e.dir)
	testing.expect_value(t, ft_mark(ed, a_txt).bar, "git_modified")
	nav_alt(&e, 'f')
	nav_alt(&e, 'f')
	fttab_run(&e, "Prov: Show")
	fttab_run(&e, "Prov: Attach")
	testing.expect_value(t, ft_scope(ed), "Prov")
	testing.expect_value(t, ft_mark(ed, a_txt).bar, "git_modified")
	fttab_run(&e, "Prov: Hold")
	plugin_unload(&e.ed, pl)
	e2e_git_settle(&e)
	testing.expect_value(t, ft_tabs(ed), "All|Open|Unsaved")
	testing.expect_value(t, ft_scope(ed), "All")
	testing.expect_value(t, ft_mark(ed, a_txt).bar, "")
	testing.expect(t, ft_walk(ed).ignore_ready, "the unloaded plugin's hold goes with it")
}

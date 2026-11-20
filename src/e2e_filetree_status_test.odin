package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "lib:tb2"

@(private = "file")
PROVIDER :: `
local function refresh()
		qed.log("info", "refresh")
		qed.filetree.set_status({
			["a.txt"] = {mark = "modified", added = 3, removed = 1},
			["new.txt"] = {mark = "added", from = "orig.txt", added = 2},
			["sub/gone.txt"] = {mark = "deleted"},
		}, {"junk"})
end
local function preview(path)
		qed.log("info", "preview " .. qed.path.rel(path))
		if path:find("gone", 1, true) then
			qed.filetree.set_base(path, "x\ny\n")
		elseif path:find("a.txt", 1, true) then
			qed.filetree.set_base(path, "one\n")
		else
			qed.filetree.set_base(path, nil)
		end
end
local function open(ctx) qed.message("open " .. qed.path.rel(ctx.file)) end
return {setup = function()
	qed.command{name = "Provide", run = function()
		qed.filetree.provide{refresh = refresh, preview = preview, open_deleted = open}
	end}
	qed.command{name = "Reprovide", run = function()
		qed.filetree.provide{refresh = refresh, preview = preview, open_deleted = function() qed.message("reopened") end}
	end}
	qed.command{name = "Unprovide", run = function() qed.filetree.provide(nil) end}
	qed.command{name = "Bad Mark", run = function()
		local ok, err = pcall(qed.filetree.set_status, {["a.txt"] = {mark = "gone"}})
		qed.message(ok and "accepted" or err)
	end}
end}`

@(private = "file")
e2e_log_has :: proc(e: ^E2E, text: string) -> bool {
	for l in e.ed.log {
		if l.source == "Prov" && l.text == text {
			return true
		}
	}
	return false
}

@(private = "file")
fts_run :: proc(e: ^E2E, name: string) {
	for c in e.ed.plugins.commands {
		if c.bare == name {
			plugin_command_run(&e.ed, c)
		}
	}
	e2e_git_settle(e)
}

@(private = "file")
fts_start :: proc() -> (E2E, ^Plugin) {
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
e2e_filetree_status_provider :: proc(t: ^testing.T) {
	e, _ := fts_start()
	defer e2e_stop(&e)
	ed := &e.ed

	testing.expect(t, !ft_tab_visible(ed, "Changed"), "no status tab and no Changed command without a provider")
	nav_alt(&e, 'f')
	nav_scan(&e)
	testing.expect(t, !e2e_log_has(&e, "refresh"), "no refresh without a provider")

	fts_run(&e, "Provide")
	testing.expect(t, e2e_log_has(&e, "refresh"), "provide over an open tree asks for a refresh")
	testing.expect(t, ft_tab_visible(ed, "Changed"), "the tab appears")
	testing.expect(t, !nav_select(ed, "junk"), "ignored dirs hide")
	testing.expect_value(t, ft_mark(ed, fmt.tprintf("%s/a.txt", e.dir)).bar, "git_modified")
	testing.expect_value(t, ft_mark(ed, fmt.tprintf("%s/sub", e.dir)).bar, "git_modified")
	filetree_toggle_ignored(ed)
	testing.expect(t, nav_select(ed, "junk"), "Toggle Ignored shows them")

	nav_alt(&e, 'g')
	testing.expect_value(t, ft_scope(ed), "Changed")
	e2e_render(&e)
	_, _, tab := nav_screen_find(&e, "All │ Open │ Changed │ Unsaved")
	testing.expect(t, tab, "the Changed tab shows with a provider")
	_, _, renamed := nav_screen_find(&e, fmt.tprintf("new.txt  %s orig.txt", ICON_TREE_RENAMED))
	testing.expect(t, renamed, "rename label")
	_, _, sized := nav_screen_find(&e, "+3  -1")
	testing.expect(t, sized, "sizes")
	testing.expect(t, nav_select(ed, "sub"), "a vanished dir is listed virtually")
	testing.expect(t, nav_select(ed, "gone.txt"), "the deleted file is listed")
	sel, _ := ft_selected(ed)
	testing.expect_value(t, ft_mark(ed, sel.path).fg, "git_deleted")

	nav_preview(&e)
	testing.expect(t, e2e_log_has(&e, "preview sub/gone.txt"), "the preview asks the provider for a base")
	testing.expect_value(t, len(ft_pane(ed).preview.rows), 2)
	for r in ft_pane(ed).preview.rows {
		testing.expect_value(t, r.kind, PreviewRowKind.Ghost)
	}

	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	testing.expect_value(t, e.ed.message, "open sub/gone.txt")
	testing.expect(t, filetree_active(ed), "open_deleted runs over the tree")

	testing.expect(t, nav_select(ed, "a.txt"))
	nav_preview(&e)
	testing.expect(t, ft_pane(ed).preview.diff, "a base gives a diff preview")
	added := false
	for r in ft_pane(ed).preview.rows {
		added ||= r.kind == .Added && r.text == "two"
	}
	testing.expect(t, added, "the added line against the base")

	testing.expect(t, nav_select(ed, "new.txt"))
	nav_preview(&e)
	testing.expect(t, !ft_pane(ed).preview.diff, "a nil base previews the file plainly")
	testing.expect(t, len(ft_pane(ed).preview.src) > 0)

	fts_run(&e, "Bad Mark")
	testing.expect(t, strings.contains(e.ed.message, "mark must be"), "a bad mark raises")
	testing.expect(t, nav_select(ed, "a.txt"), "and leaves the status alone")

	fts_run(&e, "Unprovide")
	testing.expect(t, !ft_tab_visible(ed, "Changed"), "provide(nil) drops the tab")
	testing.expect_value(t, ft_scope(ed), "All")
	testing.expect_value(t, len(ft_pane(ed).marks), 0)
	e2e_key(&e, .Esc)
}

@(test)
e2e_filetree_status_owner :: proc(t: ^testing.T) {
	e, pl := fts_start()
	defer e2e_stop(&e)
	ed := &e.ed
	other := e2e_plugin(&e, "other", `return {setup = function()
		assert(not pcall(qed.filetree.set_status, {}), "set_status needs provide")
		assert(not pcall(qed.filetree.set_base, "a.txt", "x"), "set_base needs provide")
		assert(not pcall(qed.filetree.provide, 1), "spec table required")
		assert(not pcall(qed.filetree.provide, {refresh = 1}), "callbacks must be functions")
		qed.command{name = "Steal", run = function()
			local ok, err = qed.filetree.provide{}
			qed.message(tostring(ok) .. " " .. tostring(err))
		end}
	end}`)
	testing.expect_value(t, other.state, PluginState.Enabled)
	fts_run(&e, "Provide")
	fts_run(&e, "Steal")
	testing.expect_value(t, e.ed.message, "nil taken by Prov")
	testing.expect_value(t, e.ed.plugins.shim.owner, "prov")
	testing.expect_value(t, e.ed.plugins.shim.status, 0)
	editor_dispatch(ed, tb2.Event{type = .Key, ch = 'f', mod = .Alt})
	testing.expect(t, !ft_pane(ed).list.source.walk.ignore_ready, "a provider that has not pushed holds the prewarm back")
	nav_scan(&e)
	testing.expect(t, len(ft_pane(ed).marks) > 0, "opening the tree asks for status")
	testing.expect(t, ft_pane(ed).list.source.walk.ignore_ready)
	nav_alt(&e, 'g')
	n := len(ft_pane(ed).marks)
	fts_run(&e, "Reprovide")
	testing.expect_value(t, ft_scope(ed), "Changed")
	testing.expect_value(t, len(ft_pane(ed).marks), n)
	testing.expect(t, nav_select(ed, "gone.txt"))
	e2e_key(&e, .Enter)
	e2e_git_settle(&e)
	testing.expect_value(t, e.ed.message, "reopened")
	plugin_unload(&e.ed, pl)
	e2e_git_settle(&e)
	testing.expect(t, !ft_tab_visible(ed, "Changed"), "unload drops the provider")
	testing.expect_value(t, len(ft_pane(ed).marks), 0)
	testing.expect(t, ft_pane(ed).list.source.walk.ignore_ready, "no provider means nothing to wait for")
}

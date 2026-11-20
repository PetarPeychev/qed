package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file")
walk_tree_fixture :: proc(dir: string) {
	os.make_directory_all(fmt.tprintf("%s/sub/deep", dir))
	os.make_directory_all(fmt.tprintf("%s/other", dir))
	os.make_directory_all(fmt.tprintf("%s/.hid", dir))
	for rel in ([]string{"a.txt", "sub/b.txt", "sub/deep/c.txt", "other/d.txt", ".hid/e.txt", ".dot"}) {
		nav_write(fmt.tprintf("%s/%s", dir, rel), "x\n")
	}
}

@(private = "file")
walk_rels :: proc(entries: []FileEntry, root: string) -> string {
	rels := make([dynamic]string, context.temp_allocator)
	for e in entries {
		append(&rels, walk_rel(e.path, root))
	}
	slice_sort_strings(rels[:])
	return strings.join(rels[:], ",", context.temp_allocator)
}

@(private = "file")
slice_sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) {
		for j := i; j > 0 && s[j] < s[j - 1]; j -= 1 {
			s[j], s[j - 1] = s[j - 1], s[j]
		}
	}
}

@(test)
test_walk_within_union_ignored :: proc(t: ^testing.T) {
	e := e2e_root_start("m")
	defer e2e_stop(&e)
	root := e.ed.working_root
	walk_tree_fixture(root)
	ed := &e.ed
	w := walk_acquire(ed, root, false, false)
	defer walk_release(w)
	testing.expect_value(t, walk_rels(walk_cands(ed, w), root), "a.txt,main.txt,other,other/d.txt,sub,sub/b.txt,sub/deep,sub/deep/c.txt")
	builds := w.builds
	walk_cands(ed, w)
	testing.expect_value(t, w.builds, builds)

	ed.filetree.ignored[strings.clone(fmt.tprintf("%s/sub", root))] = true
	walk_invalidate(ed)
	testing.expect(t, !walk_valid(ed, w), "an invalidation stamps the walk stale")
	testing.expect_value(t, walk_rels(walk_cands(ed, w), root), "a.txt,main.txt,other,other/d.txt")
	wi := walk_acquire(ed, root, false, true)
	defer walk_release(wi)
	testing.expect(t, strings.contains(walk_rels(walk_cands(ed, wi), root), "sub/deep/c.txt"), "ignored = true keeps ignored paths")
	wd := walk_acquire(ed, root, true, false)
	defer walk_release(wd)
	testing.expect(t, strings.contains(walk_rels(walk_cands(ed, wd), root), ".hid/e.txt"), "dotfiles = true keeps dotfiles")
	testing.expect_value(t, walk_acquire(ed, root, false, false), w)
	walk_release(w)

	within := []string{fmt.tprintf("%s/sub/deep/c.txt", root), fmt.tprintf("%s/.hid", root)}
	s := walk_scope_new(root, nil, within, nil)
	defer walk_scope_release(s)
	src := ListSource{kind = .Walk, walk = w, wscope = s}
	testing.expect_value(t, walk_rels(walk_source_cands(ed, &src), root), ".hid,.hid/e.txt,sub,sub/deep,sub/deep/c.txt")

	u := walk_scope_new(root, s, nil, []string{fmt.tprintf("%s/gone/x.txt", root)})
	defer walk_scope_release(u)
	usrc := ListSource{kind = .Walk, walk = w, wscope = u}
	testing.expect_value(t, walk_rels(walk_source_cands(ed, &usrc), root), ".hid,.hid/e.txt,gone,gone/x.txt,sub,sub/deep,sub/deep/c.txt")
	nav_write(fmt.tprintf("%s/main.txt", root), "y")
	builds = u.builds
	walk_source_cands(ed, &usrc)
	testing.expect_value(t, u.builds, builds)
}

@(private = "file")
WALK_PLUGIN :: `
local v, h
local function note(s) qed.log("info", s) end
local function cmd(name, run) qed.command{name = name, run = run} end
local function res(ok, err) return tostring(ok) .. ":" .. tostring(err) end
return {setup = function()
	qed.meta{display_name = "W"}
	cmd("Counts", function()
		local w = qed.fs.walk{}
		local n = w:count()
		note(("count %d ready %s within %d union %d dot %d"):format(n, tostring(w:ready()),
			w:within{"sub/b.txt"}:count(), w:within{"sub/b.txt"}:union{"gone/z.txt"}:count(), qed.fs.walk{dotfiles = true}:count()))
		note("narrow " .. tostring(pcall(function() w:within{"a"}:within{"b"} end)))
		note("dirs " .. tostring(pcall(function() qed.fs.dirs{}:count() end)))
	end)
	cmd("Fs", function()
		note("mkdir " .. res(qed.fs.mkdir("made/deep")))
		note("mkdir again " .. res(qed.fs.mkdir("made/deep")))
		note("copy " .. res(qed.fs.copy("sub", "made/sub")))
		note("copy over " .. res(qed.fs.copy("a.txt", "made/sub/b.txt")))
		note("copy missing " .. res(qed.fs.copy("nope", "made/x")))
		note("rename " .. res(qed.fs.rename("made/sub", "moved/sub")))
		note("rename over " .. res(qed.fs.rename("a.txt", "moved/sub/b.txt")))
		note("rename link " .. res(qed.fs.rename("link", "link2")))
		note("copy link " .. res(qed.fs.copy("link2", "link3")))
		note("remove " .. res(qed.fs.remove("moved")))
		note("remove link " .. res(qed.fs.remove("link3")))
		note("remove missing " .. res(qed.fs.remove("moved")))
	end)
	cmd("Tree", function()
		h = qed.fs.walk{}
		v = qed.ui.open{id = "wt", place = "split", size = "split:tree", scope = "wt", tabs = {"All", {label = "Sub"}},
			fields = {{hint = "find it", esc_clears = true, count = true}},
			list = {items = h, tree = true, multi = true}, preview = "auto",
			footer = {hints = {{label = "hint row"}}, chips = {{label = "chip", cmd = "W: Chip", on = true}}},
			on = {
				tab = function(view, i)
					note("tab " .. i)
					view:set(i == 2 and h:within{"sub/b.txt"} or h)
				end,
				expand = function(_, item, open) note(("expand %s %s %s"):format(qed.path.base(item.path), tostring(item.dir), tostring(open))) end,
				submit = function(_, text) note("submit " .. tostring(text)) end,
				activate = function(_, items) note("activate " .. qed.path.base(items[1].path)) end,
			}}
	end)
	cmd("Chip", function() note("chip ran") end)
	cmd("Marks", function()
		note("marks " .. tostring(v:marks({["a.txt"] = {bar = "git_added", suffix = "<- old", added = 12, removed = 3}, other = {dim = true}}, {replace = true})))
		note("bad " .. tostring(pcall(function() v:marks({x = {fg = "nope"}}) end)))
	end)
	cmd("Unmark", function() v:marks({["a.txt"] = false}) end)
	cmd("Input", function() note("footer " .. tostring(v:footer{input = {prompt = "Name: ", text = "x"}})) end)
	cmd("Chips", function() v:footer{chips = {{label = "chip", cmd = "W: Chip", on = false}}, hints = {{label = "new hints"}}} end)
	cmd("Tab", function() note("tab now " .. v:tab() .. " " .. v:tab(2)) end)
	cmd("Expand", function() note("expand all " .. tostring(v:expand(true))) end)
	cmd("Diff", function() note("preview " .. tostring(v:preview{path = "a.txt", base = "old\n"})) end)
	cmd("Mk", function() qed.fs.mkdir("fresh") end)
end}`

@(private = "file")
walk_logged :: proc(e: ^E2E, text: string) -> bool {
	for l in e.ed.log {
		if l.source == "W" && l.text == text {
			return true
		}
	}
	return false
}

@(private = "file")
walk_run_cmd :: proc(t: ^testing.T, e: ^E2E, name: string, loc := #caller_location) {
	cmd, ok := plugin_test_command(&e.ed, name)
	testing.expectf(t, ok, "%s registered", name, loc = loc)
	command_run(&e.ed, cmd)
	plugin_flush(&e.ed)
}

@(private = "file")
walk_start :: proc(t: ^testing.T) -> E2E {
	e := e2e_root_start("m")
	walk_tree_fixture(e.ed.working_root)
	pl := e2e_plugin(&e, "w", WALK_PLUGIN)
	testing.expect_value(t, pl.state, PluginState.Enabled)
	return e
}

@(test)
e2e_walk_lua_handles :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	walk_run_cmd(t, &e, "W: Counts")
	for l in e.ed.log {
		if l.source == "W" && strings.has_prefix(l.text, "count") {
			testing.expect_value(t, l.text, "count 8 ready true within 2 union 4 dot 11")
		}
	}
	testing.expect(t, walk_logged(&e, "narrow false"), "within on a narrowed handle raises")
	testing.expect(t, walk_logged(&e, "dirs false"), "count is for walk handles")
}

@(test)
e2e_walk_fs_writes :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/sub", root), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/link", root), context.temp_allocator))
	inside := fmt.tprintf("%s/made/sub/b.txt", root)
	gen := e.ed.walk_gen
	walk_run_cmd(t, &e, "W: Fs")
	testing.expect(t, e.ed.walk_gen > gen, "writes invalidate walks")
	for line in ([]string{"mkdir true:nil", "mkdir again nil:exists", "copy true:nil", "copy over nil:exists", "copy missing nil:not found", "rename true:nil", "rename over nil:exists", "rename link true:nil", "copy link true:nil", "remove true:nil", "remove link true:nil", "remove missing nil:not found"}) {
		testing.expectf(t, walk_logged(&e, line), "logged %q", line)
	}
	testing.expect(t, !os.exists(inside), "moved away")
	testing.expect(t, os.exists(fmt.tprintf("%s/sub/b.txt", root)), "removing a link leaves its target")
	testing.expect(t, os.exists(fmt.tprintf("%s/a.txt", root)), "a refused overwrite leaves the source")
	st: posix.stat_t
	testing.expect(t, posix.lstat(strings.clone_to_cstring(fmt.tprintf("%s/link2", root), context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode), "rename keeps a link a link")
}

@(test)
e2e_walk_fs_rename_repaths :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	b := fmt.tprintf("%s/sub/b.txt", root)
	testing.expect(t, editor_open_path(&e.ed, b), "open")
	testing.expect_value(t, fs_rename(&e.ed, fmt.tprintf("%s/sub", root), fmt.tprintf("%s/sub2", root)), FsError.None)
	testing.expect_value(t, editor_buffer(&e.ed).path, fmt.tprintf("%s/sub2/b.txt", root))
}

@(test)
e2e_walk_lua_tree_view :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	e2e_resize(&e, 160, 40)
	test_list_built = 0
	walk_run_cmd(t, &e, "W: Tree")
	v := test_view(&e.ed)
	testing.expect(t, v != nil && v.list.tree && v.size == .Tree, "a tree view opens")
	testing.expect_value(t, walk_rels(v.list.source.entries[:], root), "a.txt,main.txt,other,sub")
	e2e_render(&e)
	g := pane_geom(&e.ed, v)
	testing.expectf(t, test_list_built <= 3 * g.list.h, "only visible rows are built, built %d", test_list_built)
	testing.expect(t, e2e_grid_has(&e, "All │ Sub"), "tabs render")
	testing.expect(t, e2e_grid_has(&e, "find it"), "field hint renders")
	testing.expect(t, e2e_grid_has(&e, "hint row"), "footer hints render")
	testing.expect(t, e2e_grid_has(&e, "chip"), "chips render")
	testing.expect(t, e2e_grid_has(&e, "▸ sub/"), "dirs render collapsed")

	walk_run_cmd(t, &e, "W: Marks")
	testing.expect(t, walk_logged(&e, "marks true"), "marks apply")
	testing.expect(t, walk_logged(&e, "bad false"), "an unknown color raises")
	e2e_key(&e, .Arrow_Down)
	e2e_render(&e)
	x, y, found := nav_screen_find(&e, "a.txt")
	testing.expect(t, found, "a.txt row")
	testing.expect_value(t, e2e_cell(&e, g.list.x, y), '▌')
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, g.list.x, y)), e2e_rgb(COLOR_GIT_ADD))
	testing.expect(t, strings.contains(e2e_row_text(&e, y), "a.txt  <- old"), "suffix renders")
	testing.expect(t, strings.contains(e2e_row_text(&e, y), "+12  -3"), "sizes render")
	ox, oy, _ := nav_screen_find(&e, "other/")
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, ox, oy)), e2e_rgb(COLOR_FILETREE_IGNORED))
	walk_run_cmd(t, &e, "W: Unmark")
	e2e_render(&e)
	testing.expect(t, e2e_cell(&e, g.list.x, y) != '▌', "false drops a mark")

	e2e_key(&e, .Arrow_Right)
	plugin_flush(&e.ed)
	testing.expect(t, walk_logged(&e, "tab 2"), "Right switches tabs")
	plugin_flush(&e.ed)
	v = test_view(&e.ed)
	testing.expect_value(t, walk_rels(v.list.source.entries[:], root), "sub,sub/b.txt")
	e2e_key(&e, .Arrow_Left)
	plugin_flush(&e.ed)
	plugin_flush(&e.ed)
	v = test_view(&e.ed)
	testing.expect_value(t, v.tab, 0)

	for i, n := 0, len(v.list.source.entries); i < n; i += 1 {
		if walk_rel(v.list.source.entries[i].path, root) == "sub" {
			v.list.sel = i
		}
	}
	e2e_key(&e, .Enter)
	plugin_flush(&e.ed)
	testing.expect(t, walk_logged(&e, "expand sub true true"), "Enter on a dir expands it and fires expand")
	v = test_view(&e.ed)
	testing.expect(t, strings.contains(walk_rels(v.list.source.entries[:], root), "sub/b.txt"), "expanded rows")

	e2e_type(&e, "b.t")
	testing.expect(t, v.list.source.filtering, "the filter ranks paths")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "sub/b.txt"), "filtered rows show relative paths")
	e2e_key(&e, .Esc)
	testing.expect(t, test_view(&e.ed) != nil && !v.list.source.filtering, "Esc clears the filter first")

	walk_run_cmd(t, &e, "W: Mk")
	e2e_render(&e)
	testing.expect(t, strings.contains(walk_rels(test_view(&e.ed).list.source.entries[:], root), "fresh"), "a write refills the view")

	walk_run_cmd(t, &e, "W: Input")
	testing.expect(t, walk_logged(&e, "footer true"), "footer input opens")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "Name: x"), "footer input renders")
	e2e_type(&e, "y")
	e2e_key(&e, .Enter)
	plugin_flush(&e.ed)
	testing.expect(t, walk_logged(&e, "submit xy"), "Enter submits")
	walk_run_cmd(t, &e, "W: Input")
	e2e_key(&e, .Esc)
	plugin_flush(&e.ed)
	testing.expect(t, walk_logged(&e, "submit nil"), "Esc cancels with nil")
	testing.expect(t, test_view(&e.ed) != nil, "and keeps the view")

	walk_run_cmd(t, &e, "W: Chips")
	testing.expect(t, !test_view(&e.ed).chips[0].on, "chips update")
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "new hints"), "hints update")
	g = pane_geom(&e.ed, test_view(&e.ed))
	xs, _ := pane_chips_layout(&e.ed, test_view(&e.ed), g)
	e2e_mouse(&e, xs[0], g.footer_y)
	plugin_flush(&e.ed)
	testing.expect(t, walk_logged(&e, "chip ran"), "a chip click runs its command")

	walk_run_cmd(t, &e, "W: Tab")
	testing.expect(t, walk_logged(&e, "tab now 1 2"), "v:tab gets and sets")
	e.ed.filetree.scanned = true
	walk_run_cmd(t, &e, "W: Expand")
	testing.expect(t, walk_logged(&e, "expand all true"), "expand all")
	walk_run_cmd(t, &e, "W: Diff")
	testing.expect(t, walk_logged(&e, "preview true"), "v:preview")
	testing.expect(t, test_view(&e.ed).preview.diff, "a base shows a diff")

	e2e_key(&e, .Esc)
	testing.expect(t, test_view(&e.ed) == nil, "Esc with an empty filter closes")
	saved := pane_saved_find(&e.ed, "wt")
	testing.expect(t, saved != nil && len(saved.expanded) > 0, "expanded dirs persist by id")
}

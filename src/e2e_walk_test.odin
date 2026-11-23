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

	walk_invalidate(ed, "/nowhere/else.txt")
	testing.expect(t, walk_valid(w), "a write outside the root leaves the walk alone")
	ignore := make(map[string]bool, context.temp_allocator)
	ignore[fmt.tprintf("%s/sub", root)] = true
	gen := w.gen
	walk_ignore_set(ed, root, ignore, true)
	testing.expect(t, !walk_valid(w) && w.gen > gen, "a new ignore set stamps the walk stale")
	gen = w.gen
	walk_ignore_set(ed, root, ignore, true)
	testing.expect_value(t, w.gen, gen)
	testing.expect(t, strings.contains(walk_rels(walk_cands(ed, w), root), "sub/b.txt"), "a stale walk serves its old candidates")
	testing.expect(t, w.pw.active, "while the prewarm reruns it")
	for !walk_valid(w) {
		walk_pump(ed)
	}
	testing.expect(t, w.gen > gen, "landing bumps the stamp")
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
local v, h, hw, hd
local function note(s) qed.log(s) end
local function cmd(name, run) qed.command{name = name, run = run} end
local function res(ok, err) return tostring(ok) .. ":" .. tostring(err) end
return {setup = function()
	qed.meta{display_name = "W"}
	cmd("Make", function()
		hw, hd = qed.fs.walk{}, qed.fs.walk{dotfiles = true}
		note(("first %s ready %s scoped %s"):format(res(hw:count()), tostring(hw:ready()), res(hw:within{"sub/b.txt"}:count())))
		hd:count()
	end)
	cmd("Counts", function()
		local w = hw
		note(("count %d ready %s within %d union %d dot %d"):format(w:count(), tostring(w:ready()),
			w:within{"sub/b.txt"}:count(), w:within{"sub/b.txt"}:union{"gone/z.txt"}:count(), hd:count()))
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
				change = function(_, item) note("change " .. qed.path.base(item.path)) end,
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
	cmd("Write", function() qed.fs.write("written.txt", "w") end)
	cmd("Ignore", function() h:ignore{"other"} end)
	cmd("Reveal", function() note("reveal " .. tostring(v:reveal("sub/deep/c.txt"))) end)
	cmd("Select", function() v:set(h, {selected = "a.txt"}) end)
	cmd("Into", function()
		note("copy into " .. res(qed.fs.copy("sub", "sub/deep/sub")))
		note("rename into " .. res(qed.fs.rename("sub", "sub/x")))
		note("remove root " .. res(qed.fs.remove(qed.root())))
		note("copy fifo " .. res(qed.fs.copy("pipe", "pipe2")))
		note("copy dir with fifo " .. res(qed.fs.copy("other", "other2")))
	end)
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
	walk_run_cmd(t, &e, "W: Make")
	testing.expect(t, walk_logged(&e, "first nil:pending ready false scoped 2:nil"), "count is pending until the walk lands; a listed scope is ready at once")
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
	}
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
	w := walk_acquire(&e.ed, root, false, false)
	walk_cands(&e.ed, w)
	walk_run_cmd(t, &e, "W: Fs")
	testing.expect(t, !walk_valid(w), "writes invalidate walks")
	walk_release(w)
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
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, ox, oy)), e2e_rgb(COLOR_PANE_DIM_FG))
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

@(test)
e2e_walk_fs_refusals :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	posix.mkfifo(strings.clone_to_cstring(fmt.tprintf("%s/pipe", root), context.temp_allocator), {.IRUSR, .IWUSR})
	posix.mkfifo(strings.clone_to_cstring(fmt.tprintf("%s/other/fifo", root), context.temp_allocator), {.IRUSR, .IWUSR})
	walk_run_cmd(t, &e, "W: Into")
	for line in ([]string{"copy into nil:into itself", "rename into nil:into itself", "remove root nil:the root", "copy fifo nil:not a file, dir or link", "copy dir with fifo true:nil"}) {
		testing.expectf(t, walk_logged(&e, line), "logged %q", line)
	}
	testing.expect(t, os.exists(fmt.tprintf("%s/other2/d.txt", root)) && !fs_lexists(fmt.tprintf("%s/other2/fifo", root)), "special files are skipped")
	testing.expect(t, !os.exists(fmt.tprintf("%s/sub/deep/sub", root)), "nothing copied into itself")
}

@(test)
e2e_walk_tree_keys :: proc(t: ^testing.T) {
	e := walk_start(t)
	defer e2e_stop(&e)
	root := e.ed.working_root
	e2e_resize(&e, 160, 40)
	walk_run_cmd(t, &e, "W: Tree")
	plugin_flush(&e.ed)
	e2e_type(&e, "txt")
	plugin_flush(&e.ed)
	first := test_view_selected(&e.ed)
	testing.expect(t, walk_logged(&e, fmt.tprintf("change %s", first[strings.last_index_byte(first, '/') + 1:])), "change fires for a new filtered selection")
	e2e_key(&e, .Arrow_Down)
	plugin_flush(&e.ed)
	second := test_view_selected(&e.ed)
	testing.expect(t, walk_logged(&e, fmt.tprintf("change %s", second[strings.last_index_byte(second, '/') + 1:])), "and when moving in the filtered list")
	e2e_key(&e, .Esc)

	walk_run_cmd(t, &e, "W: Reveal")
	testing.expect(t, walk_logged(&e, "reveal true"), "reveal finds a nested file")
	testing.expect_value(t, ft_rel(&e, root), "sub/deep/c.txt")
	walk_run_cmd(t, &e, "W: Select")
	testing.expect_value(t, ft_rel(&e, root), "a.txt")

	v := test_view(&e.ed)
	v.list.anchor = v.list.sel
	v.list.sel = 0
	walk_run_cmd(t, &e, "W: Write")
	e2e_render(&e)
	v = test_view(&e.ed)
	testing.expect(t, v.list.anchor != nil, "a refill keeps the range")
	if a, ok := v.list.anchor.?; ok {
		testing.expect_value(t, walk_rel(v.list.source.entries[a].path, root), "a.txt")
	}

	walk_run_cmd(t, &e, "W: Ignore")
	v = test_view(&e.ed)
	testing.expect(t, v.list.source.walk.stale && len(v.list.source.walk.ignore) == 1, "h:ignore restales the walk")
	list_walk_fill(&e.ed, v)
	testing.expect(t, !strings.contains(walk_rels(v.list.source.entries[:], root), "other"), "ignored paths drop from the tree")
}

@(private = "file")
ft_rel :: proc(e: ^E2E, root: string) -> string {
	v := test_view(&e.ed)
	return walk_rel(v.list.source.entries[v.list.sel].path, root)
}

@(test)
e2e_walk_tree_filter_after_write :: proc(t: ^testing.T) {
	e := e2e_root_start("m")
	defer e2e_stop(&e)
	root := e.ed.working_root
	walk_tree_fixture(root)
	filetree_open_all(&e.ed)
	e2e_git_settle(&e)
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
	}
	w := ft_walk(&e.ed)
	testing.expectf(t, len(w.cands) > 0, "prewarm landed %d (built %v stale %v ready %v)", len(w.cands), w.built, w.stale, w.ignore_ready)
	e2e_type(&e, "txt")
	testing.expect(t, len(ft_entries(&e.ed)) > 0, "filtered rows")
	e2e_key(&e, .Esc)
	for _ in 0 ..< 2 {
		e2e_key(&e, .Arrow_Down)
	}
	e2e_key(&e, .Arrow_Down, .Shift)
	e2e_key(&e, .Ctrl_D)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
	}
	e2e_key(&e, .Ctrl_N)
	e2e_type(&e, "new/f.txt")
	e2e_key(&e, .Enter)
	e2e_type(&e, "f.t")
	testing.expect(t, w.pw.active, "the filter serves the stale walk while the prewarm reruns it")
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
	}
	e2e_render(&e)
	testing.expectf(t, len(ft_entries(&e.ed)) > 0, "filtered rows after writes: cands %d built %v stale %v", len(w.cands), w.built, w.stale)
}

@(test)
e2e_walk_expand_all_streams :: proc(t: ^testing.T) {
	e := e2e_root_start("m")
	defer e2e_stop(&e)
	for d in 0 ..< 5 {
		os.make_directory_all(fmt.tprintf("%s/d%d/sub", e.dir, d))
		nav_write(fmt.tprintf("%s/d%d/f.txt", e.dir, d), "x\n")
		nav_write(fmt.tprintf("%s/d%d/sub/g.txt", e.dir, d), "x\n")
	}
	posix.symlink(strings.clone_to_cstring(e.dir, context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/d0/sub/loop", e.dir), context.temp_allocator))
	filetree_open_all(&e.ed)
	e2e_git_settle(&e)
	e2e_render(&e)
	top := len(ft_entries(&e.ed))
	testing.expect_value(t, top, 6)
	saved := walk_fill_slice_ms
	walk_fill_slice_ms = 0
	defer walk_fill_slice_ms = saved

	ft_set_sel(&e.ed, 2)
	nav_alt(&e, 'e')
	testing.expect(t, walk_trees_busy(&e.ed), "one dir per fill: the rest is pending")
	testing.expect(t, len(ft_tree_list(&e.ed).tree.source.entries) < top + 15, "rows stream in")
	sel, _ := ft_selected(&e.ed)
	testing.expect_value(t, walk_rel(sel.path, e.dir), "d2")
	for i := 0; walk_trees_busy(&e.ed) && i < 100; i += 1 {
		e2e_key(&e, .Arrow_Down)
		e2e_key(&e, .Arrow_Up)
		e2e_ui_settle(&e)
		sel, _ = ft_selected(&e.ed)
		testing.expect_value(t, walk_rel(sel.path, e.dir), "d2")
	}
	testing.expect(t, !walk_trees_busy(&e.ed), "the expansion finishes")
	testing.expect_value(t, len(ft_entries(&e.ed)), top + 16)
	testing.expect(t, strings.contains(walk_rels(ft_entries(&e.ed), e.dir), "d4/sub/g.txt"), "the deepest rows land")
	testing.expect(t, !strings.contains(walk_rels(ft_entries(&e.ed), e.dir), "loop/"), "a symlinked dir is a leaf, so a cycle ends")

	nav_alt(&e, 'e')
	testing.expect_value(t, len(ft_entries(&e.ed)), top)
	testing.expect_value(t, ft_expanded_count(&e.ed), 0)
	nav_alt(&e, 'e')
	testing.expect_value(t, len(ft_entries(&e.ed)), top + 16)
	testing.expect(t, !walk_trees_busy(&e.ed), "read dirs are cached until the walk restales")
	nav_alt(&e, 'e')

	clear(&ft_tree_list(&e.ed).tree.source.dirs)
	nav_alt(&e, 'e')
	testing.expect(t, walk_trees_busy(&e.ed), "expanding again")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, filetree_active(&e.ed), "Esc stops the expansion before it closes the tree")
	testing.expect(t, !walk_trees_busy(&e.ed), "nothing left to read")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, !filetree_active(&e.ed), "Esc closes the tree when no Expand All runs")
}

@(test)
e2e_walk_raise_keeps_no_ref :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	src := e2e_plugin(&e, "src", `return {setup = function()
		qed.command{name = "Give", run = function() qed:emit("src:give", {walk = qed.fs.walk, dirs = qed.fs.dirs}) end}
	end}`)
	e2e_plugin(&e, "dst", `local got
	return {setup = function()
		qed:on("src:give", function(d) got = d end)
		qed.command{name = "Call", run = function()
			local a = select(2, pcall(got.walk, {root = "/tmp"}))
			local b = select(2, pcall(got.dirs))
			qed.log(tostring(a) .. "|" .. tostring(b))
		end}
	end}`)
	give, _ := plugin_test_command(&e.ed, "Src: Give")
	plugin_command_run(&e.ed, give)
	plugin_flush(&e.ed)
	plugin_unload(&e.ed, src)
	src.state = .Disabled
	walks, lists := len(e.ed.walks), len(e.ed.plugins.lists)
	call, _ := plugin_test_command(&e.ed, "Dst: Call")
	plugin_command_run(&e.ed, call)
	found := false
	for l in e.ed.log {
		found ||= l.source == "Dst" && strings.count(l.text, "plugin is not loaded") == 2
	}
	testing.expect(t, found, "a call from an unloaded plugin raises")
	testing.expect_value(t, len(e.ed.walks), walks)
	testing.expect_value(t, len(e.ed.plugins.lists), lists)
}

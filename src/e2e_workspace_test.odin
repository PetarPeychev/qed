package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

cwd_fixture :: proc(e: ^E2E) {
	root := e.ed.working_root
	for d in ([]string{"alpha", "apple", "Beta", ".hid", "alpha/inner", "alpha/Zed"}) {
		os.make_directory(fmt.tprintf("%s/%s", root, d))
	}
	nav_write(fmt.tprintf("%s/file.txt", root), "x")
	e2e_run(fmt.tprintf("ln -s %s %s", shell_quote(fmt.tprintf("%s/alpha", root)), shell_quote(fmt.tprintf("%s/link", root))))
}

WsState :: struct {
	open:      bool,
	query:     string,
	names:     string,
	paths:     []string,
	caret:     int,
	selection: [2]int,
	selected:  bool,
	highlight: string,
}

cwd_state :: proc(e: ^E2E) -> WsState {
	out := ft_lua(&e.ed, `local s = qed.plugin("workspace").state()
		if not s then return "" end
		local sel = s.selection or {-1, -1}
		return table.concat({"open", s.query, table.concat(s.labels, ","), table.concat(s.paths, "\1"), s.caret, sel[1], sel[2], s.selected or ""}, "\2")`)
	if out == "" {
		return {}
	}
	parts := strings.split(out, "\x02", context.temp_allocator)
	caret, _ := strconv.parse_int(parts[4])
	lo, _ := strconv.parse_int(parts[5])
	hi, _ := strconv.parse_int(parts[6])
	paths := strings.split(parts[3], "\x01", context.temp_allocator) if parts[3] != "" else nil
	return {open = true, query = parts[1], names = parts[2], paths = paths, caret = caret, selection = {lo, hi}, selected = lo >= 0, highlight = parts[7]}
}

cwd_open :: proc(e: ^E2E) -> bool {
	return cwd_state(e).open
}

cwd_names :: proc(e: ^E2E) -> string {
	state := cwd_state(e)
	return state.names if state.open else "<closed>"
}

cwd_first_path :: proc(e: ^E2E) -> string {
	state := cwd_state(e)
	return state.paths[0] if len(state.paths) > 0 else ""
}

cwd_reopen :: proc(e: ^E2E) {
	if cwd_open(e) {
		e2e_key(e, .Esc)
	}
	e2e_key(e, .Ctrl_O)
}

cwd_set :: proc(e: ^E2E, query: string) {
	ft_lua(&e.ed, strings.concatenate({`qed.plugin("workspace").set_query(`, lua_quote(query), `) return ""`}, context.temp_allocator))
}

cwd_query :: proc(e: ^E2E) -> string {
	state := cwd_state(e)
	return state.query if state.open else "<closed>"
}

cwd_confirm :: proc(e: ^E2E) -> string {
	if dialog, ok := test_dialog(&e.ed); ok && dialog.kind == "confirm" {
		return dialog.question
	}
	return ""
}

@(test)
e2e_cwd_open_prefill :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	state := cwd_state(&e)
	testing.expect(t, state.open, "Ctrl+O opens the picker")
	testing.expect_value(t, state.query, fmt.tprintf("%s/", root))
	testing.expect_value(t, state.caret, len(state.query))
	testing.expect(t, !state.selected, "nothing selected on open")
	testing.expect_value(t, state.names, "Beta,alpha,apple,link")
	testing.expect_value(t, state.highlight, "Beta")

	box := node_rect(&e.ed, "workspace")
	testing.expect_value(t, box.w, PICKER_WIDTH)
	top := e2e_row(&e, box.y)
	testing.expectf(t, strings.contains(top, "┌──────────") && !strings.contains(top, filepath.base(root)), "no title on the border: %q", top)
	testing.expect(t, strings.contains(e2e_row(&e, box.y + 1), fmt.tprintf("%s/", filepath.base(root))), "prompt row")
	testing.expect(t, strings.contains(e2e_row(&e, box.y + 3), "Beta"), "first row under the prompt and its rule")

	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, cwd_state(&e).highlight, "apple")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, cwd_state(&e).highlight, "alpha")

	e2e_key(&e, .Ctrl_A)
	state = cwd_state(&e)
	testing.expect(t, state.selected && state.selection[0] == 0 && state.selection[1] == len(state.query), "Ctrl+A selects the whole query")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, !cwd_open(&e), "the same chord closes the picker")

	owned := e.ed.working_root
	e.ed.working_root = "/"
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_query(&e), "/")
	e2e_key(&e, .Esc)
	e.ed.working_root = owned
}

@(test)
e2e_cwd_filters :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "a")
	testing.expect_value(t, cwd_names(&e), "alpha,apple")
	e2e_type(&e, "l")
	testing.expect_value(t, cwd_names(&e), "alpha")

	cwd_reopen(&e)
	e2e_type(&e, "be")
	testing.expect_value(t, cwd_names(&e), "Beta")
	cwd_reopen(&e)
	e2e_type(&e, "Be")
	testing.expect_value(t, cwd_names(&e), "Beta")
	cwd_reopen(&e)
	e2e_type(&e, "bE")
	testing.expect_value(t, cwd_names(&e), "")

	cwd_reopen(&e)
	e2e_key(&e, .Esc)
	filetree_toggle_dotfiles(&e.ed)
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), ".hid,Beta,alpha,apple,link")
	e2e_key(&e, .Esc)
	testing.expect(t, !cwd_open(&e), "Esc closes")
}

@(test)
e2e_cwd_dotfiles_follow_tree :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)

	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")
	e2e_key(&e, .Esc)
	e2e_plugin_config(&e, "filetree", `{"show_dotfiles": true}`, hot = true)
	plugin_flush(&e.ed)
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), ".hid,Beta,alpha,apple,link")
	e2e_key(&e, .Esc)
	filetree_toggle_dotfiles(&e.ed)
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")
	e2e_key(&e, .Esc)
	filetree_toggle_dotfiles(&e.ed)
	e2e_plugin_config(&e, "filetree", `{"enabled": false, "show_dotfiles": true}`, hot = true)
	plugin_flush(&e.ed)
	testing.expect(t, plugin_find(&e.ed.plugins, "filetree").state == .Disabled, "the tree is off")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")
}

@(test)
e2e_cwd_bases :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "../")
	testing.expect_value(t, cwd_query(&e), "../")
	found := false
	for path in cwd_state(&e).paths {
		if path == root {
			found = true
		}
	}
	testing.expect(t, found, "../ lists the root's siblings, including itself")

	cwd_reopen(&e)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "al")
	testing.expect_value(t, cwd_names(&e), "alpha")
	testing.expect_value(t, cwd_first_path(&e), fmt.tprintf("%s/alpha", root))

	cwd_reopen(&e)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "~/")
	home, _ := filepath.clean(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	for path in cwd_state(&e).paths {
		testing.expect(t, filepath.base(path) != "." && filepath.base(path) != "..", "no . / .. rows")
		testing.expect_value(t, filepath.dir(path), home)
	}
}

@(test)
e2e_cwd_drill :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "al/")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alpha/", root))
	testing.expect_value(t, cwd_names(&e), "Zed,inner")
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Tab)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alpha/inner/", root))
	testing.expect_value(t, cwd_names(&e), "")
	e2e_key(&e, .Tab)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alpha/inner/", root))

	cwd_reopen(&e)
	e2e_type(&e, "nope/")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/nope/", root))
	testing.expect_value(t, cwd_names(&e), "")

	cwd_reopen(&e)
	e2e_type(&e, "al")
	e2e_key(&e, .Arrow_Left)
	e2e_type(&e, "/")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/a/l", root))

	cwd_reopen(&e)
	e2e_type(&e, "al")
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "/")
	testing.expect_value(t, cwd_query(&e), "/")
}

@(test)
e2e_cwd_backspace :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	home, _ := filepath.clean(os.get_env("HOME", context.temp_allocator), context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")

	cwd_set(&e, "/")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), "/")

	cwd_set(&e, "~/")
	e2e_key(&e, .Backspace2)
	if home != "/" {
		parent := filepath.dir(home)
		testing.expect_value(t, cwd_query(&e), "/" if parent == "/" else fmt.tprintf("%s/", parent))
	}

	cwd_set(&e, "../../")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), "../")

	cwd_set(&e, "")
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), "")

	cwd_set(&e, fmt.tprintf("%s/al", root))
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/a", root))
	testing.expect_value(t, cwd_names(&e), "alpha,apple")

	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Arrow_Left)
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alph/", root))

	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Ctrl_A)
	e2e_key(&e, .Backspace2)
	testing.expect_value(t, cwd_query(&e), "")
}

@(test)
e2e_cwd_mouse_and_paste :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	rows := node_rect(&e.ed, "workspace_rows")
	e2e_mouse(&e, rows.x + 2, rows.y + 1)
	e2e_mouse(&e, rows.x + 2, rows.y + 1)
	e2e_ui_settle(&e)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alpha/", root))
	testing.expect(t, cwd_open(&e), "double-click drills in, it does not commit")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_paste(&e, "in")
	testing.expect_value(t, cwd_names(&e), "inner")
}

@(test)
e2e_cwd_commit :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	alpha := fmt.tprintf("%s/alpha", root)
	inside := fmt.tprintf("%s/in.txt", alpha)
	nav_write(inside, "inside")
	testing.expect(t, editor_open_path(&e.ed, inside), "open inside buffer")
	testing.expect_value(t, len(e.ed.buffers), 2)
	nav_alt(&e, 'f')
	testing.expect(t, len(ft_entries(&e.ed)) > 0, "tree populated for the old root")
	e2e_key(&e, .Esc)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, !cwd_open(&e), "Enter on the prefilled root closes, ignoring the highlight")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 2)

	e2e_key(&e, .Ctrl_O)
	cwd_set(&e, fmt.tprintf("%s/nope", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_open(&e), "a missing dir keeps the picker open")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, e.ed.message, fmt.tprintf("Not a directory: %s/nope", root))
	testing.expect_value(t, e.ed.message_level, LogLevel.Error)

	cwd_set(&e, fmt.tprintf("%s/file.txt", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_open(&e), "a file is not a directory")
	testing.expect_value(t, e.ed.working_root, root)

	cwd_set(&e, fmt.tprintf("%s/al", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_open(&e), "Enter commits the written path, not the highlighted completion")

	cwd_set(&e, alpha)
	e2e_key(&e, .Enter)
	testing.expect(t, !cwd_open(&e), "commit closes the picker")
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect_value(t, editor_buffer(&e.ed).path, inside)
	testing.expect(t, !e.ed.welcome, "inside buffer stays current")
	testing.expect(t, strings.contains(e.ed.message, alpha), "root change is logged on the message line")
	testing.expect_value(t, len(ft_entries(&e.ed)), 0)
	testing.expect_value(t, ft_expanded_count(&e.ed), 0)

	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", alpha))
	e2e_key(&e, .Enter)
	testing.expect(t, !cwd_open(&e), "trailing slash means the same dir")
	testing.expect_value(t, e.ed.working_root, alpha)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "inner")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/inner", alpha))
	testing.expect(t, e.ed.welcome, "no buffers left lands on the welcome screen")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_open(&e), "Ctrl+O works on the welcome screen")
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "../..")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, root)
}

@(test)
e2e_cwd_unsaved_confirm :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	e2e_type(&e, "x")
	testing.expect(t, editor_buffer(&e.ed).modified, "main.txt is unsaved")

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "alpha")
	before := cwd_state(&e)
	e2e_key(&e, .Enter)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	testing.expect(t, cwd_open(&e), "the picker stays under the confirm")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	e2e_key(&e, .Enter)
	testing.expect(t, cwd_open(&e), "Cancel returns to the picker")
	after := cwd_state(&e)
	testing.expect_value(t, after.query, before.query)
	testing.expect_value(t, after.caret, before.caret)
	testing.expect_value(t, after.highlight, before.highlight)
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")

	e2e_key(&e, .Enter)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	e2e_key(&e, .Esc)
	testing.expect(t, cwd_open(&e), "Esc in the confirm returns to the picker")
	testing.expect_value(t, cwd_query(&e), before.query)
	testing.expect_value(t, e.ed.working_root, root)
	e2e_key(&e, .Esc)
	testing.expect(t, !cwd_open(&e), "second Esc closes the picker")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "alpha")
	e2e_key(&e, .Enter)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, e.ed.welcome, "confirmed close discards and lands on welcome")
	testing.expect(t, !cwd_open(&e), "confirm closes the picker too")
}

@(test)
e2e_cwd_palette_and_welcome :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, strings.contains(palette_labels(&e), "|Workspace: Open Directory|"), "listed on the welcome palette")
	e2e_key(&e, .Esc)
	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_open(&e), "Ctrl+O opens on the welcome screen")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", e.ed.working_root))
	testing.expect_value(t, cwd_names(&e), "")
	e2e_render(&e)
	e2e_key(&e, .Esc)
	testing.expect(t, !cwd_open(&e), "Esc cancels")
}

cwd_tree_select :: proc(e: ^E2E, name: string) -> bool {
	for entry, i in ft_entries(&e.ed) {
		if entry.name == name {
			ft_set_sel(&e.ed, i)
			return true
		}
	}
	return false
}

cwd_tree_names :: proc(e: ^E2E) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for entry in ft_entries(&e.ed) {
		append(&names, entry.name)
	}
	return strings.join(names[:], ",", context.temp_allocator)
}

@(test)
e2e_cwd_tree_set_root :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	alpha := fmt.tprintf("%s/alpha", root)
	nav_write(fmt.tprintf("%s/in.txt", alpha), "inside")

	nav_alt(&e, 'f')
	testing.expect(t, cwd_tree_select(&e, "file.txt"), "top-level file row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect(t, !cwd_open(&e), "Ctrl+O in the tree does not open the picker")

	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Enter)
	testing.expect(t, ft_expanded_count(&e.ed) > 0, "alpha expanded before the switch")
	testing.expect(t, cwd_tree_select(&e, "inner"), "inner row")
	e2e_key(&e, .Ctrl_O)
	inner := fmt.tprintf("%s/inner", alpha)
	testing.expect_value(t, e.ed.working_root, inner)
	testing.expect(t, filetree_active(&e.ed), "tree stays open")
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect_value(t, ft_sel(&e.ed), 0)
	testing.expect_value(t, ft_expanded_count(&e.ed), 0)
	testing.expect_value(t, cwd_tree_names(&e), "")
	testing.expect(t, e.ed.welcome, "clean outside buffer closed silently")
	e2e_render(&e)

	e2e_key(&e, .Esc)
	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_open(&e), "Ctrl+O outside the tree opens the picker")
	e2e_type(&e, "../../")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, root)

	nav_alt(&e, 'f')
	e2e_type(&e, "in.txt")
	testing.expect(t, cwd_tree_select(&e, "alpha/in.txt"), "filtered file row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect(t, filetree_active(&e.ed), "tree stays open")
	testing.expect_value(t, ft_query(&e.ed), "")
	testing.expect_value(t, cwd_tree_names(&e), "Zed,inner,in.txt")
	testing.expect(t, strings.contains(e.ed.message, alpha), "root change is logged")
}

@(test)
e2e_cwd_tree_keeps_scope :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	alpha := fmt.tprintf("%s/alpha", root)
	inside := fmt.tprintf("%s/in.txt", alpha)
	nav_write(inside, "inside")
	testing.expect(t, editor_open_path(&e.ed, inside), "open inside buffer")

	nav_alt(&e, 'o')
	testing.expect_value(t, ft_scope(&e.ed), "Open")
	testing.expect_value(t, cwd_tree_names(&e), "alpha,in.txt,main.txt")
	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect(t, filetree_active(&e.ed), "tree stays open")
	testing.expect_value(t, ft_scope(&e.ed), "Open")
	testing.expect_value(t, cwd_tree_names(&e), "in.txt")
	testing.expect_value(t, len(e.ed.buffers), 1)
}

@(test)
e2e_cwd_tree_unsaved_confirm :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	e2e_type(&e, "x")

	nav_alt(&e, 'f')
	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	testing.expect(t, filetree_active(&e.ed), "the tree stays under the confirm")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	e2e_key(&e, .Enter)
	testing.expect(t, filetree_active(&e.ed), "Cancel returns to the tree")
	testing.expect(t, filetree_active(&e.ed), "tree still open")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")
	testing.expect(t, cwd_tree_select(&e, "alpha"), "tree unchanged")

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Esc)
	testing.expect(t, filetree_active(&e.ed), "Esc in the confirm returns to the tree")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, filetree_active(&e.ed), "tree stays open after confirm")
	testing.expect_value(t, ft_mode(&e.ed), FtMode.Nav)
	testing.expect(t, e.ed.welcome, "confirmed close discards the outside buffer")
	testing.expect_value(t, cwd_tree_names(&e), "Zed,inner")
}

@(test)
cwd_path_under_root :: proc(t: ^testing.T) {
	testing.expect(t, path_under("/a/b/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/bc/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/b", "/a/b"))
	testing.expect(t, path_under("/x.txt", "/"))
}

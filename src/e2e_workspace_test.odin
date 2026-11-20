package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

cwd_pane :: proc(e: ^E2E) -> ^Pane {
	p := pane_focus(&e.ed)
	if p == nil || p.owner != "workspace" || pane_path(p) == nil {
		return nil
	}
	return p
}

cwd_names :: proc(e: ^E2E) -> string {
	p := cwd_pane(e)
	if p == nil {
		return "<closed>"
	}
	names := make([dynamic]string, context.temp_allocator)
	for it in p.list.items {
		append(&names, it.label)
	}
	return strings.join(names[:], ",", context.temp_allocator)
}

cwd_first_path :: proc(e: ^E2E) -> string {
	p := cwd_pane(e)
	if p == nil || len(p.list.items) == 0 {
		return ""
	}
	return p.list.items[0].path
}

cwd_reopen :: proc(e: ^E2E) {
	if cwd_pane(e) != nil {
		e2e_key(e, .Esc)
	}
	e2e_key(e, .Ctrl_O)
}

cwd_set :: proc(e: ^E2E, query: string) {
	p := cwd_pane(e)
	f := pane_path(p)
	textfield_set(&f.field, query)
	pane_field_changed(&e.ed, p, f)
}

cwd_query :: proc(e: ^E2E) -> string {
	p := cwd_pane(e)
	if p == nil {
		return "<closed>"
	}
	return textfield_str(&pane_path(p).field)
}

cwd_confirm :: proc(e: ^E2E) -> string {
	p := pane_focus(&e.ed)
	if p == nil || p.owner != "workspace" || len(p.text) == 0 {
		return ""
	}
	return p.text[0].text
}

@(test)
e2e_cwd_open_prefill :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	p := cwd_pane(&e)
	testing.expect(t, p != nil, "Ctrl+O opens the picker")
	f := pane_path(p)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	testing.expect_value(t, f.caret, len(f.text))
	_, _, sel := textfield_selection(&f.field)
	testing.expect(t, !sel, "nothing selected on open")
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")
	testing.expect_value(t, p.list.sel, 0)

	e2e_render(&e)
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + min(len(p.list.items), PALETTE_MAX_ROWS))
	testing.expect_value(t, pane_geom(&e.ed, p).box, box)
	top := e2e_row(&e, box.y)
	testing.expectf(t, strings.contains(top, "┌──────────") && !strings.contains(top, filepath.base(root)), "no title on the border: %q", top)
	testing.expect(t, strings.contains(e2e_row(&e, box.y + 1), fmt.tprintf("> %s/", root)), "prompt row")
	testing.expect(t, strings.contains(e2e_row(&e, box.y + 3), "Beta"), "first row under the separator")

	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, p.list.sel, 2)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, p.list.sel, 1)

	e2e_key(&e, .Ctrl_A)
	lo, hi, all := textfield_selection(&f.field)
	testing.expect(t, all && lo == 0 && hi == len(f.text), "Ctrl+A selects the whole query")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_pane(&e) == nil, "the same chord closes the picker")

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
	FILETREE_SHOW_DOTFILES = true
	e2e_key(&e, .Ctrl_O)
	FILETREE_SHOW_DOTFILES = false
	testing.expect_value(t, cwd_names(&e), ".hid,Beta,alpha,apple,link")
	e2e_key(&e, .Esc)
	testing.expect(t, cwd_pane(&e) == nil, "Esc closes")
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
	for it in cwd_pane(&e).list.items {
		if it.path == root {
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
	for it in cwd_pane(&e).list.items {
		testing.expect(t, it.label != "." && it.label != "..", "no . / .. rows")
		testing.expect_value(t, filepath.dir(it.path), home)
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
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")

	cwd_set(&e, "/")
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), "/")

	cwd_set(&e, "~/")
	e2e_key(&e, .Backspace)
	if home != "/" {
		parent := filepath.dir(home)
		testing.expect_value(t, cwd_query(&e), "/" if parent == "/" else fmt.tprintf("%s/", parent))
	}

	cwd_set(&e, "../../")
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), "../")

	cwd_set(&e, "")
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), "")

	cwd_set(&e, fmt.tprintf("%s/al", root))
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/a", root))
	testing.expect_value(t, cwd_names(&e), "alpha,apple")

	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Arrow_Left)
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alph/", root))

	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Ctrl_A)
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), "")
}

@(test)
e2e_cwd_mouse_and_paste :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	e2e_render(&e)
	g := pane_geom(&e.ed, cwd_pane(&e))
	e2e_mouse(&e, g.list.x + 2, g.list.y + 1)
	e2e_mouse(&e, g.list.x + 2, g.list.y + 1)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/alpha/", root))
	testing.expect(t, cwd_pane(&e) != nil, "double-click drills in, it does not commit")
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
	testing.expect(t, len(e.ed.filetree.entries) > 0, "tree populated for the old root")
	e2e_key(&e, .Esc)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) == nil, "Enter on the prefilled root closes, ignoring the highlight")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 2)

	e2e_key(&e, .Ctrl_O)
	cwd_set(&e, fmt.tprintf("%s/nope", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) != nil, "a missing dir keeps the picker open")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, e.ed.message, fmt.tprintf("Not a directory: %s/nope", root))
	testing.expect_value(t, e.ed.message_level, LogLevel.Error)

	cwd_set(&e, fmt.tprintf("%s/file.txt", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) != nil, "a file is not a directory")
	testing.expect_value(t, e.ed.working_root, root)

	cwd_set(&e, fmt.tprintf("%s/al", root))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) != nil, "Enter commits the written path, not the highlighted completion")

	cwd_set(&e, alpha)
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) == nil, "commit closes the picker")
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect_value(t, editor_buffer(&e.ed).path, inside)
	testing.expect(t, !e.ed.welcome, "inside buffer stays current")
	testing.expect(t, strings.contains(e.ed.message, alpha), "root change is logged on the message line")
	testing.expect_value(t, len(e.ed.filetree.entries), 0)
	testing.expect_value(t, len(e.ed.filetree.expanded), 0)

	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", alpha))
	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) == nil, "trailing slash means the same dir")
	testing.expect_value(t, e.ed.working_root, alpha)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "inner")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/inner", alpha))
	testing.expect(t, e.ed.welcome, "no buffers left lands on the welcome screen")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_pane(&e) != nil, "Ctrl+O works on the welcome screen")
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
	p := cwd_pane(&e)
	f := pane_path(p)
	query := strings.clone(textfield_str(&f.field), context.temp_allocator)
	caret := f.caret
	selected := p.list.sel
	e2e_key(&e, .Enter)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	picker := pane_focus(&e.ed).parent
	testing.expect(t, pane_find_handle(&e, picker).owner == "workspace", "the confirm sits on the picker")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	e2e_key(&e, .Enter)
	testing.expect(t, cwd_pane(&e) != nil, "Cancel returns to the picker")
	testing.expect_value(t, cwd_query(&e), query)
	testing.expect_value(t, pane_path(cwd_pane(&e)).caret, caret)
	testing.expect_value(t, cwd_pane(&e).list.sel, selected)
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")

	e2e_key(&e, .Enter)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	e2e_key(&e, .Esc)
	testing.expect(t, cwd_pane(&e) != nil, "Esc in the confirm returns to the picker")
	testing.expect_value(t, cwd_query(&e), query)
	testing.expect_value(t, e.ed.working_root, root)
	e2e_key(&e, .Esc)
	testing.expect(t, pane_focus(&e.ed) == nil, "second Esc closes the picker")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "alpha")
	e2e_key(&e, .Enter)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, e.ed.welcome, "confirmed close discards and lands on welcome")
	testing.expect(t, pane_focus(&e.ed) == nil, "confirm closes the picker too")
}

pane_find_handle :: proc(e: ^E2E, handle: u64) -> ^Pane {
	i := pane_index(&e.ed, handle)
	return &e.ed.panes[i] if i >= 0 else nil
}

@(test)
e2e_cwd_palette_and_welcome :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)
	e2e_key(&e, .Ctrl_P)
	testing.expect(t, strings.contains(palette_labels(&e), "|Workspace: Open Directory|"), "listed on the welcome palette")
	e2e_key(&e, .Esc)
	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_pane(&e) != nil, "Ctrl+O opens on the welcome screen")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", e.ed.working_root))
	testing.expect_value(t, cwd_names(&e), "")
	e2e_render(&e)
	e2e_key(&e, .Esc)
	testing.expect(t, cwd_pane(&e) == nil, "Esc cancels")
}

cwd_tree_select :: proc(e: ^E2E, name: string) -> bool {
	for entry, i in e.ed.filetree.entries {
		if entry.name == name {
			e.ed.filetree.selected = i
			return true
		}
	}
	return false
}

cwd_tree_names :: proc(e: ^E2E) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for entry in e.ed.filetree.entries {
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
	ft := &e.ed.filetree

	nav_alt(&e, 'f')
	testing.expect(t, cwd_tree_select(&e, "file.txt"), "top-level file row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect(t, cwd_pane(&e) == nil, "Ctrl+O in the tree does not open the picker")

	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Enter)
	testing.expect(t, len(ft.expanded) > 0, "alpha expanded before the switch")
	testing.expect(t, cwd_tree_select(&e, "inner"), "inner row")
	e2e_key(&e, .Ctrl_O)
	inner := fmt.tprintf("%s/inner", alpha)
	testing.expect_value(t, e.ed.working_root, inner)
	testing.expect(t, ft.active, "tree stays open")
	testing.expect_value(t, ft.mode, FileTreeMode.Nav)
	testing.expect_value(t, ft.selected, 0)
	testing.expect_value(t, len(ft.expanded), 0)
	testing.expect_value(t, cwd_tree_names(&e), "")
	testing.expect(t, e.ed.welcome, "clean outside buffer closed silently")
	e2e_render(&e)

	e2e_key(&e, .Esc)
	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cwd_pane(&e) != nil, "Ctrl+O outside the tree opens the picker")
	e2e_type(&e, "../../")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, root)

	nav_alt(&e, 'f')
	e2e_type(&e, "in.txt")
	testing.expect(t, cwd_tree_select(&e, "alpha/in.txt"), "filtered file row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect(t, ft.active, "tree stays open")
	testing.expect_value(t, textfield_str(&ft.filter), "")
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
	ft := &e.ed.filetree

	nav_alt(&e, 'o')
	testing.expect_value(t, ft.scope, FileTreeScope.Open)
	testing.expect_value(t, cwd_tree_names(&e), "alpha,in.txt,main.txt")
	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect(t, ft.active, "tree stays open")
	testing.expect_value(t, ft.scope, FileTreeScope.Open)
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
	ft := &e.ed.filetree

	nav_alt(&e, 'f')
	testing.expect(t, cwd_tree_select(&e, "alpha"), "alpha row")
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_confirm(&e), "Close 1 buffer? (1 unsaved)")
	testing.expect(t, pane_focus(&e.ed).over == &ft.active, "the confirm sits on the tree")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	e2e_key(&e, .Enter)
	testing.expect(t, pane_focus(&e.ed) == nil, "Cancel returns to the tree")
	testing.expect(t, ft.active, "tree still open")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")
	testing.expect(t, cwd_tree_select(&e, "alpha"), "tree unchanged")

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Esc)
	testing.expect(t, pane_focus(&e.ed) == nil && ft.active, "Esc in the confirm returns to the tree")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, ft.active, "tree stays open after confirm")
	testing.expect_value(t, ft.mode, FileTreeMode.Nav)
	testing.expect(t, e.ed.welcome, "confirmed close discards the outside buffer")
	testing.expect_value(t, cwd_tree_names(&e), "Zed,inner")
}

@(test)
cwd_path_split :: proc(t: ^testing.T) {
	Case :: struct {
		query, base, term: string,
	}
	cases := []Case {
		{"", "", ""},
		{"src", "", "src"},
		{"src/", "src", ""},
		{"src/ma", "src", "ma"},
		{"../..", "..", ".."},
		{"../../g", "../..", "g"},
		{"~/", "~", ""},
		{"~/dev/q", "~/dev", "q"},
		{"/", "/", ""},
		{"/us", "/", "us"},
		{"/usr/lo", "/usr", "lo"},
	}
	for c in cases {
		base, term := path_split(c.query)
		testing.expectf(t, base == c.base && term == c.term, "%q -> (%q, %q), want (%q, %q)", c.query, base, term, c.base, c.term)
	}
}

@(test)
cwd_path_resolve :: proc(t: ^testing.T) {
	Case :: struct {
		base, want: string,
	}
	cases := []Case {
		{"", "/r/qed"},
		{"..", "/r"},
		{"../..", "/"},
		{"../../..", "/"},
		{"sub/dir", "/r/qed/sub/dir"},
		{"sub/../x", "/r/qed/x"},
		{"~", "/home/p"},
		{"~/dev", "/home/p/dev"},
		{"~/dev/..", "/home/p"},
		{"/", "/"},
		{"/usr/../etc", "/etc"},
	}
	for c in cases {
		got := path_resolve("/r/qed", "/home/p", c.base)
		testing.expectf(t, got == c.want, "%q -> %q, want %q", c.base, got, c.want)
	}
}

@(test)
cwd_path_prefix_smart_case :: proc(t: ^testing.T) {
	testing.expect(t, path_prefix_match("Games", ""))
	testing.expect(t, path_prefix_match("Games", "ga"))
	testing.expect(t, path_prefix_match("Games", "Ga"))
	testing.expect(t, !path_prefix_match("games", "Ga"))
	testing.expect(t, !path_prefix_match("Games", "gA"))
	testing.expect(t, !path_prefix_match("ga", "gam"))
	testing.expect(t, !path_prefix_match("agames", "ga"))
}

@(test)
cwd_path_under_root :: proc(t: ^testing.T) {
	testing.expect(t, path_under("/a/b/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/bc/c.txt", "/a/b"))
	testing.expect(t, !path_under("/a/b", "/a/b"))
	testing.expect(t, path_under("/x.txt", "/"))
}

@(test)
cwd_path_back_segment :: proc(t: ^testing.T) {
	Case :: struct {
		query, want: string,
	}
	cases := []Case {
		{"/home/p/qed/", "/home/p/"},
		{"/usr/", "/"},
		{"/", "/"},
		{"//", "/"},
		{"~/dev/games/", "~/dev/"},
		{"~/dev/", "~/"},
		{"~/", "/home/"},
		{"../../", "../"},
		{"../", ""},
		{"src/sub/", "src/"},
		{"src/", ""},
		{"dir/~/", "dir/"},
	}
	for c in cases {
		got := path_back(c.query, "/home/p")
		testing.expectf(t, got == c.want, "%q -> %q, want %q", c.query, got, c.want)
	}
	testing.expect_value(t, path_back("~/", "/root/"), "/")
}

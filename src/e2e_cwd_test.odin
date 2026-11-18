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

cwd_names :: proc(e: ^E2E) -> string {
	return strings.join(e.ed.cwdpick.names[:], ",", context.temp_allocator)
}

cwd_reopen :: proc(e: ^E2E) {
	if e.ed.cwdpick.active {
		e2e_key(e, .Esc)
	}
	e2e_key(e, .Ctrl_O)
}

cwd_set :: proc(e: ^E2E, query: string) {
	textfield_set(&e.ed.cwdpick.field, query)
	cwdpick_refilter(&e.ed)
}

cwd_query :: proc(e: ^E2E) -> string {
	return textfield_str(&e.ed.cwdpick.field)
}

@(test)
e2e_cwd_open_prefill :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	cp := &e.ed.cwdpick

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, cp.active, "Ctrl+O opens the picker")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	testing.expect_value(t, cp.field.caret, len(cp.field.text))
	_, _, sel := textfield_selection(&cp.field)
	testing.expect(t, !sel, "nothing selected on open")
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")
	testing.expect_value(t, cp.selected, 0)

	e2e_render(&e)
	box := pane_center(&e.ed, PALETTE_WIDTH, 2 + min(len(cp.matches), PALETTE_MAX_ROWS))
	top := e2e_row(&e, box.y)
	testing.expectf(t, strings.contains(top, "┌──────────") && !strings.contains(top, filepath.base(root)), "no title on the border: %q", top)

	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Arrow_Down)
	testing.expect_value(t, cp.selected, 2)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	e2e_key(&e, .Arrow_Up)
	testing.expect_value(t, cp.selected, 1)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))

	e2e_key(&e, .Ctrl_A)
	lo, hi, all := textfield_selection(&cp.field)
	testing.expect(t, all && lo == 0 && hi == len(cp.field.text), "Ctrl+A selects the whole query")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, !cp.active, "the same chord closes the picker")

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
	cp := &e.ed.cwdpick

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
	e.ed.filetree.show_dotfiles = true
	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_names(&e), ".hid,Beta,alpha,apple,link")
	e.ed.filetree.show_dotfiles = false
	e2e_key(&e, .Esc)
	testing.expect(t, !cp.active, "Esc closes")
}

@(test)
e2e_cwd_bases :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	cp := &e.ed.cwdpick

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "../")
	testing.expect_value(t, cwd_query(&e), "../")
	parent, _ := filepath.clean(fmt.tprintf("%s/..", root), context.temp_allocator)
	testing.expect_value(t, cp.base, parent)
	found := false
	for n in cp.names {
		if n == filepath.base(root) {
			found = true
		}
	}
	testing.expect(t, found, "../ lists the root's siblings, including itself")

	cwd_reopen(&e)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "al")
	testing.expect_value(t, cp.base, root)
	testing.expect_value(t, cwd_names(&e), "alpha")

	cwd_reopen(&e)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "~/")
	home, _ := filepath.clean(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, cp.base, home)
	for n in cp.names {
		testing.expect(t, n != "." && n != "..", "no . / .. rows")
	}
}

@(test)
e2e_cwd_drill :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)
	cwd_fixture(&e)
	root := strings.clone(e.ed.working_root, context.temp_allocator)
	cp := &e.ed.cwdpick

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
	testing.expect_value(t, cp.base, fmt.tprintf("%s/nope", root))
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
	cp := &e.ed.cwdpick
	home, _ := filepath.clean(os.get_env("HOME", context.temp_allocator), context.temp_allocator)

	e2e_key(&e, .Ctrl_O)
	cwd_set(&e, fmt.tprintf("%s/alpha/", root))
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", root))
	testing.expect_value(t, cp.base, root)
	testing.expect_value(t, cwd_names(&e), "Beta,alpha,apple,link")

	cwd_set(&e, "/")
	e2e_key(&e, .Backspace)
	testing.expect_value(t, cwd_query(&e), "/")

	cwd_set(&e, "~/")
	e2e_key(&e, .Backspace)
	if home != "/" {
		parent := filepath.dir(home)
		testing.expect_value(t, cwd_query(&e), "/" if parent == "/" else fmt.tprintf("%s/", parent))
		testing.expect_value(t, cp.base, parent)
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
	testing.expect(t, !e.ed.cwdpick.active, "Enter on the prefilled root closes, ignoring the highlight")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 2)

	e2e_key(&e, .Ctrl_O)
	cwd_set(&e, fmt.tprintf("%s/nope", root))
	e2e_key(&e, .Enter)
	testing.expect(t, e.ed.cwdpick.active, "a missing dir keeps the picker open")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, e.ed.message, fmt.tprintf("Not a directory: %s/nope", root))

	cwd_set(&e, fmt.tprintf("%s/file.txt", root))
	e2e_key(&e, .Enter)
	testing.expect(t, e.ed.cwdpick.active, "a file is not a directory")
	testing.expect_value(t, e.ed.working_root, root)

	cwd_set(&e, fmt.tprintf("%s/al", root))
	e2e_key(&e, .Enter)
	testing.expect(t, e.ed.cwdpick.active, "Enter commits the written path, not the highlighted completion")

	cwd_set(&e, alpha)
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.cwdpick.active, "commit closes the picker")
	testing.expect_value(t, e.ed.working_root, alpha)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect_value(t, editor_buffer(&e.ed).path, inside)
	testing.expect(t, !e.ed.welcome, "inside buffer stays current")
	testing.expect(t, strings.contains(e.ed.message, alpha), "root change is logged on the message line")
	testing.expect_value(t, len(e.ed.filetree.entries), 0)
	testing.expect_value(t, len(e.ed.filetree.expanded), 0)

	e2e_key(&e, .Ctrl_O)
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", alpha))
	cwd_set(&e, fmt.tprintf("%s/", alpha))
	e2e_key(&e, .Enter)
	testing.expect(t, !e.ed.cwdpick.active, "trailing slash means the same dir")
	testing.expect_value(t, e.ed.working_root, alpha)

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Ctrl_A)
	e2e_type(&e, "inner")
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/inner", alpha))
	testing.expect(t, e.ed.welcome, "no buffers left lands on the welcome screen")

	e2e_key(&e, .Ctrl_O)
	testing.expect(t, e.ed.cwdpick.active, "Ctrl+O works on the welcome screen")
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
	cp := &e.ed.cwdpick

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "alpha")
	e2e_key(&e, .Enter)
	testing.expect(t, cp.confirm, "unsaved outside buffer routes through the confirm")
	testing.expect_value(t, cwdpick_confirm_question(&e.ed), "Close 1 buffer? (1 unsaved)")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	query := strings.clone(cwd_query(&e), context.temp_allocator)
	caret := cp.field.caret
	selected := cp.selected
	e2e_key(&e, .Enter)
	testing.expect(t, cp.active && !cp.confirm, "Cancel returns to the picker")
	testing.expect_value(t, cwd_query(&e), query)
	testing.expect_value(t, cp.field.caret, caret)
	testing.expect_value(t, cp.selected, selected)
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect_value(t, len(e.ed.buffers), 1)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")

	e2e_key(&e, .Enter)
	testing.expect(t, cp.confirm, "Enter re-opens the confirm")
	e2e_key(&e, .Esc)
	testing.expect(t, cp.active && !cp.confirm, "Esc in the confirm returns to the picker")
	testing.expect_value(t, cwd_query(&e), query)
	testing.expect_value(t, e.ed.working_root, root)
	e2e_key(&e, .Esc)
	testing.expect(t, !cp.active, "second Esc closes the picker")
	testing.expect_value(t, e.ed.working_root, root)

	e2e_key(&e, .Ctrl_O)
	e2e_type(&e, "alpha")
	e2e_key(&e, .Enter)
	e2e_key(&e, .Arrow_Down)
	e2e_key(&e, .Enter)
	testing.expect_value(t, e.ed.working_root, fmt.tprintf("%s/alpha", root))
	testing.expect(t, e.ed.welcome, "confirmed close discards and lands on welcome")
}

@(test)
e2e_cwd_palette_and_welcome :: proc(t: ^testing.T) {
	e := e2e_welcome_start()
	defer e2e_stop(&e)
	testing.expect(t, command_available(&e.ed, "Change Working Directory"), "listed on the welcome palette")
	e2e_key(&e, .Ctrl_O)
	testing.expect(t, e.ed.cwdpick.active, "Ctrl+O opens on the welcome screen")
	testing.expect_value(t, cwd_query(&e), fmt.tprintf("%s/", e.ed.working_root))
	testing.expect_value(t, cwd_names(&e), "")
	e2e_render(&e)
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.cwdpick.active, "Esc cancels")
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
	testing.expect(t, !e.ed.cwdpick.active, "Ctrl+O in the tree does not open the picker")

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
	testing.expect(t, e.ed.cwdpick.active, "Ctrl+O outside the tree opens the picker")
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
	testing.expect_value(t, ft.mode, FileTreeMode.ConfirmRoot)
	testing.expect_value(t, filetree_root_question(&e.ed), "Close 1 buffer? (1 unsaved)")
	testing.expect_value(t, e.ed.working_root, root)
	e2e_render(&e)

	e2e_key(&e, .Enter)
	testing.expect_value(t, ft.mode, FileTreeMode.Nav)
	testing.expect(t, ft.active, "Cancel returns to the tree")
	testing.expect_value(t, e.ed.working_root, root)
	testing.expect(t, editor_buffer(&e.ed).modified, "unsaved buffer survives cancel")
	testing.expect(t, cwd_tree_select(&e, "alpha"), "tree unchanged")

	e2e_key(&e, .Ctrl_O)
	e2e_key(&e, .Esc)
	testing.expect_value(t, ft.mode, FileTreeMode.Nav)
	testing.expect(t, ft.active, "Esc in the confirm returns to the tree")
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


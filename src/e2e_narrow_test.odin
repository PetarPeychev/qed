package main

import "core:fmt"
import "core:strings"
import "core:testing"

narrow_box_has :: proc(e: ^E2E, needle: string) -> bool {
	box := ft_layout(&e.ed).box
	for y in box.y ..< box.y + box.h {
		if strings.contains(e2e_row(e, y), needle) {
			return true
		}
	}
	return false
}

@(test)
e2e_narrow_status_bar :: proc(t: ^testing.T) {
	e := e2e_root_start("main body")
	defer e2e_stop(&e)

	dir := fmt.tprintf("%s/some/rather/deeply/nested/directory", e.ed.working_root)
	e2e_run(fmt.tprintf("mkdir -p %s", shell_quote(dir)))
	path := fmt.tprintf("%s/narrow_status_file.txt", dir)
	nav_write(path, "a\nb\nc")
	testing.expect(t, editor_open_path(&e.ed, path))

	e2e_resize(&e, 50, E2E_H)
	e2e_render(&e)
	row := e2e_row(&e, E2E_H - 2)
	testing.expect(t, strings.contains(row, "narrow_status_file.txt  1/3"), row)
	testing.expect(t, !strings.contains(row, "deeply"), row)
	testing.expect(t, strings.contains(row, "[2/2]"), row)
	testing.expect_value(t, e2e_cell(&e, 49, E2E_H - 2), ' ')
}

@(test)
e2e_narrow_filetree_preview_beside_the_tree :: proc(t: ^testing.T) {
	e := e2e_root_start("NARROWPREVIEWMARK")
	defer e2e_stop(&e)

	e2e_resize(&e, 140, E2E_H)
	nav_alt(&e, 'f')
	testing.expect(t, nav_select(&e.ed, "main.txt"), "main.txt is listed")
	nav_preview(&e)
	lay := ft_layout(&e.ed)
	testing.expect(t, lay.preview, "a file previews beside the tree")
	testing.expect_value(t, lay.left_w, clamp(lay.inner.w * 40 / 100, SPLIT_TREE_MIN_WIDTH, SPLIT_TREE_MAX_WIDTH))
	e2e_render(&e)
	testing.expect(t, narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview shows at 140 cols")

	e2e_resize(&e, 60, E2E_H)
	nav_preview(&e)
	lay = ft_layout(&e.ed)
	testing.expect_value(t, lay.left_w, SPLIT_TREE_MIN_WIDTH)
	testing.expect(t, lay.right_w > 0, "the preview takes what the tree leaves")
}

@(test)
e2e_narrow_filetree_wide_caps_the_tree :: proc(t: ^testing.T) {
	e := e2e_root_start("WIDEPREVIEWMARK")
	defer e2e_stop(&e)
	nav_write(fmt.tprintf("%s/second.txt", e.dir), "2")

	e2e_resize(&e, 300, E2E_H)
	nav_alt(&e, 'f')
	nav_scan(&e)
	lay := ft_layout(&e.ed)
	testing.expect_value(t, lay.left_w, SPLIT_TREE_MAX_WIDTH)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.box.x, lay.box.y), '┌')
	testing.expect_value(t, e2e_cell(&e, lay.box.x + lay.box.w - 1, lay.box.y), '┐')
	testing.expect(t, len(ft_entries(&e.ed)) > 1, "two files listed")
	ft_set_sel(&e.ed, 0)
	e2e_mouse(&e, lay.inner.x + 3, lay.body_top + 1)
	e2e_ui_settle(&e)
	testing.expect_value(t, ft_sel(&e.ed), 1)
	e2e_mouse(&e, lay.box.x - 1, lay.body_top)
	e2e_ui_settle(&e)
	testing.expect(t, !filetree_active(&e.ed), "a click outside the box closes the tree")
}

@(test)
e2e_narrow_linefind_code_split :: proc(t: ^testing.T) {
	e := e2e_root_start("one\ntwo\nthree")
	defer e2e_stop(&e)

	e2e_resize(&e, 300, E2E_H)
	e2e_key(&e, .Ctrl_G)
	e2e_ui_settle(&e)
	testing.expect(t, goto_state(&e.ed).open, "Ctrl+G opens line jump")
	box := node_rect(&e.ed, "goto")
	query := node_rect(&e.ed, "goto_query")
	preview := node_rect(&e.ed, "goto_preview")
	testing.expect_value(t, query.w + 2, 70)
	testing.expectf(t, preview.x >= query.x + query.w && preview.w > 100, "the preview fills the rest: %v %v", query, preview)
	testing.expect_value(t, box.x, 2)

	e2e_resize(&e, 100, E2E_H)
	query = node_rect(&e.ed, "goto_query")
	testing.expect_value(t, query.w + 2, 37)

	box = node_rect(&e.ed, "goto")
	e2e_mouse(&e, box.x - 1, box.y + 3)
	e2e_ui_settle(&e)
	testing.expect(t, !goto_state(&e.ed).open, "a click outside the box closes line jump")
}

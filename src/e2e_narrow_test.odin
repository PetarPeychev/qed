package main

import "core:fmt"
import "core:strings"
import "core:testing"

narrow_box_has :: proc(e: ^E2E, needle: string) -> bool {
	box := filetree_layout(&e.ed).box
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
e2e_narrow_filetree_hides_preview :: proc(t: ^testing.T) {
	e := e2e_root_start("NARROWPREVIEWMARK")
	defer e2e_stop(&e)

	e2e_resize(&e, 140, E2E_H)
	nav_alt(&e, 'f')
	tr := &e.ed.filetree
	for entry, i in tr.entries {
		if entry.name == "main.txt" {
			tr.selected = i
		}
	}
	filetree_load_preview(&e.ed)
	lay := filetree_layout(&e.ed)
	testing.expect(t, lay.preview)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X)
	testing.expect_value(t, lay.left_w, 30)
	testing.expect_value(t, lay.right_w, 91)
	e2e_render(&e)
	testing.expect(t, narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview shows at 140 cols")

	e2e_resize(&e, 130, E2E_H)
	filetree_load_preview(&e.ed)
	lay = filetree_layout(&e.ed)
	testing.expect(t, lay.preview, "preview survives at 130 cols")
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X)
	testing.expect_value(t, lay.left_w, 30)
	testing.expect_value(t, lay.right_w, 81)

	e2e_resize(&e, 118, E2E_H)
	filetree_load_preview(&e.ed)
	lay = filetree_layout(&e.ed)
	testing.expect(t, !lay.preview, "preview hides below 119 cols")

	e2e_resize(&e, 119, E2E_H)
	filetree_load_preview(&e.ed)
	lay = filetree_layout(&e.ed)
	testing.expect(t, lay.preview, "preview shows at 119 cols")
	testing.expect_value(t, lay.left_w + 1 + lay.right_w, lay.inner.w)

	e2e_resize(&e, 60, E2E_H)
	filetree_load_preview(&e.ed)
	lay = filetree_layout(&e.ed)
	testing.expect(t, !lay.preview)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X)
	testing.expect(t, !preview_loaded(&tr.preview), "hidden preview is not loaded")
	e2e_render(&e)
	testing.expect(t, !narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview hidden at 60 cols")
	testing.expect(t, e2e_cell(&e, lay.inner.x + 30, lay.body_top) != '│', "no divider when the preview is hidden")

	e2e_resize(&e, 140, E2E_H)
	filetree_preview_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview returns when widened")
}

@(test)
e2e_narrow_filetree_centers_wide :: proc(t: ^testing.T) {
	e := e2e_root_start("WIDEPREVIEWMARK")
	defer e2e_stop(&e)

	e2e_resize(&e, 300, E2E_H)
	nav_alt(&e, 'f')
	nav_scan(&e)
	tr := &e.ed.filetree
	lay := filetree_layout(&e.ed)
	testing.expect(t, lay.preview)
	testing.expect_value(t, lay.left_w, FILETREE_LIST_MAX_WIDTH)
	testing.expect_value(t, lay.right_w, PREVIEW_MAX_WIDTH)
	testing.expect_value(t, lay.box.w, 60 + 1 + 130 + 2)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X + (300 - 2 * PICKER_MARGIN_X - lay.box.w) / 2)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.box.x, lay.box.y), '┌')
	testing.expect_value(t, e2e_cell(&e, lay.box.x + lay.box.w - 1, lay.box.y), '┐')
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.title_sep_y), '┬')
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.filter_sep_y), '┤')
	testing.expect_value(t, e2e_cell(&e, lay.box.x, lay.filter_sep_y), '├')
	testing.expect(t, e2e_cell(&e, lay.inner.x + 1, lay.tab_y) != ' ', "tab bar follows the box")
	testing.expect(t, e2e_cell(&e, lay.inner.x + 1, lay.footer_y) != ' ', "footer follows the box")

	if len(tr.entries) > 1 {
		tr.selected = 0
		e2e_mouse(&e, lay.inner.x + 3, lay.body_top + 1)
		testing.expect_value(t, tr.selected, 1)
	}
	e2e_mouse(&e, lay.box.x - 2, lay.body_top)
	testing.expect(t, !tr.active, "a click in the centering margin closes the tree")
}

@(test)
e2e_narrow_linefind_code_split :: proc(t: ^testing.T) {
	e := e2e_root_start("one\ntwo\nthree")
	defer e2e_stop(&e)

	e2e_resize(&e, 300, E2E_H)
	linefind_open(&e.ed)
	lay := overlay_layout(&e.ed, .Code)
	testing.expect(t, lay.preview)
	testing.expect_value(t, lay.left_w, CODE_LIST_MAX_WIDTH)
	testing.expect_value(t, lay.right_w, PREVIEW_MAX_WIDTH)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X + (300 - 2 * PICKER_MARGIN_X - lay.box.w) / 2)
	e2e_render(&e)
	testing.expect_value(t, e2e_cell(&e, lay.box.x, lay.box.y), '┌')
	testing.expect_value(t, e2e_cell(&e, lay.div_x, lay.title_sep_y), '┬')
	testing.expect(t, preview_loaded(&e.ed.linefind.preview))

	e2e_resize(&e, 200, E2E_H)
	lay = overlay_layout(&e.ed, .Code)
	testing.expect(t, lay.preview)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X)
	testing.expect_value(t, lay.left_w, 76)
	testing.expect_value(t, lay.right_w, 105)
	testing.expect_value(t, lay.left_w + 1 + lay.right_w, lay.inner.w)

	e2e_resize(&e, 139, E2E_H)
	lay = overlay_layout(&e.ed, .Code)
	testing.expect(t, lay.preview)
	testing.expect_value(t, lay.left_w, CODE_LIST_MIN_WIDTH)
	testing.expect_value(t, lay.right_w, PREVIEW_MIN_WIDTH)

	e2e_resize(&e, 138, E2E_H)
	lay = overlay_layout(&e.ed, .Code)
	testing.expect(t, !lay.preview)
	testing.expect_value(t, lay.box.x, PICKER_MARGIN_X)
	testing.expect_value(t, lay.left_w, lay.inner.w)

	e2e_mouse(&e, lay.box.x - 2, lay.body_top)
	testing.expect(t, !e.ed.linefind.active, "a click outside the box closes line jump")
}

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
	testing.expect_value(t, lay.left_w, LIST_MAX_WIDTH)
	e2e_render(&e)
	testing.expect(t, narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview shows at 140 cols")

	e2e_resize(&e, 60, E2E_H)
	filetree_load_preview(&e.ed)
	lay = filetree_layout(&e.ed)
	testing.expect(t, !lay.preview)
	testing.expect_value(t, lay.box.x, 0)
	testing.expect(t, !preview_loaded(&tr.preview), "hidden preview is not loaded")
	e2e_render(&e)
	testing.expect(t, !narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview hidden at 60 cols")
	testing.expect(t, e2e_cell(&e, lay.inner.x + 30, lay.body_top) != '│', "no divider when the preview is hidden")

	e2e_resize(&e, 140, E2E_H)
	filetree_preview_flush(&e.ed)
	e2e_render(&e)
	testing.expect(t, narrow_box_has(&e, "NARROWPREVIEWMARK"), "preview returns when widened")
}

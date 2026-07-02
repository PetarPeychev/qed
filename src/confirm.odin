package main

import "core:path/filepath"
import "core:strings"
import "lib:tb2"

quit_actions := [?]string{"Save All", "Discard All", "Cancel"}

QuitDialog :: struct {
	active:   bool,
	selected: int,
}

quit_dialog_open :: proc(editor: ^Editor) {
	editor.quit_dialog.active = true
	editor.quit_dialog.selected = 0
	editor.message = ""
	editor.message_error = false
}

quit_dialog_close :: proc(editor: ^Editor) {
	editor.quit_dialog.active = false
}

quit_dialog_execute :: proc(editor: ^Editor) {
	switch editor.quit_dialog.selected {
	case 0:
		for &b in editor.buffers {
			if b.modified {
				buffer_save(&b)
			}
		}
		if editor_any_modified(editor) {
			quit_dialog_close(editor)
			editor.message = "Save failed"
			editor.message_error = true
		} else {
			editor.quit = true
		}
	case 1:
		editor.quit = true
	case 2:
		quit_dialog_close(editor)
	}
}

quit_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	d := &editor.quit_dialog
	#partial switch ev.key {
	case .Esc:
		quit_dialog_close(editor)
	case .Enter:
		quit_dialog_execute(editor)
	case .Arrow_Down:
		d.selected = (d.selected + 1) % len(quit_actions)
	case .Arrow_Up:
		d.selected = (d.selected - 1 + len(quit_actions)) % len(quit_actions)
	}
}

quit_dialog_question :: proc(editor: ^Editor) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "Unsaved changes in: ")
	first := true
	for &b in editor.buffers {
		if !b.modified {
			continue
		}
		if !first {
			strings.write_string(&sb, ", ")
		}
		first = false
		if b.path != "" {
			strings.write_string(&sb, filepath.base(b.path))
		} else {
			strings.write_string(&sb, "[No Name]")
		}
	}
	return strings.to_string(sb)
}

quit_dialog_render :: proc(editor: ^Editor) {
	d := &editor.quit_dialog
	question := quit_dialog_question(editor)
	content_w := len(question)
	for a in quit_actions {
		content_w = max(content_w, len(a))
	}
	content_w += 2
	content_w = min(content_w, int(tb2.width()) - 4)
	content_h := 2 + len(quit_actions)

	box := pane_center(editor, content_w, content_h)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, inner.w - 2, question, COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)
	for a, i in quit_actions {
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == d.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, a, fg, bg)
	}
	tb2.hide_cursor()
}

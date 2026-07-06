package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "lib:tb2"

quit_actions := [?]string{"Save All", "Discard All", "Cancel"}
close_actions := [?]string{"Save", "Discard", "Cancel"}
conflict_actions := [?]string{"Cancel", "Overwrite (keep my version)", "Reload (discard my changes)"}

QuitDialog :: struct {
	active:   bool,
	selected: int,
}

quit_dialog_open :: proc(editor: ^Editor) {
	editor.quit_dialog.active = true
	editor.quit_dialog.selected = 0
	editor_set_message(editor, "")
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
			editor_set_message(editor, "Save failed", true)
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
	dialog_render(editor, quit_dialog_question(editor), quit_actions[:], editor.quit_dialog.selected)
}

CloseDialog :: struct {
	active:   bool,
	selected: int,
}

close_dialog_open :: proc(editor: ^Editor) {
	editor.close_dialog.active = true
	editor.close_dialog.selected = 0
	editor_set_message(editor, "")
}

close_dialog_close :: proc(editor: ^Editor) {
	editor.close_dialog.active = false
}

close_dialog_execute :: proc(editor: ^Editor) {
	switch editor.close_dialog.selected {
	case 0:
		b := editor_buffer(editor)
		buffer_save(b)
		close_dialog_close(editor)
		if b.modified {
			editor_set_message(editor, "Save failed", true)
		} else {
			editor_close_current(editor)
		}
	case 1:
		close_dialog_close(editor)
		editor_close_current(editor)
	case 2:
		close_dialog_close(editor)
	}
}

close_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	d := &editor.close_dialog
	#partial switch ev.key {
	case .Esc:
		close_dialog_close(editor)
	case .Enter:
		close_dialog_execute(editor)
	case .Arrow_Down:
		d.selected = (d.selected + 1) % len(close_actions)
	case .Arrow_Up:
		d.selected = (d.selected - 1 + len(close_actions)) % len(close_actions)
	}
}

close_dialog_render :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	question := fmt.tprintf("Save changes to %s?", name)
	dialog_render(editor, question, close_actions[:], editor.close_dialog.selected)
}

ConflictDialog :: struct {
	active:   bool,
	selected: int,
}

conflict_dialog_open :: proc(editor: ^Editor) {
	editor.conflict_dialog.active = true
	editor.conflict_dialog.selected = 0
	editor_set_message(editor, "")
}

conflict_dialog_close :: proc(editor: ^Editor) {
	editor.conflict_dialog.active = false
}

conflict_dialog_execute :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	selected := editor.conflict_dialog.selected
	conflict_dialog_close(editor)
	switch selected {
	case 1:
		editor_force_save(editor, b)
	case 2:
		editor_reload_buffer(editor, b)
	}
}

conflict_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	d := &editor.conflict_dialog
	#partial switch ev.key {
	case .Esc:
		conflict_dialog_close(editor)
	case .Enter:
		conflict_dialog_execute(editor)
	case .Arrow_Down:
		d.selected = (d.selected + 1) % len(conflict_actions)
	case .Arrow_Up:
		d.selected = (d.selected - 1 + len(conflict_actions)) % len(conflict_actions)
	}
}

conflict_dialog_render :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	question := fmt.tprintf("%s changed on disk since you loaded it.", name)
	dialog_render(editor, question, conflict_actions[:], editor.conflict_dialog.selected)
}

dialog_render :: proc(editor: ^Editor, question: string, actions: []string, selected: int) {
	content_w := len(question)
	for a in actions {
		content_w = max(content_w, len(a))
	}
	content_w += 2
	content_w = min(content_w, int(tb2.width()) - 4)
	content_h := 2 + len(actions)

	box := pane_center(editor, content_w, content_h)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, inner.w - 2, question, COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)
	for a, i in actions {
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, a, fg, bg)
	}
	tb2.hide_cursor()
}

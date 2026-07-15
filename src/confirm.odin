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
	editor_clear_message(editor)
}

quit_dialog_close :: proc(editor: ^Editor) {
	editor.quit_dialog.active = false
}

quit_dialog_execute :: proc(editor: ^Editor) {
	switch editor.quit_dialog.selected {
	case 0:
		quit_dialog_close(editor)
		conflict := false
		for &b in editor.buffers {
			if !b.modified {
				continue
			}
			if buffer_disk_changed(&b) {
				conflict = true
				continue
			}
			editor_save_full(editor, &b)
		}
		if conflict {
			editor_log(editor, .Warn, "", fmt.tprintf("File changed on disk — save it with %s to resolve", command_shortcut("Save")))
		} else if lsp_format_pending() {
			editor_save_intent_set(editor, .Quit, "")
		} else if editor_any_modified(editor) {
			editor_log(editor, .Error, "", "Save failed")
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
	dialog_key(editor, ev, &editor.quit_dialog.selected, len(quit_actions), quit_dialog_execute, quit_dialog_close)
}

quit_dialog_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_mouse(editor, ev, quit_dialog_question(editor), quit_actions[:], &editor.quit_dialog.selected, quit_dialog_execute, quit_dialog_close)
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
	editor_clear_message(editor)
}

close_dialog_close :: proc(editor: ^Editor) {
	editor.close_dialog.active = false
}

close_dialog_execute :: proc(editor: ^Editor) {
	switch editor.close_dialog.selected {
	case 0:
		b := editor_buffer(editor)
		close_dialog_close(editor)
		if buffer_disk_changed(b) {
			conflict_dialog_open(editor)
			return
		}
		editor_save_intent_set(editor, .Close, b.path)
		editor_save_full(editor, b)
	case 1:
		close_dialog_close(editor)
		editor_close_current(editor)
	case 2:
		close_dialog_close(editor)
	}
}

close_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_key(editor, ev, &editor.close_dialog.selected, len(close_actions), close_dialog_execute, close_dialog_close)
}

close_dialog_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_mouse(editor, ev, close_dialog_question(editor), close_actions[:], &editor.close_dialog.selected, close_dialog_execute, close_dialog_close)
}

close_dialog_question :: proc(editor: ^Editor) -> string {
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	return fmt.tprintf("Save changes to %s?", name)
}

close_dialog_render :: proc(editor: ^Editor) {
	dialog_render(editor, close_dialog_question(editor), close_actions[:], editor.close_dialog.selected)
}

ConflictDialog :: struct {
	active:   bool,
	selected: int,
}

conflict_dialog_open :: proc(editor: ^Editor) {
	editor.conflict_dialog.active = true
	editor.conflict_dialog.selected = 0
	editor_clear_message(editor)
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
		b.disk = buffer_disk_stamp(b.path) // accept the disk state so a format-chained save can't re-raise the conflict
		editor_save_full(editor, b)
	case 2:
		editor_reload_buffer(editor, b)
	}
}

conflict_dialog_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_key(editor, ev, &editor.conflict_dialog.selected, len(conflict_actions), conflict_dialog_execute, conflict_dialog_close)
}

conflict_dialog_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	dialog_mouse(editor, ev, conflict_dialog_question(editor), conflict_actions[:], &editor.conflict_dialog.selected, conflict_dialog_execute, conflict_dialog_close)
}

conflict_dialog_question :: proc(editor: ^Editor) -> string {
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	return fmt.tprintf("%s changed on disk since you loaded it.", name)
}

conflict_dialog_render :: proc(editor: ^Editor) {
	dialog_render(editor, conflict_dialog_question(editor), conflict_actions[:], editor.conflict_dialog.selected)
}

dialog_box :: proc(editor: ^Editor, question: string, actions: []string) -> Rect {
	content_w := len(question)
	for a in actions {
		content_w = max(content_w, len(a))
	}
	content_w += 2
	content_w = min(content_w, int(tb2.width()) - 4)
	return pane_center(editor, content_w, 2 + len(actions))
}

dialog_key :: proc(editor: ^Editor, ev: tb2.Event, selected: ^int, n: int, execute, close: proc(editor: ^Editor)) {
	#partial switch ev.key {
	case .Esc:
		close(editor)
	case .Enter:
		execute(editor)
	case .Arrow_Down:
		selected^ = min(selected^ + 1, n - 1)
	case .Arrow_Up:
		selected^ = max(selected^ - 1, 0)
	}
}

dialog_mouse :: proc(
	editor: ^Editor,
	ev: tb2.Event,
	question: string,
	actions: []string,
	selected: ^int,
	execute, close: proc(editor: ^Editor),
) {
	if ev.key != .Mouse_Left {
		return
	}
	box := dialog_box(editor, question, actions)
	motion := ev_motion(ev)
	if !mouse_in_rect(ev, box) {
		if !motion {
			close(editor)
		}
		return
	}
	off := overlay_row_off(ev, Rect{box.x + 1, box.y + 3, box.w - 2, len(actions)})
	if off < 0 {
		return
	}
	selected^ = off
	if !motion && overlay_double_click(editor, off) {
		execute(editor)
	}
}

dialog_render :: proc(editor: ^Editor, question: string, actions: []string, selected: int) {
	box := dialog_box(editor, question, actions)
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

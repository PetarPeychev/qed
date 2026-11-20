package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "lib:tb2"

quit_actions := [?]string{"Save All", "Discard All", "Cancel"}
close_actions := [?]string{"Save", "Discard", "Cancel"}
conflict_actions := [?]string{"Cancel", "Overwrite (keep my version)", "Reload (discard my changes)"}

quit_dialog_open :: proc(editor: ^Editor) {
	if pane_find(editor, "quit") != nil {
		return
	}
	editor_clear_message(editor)
	text := []PaneLine{{text = quit_dialog_question(editor)}}
	pane_open(editor, {id = "quit", safety = true, text = text, list = {items = pane_labels(quit_actions[:])}, on = {activate = quit_dialog_execute}})
}

quit_dialog_execute :: proc(editor: ^Editor, p: ^Pane) {
	switch p.list.sel {
	case 0:
		conflict := false
		ids := make([dynamic]u64, context.temp_allocator)
		for &b in editor.buffers {
			if !b.modified {
				continue
			}
			if buffer_disk_changed(&b) {
				conflict = true
				continue
			}
			append(&ids, b.id)
		}
		for id in ids {
			if b, _ := api_buf_find(editor, id); b != nil {
				editor_save_full(editor, b)
			}
		}
		if conflict {
			editor_log(editor, .Warn, "", fmt.tprintf("File changed on disk — save it with %s to resolve", command_shortcut("Save")))
		} else if len(editor.plugins.saves) > 0 {
			editor_save_intent_set(editor, .Quit, "")
		} else if editor_any_modified(editor) {
			editor_log(editor, .Error, "", "Save failed")
		} else {
			editor.quit = true
		}
	case 1:
		editor.quit = true
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

close_dialog_open :: proc(editor: ^Editor) {
	if pane_find(editor, "close") != nil {
		return
	}
	editor_clear_message(editor)
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	text := []PaneLine{{text = fmt.tprintf("Save changes to %s?", name)}}
	pane_open(editor, {id = "close", safety = true, ctx = {buf = b.id}, text = text, list = {items = pane_labels(close_actions[:])}, on = {activate = close_dialog_execute}})
}

close_dialog_execute :: proc(editor: ^Editor, p: ^Pane) {
	b, idx := pane_buffer(editor, p)
	if b == nil {
		return
	}
	switch p.list.sel {
	case 0:
		if buffer_disk_changed(b) {
			conflict_dialog_open(editor, b)
			return
		}
		editor_save_intent_set(editor, .Close, b.path)
		editor_save_full(editor, b)
	case 1:
		editor_close_index(editor, idx)
	}
}

conflict_dialog_open :: proc(editor: ^Editor, b: ^Buffer) {
	if pane_find(editor, "conflict") != nil {
		return
	}
	editor_clear_message(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	text := []PaneLine{{text = fmt.tprintf("%s changed on disk since you loaded it.", name)}}
	pane_open(editor, {id = "conflict", safety = true, ctx = {buf = b.id}, text = text, list = {items = pane_labels(conflict_actions[:])}, on = {activate = conflict_dialog_execute}})
}

conflict_dialog_execute :: proc(editor: ^Editor, p: ^Pane) {
	b, _ := pane_buffer(editor, p)
	if b == nil {
		return
	}
	switch p.list.sel {
	case 1:
		b.disk = buffer_disk_stamp(b.path) // accept the disk state so a format-chained save can't re-raise the conflict
		editor_save_full(editor, b)
	case 2:
		editor_reload_buffer(editor, b)
	}
}

dialog_pane :: proc(question: string, actions: []string, selected: int) -> Pane {
	text := make([]PaneLine, 1, context.temp_allocator)
	text[0].text = question
	return {text = text, has_list = true, list = {items = pane_labels(actions), sel = selected}}
}

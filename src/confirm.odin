package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "lib:tb2"

quit_actions := [?]string{"Cancel", "Save All", "Discard All"}
close_actions := [?]string{"Cancel", "Save", "Discard"}
conflict_actions := [?]string{"Cancel", "Overwrite (keep my version)", "Reload (discard my changes)"}

SafetyKind :: enum u8 {
	None,
	Quit,
	Close,
	Conflict,
}

// a core dialog in the alert layer, built without Lua so it works with plugins broken or off; mounted last, it wins
Safety :: struct {
	kind:       SafetyKind,
	buf:        u64,
	choices:    []string,
	selected:   int,
	handle:     u64,
	clicked_at: Maybe(time.Tick),
}

safety_open :: proc(editor: ^Editor) -> bool {
	return editor.safety.kind != .None
}

@(private = "file")
safety_mount :: proc(editor: ^Editor, kind: SafetyKind, buf: u64, question: string, choices: []string, selected: int) {
	box := ui_core_pane(editor, "safety", {form = .Fit})
	column := ui_core_node(.Column)
	column.separator = true
	column.style = ui_core_pane_style()
	ui_core_add(box, column)
	asked := ui_core_text(fmt.tprintf(" %s ", question))
	asked.wrap, asked.wrap_set = true, true
	ui_core_add(column, asked)
	rows := ui_core_node(.Column, "safety_choices")
	rows.highlight_style = {set = {.Fg, .Bg}, fg = strings.clone("pane_selection_foreground"), bg = strings.clone("pane_selection_background")}
	ui_core_add(column, rows)
	for choice, i in choices {
		row := ui_core_text(fmt.tprintf(" %s ", choice), fmt.tprintf("safety_choice_%d", i))
		row.key = strings.clone(fmt.tprintf("%d", i))
		ui_core_add(rows, row)
	}
	// a full-screen catcher under the box: every key that bubbles up and every click lands on the dialog
	catcher := ui_core_node(.Column, "safety_catcher")
	catcher.float = .Screen
	catcher.width = {form = .Percent, value = 100}
	catcher.height = {form = .Percent, value = 100}
	catcher.core_event = safety_event
	ui_core_add(catcher, box)
	editor.safety = {kind = kind, buf = buf, choices = choices, selected = selected}
	editor.safety.handle = ui_mount_add(editor, "", "alert", catcher)
	ui_resolve(editor)
	ui_focus_set(editor, rows.identity)
	safety_highlight(editor)
}

@(private = "file")
safety_highlight :: proc(editor: ^Editor) {
	if node := ui_find(&editor.ui, "#/safety_choices"); node != nil {
		state := ui_node_state(&editor.ui, node)
		delete(state.highlighted)
		state.highlighted = strings.clone(fmt.tprintf("%d", editor.safety.selected))
	}
}

safety_close :: proc(editor: ^Editor) {
	if editor.safety.kind == .None {
		return
	}
	ui_mount_remove(editor, editor.safety.handle)
	editor.safety = {}
}

@(private = "file")
safety_choose :: proc(editor: ^Editor) {
	dialog := editor.safety
	safety_close(editor)
	switch dialog.kind {
	case .None:
	case .Quit:
		quit_dialog_execute(editor, dialog.selected)
	case .Close:
		close_dialog_execute(editor, dialog.buf, dialog.selected)
	case .Conflict:
		conflict_dialog_execute(editor, dialog.buf, dialog.selected)
	}
}

@(private = "file")
safety_move :: proc(editor: ^Editor, step: int) {
	editor.safety.selected = clamp(editor.safety.selected + step, 0, len(editor.safety.choices) - 1)
	safety_highlight(editor)
}

@(private = "file")
safety_event :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	#partial switch ev.type {
	case .Key:
		#partial switch ev.key {
		case .Arrow_Up, .Arrow_Left:
			safety_move(editor, -1)
		case .Arrow_Down, .Arrow_Right, .Tab:
			safety_move(editor, 1)
		case .Enter:
			safety_choose(editor)
		case .Esc:
			safety_close(editor)
		}
	case .Mouse:
		if ev.key != .Mouse_Left {
			return true
		}
		for _, i in editor.safety.choices {
			node := ui_find(&editor.ui, fmt.tprintf("#/safety_choice_%d", i))
			if node == nil || !ui_rect_has(node.rect, int(ev.x), int(ev.y)) {
				continue
			}
			clicked_at, clicked := editor.safety.clicked_at.?
			again := editor.safety.selected == i && clicked && ms_since(clicked_at) < f64(DOUBLE_CLICK_MS)
			editor.safety.selected = i
			safety_highlight(editor)
			editor.safety.clicked_at = time.tick_now()
			if again {
				safety_choose(editor)
			}
			break
		}
	}
	return true
}

quit_dialog_open :: proc(editor: ^Editor) {
	if safety_open(editor) {
		return
	}
	editor_clear_message(editor)
	safety_mount(editor, .Quit, 0, quit_dialog_question(editor), quit_actions[:], 1)
}

quit_dialog_execute :: proc(editor: ^Editor, choice: int) {
	switch choice {
	case 1:
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
			editor_log(editor, .Warn, "", fmt.tprintf("File changed on disk — save it with %s to resolve", command_shortcut("save")))
		} else if len(editor.plugins.saves) > 0 {
			editor_save_intent_set(editor, .Quit, "")
		} else if editor_any_modified(editor) {
			editor_log(editor, .Error, "", "Save failed")
		} else {
			editor.quit = true
		}
	case 2:
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

@(private = "file")
safety_buffer :: proc(editor: ^Editor, id: u64) -> (^Buffer, int) {
	b, idx := api_buf_find(editor, id)
	if b == nil {
		editor_log(editor, .Warn, "", "Buffer closed while the dialog was open")
	}
	return b, idx
}

close_dialog_open :: proc(editor: ^Editor) {
	if safety_open(editor) {
		return
	}
	editor_clear_message(editor)
	b := editor_buffer(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	safety_mount(editor, .Close, b.id, fmt.tprintf("Save changes to %s?", name), close_actions[:], 1)
}

close_dialog_execute :: proc(editor: ^Editor, buf: u64, choice: int) {
	b, idx := safety_buffer(editor, buf)
	if b == nil {
		return
	}
	switch choice {
	case 1:
		if buffer_disk_changed(b) {
			conflict_dialog_open(editor, b)
			return
		}
		editor_save_intent_set(editor, .Close, b.path)
		editor_save_full(editor, b)
	case 2:
		editor_close_index(editor, idx)
	}
}

conflict_dialog_open :: proc(editor: ^Editor, b: ^Buffer) {
	if safety_open(editor) {
		return
	}
	editor_clear_message(editor)
	name := filepath.base(b.path) if b.path != "" else "[No Name]"
	safety_mount(editor, .Conflict, b.id, fmt.tprintf("%s changed on disk since you loaded it.", name), conflict_actions[:], 0)
}

conflict_dialog_execute :: proc(editor: ^Editor, buf: u64, choice: int) {
	b, _ := safety_buffer(editor, buf)
	if b == nil {
		return
	}
	switch choice {
	case 1:
		b.disk = buffer_disk_stamp(b.path) // accept the disk state so a format-chained save can't re-raise the conflict
		editor_save_full(editor, b)
	case 2:
		editor_reload_buffer(editor, b)
	}
}

package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "lib:tb2"

quit_actions := [?]string{"Cancel", "Save All", "Discard All"}
close_actions := [?]string{"Cancel", "Save", "Discard"}
conflict_actions := [?]string{"Cancel", "Overwrite (keep my version)", "Reload (discard my changes)"}

SAFETY_WIDTH :: 64

SafetyKind :: enum u8 {
	None,
	Quit,
	Close,
	Conflict,
}

// a core dialog in the alert layer, built without Lua so it works with plugins broken or off; mounted last, it wins
Safety :: struct {
	kind:     SafetyKind,
	buf:      u64,
	choices:  []string,
	selected: int,
	handle:   u64,
}

safety_dialog :: proc(editor: ^Editor) -> string {
	switch editor.safety.kind {
	case .None:
		return ""
	case .Quit:
		return "quit"
	case .Close:
		return "close"
	case .Conflict:
		return "conflict"
	}
	return ""
}

safety_open :: proc(editor: ^Editor) -> bool {
	return editor.safety.kind != .None
}

@(private = "file")
safety_node :: proc(kind: UiKind, id := "") -> ^UiNode {
	node := new(UiNode)
	node.kind = kind
	node.id = strings.clone(id)
	return node
}

@(private = "file")
safety_text :: proc(text: string, id := "") -> ^UiNode {
	node := safety_node(.Text, id)
	append(&node.spans, UiSpan{text = strings.clone(text)})
	return node
}

@(private = "file")
safety_add :: proc(parent, child: ^UiNode) {
	append(&parent.child_slots, len(parent.children))
	append(&parent.children, child)
	child.parent = parent
}

@(private = "file")
safety_mount :: proc(editor: ^Editor, kind: SafetyKind, buf: u64, question: string, choices: []string, selected: int) {
	box := safety_node(.Box, "safety")
	box.float, box.anchor, box.border = .Screen, .Top, true
	box.width = {form = .Cells, value = SAFETY_WIDTH}
	box.height = {form = .Fit}
	box.margin = {3, 2, 2, 2}
	box.style = {set = {.Fg, .Bg}, fg = strings.clone("pane_foreground"), bg = strings.clone("pane_background")}
	column := safety_node(.Column)
	safety_add(box, column)
	asked := safety_text(fmt.tprintf(" %s", question))
	asked.wrap, asked.wrap_set = true, true
	safety_add(column, asked)
	rows := safety_node(.Column, "safety_choices")
	rows.highlight_style = {set = {.Fg, .Bg}, fg = strings.clone("pane_selection_foreground"), bg = strings.clone("pane_selection_background")}
	safety_add(column, rows)
	for choice, i in choices {
		row := safety_text(fmt.tprintf(" %s", choice), fmt.tprintf("safety_choice_%d", i))
		row.key = strings.clone(fmt.tprintf("%d", i))
		safety_add(rows, row)
	}
	editor.safety = {kind = kind, buf = buf, choices = choices, selected = selected}
	editor.safety.handle = ui_mount_add(editor, "", "alert", box)
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

// every key and click goes here while a safety dialog shows; nothing reaches below it
safety_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
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
			return
		}
		for _, i in editor.safety.choices {
			node := ui_find(&editor.ui, fmt.tprintf("#/safety_choice_%d", i))
			if node == nil || !ui_rect_has(node.rect, int(ev.x), int(ev.y)) {
				continue
			}
			again := editor.safety.selected == i && editor.click_count > 0 && ms_since(editor.last_click_tick) < UI_DOUBLE_CLICK_MS
			editor.safety.selected = i
			safety_highlight(editor)
			editor.click_count = 1
			editor.last_click_tick = time.tick_now()
			if again {
				safety_choose(editor)
			}
			return
		}
	}
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
			editor_log(editor, .Warn, "", fmt.tprintf("File changed on disk — save it with %s to resolve", command_shortcut("Save")))
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

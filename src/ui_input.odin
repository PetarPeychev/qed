package main

import "core:fmt"
import "core:strings"
import "core:time"
import "lib:tb2"

UI_DOUBLE_CLICK_MS :: 400
UI_WHEEL_STEP :: 3

ui_dispatch :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	ui := &editor.ui
	#partial switch ev.type {
	case .Key:
		focus := ui_focused(editor)
		if focus == nil {
			return false
		}
		ui_dispatch_key(editor, focus, ev)
		return true
	case .Mouse:
		if len(ui.mounts) == 0 {
			return false
		}
		return ui_dispatch_mouse(editor, ev) || ui_layer_used(ui, "base")
	}
	return false
}

ui_target_editor :: proc(node: ^UiNode) -> ^UiNode {
	for n := node; n != nil; n = n.parent {
		if n.kind == .Editor {
			return n
		}
	}
	return nil
}

ui_dispatch_key :: proc(editor: ^Editor, focus: ^UiNode, ev: tb2.Event) {
	ui := &editor.ui
	chord := ui_chord_of_event(ev)
	text := ""
	if ev.ch != 0 && !ev_alt(ev) {
		text = fmt.tprintf("%c", ev.ch)
	}
	editor_clear_message(editor)
	defer ui.target = nil
	gen := ui.gen
	for n := focus; n != nil; n = n.parent {
		ui.target = n if n.kind == .Editor else nil
		for scope in n.scope {
			if ui_scope_run(editor, scope, chord) {
				return
			}
		}
		if n.handlers[.Key] != 0 && ui_handler_call(editor, n.owner, n.handlers[.Key], {chord = chord, text = text}) {
			return
		}
		if ui.gen != gen {
			return
		}
		if n.kind == .Editor && text != "" && !n.readonly {
			ui_editor_type(editor, n, ev.ch)
			return
		}
	}
	ui_global_binds(editor, ev)
}

ui_scope_run :: proc(editor: ^Editor, scope, chord: string) -> bool {
	if chord == "" {
		return false
	}
	for cmd in pane_commands {
		if cmd.scope != scope || cmd.run == nil || (scope == "editor" && editor.ui.target == nil) {
			continue
		}
		_, _, shortcut := command_effective_bind(cmd)
		if shortcut != "" && ui_chord_normalize(shortcut) == chord {
			cmd.run(editor)
			return true
		}
	}
	for cmd in editor.plugins.commands {
		if cmd.scope == scope && cmd.shortcut != "" && ui_chord_normalize(cmd.shortcut) == chord {
			plugin_command_chord(editor, cmd)
			return true
		}
	}
	return false
}

ui_global_binds :: proc(editor: ^Editor, ev: tb2.Event) {
	if pcmd, pok := plugin_command_for_event(editor, ev, ""); pok {
		plugin_command_chord(editor, pcmd)
		return
	}
	if ev_alt(ev) && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			if command_enabled(cmd) {
				cmd.run(editor)
			}
		}
		return
	}
	if ev.ch == 0 {
		if cmd, ok := command_for_key(ev.key); ok && command_enabled(cmd) {
			cmd.run(editor)
		}
	}
}

ui_editor_type :: proc(editor: ^Editor, node: ^UiNode, r: rune) {
	b := ui_buffer(editor, node.buffer)
	if b == nil {
		return
	}
	buffer_type_rune(b, r)
	b.typed_rev = b.rev
	ui_state(&editor.ui, node.identity).reveal = true
}

ui_paste :: proc(editor: ^Editor, text: string) -> bool {
	focus := ui_focused(editor)
	if focus == nil {
		return false
	}
	for n := focus; n != nil; n = n.parent {
		if n.handlers[.Paste] != 0 && ui_handler_call(editor, n.owner, n.handlers[.Paste], {text = text}) {
			return true
		}
		if n.kind == .Editor && !n.readonly {
			if b := ui_buffer(editor, n.buffer); b != nil {
				buffer_paste(b, text)
				ui_state(&editor.ui, n.identity).reveal = true
			}
			return true
		}
	}
	return false
}

ui_mouse_button :: proc(key: tb2.Key) -> string {
	#partial switch key {
	case .Mouse_Right:
		return "right"
	case .Mouse_Middle:
		return "middle"
	}
	return "left"
}

ui_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	ui := &editor.ui
	x, y := int(ev.x), int(ev.y)
	motion := (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0
	if ev.key == .Mouse_Release {
		was := ui.drag.active
		ui.drag.active = false
		return was
	}
	if motion && ev.key == .Mouse_Left {
		if !ui.drag.active {
			return false
		}
		if n := ui_find(ui, ui.drag.node); n != nil && n.kind == .Editor {
			if b := ui_buffer(editor, n.buffer); b != nil {
				if b.selection == nil {
					b.selection = b.cursor
				}
				b.cursor = ui_editor_point(editor, n, x, y)
				ui_state(ui, n.identity).reveal = true
			}
		}
		return true
	}
	wheel := ev.key == .Mouse_Wheel_Up || ev.key == .Mouse_Wheel_Down
	event := UiEvent.Wheel if wheel else UiEvent.Click
	if !wheel {
		if editor.click_count > 0 && editor.last_click_pos == {y, x} && ms_since(editor.last_click_tick) < UI_DOUBLE_CLICK_MS {
			event = .Double_Click
			editor.click_count = 0
		} else {
			editor.click_count = 1
		}
		editor.last_click_tick = time.tick_now()
		editor.last_click_pos = {y, x}
	}
	if !wheel && ev.key == .Mouse_Left {
		for i := len(ui.hits) - 1; i >= 0; i -= 1 {
			if ui_rect_has(ui.hits[i].rect, x, y) {
				for n := ui.hits[i].node; n != nil; n = n.parent {
					if n.identity[0] == '#' {
						ui_focus_set(editor, n.identity)
						break
					}
				}
				break
			}
		}
	}
	gen := ui.gen
	visited := make(map[^UiNode]bool, 16, context.temp_allocator)
	for i := len(ui.hits) - 1; i >= 0; i -= 1 {
		hit := ui.hits[i]
		if !ui_rect_has(hit.rect, x, y) || visited[hit.node] {
			continue
		}
		for n := hit.node; n != nil; n = n.parent {
			if visited[n] {
				break
			}
			visited[n] = true
			args := UiHandlerArgs{mouse = true, x = x - n.rect.x + 1, y = y - n.rect.y + 1, button = ui_mouse_button(ev.key)}
			if event == .Double_Click && n.handlers[.Click] != 0 && ui_handler_call(editor, n.owner, n.handlers[.Click], args) {
				return true
			}
			if n.handlers[event] != 0 && ui_handler_call(editor, n.owner, n.handlers[event], args) {
				return true
			}
			if ui.gen != gen {
				return true
			}
			if ui_mouse_native(editor, n, ev, x, y, wheel) {
				return true
			}
		}
	}
	return false
}

ui_mouse_native :: proc(editor: ^Editor, n: ^UiNode, ev: tb2.Event, x, y: int, wheel: bool) -> bool {
	ui := &editor.ui
	step := -UI_WHEEL_STEP if ev.key == .Mouse_Wheel_Up else UI_WHEEL_STEP
	#partial switch n.kind {
	case .Scroll:
		if wheel {
			state := ui_state(ui, n.identity)
			state.offset = max(state.offset + step, 0)
			return true
		}
	case .Editor:
		b := ui_buffer(editor, n.buffer)
		if b == nil {
			return false
		}
		state := ui_state(ui, n.identity)
		if wheel {
			state.scroll_row = clamp(state.scroll_row + step, 0, len(b.lines) - 1)
			state.scroll_sub = 0
			return true
		}
		if ev.key != .Mouse_Left {
			return false
		}
		b.selection = nil
		b.cursor = ui_editor_point(editor, n, x, y)
		cursor_goal_sync(b)
		buffer_undo_commit(b)
		state.reveal = true
		delete(ui.drag.node)
		ui.drag = {node = strings.clone(n.identity), active = true}
		return true
	}
	return false
}

ui_editor_point :: proc(editor: ^Editor, node: ^UiNode, x, y: int) -> Cursor {
	b := ui_buffer(editor, node.buffer)
	state := ui_state(&editor.ui, node.identity)
	gutter := digit_count(len(b.lines)) + 2 if node.line_numbers else 0
	w := ui_editor_text_width(node, b)
	dy := max(y - node.rect.y, 0)
	dx := x - node.rect.x
	if b.wrap && w > 0 {
		row, sub := state.scroll_row, state.scroll_sub
		for dy > 0 {
			if sub + 1 < line_rows(b, w, row) {
				sub += 1
			} else if row + 1 < len(b.lines) {
				row += 1
				sub = 0
			} else {
				break
			}
			dy -= 1
		}
		return {row, editor_wrap_col(b, w, row, sub, gutter, dx)}
	}
	row := clamp(state.scroll_row + dy, 0, len(b.lines) - 1)
	text := b.lines[row].text[:]
	return {row, col_at_visual(text, state.scroll_col + max(dx - gutter, 0))}
}

ui_target_buffer :: proc(editor: ^Editor, edits := false) -> ^Buffer {
	n := editor.ui.target
	if n == nil || (edits && n.readonly) {
		return nil
	}
	b := ui_buffer(editor, n.buffer)
	if b != nil {
		ui_state(&editor.ui, n.identity).reveal = true
	}
	return b
}

ui_move :: proc(editor: ^Editor, select: bool, move: proc(b: ^Buffer)) {
	b := ui_target_buffer(editor)
	if b == nil {
		return
	}
	buffer_undo_commit(b)
	if select {
		selection_set_anchor(b)
	} else {
		b.selection = nil
	}
	move(b)
}

ui_cmd_left :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor)
	if b == nil {
		return
	}
	if from, _, ok := selection_range(b); ok {
		b.selection = nil
		b.cursor = from
		cursor_goal_sync(b)
		return
	}
	ui_move(editor, false, cursor_move_left)
}

ui_cmd_right :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor)
	if b == nil {
		return
	}
	if _, to, ok := selection_range(b); ok {
		b.selection = nil
		b.cursor = to
		cursor_goal_sync(b)
		return
	}
	ui_move(editor, false, cursor_move_right)
}

ui_cursor_up :: proc(b: ^Buffer) {cursor_move_up_n(b, 1)}
ui_cursor_down :: proc(b: ^Buffer) {cursor_move_down_n(b, 1)}

ui_cmd_up :: proc(editor: ^Editor) {ui_move(editor, false, ui_cursor_up)}
ui_cmd_down :: proc(editor: ^Editor) {ui_move(editor, false, ui_cursor_down)}
ui_cmd_select_left :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_left)}
ui_cmd_select_right :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_right)}
ui_cmd_select_up :: proc(editor: ^Editor) {ui_move(editor, true, ui_cursor_up)}
ui_cmd_select_down :: proc(editor: ^Editor) {ui_move(editor, true, ui_cursor_down)}
ui_cmd_word_left :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_word_left)}
ui_cmd_word_right :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_word_right)}
ui_cmd_line_start :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_home_smart)}
ui_cmd_line_end :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_end)}

ui_cmd_newline :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor, true)
	if b == nil {
		return
	}
	if selection_active(b) {
		buffer_replace_selection(b, "\n")
	} else {
		buffer_newline(b)
	}
	b.typed_rev = b.rev
}

ui_cmd_backspace :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor, true)
	if b == nil {
		return
	}
	if selection_active(b) {
		buffer_delete_selection(b)
	} else if !buffer_backspace_pair(b) {
		buffer_backspace(b)
	}
	b.typed_rev = b.rev
}

ui_cmd_delete :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor, true)
	if b == nil {
		return
	}
	if selection_active(b) {
		buffer_delete_selection(b)
	} else {
		buffer_delete_forward(b)
	}
	b.typed_rev = b.rev
}

ui_cmd_undo :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor, true)
	if b == nil {
		return
	}
	if !editor.welcome && b == editor_buffer(editor) {
		editor_undo(editor)
	} else {
		buffer_undo(b)
	}
}

ui_cmd_redo :: proc(editor: ^Editor) {
	b := ui_target_buffer(editor, true)
	if b == nil {
		return
	}
	if !editor.welcome && b == editor_buffer(editor) {
		editor_redo(editor)
	} else {
		buffer_redo(b)
	}
}

ui_cmd_select_all :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor); b != nil {
		cursor_select_all(b)
	}
}

ui_cmd_copy :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor); b != nil {
		buffer_copy(b)
	}
}

ui_cmd_cut :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor, true); b != nil {
		buffer_cut(b)
	}
}

ui_cmd_paste :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor, true); b != nil {
		buffer_paste_clipboard(b)
	}
}

ui_cmd_indent :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor, true); b != nil {
		buffer_indent(b)
	}
}

ui_cmd_dedent :: proc(editor: ^Editor) {
	if b := ui_target_buffer(editor, true); b != nil {
		buffer_dedent(b)
	}
}

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
	case .Resize:
		for key, &state in ui.states {
			if state.kind == .Editor {
				state.reveal = true
			}
		}
		return false
	case .Mouse:
		if len(ui.mounts) == 0 {
			return false
		}
		return ui_dispatch_mouse(editor, ev) || ui_layer_used(ui, "base")
	}
	return false
}

ui_target_editor :: proc(node: ^UiNode) -> ^UiNode {
	for node := node; node != nil; node = node.parent {
		if node.kind == .Editor {
			return node
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
	main_view := focus.kind == .Editor && ui_node_edits(focus) && ui_editor_shows_current(editor, ui_buffer(editor, focus.buffer))
	if main_view {
		editor.hover_active = false
		if editor.completion.active {
			if completion_key(editor, ev) {
				ui_node_state(ui, focus).reveal = true
				return
			}
			if !completion_keeps(ev) {
				completion_dismiss(editor)
			}
		}
		if inline_active(editor) {
			if inline_key(editor, ev) {
				return
			}
			inline_dismiss(editor)
		}
		defer completion_after(editor, ev)
	}
	defer ui.target = nil
	gen := ui.gen
	for node := focus; node != nil; node = node.parent {
		ui.target = node
		session := term_find(editor, node.session) if node.kind == .Terminal else nil
		// full-screen programs (alt-screen) own Escape
		program_escape := session != nil && ev.key == .Esc && !ev_alt(ev) && session.altscreen
		for scope in node.scope {
			if !program_escape && ui_scope_run(editor, scope, chord) {
				return
			}
		}
		if node.handlers[.Key] != 0 && ui_handler_call(editor, node.owner, node.handlers[.Key], {chord = chord, text = text}) {
			return
		}
		if ui.gen != gen {
			return
		}
		if session != nil && session.alive {
			term_key(session, ev)
			return
		}
		if node.kind == .Editor && text != "" && !node.readonly && ui_node_edits(node) {
			ui_editor_type(editor, node, ev.ch)
			return
		}
	}
	ui_global_binds(editor, ev)
}

ui_scope_run :: proc(editor: ^Editor, scope, chord: string) -> bool {
	if chord == "" {
		return false
	}
	for command in pane_commands {
		if command.scope != scope || command.run == nil {
			continue
		}
		_, _, shortcut := command_effective_bind(command)
		if shortcut != "" && ui_chord_cached(&editor.ui, shortcut) == chord {
			command.run(editor)
			return true
		}
	}
	for command in editor.plugins.commands {
		if command.scope == scope && command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord {
			plugin_command_chord(editor, command)
			return true
		}
	}
	return false
}

ui_global_binds :: proc(editor: ^Editor, ev: tb2.Event) {
	chord := ui_chord_of_event(ev)
	if chord == "" {
		return
	}
	for command in editor.plugins.commands {
		if command.scope == "" && command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord {
			plugin_command_chord(editor, command)
			return
		}
	}
	for command in commands {
		if command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord {
			if command_enabled(command) {
				command.run(editor)
			}
			return
		}
	}
}

ui_node_edits :: proc(node: ^UiNode) -> bool {
	for scope in node.scope {
		if scope == "editor" {
			return true
		}
	}
	return false
}

ui_editor_type :: proc(editor: ^Editor, node: ^UiNode, character: rune) {
	buffer := ui_buffer(editor, node.buffer)
	if buffer == nil {
		return
	}
	handled := buffer_type_pair(buffer, character)
	if !handled && character <= 0x7f {
		handled = buffer_close_dedent(buffer, u8(character))
	}
	if !handled {
		buffer_type_rune(buffer, character)
	}
	buffer.typed_rev = buffer.rev
	ui_node_state(&editor.ui, node).reveal = true
}

ui_paste :: proc(editor: ^Editor, text: string) -> bool {
	focus := ui_focused(editor)
	if focus == nil {
		return false
	}
	for node := focus; node != nil; node = node.parent {
		if node.handlers[.Paste] != 0 && ui_handler_call(editor, node.owner, node.handlers[.Paste], {text = text}) {
			return true
		}
		if node.kind == .Terminal {
			if session := term_find(editor, node.session); session != nil {
				term_paste(session, text)
				return true
			}
		}
		if node.kind == .Editor && !node.readonly && ui_node_edits(node) {
			if buffer := ui_buffer(editor, node.buffer); buffer != nil {
				buffer_paste(buffer, text)
				ui_node_state(&editor.ui, node).reveal = true
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
	cell_x, cell_y := int(ev.x), int(ev.y)
	motion := (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0
	if ui.drag.active && (ev.key == .Mouse_Release || motion) {
		if node := ui_find(ui, ui.drag.node); node != nil && node.kind == .Terminal {
			term_dispatch_mouse(editor, ev)
			if ev.key == .Mouse_Release {
				ui.drag.active = false
			}
			return true
		}
	}
	if ev.key == .Mouse_Release {
		was := ui.drag.active
		ui.drag.active = false
		return was
	}
	if motion && ev.key == .Mouse_Left {
		if !ui.drag.active {
			return false
		}
		if node := ui_find(ui, ui.drag.node); node != nil && node.kind == .Editor {
			if buffer := ui_buffer(editor, node.buffer); buffer != nil {
				if buffer.selection == nil {
					buffer.selection = buffer.cursor
				}
				buffer.cursor = ui_editor_point(editor, node, cell_x, cell_y)
				ui_node_state(ui, node).reveal = true
			}
		}
		return true
	}
	wheel := ev.key == .Mouse_Wheel_Up || ev.key == .Mouse_Wheel_Down
	event := UiEvent.Wheel if wheel else UiEvent.Click
	if !wheel {
		if editor.click_count > 0 && editor.last_click_pos == {cell_y, cell_x} && ms_since(editor.last_click_tick) < UI_DOUBLE_CLICK_MS {
			event = .Double_Click
			editor.click_count = 0
		} else {
			editor.click_count = 1
		}
		editor.last_click_tick = time.tick_now()
		editor.last_click_pos = {cell_y, cell_x}
	}
	if event == .Double_Click {
		clicked := ui_mouse_bubble(editor, ev, cell_x, cell_y, .Click, true)
		return ui_mouse_bubble(editor, ev, cell_x, cell_y, .Double_Click, false) || clicked
	}
	return ui_mouse_bubble(editor, ev, cell_x, cell_y, event, true)
}

ui_mouse_bubble :: proc(editor: ^Editor, ev: tb2.Event, cell_x, cell_y: int, event: UiEvent, native: bool) -> bool {
	ui := &editor.ui
	wheel := event == .Wheel
	gen := ui.gen
	visited := make(map[^UiNode]bool, 16, context.temp_allocator)
	for i := len(ui.hits) - 1; i >= 0; i -= 1 {
		hit := ui.hits[i]
		if !ui_rect_has(hit.rect, cell_x, cell_y) || visited[hit.node] {
			continue
		}
		for node := hit.node; node != nil; node = node.parent {
			if visited[node] {
				break
			}
			visited[node] = true
			args := UiHandlerArgs{mouse = true, x = cell_x - node.rect.x + 1, y = cell_y - node.rect.y + 1, button = ui_mouse_button(ev.key)}
			if node.handlers[event] != 0 && ui_handler_call(editor, node.owner, node.handlers[event], args) {
				return true
			}
			if ui.gen != gen {
				return true
			}
			if native && ui_mouse_native(editor, node, ev, cell_x, cell_y, wheel) {
				return true
			}
		}
	}
	return false
}

ui_mouse_native :: proc(editor: ^Editor, node: ^UiNode, ev: tb2.Event, cell_x, cell_y: int, wheel: bool) -> bool {
	ui := &editor.ui
	step := -UI_WHEEL_STEP if ev.key == .Mouse_Wheel_Up else UI_WHEEL_STEP
	#partial switch node.kind {
	case .Preview:
		if wheel {
			if entry, ok := editor.ui.previews[node.identity]; ok {
				preview_scroll_by(&entry.preview, step, node.rect.h)
				return true
			}
		}
	case .Terminal:
		if session := term_find(editor, node.session); session != nil {
			if ev.key == .Mouse_Left {
				if node.id != "" {
					ui_focus_set(editor, node.identity)
				}
				delete(ui.drag.node)
				ui.drag = {node = strings.clone(node.identity), active = true}
			}
			editor.terminal.shown = session
			term_dispatch_mouse(editor, ev)
			return true
		}
	case .Scroll:
		if wheel {
			state := ui_node_state(ui, node)
			state.offset = max(state.offset + step, 0)
			return true
		}
	case .Editor:
		buffer := ui_buffer(editor, node.buffer)
		if buffer == nil {
			return false
		}
		state := ui_node_state(ui, node)
		if wheel {
			state.scroll_row = clamp(state.scroll_row + step, 0, len(buffer.lines) - 1)
			state.scroll_sub = 0
			return true
		}
		if ev.key != .Mouse_Left {
			return false
		}
		if node.id != "" {
			ui_focus_set(editor, node.identity)
		}
		buffer.selection = nil
		buffer.cursor = ui_editor_point(editor, node, cell_x, cell_y)
		cursor_goal_sync(buffer)
		buffer_undo_commit(buffer)
		state.reveal = true
		delete(ui.drag.node)
		ui.drag = {node = strings.clone(node.identity), active = true}
		return true
	}
	return false
}

ui_editor_point :: proc(editor: ^Editor, node: ^UiNode, cell_x, cell_y: int) -> Cursor {
	buffer := ui_buffer(editor, node.buffer)
	state := ui_node_state(&editor.ui, node)
	gutter := digit_count(len(buffer.lines)) + 2 if node.line_numbers else 0
	width := ui_editor_text_width(node, buffer)
	dy := max(cell_y - node.rect.y, 0)
	dx := cell_x - node.rect.x
	if buffer.wrap && width > 0 {
		row, sub := state.scroll_row, state.scroll_sub
		for dy > 0 {
			if sub + 1 < line_rows(buffer, width, row) {
				sub += 1
			} else if row + 1 < len(buffer.lines) {
				row += 1
				sub = 0
			} else {
				break
			}
			dy -= 1
		}
		return {row, editor_wrap_col(buffer, width, row, sub, gutter, dx)}
	}
	row := clamp(state.scroll_row + dy, 0, len(buffer.lines) - 1)
	text := buffer.lines[row].text[:]
	return {row, col_at_visual(text, state.scroll_col + max(dx - gutter, 0))}
}

ui_target_buffer :: proc(editor: ^Editor, edits := false) -> ^Buffer {
	node := editor.ui.target
	if node == nil || (edits && node.readonly) {
		return nil
	}
	buffer := ui_buffer(editor, node.buffer)
	if buffer != nil {
		ui_node_state(&editor.ui, node).reveal = true
	}
	return buffer
}

ui_move :: proc(editor: ^Editor, select: bool, move: proc(buffer: ^Buffer)) {
	buffer := ui_target_buffer(editor)
	if buffer == nil {
		return
	}
	buffer_undo_commit(buffer)
	if select {
		selection_set_anchor(buffer)
	} else {
		buffer.selection = nil
	}
	move(buffer)
}

ui_command_left :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor)
	if buffer == nil {
		return
	}
	if from, _, ok := selection_range(buffer); ok {
		buffer.selection = nil
		buffer.cursor = from
		cursor_goal_sync(buffer)
		return
	}
	ui_move_accelerated(editor, .Arrow_Left, cursor_move_left)
}

ui_command_right :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor)
	if buffer == nil {
		return
	}
	if _, to, ok := selection_range(buffer); ok {
		buffer.selection = nil
		buffer.cursor = to
		cursor_goal_sync(buffer)
		return
	}
	ui_move_accelerated(editor, .Arrow_Right, cursor_move_right)
}

ui_cursor_up :: proc(buffer: ^Buffer) {cursor_move_up_n(buffer, 1)}
ui_cursor_down :: proc(buffer: ^Buffer) {cursor_move_down_n(buffer, 1)}

ui_move_accelerated :: proc(editor: ^Editor, key: tb2.Key, move: proc(buffer: ^Buffer), select := false) {
	buffer := ui_target_buffer(editor)
	if buffer == nil {
		return
	}
	buffer_undo_commit(buffer)
	if select {
		selection_set_anchor(buffer)
	} else {
		buffer.selection = nil
	}
	for _ in 0 ..< editor_accel_step(editor, key) {
		move(buffer)
	}
}

ui_command_up :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Up, ui_cursor_up)}
ui_command_down :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Down, ui_cursor_down)}

ui_command_move_line_up :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_move_lines(buffer, -1)
	}
}

ui_command_move_line_down :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_move_lines(buffer, +1)
	}
}
ui_command_select_left :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Left, cursor_move_left, true)}
ui_command_select_right :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Right, cursor_move_right, true)}
ui_command_select_up :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Up, ui_cursor_up, true)}
ui_command_select_down :: proc(editor: ^Editor) {ui_move_accelerated(editor, .Arrow_Down, ui_cursor_down, true)}
ui_command_word_left :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_word_left)}
ui_command_word_right :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_word_right)}
ui_command_line_start :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_home_smart)}
ui_command_line_end :: proc(editor: ^Editor) {ui_move(editor, false, cursor_move_end)}

ui_command_newline :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor, true)
	if buffer == nil {
		return
	}
	if selection_active(buffer) {
		buffer_replace_selection(buffer, "\n")
	} else {
		buffer_newline(buffer)
	}
	buffer.typed_rev = buffer.rev
}

ui_command_backspace :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor, true)
	if buffer == nil {
		return
	}
	if selection_active(buffer) {
		buffer_delete_selection(buffer)
	} else if !buffer_backspace_pair(buffer) {
		buffer_backspace(buffer)
	}
	buffer.typed_rev = buffer.rev
}

ui_command_delete :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor, true)
	if buffer == nil {
		return
	}
	if selection_active(buffer) {
		buffer_delete_selection(buffer)
	} else {
		buffer_delete_forward(buffer)
	}
	buffer.typed_rev = buffer.rev
}

ui_command_undo :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor, true)
	if buffer == nil {
		return
	}
	if !editor.welcome && buffer == editor_buffer(editor) {
		editor_undo(editor)
	} else {
		buffer_undo(buffer)
	}
}

ui_command_redo :: proc(editor: ^Editor) {
	buffer := ui_target_buffer(editor, true)
	if buffer == nil {
		return
	}
	if !editor.welcome && buffer == editor_buffer(editor) {
		editor_redo(editor)
	} else {
		buffer_redo(buffer)
	}
}

ui_command_select_all :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor); buffer != nil {
		cursor_select_all(buffer)
	}
}

ui_command_copy :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor); buffer != nil {
		buffer_copy(buffer)
	}
}

ui_command_cut :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_cut(buffer)
	}
}

ui_command_paste :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_paste_clipboard(buffer)
	}
}

ui_command_indent :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_indent(buffer)
	}
}

ui_command_dedent :: proc(editor: ^Editor) {
	if buffer := ui_target_buffer(editor, true); buffer != nil {
		buffer_dedent(buffer)
	}
}

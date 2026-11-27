package main

import "core:fmt"
import "core:strings"
import "core:time"
import "lib:tb2"

ui_dispatch :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	ui := &editor.ui
	#partial switch ev.type {
	case .Key:
		focus := ui_focused(editor)
		if focus == nil {
			// no layout (disabled or broken): the global binds still work, so Quit, Save and the palette do
			if editor.welcome {
				return false
			}
			ui_global_binds(editor, ev)
			return true
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
	// a flush can re-parent a node under one already visited: each identity hears a key once
	visited := make(map[string]bool, 8, context.temp_allocator)
	for node := focus; node != nil; node = node.parent {
		if visited[node.identity] {
			continue
		}
		visited[node.identity] = true
		ui.target = node
		session := term_find(editor, node.session) if node.kind == .Terminal else nil
		// full-screen programs (alt-screen) own Escape
		program_escape := session != nil && ev.key == .Esc && !ev_alt(ev) && session.altscreen
		for scope in node.scope {
			if !program_escape && ui_scope_run(editor, scope, chord) {
				return
			}
		}
		// a pre-command flush that replaced the tree hands the key on from the same node in the new tree, whose
		// session may differ (or be gone)
		if ui.gen != gen && ui.target != nil {
			node = ui.target
			gen = ui.gen
			session = term_find(editor, node.session) if node.kind == .Terminal else nil
		}
		if node.handlers[.Key] != 0 && ui_handler_call(editor, node.owner, node.handlers[.Key], {chord = chord, text = text}) {
			return
		}
		if node.core_event != nil && node.core_event(editor, ev) {
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
	if chord == "" || !ui_scope_has_chord(editor, scope, chord) {
		return false
	}
	if !ui_flush_before_command(editor) {
		return true
	}
	for command in scoped_commands {
		if command.scope == scope && command.run != nil && ui_core_chord(editor, command) == chord && (command.applies == nil || command.applies(editor)) {
			command.run(editor)
			return true
		}
	}
	for command in editor.plugins.commands {
		if command.scope == scope && command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord && plugin_command_when(editor, command) {
			plugin_command_run(editor, command)
			return true
		}
	}
	return false
}

@(private = "file")
ui_core_chord :: proc(editor: ^Editor, command: Command) -> string {
	_, _, shortcut := command_effective_bind(command)
	return ui_chord_cached(&editor.ui, shortcut) if shortcut != "" else ""
}

@(private = "file")
ui_scope_has_chord :: proc(editor: ^Editor, scope, chord: string) -> bool {
	for command in scoped_commands {
		if command.scope == scope && command.run != nil && ui_core_chord(editor, command) == chord {
			return true
		}
	}
	for command in editor.plugins.commands {
		if command.scope == scope && command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord {
			return true
		}
	}
	return false
}

// a command acts on what the keys typed before it changed, so their change events run first, and only then is it
// asked whether it applies. A handler that replaced the tree leaves the command the new node with the same identity,
// laid out as the next frame would; when that node is gone there is nothing to act on
ui_flush_before_command :: proc(editor: ^Editor) -> bool {
	ui := &editor.ui
	identity := strings.clone(ui.target.identity, context.temp_allocator) if ui.target != nil else ""
	gen := ui.gen
	plugin_flush(editor)
	if ui.gen == gen || identity == "" {
		return true
	}
	ui_resolve(editor)
	ui.target = ui_find(ui, identity)
	if ui.target == nil {
		return false
	}
	ui_layout(editor)
	return true
}

ui_global_binds :: proc(editor: ^Editor, ev: tb2.Event) {
	chord := ui_chord_of_event(ev)
	if chord == "" {
		return
	}
	// one rule for every command: one that does not apply now lets its chord pass to the next
	for command in editor.plugins.commands {
		if command.scope == "" && command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord && plugin_command_when(editor, command) {
			plugin_command_run(editor, command)
			return
		}
	}
	for command in commands {
		if command.shortcut != "" && ui_chord_cached(&editor.ui, command.shortcut) == chord && command_enabled(command) {
			command.run(editor)
			return
		}
	}
}

ui_node_in_scope :: proc(node: ^UiNode, scope: string) -> bool {
	for ancestor := node; ancestor != nil; ancestor = ancestor.parent {
		for name in ancestor.scope {
			if name == scope {
				return true
			}
		}
	}
	return false
}

ui_node_edits :: proc(node: ^UiNode) -> bool {
	for scope in node.scope {
		if scope == "editor" {
			return true
		}
	}
	return false
}

// an editor node one row high is a field: no indenting, auto-pairs or newlines; pasted newlines become spaces
ui_node_one_line :: proc(node: ^UiNode) -> bool {
	return node.kind == .Editor && node.height.form == .Cells && node.height.value == 1
}

ui_target_multiline :: proc(editor: ^Editor) -> bool {
	return editor.ui.target != nil && !ui_node_one_line(editor.ui.target)
}

// a terminal with erase ^H sends Ctrl+h for Backspace: a field takes it, the main editor leaves it to Replace
ui_target_one_line :: proc(editor: ^Editor) -> bool {
	return editor.ui.target != nil && ui_node_one_line(editor.ui.target)
}

ui_editor_type :: proc(editor: ^Editor, node: ^UiNode, character: rune) {
	buffer := ui_buffer(editor, node.buffer)
	if buffer == nil {
		return
	}
	if ui_node_one_line(node) {
		buffer_type_rune(buffer, character)
		buffer.typed_rev = buffer.rev
		ui_node_state(&editor.ui, node).reveal = true
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
				ui_node_paste(editor, node, buffer, text)
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
	// the wheel over the hover scrolls it; any other click or wheel closes the caret popups, and a wheel over the
	// completion menu or the diagnostic box only closes it (the editor under it does not scroll)
	popup := caret_popup_root(editor)
	wheel_over_popup := popup != nil && ui_rect_has(popup.rect, cell_x, cell_y) && ev_wheel(ev)
	if wheel_over_popup && popup.id != "caret_hover" {
		completion_dismiss(editor)
		caret_diagnostic_close(editor)
		return true
	}
	if !motion && ev.key != .Mouse_Release && !wheel_over_popup {
		editor.hover_active = false
		completion_dismiss(editor)
		inline_dismiss(editor)
	}
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
				// dragging past an edge scrolls one row further
				if cell_y < node.rect.y {
					cursor_move_up_n(buffer, 1)
				} else if cell_y >= node.rect.y + node.rect.h {
					cursor_move_down_n(buffer, 1)
				}
				cursor_goal_sync(buffer)
				ui_node_state(ui, node).reveal = true
			}
		} else if node != nil && node.kind == .Virtual_Column {
			// a drag over a range list's rows extends from the pressed row, as Shift+Up/Down do
			if list := ui_list_find(ui, node.list); list != nil && ui_list_count(list) > 0 {
				row := clamp(cell_y - node.rect.y, 0, ui_list_count(list) - 1)
				ui_list_highlight(editor, node, strings.clone(ui_list_key(list, row), context.temp_allocator), true)
			}
		}
		return true
	}
	wheel := ev_wheel(ev)
	event := UiEvent.Wheel if wheel else UiEvent.Click
	if !wheel {
		if editor.click_count > 0 && editor.last_click_pos == {cell_y, cell_x} && ms_since(editor.last_click_tick) < f64(DOUBLE_CLICK_MS) {
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
			// on.wheel carries no direction, so a sideways wheel would read as a vertical one
			if node.handlers[event] != 0 && !ev_wheel_sideways(ev) && ui_handler_call(editor, node.owner, node.handlers[event], args) {
				return true
			}
			if native && node.core_event != nil && node.core_event(editor, ev) {
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

ui_editor_scroll_sideways :: proc(state: ^UiState, buffer: ^Buffer, width: int, left: bool) {
	if left {
		state.scroll_col = max(state.scroll_col - WHEEL_SCROLL_COLUMNS, 0)
		return
	}
	// as far as revealing the caret at the end of the longest line would scroll
	limit := buffer_width_max(buffer) - width + min(SCROLL_MARGIN, width / 4) + 1
	if state.scroll_col < limit {
		state.scroll_col = min(state.scroll_col + WHEEL_SCROLL_COLUMNS, limit)
	}
}

ui_mouse_native :: proc(editor: ^Editor, node: ^UiNode, ev: tb2.Event, cell_x, cell_y: int, wheel: bool) -> bool {
	ui := &editor.ui
	step := -WHEEL_SCROLL_LINES if ev.key == .Mouse_Wheel_Up else WHEEL_SCROLL_LINES
	if node.is_item && node.parent != nil && node.parent.kind == .Virtual_Column && ev.key == .Mouse_Left && !wheel {
		ui_list_highlight(editor, node.parent, strings.clone(node.key, context.temp_allocator), false)
		if ui_node_in_scope(node.parent, "list_range") {
			delete(ui.drag.node)
			ui.drag = {node = strings.clone(node.parent.identity), active = true}
		}
		return true
	}
	#partial switch node.kind {
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
	case .Markdown:
		if ev.key != .Mouse_Left {
			return false
		}
		if node.id != "" {
			ui_focus_set(editor, node.identity)
		}
		ui_markdown_click(editor, node, cell_x, cell_y)
		return true
	case .Scroll:
		if wheel {
			if !ev_wheel_sideways(ev) {
				ui_scroll_by(editor, node, step, true)
			}
			return true
		}
	case .Editor:
		buffer := ui_buffer(editor, node.buffer)
		if buffer == nil {
			return false
		}
		state := ui_node_state(ui, node)
		if wheel {
			width := ui_editor_text_width(node, buffer)
			wraps := ui_editor_wraps(node)
			if ev_wheel_sideways(ev) {
				if !wraps && width > 0 {
					ui_editor_scroll_sideways(state, buffer, width, ev.key == .Mouse_Wheel_Up || ev.key == .Mouse_Wheel_Left)
				}
				return true
			}
			if !wraps || width <= 0 {
				state.scroll_row = row_shown_step(buffer, state.scroll_row, step)
				state.scroll_sub = 0
				return true
			}
			if step < 0 {
				state.scroll_row, state.scroll_sub = vpos_up(buffer, width, state.scroll_row, state.scroll_sub, -step)
				return true
			}
			last := row_shown_prev(buffer, len(buffer.lines) - 1)
			max_row, max_sub := vpos_up(buffer, width, last, line_rows(buffer, width, last) - 1, node.rect.h - 1)
			row, sub := vpos_down(buffer, width, state.scroll_row, state.scroll_sub, step)
			if vpos_cmp(row, sub, max_row, max_sub) > 0 {
				row, sub = max_row, max_sub
			}
			state.scroll_row, state.scroll_sub = row, sub
			return true
		}
		if ev.key != .Mouse_Left {
			return false
		}
		if node.id != "" {
			ui_focus_set(editor, node.identity)
		}
		// a second click on the same spot selects the word, a third the line
		pos := ui_editor_point(editor, node, cell_x, cell_y)
		clicks := &ui.editor_clicks
		recent := clicks.count > 0 && ms_since(clicks.tick) <= f64(DOUBLE_CLICK_MS) && clicks.pos == pos && clicks.node == node.buffer
		clicks.count = clicks.count + 1 if recent else 1
		if clicks.count > 3 {
			clicks.count = 1
		}
		clicks.tick, clicks.pos, clicks.node = time.tick_now(), pos, node.buffer
		switch clicks.count {
		case 2:
			from, to := word_range_at(buffer, pos)
			buffer.selection, buffer.cursor = from, to
		case 3:
			from, to := line_range_at(buffer, pos.row)
			buffer.selection, buffer.cursor = from, to
		case:
			buffer.selection = nil
			buffer.cursor = pos
		}
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
	// vpos steps over ghost rows as the renderer draws them
	if ui_editor_wraps(node) && width > 0 {
		row, sub := vpos_down(buffer, width, state.scroll_row, state.scroll_sub, dy)
		return {row, editor_wrap_col(buffer, width, row, sub, gutter, dx)}
	}
	row, _ := vpos_down(buffer, 0, state.scroll_row, 0, dy)
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
		// collapsing a selection ends a held-key streak
		editor.accel_count, editor.accel_rem = 0, 0
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
		// collapsing a selection ends a held-key streak
		editor.accel_count, editor.accel_rem = 0, 0
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
ui_command_paragraph_up :: proc(editor: ^Editor) {ui_move(editor, false, cursor_paragraph_prev)}
ui_command_paragraph_down :: proc(editor: ^Editor) {ui_move(editor, false, cursor_paragraph_next)}
ui_command_select_word_left :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_word_left)}
ui_command_select_word_right :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_word_right)}
ui_command_select_line_start :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_home_smart)}
ui_command_select_line_end :: proc(editor: ^Editor) {ui_move(editor, true, cursor_move_end)}
ui_command_select_paragraph_up :: proc(editor: ^Editor) {ui_move(editor, true, cursor_paragraph_prev)}
ui_command_select_paragraph_down :: proc(editor: ^Editor) {ui_move(editor, true, cursor_paragraph_next)}

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
		if text := clipboard_get(context.temp_allocator); len(text) > 0 {
			ui_node_paste(editor, editor.ui.target, buffer, text)
		}
	}
}

// every paste into a one-row field (bracketed or Ctrl+V) lands on its one line
ui_node_paste :: proc(editor: ^Editor, node: ^UiNode, buffer: ^Buffer, text: string) {
	pasted := text
	if ui_node_one_line(node) {
		pasted, _ = strings.replace_all(text, "\r\n", " ", context.temp_allocator)
		pasted, _ = strings.replace_all(pasted, "\n", " ", context.temp_allocator)
		pasted, _ = strings.replace_all(pasted, "\r", " ", context.temp_allocator)
	}
	buffer_paste(buffer, pasted)
	ui_node_state(&editor.ui, node).reveal = true
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

ui_list_target :: proc(node: ^UiNode) -> ^UiNode {
	return ui_first_of_kind(node, .Virtual_Column)
}

ui_first_of_kind :: proc(node: ^UiNode, kind: UiKind) -> ^UiNode {
	if node == nil {
		return nil
	}
	if node.kind == kind {
		return node
	}
	for child in node.expanded {
		if found := ui_first_of_kind(child, kind); found != nil {
			return found
		}
	}
	return nil
}

ui_state_changed :: proc(editor: ^Editor, node: ^UiNode) {
	if node.handlers[.State] == 0 {
		return
	}
	state := ui_node_state_peek(&editor.ui, node)
	ui_handler_call(editor, node.owner, node.handlers[.State], {state = true, highlighted = state.highlighted, extend_from = state.extend_from, list = ui_list_find(&editor.ui, node.list)})
}

ui_list_highlight :: proc(editor: ^Editor, node: ^UiNode, key: string, extend: bool) {
	state := ui_node_state(&editor.ui, node)
	if state.highlighted == key && extend == (state.extend_from != "") {
		return
	}
	if extend && state.extend_from == "" {
		state.extend_from = strings.clone(state.highlighted)
	} else if !extend && state.extend_from != "" {
		delete(state.extend_from)
		state.extend_from = ""
	}
	delete(state.highlighted)
	state.highlighted = strings.clone(key)
	state.reveal = true
	if list := ui_list_find(&editor.ui, node.list); list != nil {
		state.key_kind = ui_list_keys_owner(editor, list).key_kind
	}
	ui_follow_park(editor, node, key)
	ui_state_changed(editor, node)
}

// a highlight off the list's last row parks a follow scroll; back on the last row it follows again
ui_follow_park :: proc(editor: ^Editor, node: ^UiNode, key: string) {
	scroll := ui_enclosing_scroll(node)
	list := ui_list_find(&editor.ui, node.list)
	if scroll == nil || !scroll.follow || list == nil {
		return
	}
	at, present := ui_list_position(list, key)
	ui_node_state(&editor.ui, scroll).parked = present && at < ui_list_count(list) - 1
}

ui_list_move :: proc(editor: ^Editor, step: int, extend := false) {
	node := ui_list_target(editor.ui.target)
	if node == nil {
		ui_scroll_move(editor, step)
		return
	}
	list := ui_list_find(&editor.ui, node.list)
	if list == nil {
		return
	}
	ui_list_settle_all(editor, list)
	count := ui_list_count(list)
	if count == 0 {
		return
	}
	state := ui_node_state_peek(&editor.ui, node)
	index, present := ui_list_position(list, state.highlighted)
	target := clamp(index + step, 0, count - 1) if present else (0 if step > 0 else count - 1)
	ui_list_highlight(editor, node, strings.clone(ui_list_key(list, target), context.temp_allocator), extend)
}

ui_scroll_move :: proc(editor: ^Editor, step: int) {
	scroll := ui_first_of_kind(editor.ui.target, .Scroll)
	if scroll == nil {
		return
	}
	ui_scroll_by(editor, scroll, step)
}

ui_scroll_by :: proc(editor: ^Editor, scroll: ^UiNode, step: int, wheel := false) {
	state := ui_node_state(&editor.ui, scroll)
	before := state.offset
	// the wheel leaves the far end to layout (content may have grown since the last one); keys stop at the known end
	state.offset = max(state.offset + step, 0) if wheel else clamp(state.offset + step, 0, state.max_offset)
	// layout recomputes at_end from the offset (left set, `follow` would snap back); the user scrolling is the newer
	// intent than a parked highlight, so reaching the end follows again
	state.at_end, state.parked = false, false
	if scroll.handlers[.State] == 0 {
		return
	}
	// on.state reports the offset layout settles on
	ui_resolve(editor)
	ui_layout(editor)
	state = ui_node_state(&editor.ui, scroll)
	if state.offset != before {
		ui_handler_call(editor, scroll.owner, scroll.handlers[.State], {scrolled = true, offset = state.offset})
	}
}

ui_list_page :: proc(editor: ^Editor) -> int {
	if node := ui_list_target(editor.ui.target); node != nil {
		return max(node.clip.h - 1, 1)
	}
	if scroll := ui_first_of_kind(editor.ui.target, .Scroll); scroll != nil {
		return max(scroll.rect.h - (scroll.header.rect.h if scroll.header != nil else 0) - 1, 1)
	}
	return 1
}

ui_command_list_next :: proc(editor: ^Editor) {ui_list_move(editor, editor_accel_step(editor, .Arrow_Down))}
ui_command_list_previous :: proc(editor: ^Editor) {ui_list_move(editor, -editor_accel_step(editor, .Arrow_Up))}
ui_command_list_page_down :: proc(editor: ^Editor) {ui_list_move(editor, ui_list_page(editor))}
ui_command_list_page_up :: proc(editor: ^Editor) {ui_list_move(editor, -ui_list_page(editor))}
ui_command_list_first :: proc(editor: ^Editor) {ui_list_move(editor, -max(int) / 2)}
ui_command_list_last :: proc(editor: ^Editor) {ui_list_move(editor, max(int) / 2)}
ui_command_list_extend_down :: proc(editor: ^Editor) {ui_list_move(editor, 1, true)}
ui_command_list_extend_up :: proc(editor: ^Editor) {ui_list_move(editor, -1, true)}

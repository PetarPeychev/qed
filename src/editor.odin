package main

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

Editor :: struct {
	buffer:     Buffer,
	scroll_row:    int,
	scroll_col:    int,
	message:       string,
	message_error: bool,
	confirm_quit:  bool,
	quit:          bool,
	pasting:       bool,
	paste_buf:     [dynamic]u8,
	paste_last_cr: bool,
	last_click_tick: time.Tick,
	last_click_pos:  Cursor,
	click_count:     int,
}

editor_init :: proc(path: string = "") -> Editor {
	tb2.init()
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	editor := Editor {
		buffer = buffer_new(),
	}
	if path != "" {
		buffer_open(&editor.buffer, path)
	}
	return editor
}

editor_shutdown :: proc(editor: ^Editor) {
	buffer_destroy(&editor.buffer)
	delete(editor.paste_buf)
	clipboard_shutdown()
	tb2.shutdown()
}

editor_gutter_width :: proc(editor: ^Editor) -> int {
	n := len(editor.buffer.lines)
	digits := 1
	for n >= 10 {
		digits += 1
		n /= 10
	}
	return digits + 1
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - 2)
	return
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.type {
	case .Key:
		if editor.pasting {
			editor_paste_accumulate(editor, ev)
		} else {
			editor_dispatch_key(editor, ev)
		}
	case .Paste_Begin:
		editor.pasting = true
		editor.paste_last_cr = false
		editor.message = ""
		editor.message_error = false
		clear(&editor.paste_buf)
	case .Paste_End:
		editor_paste_commit(editor)
	case .Mouse:
		if !editor.pasting {
			editor_dispatch_mouse(editor, ev)
		}
	case .Resize:
		editor_scroll(editor)
	}
}

editor_mouse_cursor :: proc(editor: ^Editor, x, y: int) -> Cursor {
	gutter := editor_gutter_width(editor)
	_, h := editor_viewport(editor)
	row := clamp(editor.scroll_row + min(y, h - 1), 0, len(editor.buffer.lines) - 1)
	col := clamp(editor.scroll_col + max(0, x - gutter), 0, len(editor.buffer.lines[row].text))
	return {row, col}
}

editor_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	if editor.confirm_quit {
		return
	}
	editor.message = ""
	editor.message_error = false
	b := &editor.buffer

	#partial switch ev.key {
	case .Mouse_Left:
		buffer_undo_commit(b)
		pos := editor_mouse_cursor(editor, int(ev.x), int(ev.y))
		if (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0 {
			selection_set_anchor(b)
			b.cursor = pos
			b.goal_col = pos.col
			editor_scroll(editor)
			return
		}
		recent :=
			editor.click_count > 0 &&
			time.duration_milliseconds(time.tick_since(editor.last_click_tick)) <= DOUBLE_CLICK_MS &&
			pos == editor.last_click_pos
		editor.click_count = editor.click_count + 1 if recent else 1
		if editor.click_count > 3 {
			editor.click_count = 1
		}
		editor.last_click_tick = time.tick_now()
		editor.last_click_pos = pos

		switch editor.click_count {
		case 2:
			from, to := word_range_at(b, pos)
			b.selection = from
			b.cursor = to
			b.goal_col = to.col
		case 3:
			from, to := line_range_at(b, pos.row)
			b.selection = from
			b.cursor = to
			b.goal_col = to.col
		case:
			b.selection = nil
			b.cursor = pos
			b.goal_col = pos.col
		}
		editor_scroll(editor)
	case .Mouse_Wheel_Up:
		editor.scroll_row = max(0, editor.scroll_row - WHEEL_SCROLL_LINES)
	case .Mouse_Wheel_Down:
		_, h := editor_viewport(editor)
		max_scroll := max(0, len(b.lines) - h)
		editor.scroll_row = min(max_scroll, editor.scroll_row + WHEEL_SCROLL_LINES)
	}
}

editor_paste_accumulate :: proc(editor: ^Editor, ev: tb2.Event) {
	if ev.ch != 0 {
		bytes, n := utf8.encode_rune(ev.ch)
		append(&editor.paste_buf, ..bytes[:n])
		editor.paste_last_cr = false
		return
	}
	#partial switch ev.key {
	case .Enter:
		append(&editor.paste_buf, '\n')
		editor.paste_last_cr = true
	case .Ctrl_J:
		if !editor.paste_last_cr {
			append(&editor.paste_buf, '\n')
		}
		editor.paste_last_cr = false
	case .Tab:
		append(&editor.paste_buf, '\t')
		editor.paste_last_cr = false
	case:
		editor.paste_last_cr = false
	}
}

editor_paste_commit :: proc(editor: ^Editor) {
	editor.pasting = false
	if len(editor.paste_buf) == 0 {
		return
	}
	buffer_paste(&editor.buffer, string(editor.paste_buf[:]))
	clear(&editor.paste_buf)
	editor_scroll(editor)
}

editor_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	if editor.confirm_quit {
		editor.confirm_quit = false
		editor.message = ""
		switch ev.ch {
		case 'y', 'Y':
			editor_save(editor)
			if !editor.buffer.modified {
				editor.quit = true
			}
		case 'n', 'N':
			editor.quit = true
		}
		return
	}

	editor.message = ""
	editor.message_error = false
	b := &editor.buffer
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	shift := (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0
	_, h := editor_viewport(editor)

	#partial switch ev.key {
	case .Ctrl_Q:
		if editor.buffer.modified {
			editor.message = "Save before quitting? (y/n/esc)"
			editor.confirm_quit = true
		} else {
			editor.quit = true
		}
	case .Ctrl_S:
		editor_save(editor)
	case .Ctrl_Z:
		buffer_undo(b)
	case .Ctrl_Y:
		buffer_redo(b)
	case .Ctrl_A:
		cursor_select_all(b)
	case .Ctrl_C:
		editor_copy(editor)
	case .Ctrl_X:
		editor_cut(editor)
	case .Ctrl_V:
		editor_paste(editor)
	case .Enter:
		if selection_active(b) {
			buffer_replace_selection(b, "\n")
		} else {
			buffer_newline(b)
		}
	case .Tab:
		buffer_indent(b)
	case .Back_Tab:
		buffer_dedent(b)
	case .Backspace, .Backspace2:
		if selection_active(b) {
			buffer_delete_selection(b)
		} else {
			buffer_backspace(b)
		}
	case .Delete:
		if selection_active(b) {
			buffer_delete_selection(b)
		} else {
			buffer_delete_forward(b)
		}
	case .Arrow_Left, .Arrow_Right, .Arrow_Up, .Arrow_Down, .Home, .End, .Pgup, .Pgdn:
		buffer_undo_commit(b)
		sel_from, sel_to, had_sel := selection_range(b)
		if shift {
			selection_set_anchor(b)
		} else {
			b.selection = nil
		}
		collapse := had_sel && !shift && !ctrl
		#partial switch ev.key {
		case .Arrow_Left:
			if collapse {
				b.cursor = sel_from
				b.goal_col = sel_from.col
			} else if ctrl {
				cursor_move_word_left(b)
			} else {
				cursor_move_left(b)
			}
		case .Arrow_Right:
			if collapse {
				b.cursor = sel_to
				b.goal_col = sel_to.col
			} else if ctrl {
				cursor_move_word_right(b)
			} else {
				cursor_move_right(b)
			}
		case .Arrow_Up:
			cursor_move_up_n(b, 1)
		case .Arrow_Down:
			cursor_move_down_n(b, 1)
		case .Home:
			if ctrl {
				cursor_move_buffer_start(b)
			} else {
				cursor_move_home(b)
			}
		case .End:
			if ctrl {
				cursor_move_buffer_end(b)
			} else {
				cursor_move_end(b)
			}
		case .Pgup:
			cursor_move_up_n(b, h)
		case .Pgdn:
			cursor_move_down_n(b, h)
		}
	case:
		if ev.ch == 0 {
			return
		}
		buffer_type_rune(b, ev.ch)
	}
	editor_scroll(editor)
}

editor_copy :: proc(editor: ^Editor) {
	b := &editor.buffer
	if selection_active(b) {
		from, to, _ := selection_range(b)
		clipboard_set(buffer_text_range(b, from, to))
	} else {
		line := b.lines[b.cursor.row].text[:]
		clipboard_set(strings.concatenate({string(line), "\n"}, context.temp_allocator))
	}
}

editor_cut :: proc(editor: ^Editor) {
	editor_copy(editor)
	b := &editor.buffer
	if selection_active(b) {
		buffer_delete_selection(b)
	} else {
		buffer_delete_line(b)
	}
}

editor_paste :: proc(editor: ^Editor) {
	text := clipboard_get(context.temp_allocator)
	if len(text) == 0 {
		return
	}
	buffer_paste(&editor.buffer, text)
}

editor_save :: proc(editor: ^Editor) {
	switch buffer_save(&editor.buffer) {
	case .None:
		editor.message = "Saved"
	case .NoPath:
		editor.message = "No file name"
		editor.message_error = true
	case .WriteError, .RenameError:
		editor.message = "Save failed"
		editor.message_error = true
	}
}

editor_scroll :: proc(editor: ^Editor) {
	w, h := editor_viewport(editor)
	cur := editor.buffer.cursor

	if cur.row < editor.scroll_row + SCROLL_MARGIN {
		editor.scroll_row = cur.row - SCROLL_MARGIN
	}
	if cur.row > editor.scroll_row + h - 1 - SCROLL_MARGIN {
		editor.scroll_row = cur.row - h + 1 + SCROLL_MARGIN
	}
	max_scroll_row := max(0, len(editor.buffer.lines) - h)
	editor.scroll_row = clamp(editor.scroll_row, 0, max_scroll_row)

	if cur.col < editor.scroll_col + SCROLL_MARGIN {
		editor.scroll_col = cur.col - SCROLL_MARGIN
	}
	if cur.col > editor.scroll_col + w - 1 - SCROLL_MARGIN {
		editor.scroll_col = cur.col - w + 1 + SCROLL_MARGIN
	}
	editor.scroll_col = max(0, editor.scroll_col)
}

editor_render :: proc(editor: ^Editor) {
	tb2.clear()
	full_w := int(tb2.width())
	gutter := editor_gutter_width(editor)
	w, h := editor_viewport(editor)

	sel_from, sel_to, sel_ok := selection_range(&editor.buffer)

	for screen_y in 0 ..< h {
		row := editor.scroll_row + screen_y
		if row >= len(editor.buffer.lines) {
			break
		}
		current := row == editor.buffer.cursor.row
		editor_render_gutter(screen_y, gutter, row + 1, current)

		text := editor.buffer.lines[row].text
		row_sel_from, row_sel_to := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			row_sel_from = sel_from.col if row == sel_from.row else 0
			row_sel_to = sel_to.col if row == sel_to.row else len(text) + 1
		}
		editor_render_text_row(gutter, screen_y, w, text[:], editor.scroll_col, current, row_sel_from, row_sel_to)
	}

	name := editor.buffer.path if editor.buffer.path != "" else "[No Name]"
	status := name
	if editor.buffer.modified {
		status = fmt.tprintf("%s [*]", name)
	}
	editor_render_row(0, h, full_w, status, COLOR_STATUS_FG, COLOR_STATUS_BG)
	message_fg := COLOR_ERROR_FG if editor.message_error else COLOR_FG
	editor_render_row(0, h + 1, full_w, editor.message, message_fg, COLOR_BG)

	cx := gutter + editor.buffer.cursor.col - editor.scroll_col
	cy := editor.buffer.cursor.row - editor.scroll_row
	tb2.set_cursor(i32(cx), i32(cy))
	tb2.present()
}

editor_render_gutter :: proc(y, width, number: int, current: bool) {
	label := fmt.tprintf("%d", number)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< width - 1 - len(label) {
		strings.write_byte(&sb, ' ')
	}
	strings.write_string(&sb, label)
	strings.write_byte(&sb, ' ')
	fg := COLOR_CURRENT_LINE_FG if current else COLOR_GUTTER_FG
	cstr := strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
	tb2.print(0, i32(y), fg, COLOR_GUTTER_BG, cstr)
}

editor_render_text_row :: proc(
	gutter, y, w: int,
	text: []u8,
	scroll_col: int,
	current: bool,
	sel_from, sel_to: int,
) {
	bg_normal := COLOR_CURRENT_LINE_BG if current else COLOR_BG
	for sx in 0 ..< w {
		col := scroll_col + sx
		ch := rune(' ')
		if col < len(text) {
			ch = rune(text[col])
		}
		fg := COLOR_FG
		bg := bg_normal
		if sel_from >= 0 && col >= sel_from && col < sel_to {
			fg = COLOR_BG
			bg = COLOR_FG
		}
		tb2.set_cell(i32(gutter + sx), i32(y), ch, fg, bg)
	}
}

editor_render_row :: proc(x, y, w: int, text: string, fg, bg: tb2.Color) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, text)
	for _ in len(text) ..< w {
		strings.write_byte(&sb, ' ')
	}
	row := strings.to_string(sb)
	if len(row) > w {
		row = row[:w]
	}
	cstr := strings.clone_to_cstring(row, context.temp_allocator)
	tb2.print(i32(x), i32(y), fg, bg, cstr)
}

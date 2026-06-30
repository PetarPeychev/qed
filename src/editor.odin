package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

Editor :: struct {
	buffer:     Buffer,
	scroll_row: int,
	scroll_col: int,
	message:    string,
	quit:       bool,
}

editor_init :: proc(path: string = "") -> Editor {
	tb2.init()
	tb2.set_output_mode(.Truecolor)
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
	tb2.shutdown()
}

editor_viewport :: proc() -> (w, h: int) {
	return int(tb2.width()), max(0, int(tb2.height()) - 2)
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	#partial switch ev.type {
	case .Key:
		editor_dispatch_key(editor, ev)
	case .Resize:
		editor_scroll(editor)
	}
}

editor_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	editor.message = ""
	b := &editor.buffer
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	_, h := editor_viewport()

	#partial switch ev.key {
	case .Ctrl_Q:
		editor.quit = true
	case .Arrow_Left:
		if ctrl {
			cursor_move_word_left(b)
		} else {
			cursor_move_left(b)
		}
	case .Arrow_Right:
		if ctrl {
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
	case .Enter:
		buffer_insert_text(b, "\n")
	case .Tab:
		buffer_insert_tab(b)
	case .Backspace, .Backspace2:
		buffer_backspace(b)
	case .Delete:
		buffer_delete_forward(b)
	case:
		if ev.ch == 0 {
			return
		}
		buffer_insert_rune(b, ev.ch)
	}
	editor_scroll(editor)
}

editor_scroll :: proc(editor: ^Editor) {
	w, h := editor_viewport()
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
	w, h := editor_viewport()
	for screen_y in 0 ..< h {
		row := editor.scroll_row + screen_y
		if row >= len(editor.buffer.lines) {
			break
		}
		text := editor.buffer.lines[row].text
		if editor.scroll_col < len(text) {
			end := min(editor.scroll_col + w, len(text))
			visible := string(text[editor.scroll_col:end])
			cstr := strings.clone_to_cstring(visible, context.temp_allocator)
			tb2.print(0, i32(screen_y), COLOR_FG, COLOR_BG, cstr)
		}
	}

	name := editor.buffer.path if editor.buffer.path != "" else "[No Name]"
	status := name
	if editor.buffer.modified {
		status = fmt.tprintf("%s [*]", name)
	}
	editor_render_row(h, w, status, COLOR_STATUS_FG, COLOR_STATUS_BG)
	editor_render_row(h + 1, w, editor.message, COLOR_FG, COLOR_BG)

	cx := editor.buffer.cursor.col - editor.scroll_col
	cy := editor.buffer.cursor.row - editor.scroll_row
	tb2.set_cursor(i32(cx), i32(cy))
	tb2.present()
}

editor_render_row :: proc(y, w: int, text: string, fg, bg: tb2.Color) {
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
	tb2.print(0, i32(y), fg, bg, cstr)
}

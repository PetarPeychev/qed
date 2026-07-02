package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "lib:tb2"

Editor :: struct {
	buffers:         [dynamic]Buffer,
	current:         int,
	working_root:    string,
	welcome:         bool,
	scroll_row:      int,
	scroll_col:      int,
	message:         string,
	message_error:   bool,
	quit_dialog:     QuitDialog,
	close_dialog:    CloseDialog,
	quit:            bool,
	pasting:         bool,
	paste_buf:       [dynamic]u8,
	paste_last_cr:   bool,
	last_click_tick: time.Tick,
	last_click_pos:  Cursor,
	click_count:     int,
	palette:         Palette,
	picker:          Picker,
	linefind:        LineFind,
	projsearch:      ProjSearch,
}

editor_init :: proc(path: string = "") -> Editor {
	tb2.init()
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	editor := Editor {
		buffers = make([dynamic]Buffer, 0, 8),
	}
	b := buffer_new()
	if path != "" && !os.is_dir(path) {
		abs, err := filepath.abs(path, context.temp_allocator)
		if err != nil {
			abs = path
		}
		buffer_open(&b, abs)
		editor.working_root, _ = os.get_working_directory(context.allocator)
	} else {
		editor.welcome = true
		if path != "" {
			abs, err := filepath.abs(path, context.allocator)
			editor.working_root = abs if err == nil else strings.clone(path)
		} else {
			editor.working_root, _ = os.get_working_directory(context.allocator)
		}
	}
	append(&editor.buffers, b)
	return editor
}

editor_shutdown :: proc(editor: ^Editor) {
	for &b in editor.buffers {
		buffer_destroy(&b)
	}
	delete(editor.buffers)
	delete(editor.working_root)
	delete(editor.paste_buf)
	palette_destroy(&editor.palette)
	picker_destroy(&editor.picker)
	linefind_destroy(&editor.linefind)
	projsearch_destroy(&editor.projsearch)
	clipboard_shutdown()
	tb2.shutdown()
}

editor_buffer :: proc(editor: ^Editor) -> ^Buffer {
	return &editor.buffers[editor.current]
}

editor_gutter_width :: proc(editor: ^Editor) -> int {
	n := len(editor_buffer(editor).lines)
	digits := 1
	for n >= 10 {
		digits += 1
		n /= 10
	}
	return digits + 1
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - STATUS_ROWS)
	return
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	if editor.palette.active {
		#partial switch ev.type {
		case .Key:
			palette_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.picker.active {
		#partial switch ev.type {
		case .Key:
			picker_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.linefind.active {
		#partial switch ev.type {
		case .Key:
			linefind_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.projsearch.active {
		#partial switch ev.type {
		case .Key:
			projsearch_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.welcome {
		if ev.type == .Key {
			alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
			if alt && ev.ch == 'F' {
				projsearch_open(editor)
				return
			}
			#partial switch ev.key {
			case .Ctrl_Q:
				editor_request_quit(editor)
			case .Ctrl_O:
				picker_open(editor)
			case .Ctrl_P:
				palette_open(editor)
			}
		}
		return
	}
	if editor.quit_dialog.active {
		#partial switch ev.type {
		case .Key:
			quit_dialog_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.close_dialog.active {
		#partial switch ev.type {
		case .Key:
			close_dialog_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
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
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	_, h := editor_viewport(editor)
	row := clamp(editor.scroll_row + min(y, h - 1), 0, len(b.lines) - 1)
	col := col_at_visual(b.lines[row].text[:], editor.scroll_col + max(0, x - gutter))
	return {row, col}
}

editor_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	editor.message = ""
	editor.message_error = false
	b := editor_buffer(editor)

	#partial switch ev.key {
	case .Mouse_Left:
		buffer_undo_commit(b)
		pos := editor_mouse_cursor(editor, int(ev.x), int(ev.y))
		if (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0 {
			selection_set_anchor(b)
			b.cursor = pos
			cursor_goal_sync(b)
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
			cursor_goal_sync(b)
		case 3:
			from, to := line_range_at(b, pos.row)
			b.selection = from
			b.cursor = to
			cursor_goal_sync(b)
		case:
			b.selection = nil
			b.cursor = pos
			cursor_goal_sync(b)
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
	buffer_paste(editor_buffer(editor), string(editor.paste_buf[:]))
	clear(&editor.paste_buf)
	editor_scroll(editor)
}

editor_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	editor.message = ""
	editor.message_error = false
	b := editor_buffer(editor)
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	shift := (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
	_, h := editor_viewport(editor)

	if alt && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			cmd.run(editor)
			editor_scroll(editor)
		}
		return
	}

	if cmd, ok := command_for_key(ev.key); ok {
		cmd.run(editor)
		editor_scroll(editor)
		return
	}

	#partial switch ev.key {
	case .Ctrl_P:
		palette_open(editor)
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
		collapse := had_sel && !shift && !ctrl && !alt
		#partial switch ev.key {
		case .Arrow_Left:
			if alt {
				cursor_move_home_smart(b)
			} else if collapse {
				b.cursor = sel_from
				cursor_goal_sync(b)
			} else if ctrl {
				cursor_move_word_left(b)
			} else {
				cursor_move_left(b)
			}
		case .Arrow_Right:
			if alt {
				cursor_move_end(b)
			} else if collapse {
				b.cursor = sel_to
				cursor_goal_sync(b)
			} else if ctrl {
				cursor_move_word_right(b)
			} else {
				cursor_move_right(b)
			}
		case .Arrow_Up:
			if ctrl {
				cursor_paragraph_prev(b)
			} else {
				cursor_move_up_n(b, 1)
			}
		case .Arrow_Down:
			if ctrl {
				cursor_paragraph_next(b)
			} else {
				cursor_move_down_n(b, 1)
			}
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

editor_request_quit :: proc(editor: ^Editor) {
	if editor_any_modified(editor) {
		quit_dialog_open(editor)
	} else {
		editor.quit = true
	}
}

editor_any_modified :: proc(editor: ^Editor) -> bool {
	for &b in editor.buffers {
		if b.modified {
			return true
		}
	}
	return false
}

editor_find_buffer :: proc(editor: ^Editor, path: string) -> int {
	for &b, i in editor.buffers {
		if b.path == path {
			return i
		}
	}
	return -1
}

editor_switch_to :: proc(editor: ^Editor, idx: int) {
	editor.current = idx
	editor.welcome = false
	editor.scroll_row = 0
	editor.scroll_col = 0
	editor_scroll(editor)
}

editor_close_buffer :: proc(editor: ^Editor) {
	if editor.welcome {
		return
	}
	if editor_buffer(editor).modified {
		close_dialog_open(editor)
	} else {
		editor_close_current(editor)
	}
}

editor_close_current :: proc(editor: ^Editor) {
	idx := editor.current
	buffer_destroy(&editor.buffers[idx])
	ordered_remove(&editor.buffers, idx)
	if len(editor.buffers) == 0 {
		append(&editor.buffers, buffer_new())
		editor.current = 0
		editor.welcome = true
		editor.scroll_row = 0
		editor.scroll_col = 0
	} else {
		editor_switch_to(editor, min(idx, len(editor.buffers) - 1))
	}
}

editor_open_path :: proc(editor: ^Editor, path: string) {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil {
		abs = path
	}
	if idx := editor_find_buffer(editor, abs); idx >= 0 {
		editor_switch_to(editor, idx)
		return
	}

	b := buffer_new()
	buffer_open(&b, abs)

	scratch := editor.buffers[0]
	if len(editor.buffers) == 1 && scratch.path == "" && !scratch.modified {
		buffer_destroy(&editor.buffers[0])
		editor.buffers[0] = b
		editor_switch_to(editor, 0)
	} else {
		append(&editor.buffers, b)
		editor_switch_to(editor, len(editor.buffers) - 1)
	}
}

editor_copy :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
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
	b := editor_buffer(editor)
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
	buffer_paste(editor_buffer(editor), text)
}

editor_save :: proc(editor: ^Editor) {
	switch buffer_save(editor_buffer(editor)) {
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
	b := editor_buffer(editor)
	w, h := editor_viewport(editor)
	cur := b.cursor

	if cur.row < editor.scroll_row + SCROLL_MARGIN {
		editor.scroll_row = cur.row - SCROLL_MARGIN
	}
	if cur.row > editor.scroll_row + h - 1 - SCROLL_MARGIN {
		editor.scroll_row = cur.row - h + 1 + SCROLL_MARGIN
	}
	max_scroll_row := max(0, len(b.lines) - h)
	editor.scroll_row = clamp(editor.scroll_row, 0, max_scroll_row)

	cur_vcol := visual_col(b.lines[cur.row].text[:], cur.col)
	if cur_vcol < editor.scroll_col + SCROLL_MARGIN {
		editor.scroll_col = cur_vcol - SCROLL_MARGIN
	}
	if cur_vcol > editor.scroll_col + w - 1 - SCROLL_MARGIN {
		editor.scroll_col = cur_vcol - w + 1 + SCROLL_MARGIN
	}
	editor.scroll_col = max(0, editor.scroll_col)
}

editor_render :: proc(editor: ^Editor) {
	tb2.clear()
	if editor.welcome {
		editor_render_welcome(editor)
	} else {
		editor_render_buffer(editor)
	}

	switch {
	case editor.palette.active:
		palette_render(editor)
	case editor.picker.active:
		picker_render(editor)
	case editor.linefind.active:
		linefind_render(editor)
	case editor.projsearch.active:
		projsearch_render(editor)
	case editor.quit_dialog.active:
		quit_dialog_render(editor)
	case editor.close_dialog.active:
		close_dialog_render(editor)
	case editor.welcome:
		tb2.hide_cursor()
	case:
		b := editor_buffer(editor)
		gutter := editor_gutter_width(editor)
		vcol := visual_col(b.lines[b.cursor.row].text[:], b.cursor.col)
		cx := gutter + vcol - editor.scroll_col
		cy := b.cursor.row - editor.scroll_row
		tb2.set_cursor(i32(cx), i32(cy))
	}
	tb2.present()
}

editor_render_buffer :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	full_w := int(tb2.width())
	gutter := editor_gutter_width(editor)
	w, h := editor_viewport(editor)

	sel_from, sel_to, sel_ok := selection_range(b)

	for screen_y in 0 ..< h {
		row := editor.scroll_row + screen_y
		if row >= len(b.lines) {
			break
		}
		current := row == b.cursor.row
		editor_render_gutter(screen_y, gutter, row + 1, current)

		text := b.lines[row].text
		row_sel_from, row_sel_to := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			row_sel_from = sel_from.col if row == sel_from.row else 0
			row_sel_to = sel_to.col if row == sel_to.row else len(text) + 1
		}
		editor_render_text_row(gutter, screen_y, w, text[:], editor.scroll_col, current, row_sel_from, row_sel_to)
	}

	name := b.path if b.path != "" else "[No Name]"
	status := name
	if b.modified {
		status = fmt.tprintf("%s [*]", name)
	}
	if len(editor.buffers) > 1 {
		status = fmt.tprintf("%s  [%d/%d]", status, editor.current + 1, len(editor.buffers))
	}
	editor_render_row(0, h, full_w, status, COLOR_STATUS_FG, COLOR_STATUS_BG)
	indent := "Tabs" if b.indent == .Tabs else fmt.tprintf("Spaces:%d", TAB_WIDTH)
	indent_cstr := strings.clone_to_cstring(indent, context.temp_allocator)
	tb2.print(i32(max(0, full_w - len(indent) - 1)), i32(h), COLOR_STATUS_FG, COLOR_STATUS_BG, indent_cstr)
	message_fg := COLOR_ERROR_FG if editor.message_error else COLOR_FG
	editor_render_row(0, h + 1, full_w, editor.message, message_fg, COLOR_BG)
}

editor_render_welcome :: proc(editor: ^Editor) {
	w := int(tb2.width())
	h := int(tb2.height())

	art := [?]string {
		"  .g8\"\"8q. `7MM\"\"YMMM`7MM\"\"\"Yb.   ",
		".dP'    `YM. MM    `7  MM    `Yb. ",
		"dM'      `MM MM   d    MM     `Mb ",
		"MM        MM MMmmMM    MM      MM ",
		"MM.      ,MP MM   Y ,  MM     ,MP ",
		"`Mb.    ,dP' MM    ,M  MM    ,dP' ",
		"  `\"bmmd\"' .JMMmmmMMM.JMMmmmdP'   ",
		"      MMb                          ",
		"       `bood'                      ",
	}
	hints := [?]string {
		"Ctrl+O    Open file",
		"Ctrl+P    Command palette",
		"Ctrl+Q    Quit",
	}

	hint_w := 0
	for line in hints {
		hint_w = max(hint_w, len(line))
	}
	hint_x := max(0, (w - hint_w) / 2)

	y := max(0, h / 2 - (len(art) + 1 + len(hints)) / 2)
	for line in art {
		editor_render_welcome_line(max(0, (w - len(line)) / 2), y, line)
		y += 1
	}
	y += 1
	for line in hints {
		editor_render_welcome_line(hint_x, y, line)
		y += 1
	}
}

editor_render_welcome_line :: proc(x, y: int, text: string) {
	if y < 0 || y >= int(tb2.height()) {
		return
	}
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	tb2.print(i32(x), i32(y), COLOR_FG, COLOR_BG, cstr)
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
		tb2.set_cell(i32(gutter + sx), i32(y), ' ', COLOR_FG, bg_normal)
	}

	draw :: proc(gutter, y, sx, w: int, ch: rune, selected: bool, bg_normal: tb2.Color) {
		if sx < 0 || sx >= w {
			return
		}
		fg, bg := COLOR_FG, bg_normal
		if selected {
			fg, bg = COLOR_BG, COLOR_FG
		}
		tb2.set_cell(i32(gutter + sx), i32(y), ch, fg, bg)
	}

	draw_cluster :: proc(
		gutter, y, w: int,
		cluster: []u8,
		vcol, scroll_col: int,
		selected: bool,
		bg_normal: tb2.Color,
	) -> int {
		if cluster[0] == '\t' {
			next := (vcol / TAB_WIDTH + 1) * TAB_WIDTH
			for v in vcol ..< next {
				draw(gutter, y, v - scroll_col, w, ' ', selected, bg_normal)
			}
			return next
		}
		sx := vcol - scroll_col
		if sx >= 0 && sx < w {
			r, n := utf8.decode_rune(cluster)
			draw(gutter, y, sx, w, r, selected, bg_normal)
			rest := cluster[n:]
			for len(rest) > 0 {
				rr, m := utf8.decode_rune(rest)
				tb2.extend_cell(i32(gutter + sx), i32(y), rr)
				rest = rest[m:]
			}
		}
		return vcol + cluster_width(cluster)
	}

	vcol := 0
	pstart := -1
	psel := false
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if pstart >= 0 {
			vcol = draw_cluster(gutter, y, w, text[pstart:g.byte_index], vcol, scroll_col, psel, bg_normal)
		}
		pstart = g.byte_index
		psel = sel_from >= 0 && g.byte_index >= sel_from && g.byte_index < sel_to
	}
	if pstart >= 0 {
		vcol = draw_cluster(gutter, y, w, text[pstart:], vcol, scroll_col, psel, bg_normal)
	}
	if sel_from >= 0 && len(text) >= sel_from && len(text) < sel_to {
		draw(gutter, y, vcol - scroll_col, w, ' ', true, bg_normal)
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

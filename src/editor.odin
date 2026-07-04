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
	message_store:   [dynamic]u8,
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
	bufswitch:       BufSwitch,
	langpick:        LangPick,
	linefind:        LineFind,
	projsearch:      ProjSearch,
	rename:          Rename,
	jumps:           JumpList,
	jump_lock:       bool,
	hover:           [dynamic]u8,
	hover_active:    bool,
	completion:      Completion,
	format_on_save:  bool,
}

editor_init :: proc(path: string = "") -> Editor {
	tb2.init()
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	editor := Editor {
		buffers        = make([dynamic]Buffer, 0, 8),
		format_on_save = FORMAT_ON_SAVE,
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
	lsp_stop(editor)
	for &b in editor.buffers {
		buffer_destroy(&b)
	}
	delete(editor.buffers)
	delete(editor.working_root)
	delete(editor.paste_buf)
	delete(editor.message_store)
	delete(editor.hover)
	completion_destroy(&editor.completion)
	palette_destroy(&editor.palette)
	picker_destroy(&editor.picker)
	bufswitch_destroy(&editor.bufswitch)
	langpick_destroy(&editor.langpick)
	linefind_destroy(&editor.linefind)
	projsearch_destroy(&editor.projsearch)
	rename_destroy(&editor.rename)
	jump_destroy(&editor.jumps)
	delete(g_language_rules)
	syntax_shutdown()
	clipboard_shutdown()
	tb2.shutdown()
}

editor_buffer :: proc(editor: ^Editor) -> ^Buffer {
	return &editor.buffers[editor.current]
}

// Copy into owned storage: callers pass temp-allocator strings, and the main
// loop's free_all would leave editor.message dangling into reused temp memory.
editor_set_message :: proc(editor: ^Editor, msg: string, is_error := false) {
	clear(&editor.message_store)
	append(&editor.message_store, ..transmute([]u8)msg)
	editor.message = string(editor.message_store[:])
	editor.message_error = is_error
}

editor_set_language :: proc(editor: ^Editor, lang: Language) {
	b := editor_buffer(editor)
	if b.language == lang {
		return
	}
	if b.lsp_open {
		lsp_did_close(editor, b)
	}
	b.language = lang
	highlight_destroy(&b.hl)
	b.hl = {}
	editor_set_message(editor, fmt.tprintf("Language: %s", LANGUAGES[lang].name))
}

editor_gutter_width :: proc(editor: ^Editor) -> int {
	n := len(editor_buffer(editor).lines)
	digits := 1
	for n >= 10 {
		digits += 1
		n /= 10
	}
	return digits + 2
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - STATUS_ROWS)
	return
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	origin := jump_here(editor)
	defer jump_record(editor, origin)
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
	if editor.bufswitch.active {
		#partial switch ev.type {
		case .Key:
			bufswitch_dispatch_key(editor, ev)
		case .Resize:
			editor_scroll(editor)
		}
		return
	}
	if editor.langpick.active {
		#partial switch ev.type {
		case .Key:
			langpick_dispatch_key(editor, ev)
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
	if editor.rename.active {
		#partial switch ev.type {
		case .Key:
			rename_dispatch_key(editor, ev)
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
		editor_set_message(editor, "")
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
	editor_set_message(editor, "")
	editor.hover_active = false
	completion_dismiss(editor)
	b := editor_buffer(editor)

	#partial switch ev.key {
	case .Mouse_Left:
		buffer_undo_commit(b)
		if (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0 {
			selection_set_anchor(b)
			_, h := editor_viewport(editor)
			gutter := editor_gutter_width(editor)
			y := int(ev.y)
			row: int
			switch {
			case y <= 0:
				row = editor.scroll_row - 1
			case y >= h - 1:
				row = editor.scroll_row + h
			case:
				row = editor.scroll_row + y
			}
			row = clamp(row, 0, len(b.lines) - 1)
			col := col_at_visual(b.lines[row].text[:], editor.scroll_col + max(0, int(ev.x) - gutter))
			b.cursor = {row, col}
			cursor_goal_sync(b)
			editor_scroll(editor)
			return
		}
		pos := editor_mouse_cursor(editor, int(ev.x), int(ev.y))
		recent :=
			editor.click_count > 0 &&
			time.duration_milliseconds(time.tick_since(editor.last_click_tick)) <= f64(DOUBLE_CLICK_MS) &&
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
	if editor.completion.active {
		if completion_key(editor, ev) {
			editor_scroll(editor)
			return
		}
		if !completion_keeps(ev) {
			completion_dismiss(editor)
		}
	}
	editor_set_message(editor, "")
	editor.hover_active = false
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

	if alt {
		#partial switch ev.key {
		case .Arrow_Up:
			buffer_move_lines(b, -1)
			editor_scroll(editor)
			return
		case .Arrow_Down:
			buffer_move_lines(b, +1)
			editor_scroll(editor)
			return
		}
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
	completion_after(editor, ev)
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
	completion_dismiss(editor)
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
	editor.jump_lock = true
	idx := editor.current
	lsp_did_close(editor, &editor.buffers[idx])
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

editor_load_buffer :: proc(editor: ^Editor, path: string) -> int {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil {
		abs = path
	}
	if idx := editor_find_buffer(editor, abs); idx >= 0 {
		return idx
	}
	b := buffer_new()
	if buffer_open(&b, abs) != .None {
		buffer_destroy(&b)
		return -1
	}
	scratch := editor.buffers[0]
	if len(editor.buffers) == 1 && scratch.path == "" && !scratch.modified {
		buffer_destroy(&editor.buffers[0])
		editor.buffers[0] = b
		return 0
	}
	append(&editor.buffers, b)
	return len(editor.buffers) - 1
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
	b := editor_buffer(editor)
	if editor.format_on_save {
		if LANGUAGES[b.language].formatter != "" {
			format_external(editor, b, true)
			return
		}
		if lsp_send_format(editor, b, .FormatOnSave) {
			return
		}
	}
	editor_save_buffer(editor, b)
}

editor_save_path :: proc(editor: ^Editor, path: string) {
	if idx := editor_find_buffer(editor, path); idx >= 0 {
		editor_save_buffer(editor, &editor.buffers[idx])
	}
}

editor_save_buffer :: proc(editor: ^Editor, b: ^Buffer) {
	switch buffer_save(b) {
	case .None:
		editor_set_message(editor, "Saved")
		lsp_did_save(editor, b)
	case .NoPath:
		editor_set_message(editor, "No file name", true)
	case .WriteError, .RenameError:
		editor_set_message(editor, "Save failed", true)
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
		_, vh := editor_viewport(editor)
		if !editor_buffer(editor).big {
			highlight_update(editor_buffer(editor), editor.scroll_row, editor.scroll_row + vh - 1)
			if g_syntax_error != "" {
				editor_set_message(editor, fmt.tprintf("syntax: failed to load %s grammar", g_syntax_error), true)
				g_syntax_error = ""
			}
			git_gutter_update(editor_buffer(editor))
		}
		editor_render_buffer(editor)
	}

	switch {
	case editor.palette.active:
		palette_render(editor)
	case editor.picker.active:
		picker_render(editor)
	case editor.bufswitch.active:
		bufswitch_render(editor)
	case editor.langpick.active:
		langpick_render(editor)
	case editor.linefind.active:
		linefind_render(editor)
	case editor.projsearch.active:
		projsearch_render(editor)
	case editor.rename.active:
		rename_render(editor)
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
		if editor.completion.active {
			completion_render(editor, cx, cy)
		} else if editor.hover_active {
			editor_render_hover_pane(editor, cx, cy)
		} else {
			editor_render_diag_pane(editor, cx, cy)
		}
	}
	tb2.present()
}

editor_render_diag_pane :: proc(editor: ^Editor, cx, cy: int) {
	b := editor_buffer(editor)
	d, ok := diagnostic_at(b, b.cursor)
	if !ok {
		return
	}
	text_w := int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X - 2
	if text_w < 8 {
		return
	}
	lines := wrap_text(d.message, text_w)
	editor_render_text_pane(editor, cx, cy, lines[:], diagnostic_color(d.severity))
}

editor_render_hover_pane :: proc(editor: ^Editor, cx, cy: int) {
	text_w := int(tb2.width()) - 2 * DIAG_PANE_MARGIN_X - 2
	if text_w < 8 {
		return
	}
	lines := wrap_text(string(editor.hover[:]), text_w)
	editor_render_text_pane(editor, cx, cy, lines[:], COLOR_PANE_FG)
}

editor_render_text_pane :: proc(editor: ^Editor, cx, cy: int, lines: []string, fg: tb2.Color) {
	content_h := min(len(lines), DIAG_PANE_MAX_LINES)
	if content_h == 0 {
		return
	}
	sw := int(tb2.width())
	_, h := editor_viewport(editor)
	content_w := 0
	for line in lines[:content_h] {
		content_w = max(content_w, len(line))
	}
	pane_w := content_w + 2
	pane_h := content_h + 2
	y := cy + 1
	if y + pane_h > h {
		y = cy - pane_h
	}
	if y < 0 {
		return
	}
	x := clamp(cx, 0, max(0, sw - pane_w))
	box := pane_draw_box({x, y, pane_w, pane_h})
	for line, i in lines[:content_h] {
		pane_text(box.x, box.y + i, box.w, line, fg, COLOR_PANE_BG)
	}
}

wrap_text :: proc(text: string, width: int, allocator := context.temp_allocator) -> [dynamic]string {
	lines := make([dynamic]string, allocator)
	for raw in strings.split(text, "\n", allocator) {
		words := strings.fields(raw, allocator)
		if len(words) == 0 {
			if len(lines) > 0 {
				append(&lines, "")
			}
			continue
		}
		sb := strings.builder_make(allocator)
		for word in words {
			w := word
			for {
				if strings.builder_len(sb) > 0 && strings.builder_len(sb) + 1 + len(w) > width {
					append(&lines, strings.clone(strings.to_string(sb), allocator))
					strings.builder_reset(&sb)
				}
				if len(w) <= width {
					break
				}
				append(&lines, w[:width])
				w = w[width:]
			}
			if strings.builder_len(sb) > 0 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, w)
		}
		if strings.builder_len(sb) > 0 {
			append(&lines, strings.clone(strings.to_string(sb), allocator))
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1] == "" {
		pop(&lines)
	}
	return lines
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
		severity := 0
		for d in b.diags {
			if row >= d.from.row && row <= d.to.row && (severity == 0 || d.severity < severity) {
				severity = d.severity
			}
		}
		editor_render_gutter(screen_y, gutter, row + 1, current, severity, git_mark_at(b, row))

		text := b.lines[row].text
		row_sel_from, row_sel_to := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			row_sel_from = sel_from.col if row == sel_from.row else 0
			row_sel_to = sel_to.col if row == sel_to.row else len(text) + 1
		}
		row_diags := make([dynamic][2]int, context.temp_allocator)
		for d in b.diags {
			if row < d.from.row || row > d.to.row {
				continue
			}
			ds := clamp(d.from.col if row == d.from.row else 0, 0, len(text))
			de := clamp(d.to.col if row == d.to.row else len(text), 0, len(text))
			if ds == de {
				de = min(de + 1, len(text))
			}
			if ds < de {
				append(&row_diags, [2]int{ds, de})
			}
		}
		colors := highlight_colors(b, row)
		editor_render_text_row(gutter, screen_y, w, text[:], colors, editor.scroll_col, current, row_sel_from, row_sel_to, row_diags[:])
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
	right := LANGUAGES[b.language].name
	if b.big {
		right = fmt.tprintf("%s  big", right)
	} else if lsp := lsp_status_label(b); lsp != "" {
		right = fmt.tprintf("%s  %s", right, lsp)
	}
	right = fmt.tprintf("%s  %s", right, indent)
	right_w := visual_width(transmute([]u8)right)
	right_cstr := strings.clone_to_cstring(right, context.temp_allocator)
	tb2.print(i32(max(0, full_w - right_w - 1)), i32(h), COLOR_STATUS_FG, COLOR_STATUS_BG, right_cstr)
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
		"       `bmmd'                      ",
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

editor_render_gutter :: proc(y, width, number: int, current: bool, severity: int, mark: GitMark) {
	mark_ch, mark_fg := git_mark_glyph(mark)
	tb2.set_cell(0, i32(y), mark_ch, mark_fg, COLOR_GUTTER_BG)

	label := fmt.tprintf("%d", number)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< width - 2 - len(label) {
		strings.write_byte(&sb, ' ')
	}
	strings.write_string(&sb, label)
	if severity > 0 {
		strings.write_rune(&sb, '●')
	} else {
		strings.write_byte(&sb, ' ')
	}
	fg := COLOR_CURRENT_LINE_FG if current else COLOR_GUTTER_FG
	if severity > 0 {
		fg = diagnostic_color(severity)
	}
	cstr := strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
	tb2.print(1, i32(y), fg, COLOR_GUTTER_BG, cstr)
}

editor_render_text_row :: proc(
	gutter, y, w: int,
	text: []u8,
	colors: []tb2.Color,
	scroll_col: int,
	current: bool,
	sel_from, sel_to: int,
	diags: [][2]int,
) {
	bg_normal := COLOR_CURRENT_LINE_BG if current else COLOR_BG
	for sx in 0 ..< w {
		tb2.set_cell(i32(gutter + sx), i32(y), ' ', COLOR_FG, bg_normal)
	}

	draw :: proc(gutter, y, sx, w: int, ch: rune, selected: bool, fg_base, bg_normal: tb2.Color) {
		if sx < 0 || sx >= w {
			return
		}
		fg, bg := fg_base, bg_normal
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
		fg_base, bg_normal: tb2.Color,
	) -> int {
		if cluster[0] == '\t' {
			next := (vcol / TAB_WIDTH + 1) * TAB_WIDTH
			for v in vcol ..< next {
				draw(gutter, y, v - scroll_col, w, ' ', selected, fg_base, bg_normal)
			}
			return next
		}
		sx := vcol - scroll_col
		if sx >= 0 && sx < w {
			r, n := utf8.decode_rune(cluster)
			draw(gutter, y, sx, w, r, selected, fg_base, bg_normal)
			rest := cluster[n:]
			for len(rest) > 0 {
				rr, m := utf8.decode_rune(rest)
				tb2.extend_cell(i32(gutter + sx), i32(y), rr)
				rest = rest[m:]
			}
		}
		return vcol + cluster_width(cluster)
	}

	underlined :: proc(diags: [][2]int, col: int) -> bool {
		for r in diags {
			if col >= r[0] && col < r[1] {
				return true
			}
		}
		return false
	}

	vcol := 0
	pstart := -1
	psel := false
	pfg := COLOR_FG
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if pstart >= 0 {
			vcol = draw_cluster(gutter, y, w, text[pstart:g.byte_index], vcol, scroll_col, psel, pfg, bg_normal)
		}
		pstart = g.byte_index
		psel = sel_from >= 0 && g.byte_index >= sel_from && g.byte_index < sel_to
		pfg = colors[pstart] if colors != nil && pstart < len(colors) else COLOR_FG
		if underlined(diags, pstart) {
			pfg = tb2.Color(u64(pfg) | u64(tb2.Color.Underline))
		}
	}
	if pstart >= 0 {
		vcol = draw_cluster(gutter, y, w, text[pstart:], vcol, scroll_col, psel, pfg, bg_normal)
	}
	if sel_from >= 0 && len(text) >= sel_from && len(text) < sel_to {
		draw(gutter, y, vcol - scroll_col, w, ' ', true, COLOR_FG, bg_normal)
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

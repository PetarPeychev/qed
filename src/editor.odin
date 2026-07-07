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
	scroll_sub:      int,
	scroll_col:      int,
	message:         string,
	message_store:   [dynamic]u8,
	message_error:   bool,
	quit_dialog:     QuitDialog,
	close_dialog:    CloseDialog,
	conflict_dialog: ConflictDialog,
	disk_poll:       time.Tick,
	quit:            bool,
	pasting:         bool,
	paste_buf:       [dynamic]u8,
	paste_last_cr:   bool,
	last_click_tick: time.Tick,
	last_click_pos:  Cursor,
	click_count:     int,
	overlay_click_tick: time.Tick,
	overlay_click_idx:  int,
	palette:         Palette,
	picker:          Picker,
	bufswitch:       BufSwitch,
	langpick:        LangPick,
	indentpick:      IndentPick,
	linefind:        LineFind,
	projsearch:      ProjSearch,
	rename:          Rename,
	filetree:        FileTree,
	jumps:           JumpList,
	jump_lock:       bool,
	hover:           [dynamic]u8,
	hover_active:    bool,
	completion:      Completion,
	format_on_save:  bool,
	hunk_highlight:  bool,
	llm:             Llm,
	aiedit:          AiEdit,
	fim:             Fim,
	terminal:        Terminal,
}

editor_init :: proc(path: string = "") -> Editor {
	tb2.init()
	tb2.set_output_mode(.Truecolor)
	tb2.set_input_mode(.Mouse)
	tb2.set_clear_attrs(COLOR_FG, COLOR_BG)
	editor := Editor {
		buffers        = make([dynamic]Buffer, 0, 8),
		format_on_save = FORMAT_ON_SAVE,
		hunk_highlight = GIT_HUNK_HIGHLIGHT,
		fim            = Fim{enabled = LLM_COMPLETION_ENABLED},
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
	indentpick_destroy(&editor.indentpick)
	linefind_destroy(&editor.linefind)
	projsearch_destroy(&editor.projsearch)
	rename_destroy(&editor.rename)
	filetree_destroy(&editor.filetree)
	jump_destroy(&editor.jumps)
	llm_cancel_all(editor)
	delete(editor.llm.requests)
	fim_dismiss(editor)
	aiedit_destroy(&editor.aiedit)
	term_destroy(editor)
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
	return digit_count(len(editor_buffer(editor).lines)) + 2
}

editor_viewport :: proc(editor: ^Editor) -> (w, h: int) {
	w = max(0, int(tb2.width()) - editor_gutter_width(editor))
	h = max(0, int(tb2.height()) - STATUS_ROWS)
	return
}

Overlay :: struct {
	active:   ^bool,
	dispatch: proc(editor: ^Editor, ev: tb2.Event),
	render:   proc(editor: ^Editor),
	mouse:    proc(editor: ^Editor, ev: tb2.Event),
}

editor_overlays :: proc(editor: ^Editor) -> [14]Overlay {
	return {
		{&editor.terminal.active, term_dispatch, term_render, term_dispatch_mouse},
		{&editor.aiedit.active, aiedit_dispatch_key, aiedit_render, aiedit_dispatch_mouse},
		{&editor.palette.active, palette_dispatch_key, palette_render, palette_dispatch_mouse},
		{&editor.picker.active, picker_dispatch_key, picker_render, picker_dispatch_mouse},
		{&editor.bufswitch.active, bufswitch_dispatch_key, bufswitch_render, bufswitch_dispatch_mouse},
		{&editor.langpick.active, langpick_dispatch_key, langpick_render, langpick_dispatch_mouse},
		{&editor.indentpick.active, indentpick_dispatch_key, indentpick_render, indentpick_dispatch_mouse},
		{&editor.linefind.active, linefind_dispatch_key, linefind_render, linefind_dispatch_mouse},
		{&editor.projsearch.active, projsearch_dispatch_key, projsearch_render, projsearch_dispatch_mouse},
		{&editor.rename.active, rename_dispatch_key, rename_render, rename_dispatch_mouse},
		{&editor.filetree.active, filetree_dispatch_key, filetree_render, filetree_dispatch_mouse},
		{&editor.quit_dialog.active, quit_dialog_dispatch_key, quit_dialog_render, quit_dialog_dispatch_mouse},
		{&editor.close_dialog.active, close_dialog_dispatch_key, close_dialog_render, close_dialog_dispatch_mouse},
		{&editor.conflict_dialog.active, conflict_dialog_dispatch_key, conflict_dialog_render, conflict_dialog_dispatch_mouse},
	}
}

editor_dispatch :: proc(editor: ^Editor, ev: tb2.Event) {
	origin := jump_here(editor)
	defer jump_record(editor, origin)
	for ov in editor_overlays(editor) {
		if ov.active^ {
			#partial switch ev.type {
			case .Key:
				ov.dispatch(editor, ev)
			case .Mouse:
				if ov.mouse != nil {
					ov.mouse(editor, ev)
				}
			case .Resize:
				editor_scroll(editor)
				if editor.terminal.active {
					term_resize(editor)
				}
			}
			return
		}
	}
	if editor.welcome {
		if ev.type == .Key {
			alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
			if alt && ev.ch == 'F' {
				projsearch_open(editor)
				return
			}
			if alt && ev.ch == 'f' {
				filetree_open(editor)
				return
			}
			if alt && ev.ch == 't' {
				term_toggle(editor)
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
	w, h := editor_viewport(editor)
	if b.wrap && w > 0 {
		row, sub := vpos_down(b, w, editor.scroll_row, editor.scroll_sub, clamp(y, 0, h - 1))
		return {row, editor_wrap_col(b, w, row, sub, gutter, x)}
	}
	row := clamp(editor.scroll_row + min(y, h - 1), 0, len(b.lines) - 1)
	col := col_at_visual(b.lines[row].text[:], editor.scroll_col + max(0, x - gutter))
	return {row, col}
}

editor_wrap_col :: proc(b: ^Buffer, w, row, sub, gutter, x: int) -> int {
	text := b.lines[row].text[:]
	seg_start, seg_end := wrap_segment(text, w, sub)
	target := visual_col(text, seg_start) + max(0, x - gutter)
	return clamp(col_at_visual(text, target), seg_start, seg_end)
}

editor_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	editor_set_message(editor, "")
	editor.hover_active = false
	completion_dismiss(editor)
	fim_dismiss(editor)
	b := editor_buffer(editor)

	#partial switch ev.key {
	case .Mouse_Left:
		buffer_undo_commit(b)
		if (u8(ev.mod) & u8(tb2.Mod.Motion)) != 0 {
			selection_set_anchor(b)
			w, h := editor_viewport(editor)
			gutter := editor_gutter_width(editor)
			y := int(ev.y)
			if b.wrap && w > 0 {
				tr, ts: int
				switch {
				case y <= 0:
					tr, ts = vpos_up(b, w, editor.scroll_row, editor.scroll_sub, 1)
				case y >= h - 1:
					tr, ts = vpos_down(b, w, editor.scroll_row, editor.scroll_sub, h)
				case:
					tr, ts = vpos_down(b, w, editor.scroll_row, editor.scroll_sub, y)
				}
				b.cursor = {tr, editor_wrap_col(b, w, tr, ts, gutter, int(ev.x))}
				cursor_goal_sync(b)
				editor_scroll(editor)
				return
			}
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
		w, _ := editor_viewport(editor)
		if b.wrap && w > 0 {
			editor.scroll_row, editor.scroll_sub = vpos_up(b, w, editor.scroll_row, editor.scroll_sub, WHEEL_SCROLL_LINES)
		} else {
			editor.scroll_row = max(0, editor.scroll_row - WHEEL_SCROLL_LINES)
		}
	case .Mouse_Wheel_Down:
		w, h := editor_viewport(editor)
		if b.wrap && w > 0 {
			last := len(b.lines) - 1
			max_r, max_s := vpos_up(b, w, last, wrap_rows(b.lines[last].text[:], w) - 1, h - 1)
			r, s := vpos_down(b, w, editor.scroll_row, editor.scroll_sub, WHEEL_SCROLL_LINES)
			if vpos_cmp(r, s, max_r, max_s) > 0 {
				r, s = max_r, max_s
			}
			editor.scroll_row, editor.scroll_sub = r, s
		} else {
			max_scroll := max(0, len(b.lines) - h)
			editor.scroll_row = min(max_scroll, editor.scroll_row + WHEEL_SCROLL_LINES)
		}
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
	if !editor.completion.active && fim_ghost_active(editor) {
		if fim_ghost_key(editor, ev) {
			return
		}
		fim_dismiss(editor)
	}
	editor_set_message(editor, "")
	editor.hover_active = false
	b := editor_buffer(editor)
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	shift := (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0

	if alt && ev.ch != 0 {
		if cmd, ok := command_for_alt(ev.ch); ok {
			cmd.run(editor)
		}
		return
	}

	if cmd, ok := command_for_key(ev.key); ok {
		cmd.run(editor)
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
		return
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
		} else if !buffer_backspace_pair(b) {
			buffer_backspace(b)
		}
	case .Delete:
		if selection_active(b) {
			buffer_delete_selection(b)
		} else {
			buffer_delete_forward(b)
		}
	case .Arrow_Left, .Arrow_Right, .Arrow_Up, .Arrow_Down:
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
		}
	case:
		if ev.ch == 0 {
			return
		}
		handled := buffer_type_pair(b, ev.ch)
		if !handled && ev.ch <= 0x7f {
			handled = buffer_close_dedent(b, u8(ev.ch))
		}
		if !handled {
			buffer_type_rune(b, ev.ch)
		}
	}
	editor_scroll(editor)
	completion_after(editor, ev)
	fim_after(editor, ev)
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
	editor.scroll_sub = 0
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
		editor.scroll_sub = 0
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
	editor_scroll(editor)
}

editor_paste :: proc(editor: ^Editor) {
	text := clipboard_get(context.temp_allocator)
	if len(text) == 0 {
		return
	}
	buffer_paste(editor_buffer(editor), text)
	editor_scroll(editor)
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
	if buffer_disk_changed(b) {
		conflict_dialog_open(editor)
		return
	}
	editor_force_save(editor, b)
}

editor_force_save :: proc(editor: ^Editor, b: ^Buffer) {
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

editor_reload_buffer :: proc(editor: ^Editor, b: ^Buffer) {
	lsp_did_close(editor, b)
	switch buffer_reload(b) {
	case .None:
		if b == editor_buffer(editor) {
			editor_scroll(editor)
			editor_set_message(editor, "Reloaded from disk")
		}
	case .FileOpenError, .FileReadError:
		editor_set_message(editor, "Reload failed", true)
	}
}

editor_maybe_poll_disk :: proc(editor: ^Editor) -> bool {
	if time.duration_milliseconds(time.tick_since(editor.disk_poll)) < f64(DISK_POLL_MS) {
		return false
	}
	editor.disk_poll = time.tick_now()
	return editor_poll_disk(editor)
}

editor_poll_disk :: proc(editor: ^Editor) -> bool {
	cur := editor_buffer(editor)
	changed := false
	for &b in editor.buffers {
		if b.path == "" || !buffer_disk_changed(&b) {
			continue
		}
		if b.modified {
			if !b.disk_conflict {
				b.disk_conflict = true
				if &b == cur {
					editor_set_message(editor, "File changed on disk — you have unsaved edits", true)
					changed = true
				}
			}
			continue
		}
		if highlight_busy(&b) {
			continue // don't swap content under a running parse; retry next poll
		}
		editor_reload_buffer(editor, &b)
		changed = true
	}
	return changed
}

editor_scroll :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	w, h := editor_viewport(editor)
	b.wrap_width = w
	cur := b.cursor

	if b.wrap && w > 0 {
		editor.scroll_col = 0
		editor_scroll_wrap(editor, b, w, h)
		return
	}
	editor.scroll_sub = 0

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

editor_scroll_wrap :: proc(editor: ^Editor, b: ^Buffer, w, h: int) {
	cur := b.cursor
	cur_sub := wrap_subrow(b.lines[cur.row].text[:], w, cur.col)

	top_r := clamp(editor.scroll_row, 0, len(b.lines) - 1)
	top_s := clamp(editor.scroll_sub, 0, wrap_rows(b.lines[top_r].text[:], w) - 1)

	mr, ms := vpos_up(b, w, cur.row, cur_sub, SCROLL_MARGIN)
	if vpos_cmp(top_r, top_s, mr, ms) > 0 {
		top_r, top_s = mr, ms
	}
	lr, ls := vpos_up(b, w, cur.row, cur_sub, h - 1 - SCROLL_MARGIN)
	if vpos_cmp(top_r, top_s, lr, ls) < 0 {
		top_r, top_s = lr, ls
	}
	last := len(b.lines) - 1
	max_r, max_s := vpos_up(b, w, last, wrap_rows(b.lines[last].text[:], w) - 1, h - 1)
	if vpos_cmp(top_r, top_s, max_r, max_s) > 0 {
		top_r, top_s = max_r, max_s
	}
	editor.scroll_row = top_r
	editor.scroll_sub = top_s
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

	for ov in editor_overlays(editor) {
		if ov.active^ {
			ov.render(editor)
			tb2.present()
			return
		}
	}
	if editor.welcome {
		tb2.hide_cursor()
	} else {
		b := editor_buffer(editor)
		gutter := editor_gutter_width(editor)
		w, h := editor_viewport(editor)
		text := b.lines[b.cursor.row].text[:]
		cx, cy: int
		above := false
		if b.wrap && w > 0 {
			seg := wrap_seg_start(text, w, b.cursor.col)
			cur_sub := wrap_subrow(text, w, b.cursor.col)
			cx = gutter + visual_col(text, b.cursor.col) - visual_col(text, seg)
			above =
				b.cursor.row < editor.scroll_row ||
				(b.cursor.row == editor.scroll_row && cur_sub < editor.scroll_sub)
			cy = vpos_dist(b, w, editor.scroll_row, editor.scroll_sub, b.cursor.row, cur_sub)
		} else {
			cx = gutter + visual_col(text, b.cursor.col) - editor.scroll_col
			cy = b.cursor.row - editor.scroll_row
		}
		if above || cy < 0 || cy >= h || cx < gutter || cx >= gutter + w {
			tb2.hide_cursor()
		} else {
			tb2.set_cursor(i32(cx), i32(cy))
			if editor.completion.active {
				completion_render(editor, cx, cy)
			} else if fim_ghost_active(editor) {
				// A wrapped buffer draws the ghost inline in editor_render_buffer.
				if !(b.wrap && w > 0) {
					fim_render(editor, cx, cy)
				}
			} else if editor.hover_active {
				editor_render_hover_pane(editor, cx, cy)
			} else {
				editor_render_diag_pane(editor, cx, cy)
			}
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
	editor_render_text_pane(editor, cx, cy, lines[:], COLOR_PANE_FG, HOVER_PANE_MAX_LINES)
}

editor_render_text_pane :: proc(editor: ^Editor, cx, cy: int, lines: []string, fg: tb2.Color, max_lines := DIAG_PANE_MAX_LINES) {
	if len(lines) == 0 {
		return
	}
	sw := int(tb2.width())
	_, h := editor_viewport(editor)
	room_below := h - (cy + 1)
	room_above := cy
	content_h := min(len(lines), max_lines, max(room_below, room_above) - 2)
	if content_h <= 0 {
		return
	}
	content_w := 0
	for line in lines[:content_h] {
		content_w = max(content_w, len(line))
	}
	pane_w := content_w + 2
	pane_h := content_h + 2
	y := room_below >= pane_h ? cy + 1 : cy - pane_h
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

// Lays out the cursor's logical line as prefix + dimmed ghost + suffix and
// renders it through the wrap machinery, so ghost and the relocated suffix obey
// the same soft-wrap rules as real text. Ghost newlines are hard breaks. Returns
// the next screen row.
editor_render_ghost_line :: proc(editor: ^Editor, b: ^Buffer, row, gutter, w, h, screen_y: int, colors: []tb2.Color, line_bg: tb2.Color) -> int {
	text := b.lines[row].text[:]
	cut := b.cursor.col
	glines := strings.split(editor.fim.ghost, "\n", context.temp_allocator)
	mark := git_mark_at(b, row)

	sy := screen_y
	first_row := true
	color_at :: proc(colors: []tb2.Color, i: int) -> tb2.Color {
		return colors[i] if colors != nil && i < len(colors) else COLOR_FG
	}
	for gl, gi in glines {
		content := make([dynamic]u8, context.temp_allocator)
		ccol := make([dynamic]tb2.Color, context.temp_allocator)
		if gi == 0 {
			append(&content, ..text[:cut])
			for i in 0 ..< cut {
				append(&ccol, color_at(colors, i))
			}
		}
		append(&content, ..transmute([]u8)gl)
		for _ in 0 ..< len(gl) {
			append(&ccol, COLOR_GHOST_FG)
		}
		if gi == len(glines) - 1 {
			append(&content, ..text[cut:])
			for i in cut ..< len(text) {
				append(&ccol, color_at(colors, i))
			}
		}

		ct := content[:]
		segs := line_wrap(ct, w)
		for s in 0 ..< len(segs) {
			if sy >= h {
				return sy
			}
			seg_start := segs[s]
			seg_end := segs[s + 1] if s + 1 < len(segs) else len(ct)
			x_origin := visual_col(ct, seg_start)
			editor_render_gutter(sy, gutter, row + 1, true, 0, mark, !first_row)
			editor_render_text_row(gutter, sy, w, ct, ccol[:], x_origin, line_bg, -1, -1, nil, seg_start, seg_end)
			sy += 1
			first_row = false
		}
	}
	return sy
}

editor_render_buffer :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	full_w := int(tb2.width())
	gutter := editor_gutter_width(editor)
	w, h := editor_viewport(editor)

	sel_from, sel_to, sel_ok := selection_range(b)

	bra, brm: Cursor
	br_ok := false
	if !b.big && !sel_ok {
		bra, brm, br_ok = bracket_match(b)
	}

	ai_rows: [][2]int
	if len(editor.llm.requests) > 0 {
		ai_rows = llm_active_rows(editor, b)
	}

	b.wrap_width = w
	wrapping := b.wrap && w > 0
	gap := fim_ghost_gap(editor)
	// While a ghost shows, the cursor line is drawn only up to the caret; the
	// suffix is relocated after the ghost by fim_render (else it'd paint over it).
	ghost_cut := !editor.completion.active && fim_ghost_active(editor)
	screen_y := 0
	for row := editor.scroll_row; row < len(b.lines) && screen_y < h; row += 1 {
		current := row == b.cursor.row
		severity := 0
		for d in b.diags {
			if row >= d.from.row && row <= d.to.row && (severity == 0 || d.severity < severity) {
				severity = d.severity
			}
		}
		mark := git_mark_at(b, row)

		text := b.lines[row].text
		row_sel_from, row_sel_to := -1, -1
		if sel_ok && row >= sel_from.row && row <= sel_to.row {
			row_sel_from = sel_from.col if row == sel_from.row else 0
			row_sel_to = sel_to.col if row == sel_to.row else len(text) + 1
		}
		underlines := make([dynamic][2]int, context.temp_allocator)
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
				append(&underlines, [2]int{ds, de})
			}
		}
		if br_ok {
			if bra.row == row {
				append(&underlines, [2]int{bra.col, bra.col + 1})
			}
			if brm.row == row {
				append(&underlines, [2]int{brm.col, brm.col + 1})
			}
		}
		ai_edit := false
		for r in ai_rows {
			if row >= r[0] && row <= r[1] {
				ai_edit = true
				break
			}
		}
		colors := highlight_colors(b, row)
		line_bg := editor_line_bg(current, ai_edit, mark, editor.hunk_highlight)

		ghost_row := ghost_cut && row == b.cursor.row
		if wrapping {
			if ghost_row {
				// Ghost + suffix wrap as one flow, pushing lines below down by the
				// rows they consume (no separate gap needed).
				screen_y = editor_render_ghost_line(editor, b, row, gutter, w, h, screen_y, colors, line_bg)
				continue
			}
			segs := line_wrap(text[:], w)
			start_sub := editor.scroll_sub if row == editor.scroll_row else 0
			for s in start_sub ..< len(segs) {
				if screen_y >= h {
					break
				}
				seg_start := segs[s]
				seg_end := segs[s + 1] if s + 1 < len(segs) else len(text)
				x_origin := visual_col(text[:], seg_start)
				editor_render_gutter(screen_y, gutter, row + 1, current, severity, mark, s > 0)
				editor_render_text_row(gutter, screen_y, w, text[:], colors, x_origin, line_bg, row_sel_from, row_sel_to, underlines[:], seg_start, seg_end)
				screen_y += 1
			}
		} else {
			// Unwrapped: ghost + suffix stay on one row (clipped), drawn by
			// fim_render, so cut the real line at the caret and reserve gap rows.
			text_end := b.cursor.col if ghost_row else len(text)
			editor_render_gutter(screen_y, gutter, row + 1, current, severity, mark, false)
			editor_render_text_row(gutter, screen_y, w, text[:], colors, editor.scroll_col, line_bg, row_sel_from, row_sel_to, underlines[:], 0, text_end)
			screen_y += 1
			if gap > 0 && row == b.cursor.row {
				screen_y += gap
			}
		}
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
	indent := "Tabs" if b.indent == .Tabs else fmt.tprintf("Spaces:%d", b.indent_width)
	right := LANGUAGES[b.language].name
	if b.big {
		right = fmt.tprintf("%s  big", right)
	} else if lsp := lsp_status_label(b); lsp != "" {
		right = fmt.tprintf("%s  %s", right, lsp)
	}
	right = fmt.tprintf("%s  %s", right, indent)
	if n := len(editor.llm.requests); n > 0 {
		right = fmt.tprintf("AI:%d  %s", n, right)
	}
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

editor_render_gutter :: proc(y, width, number: int, current: bool, severity: int, mark: GitMark, continuation: bool) {
	if continuation {
		for x in 0 ..< width {
			tb2.set_cell(i32(x), i32(y), ' ', COLOR_GUTTER_FG, COLOR_GUTTER_BG)
		}
		return
	}
	mark_ch, mark_fg := git_mark_glyph(mark)
	tb2.set_cell(0, i32(y), mark_ch, mark_fg, COLOR_GUTTER_BG)

	label := fmt.tprintf("%d", number)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< width - 2 - len(label) {
		strings.write_byte(&sb, ' ')
	}
	strings.write_string(&sb, label)
	if severity > 0 {
		strings.write_rune(&sb, diagnostic_glyph(severity))
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

color_over :: proc(base, tint: tb2.Color, alpha: f32) -> tb2.Color {
	b := u64(base) & 0xffffff
	t := u64(tint) & 0xffffff
	chan :: proc(base, tint: u64, shift: uint, alpha: f32) -> u64 {
		bc := f32((base >> shift) & 0xff)
		tc := f32((tint >> shift) & 0xff)
		return u64(bc + (tc - bc) * alpha + 0.5) << shift
	}
	return tb2.Color(chan(b, t, 16, alpha) | chan(b, t, 8, alpha) | chan(b, t, 0, alpha))
}

editor_line_bg :: proc(current, ai_edit: bool, mark: GitMark, hunk: bool) -> tb2.Color {
	bg := COLOR_BG
	if hunk {
		#partial switch mark {
		case .Added:
			bg = color_over(bg, COLOR_GIT_ADD, GIT_HUNK_TINT)
		case .Modified:
			bg = color_over(bg, COLOR_GIT_MOD, GIT_HUNK_TINT)
		}
	}
	if ai_edit {
		bg = color_over(bg, COLOR_AI_EDIT_BG, AI_EDIT_TINT)
	}
	if current {
		bg = color_over(bg, COLOR_CURRENT_LINE_BG, CURRENT_LINE_TINT)
	}
	return bg
}

// Renders the byte range [col_start, col_end) of `text` on screen row `y`.
// `x_origin` is the visual column mapped to screen x 0 (horizontal scroll when
// unwrapped; the segment's start column when wrapped). Clusters outside the
// range still advance the running visual column so tab stops stay absolute.
editor_render_text_row :: proc(
	gutter, y, w: int,
	text: []u8,
	colors: []tb2.Color,
	x_origin: int,
	bg_normal: tb2.Color,
	sel_from, sel_to: int,
	underlines: [][2]int,
	col_start, col_end: int,
) {
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

	underlined :: proc(underlines: [][2]int, col: int) -> bool {
		for r in underlines {
			if col >= r[0] && col < r[1] {
				return true
			}
		}
		return false
	}

	emit :: proc(gutter, y, w: int, text: []u8, pstart, pend, vcol, x_origin, col_start, col_end: int, psel: bool, pfg, bg_normal: tb2.Color) -> int {
		if pstart >= col_start && pstart < col_end {
			return draw_cluster(gutter, y, w, text[pstart:pend], vcol, x_origin, psel, pfg, bg_normal)
		}
		return vcol + seg_width(text, pstart, pend, vcol)
	}

	vcol := 0
	pstart := -1
	psel := false
	pfg := COLOR_FG
	it := utf8.decode_grapheme_iterator_make(string(text))
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if pstart >= 0 {
			vcol = emit(gutter, y, w, text, pstart, g.byte_index, vcol, x_origin, col_start, col_end, psel, pfg, bg_normal)
		}
		pstart = g.byte_index
		psel = sel_from >= 0 && g.byte_index >= sel_from && g.byte_index < sel_to
		pfg = colors[pstart] if colors != nil && pstart < len(colors) else COLOR_FG
		if underlined(underlines, pstart) {
			pfg = tb2.Color(u64(pfg) | u64(tb2.Color.Underline))
		}
	}
	if pstart >= 0 {
		vcol = emit(gutter, y, w, text, pstart, len(text), vcol, x_origin, col_start, col_end, psel, pfg, bg_normal)
	}
	if col_end >= len(text) && sel_from >= 0 && len(text) >= sel_from && len(text) < sel_to {
		draw(gutter, y, vcol - x_origin, w, ' ', true, COLOR_FG, bg_normal)
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

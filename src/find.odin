package main

import "core:fmt"
import "core:text/regex"
import "core:unicode"
import "lib:tb2"

FIND_MAX_MATCHES :: 5000
FIND_BOX_WIDTH :: 50
FIND_STATUS_W :: 15
FIND_LABEL :: "Find "
FIND_RLABEL :: "Repl "

FindMatch :: struct {
	row, from, to: int,
}

Find :: struct {
	active:         bool,
	replacing:      bool,
	focus_replace:  bool,
	regex:          bool,
	case_sensitive: bool,
	invalid:        bool,
	field:          TextField,
	replace:        TextField,
	matches:        [dynamic]FindMatch,
	current:        int,
	origin:         Cursor,
}

find_destroy :: proc(f: ^Find) {
	textfield_destroy(&f.field)
	textfield_destroy(&f.replace)
	delete(f.matches)
}

find_open :: proc(editor: ^Editor) {find_begin(editor, false)}
find_open_replace :: proc(editor: ^Editor) {find_begin(editor, true)}

find_begin :: proc(editor: ^Editor, replacing: bool) {
	f := &editor.find
	b := editor_buffer(editor)
	editor_set_message(editor, "")
	f.active = true
	f.replacing = replacing
	f.focus_replace = false
	f.origin = b.cursor
	if from, to, ok := selection_range(b); ok && from.row == to.row && to.col > from.col {
		textfield_set(&f.field, string(b.lines[from.row].text[from.col:to.col]))
	}
	textfield_select_all(&f.field)
	find_scan(editor)
	find_jump(editor)
}

find_close :: proc(editor: ^Editor) {
	editor.find.active = false
	clear(&editor.find.matches)
}

find_ci :: proc(f: ^Find, q: string) -> bool {
	if f.case_sensitive {
		return false
	}
	for r in q {
		if unicode.is_upper(r) {
			return false
		}
	}
	return true
}

find_eq :: proc(a, b: string, ci: bool) -> bool {
	if !ci {
		return a == b
	}
	for i in 0 ..< len(a) {
		if ascii_lower(a[i]) != ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

find_scan :: proc(editor: ^Editor) {
	f := &editor.find
	clear(&f.matches)
	f.invalid = false
	f.current = -1
	q := textfield_str(&f.field)
	if len(q) == 0 {
		return
	}
	ci := find_ci(f, q)
	b := editor_buffer(editor)

	if f.regex {
		flags: regex.Flags
		if ci {
			flags += {.Case_Insensitive}
		}
		re, err := regex.create(q, flags, context.temp_allocator, context.temp_allocator)
		if err != nil {
			f.invalid = true
			return
		}
		capbuf := regex.preallocate_capture(context.temp_allocator)
		outer: for line, row in b.lines {
			s := string(line.text[:])
			off := 0
			for off <= len(s) {
				_, ok := regex.match_with_preallocated_capture(re, s[off:], &capbuf, context.temp_allocator)
				if !ok {
					break
				}
				from := off + capbuf.pos[0][0]
				to := off + capbuf.pos[0][1]
				if to <= from {
					off = from + 1
					continue
				}
				append(&f.matches, FindMatch{row, from, to})
				if len(f.matches) >= FIND_MAX_MATCHES {
					break outer
				}
				off = to
			}
		}
	} else {
		n := len(q)
		outer2: for line, row in b.lines {
			s := string(line.text[:])
			start := 0
			for start + n <= len(s) {
				if find_eq(s[start:start + n], q, ci) {
					append(&f.matches, FindMatch{row, start, start + n})
					if len(f.matches) >= FIND_MAX_MATCHES {
						break outer2
					}
					start += n
				} else {
					start += 1
				}
			}
		}
	}
	find_pick_current(f)
}

find_pick_current :: proc(f: ^Find) {
	f.current = -1
	for m, i in f.matches {
		if m.row > f.origin.row || (m.row == f.origin.row && m.from >= f.origin.col) {
			f.current = i
			return
		}
	}
	if len(f.matches) > 0 {
		f.current = 0
	}
}

find_jump :: proc(editor: ^Editor) {
	f := &editor.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	b := editor_buffer(editor)
	b.selection = Cursor{m.row, m.from}
	b.cursor = {m.row, m.to}
	cursor_goal_sync(b)
	editor_scroll(editor)
}

find_step :: proc(editor: ^Editor, dir: int) {
	f := &editor.find
	n := len(f.matches)
	if n == 0 {
		return
	}
	if f.current < 0 {
		f.current = 0 if dir > 0 else n - 1
	} else {
		f.current = (f.current + dir + n) % n
	}
	find_jump(editor)
}

find_replace_current :: proc(editor: ^Editor) {
	f := &editor.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	b := editor_buffer(editor)
	repl := textfield_str(&f.replace)
	edit_open(b, .Atomic)
	edit_delete(b, {m.row, m.from}, {m.row, m.to})
	edit_insert(b, {m.row, m.from}, repl)
	buffer_undo_commit(b)
	f.origin = {m.row, m.from + len(repl)}
	find_scan(editor)
	find_jump(editor)
}

find_replace_all :: proc(editor: ^Editor) {
	f := &editor.find
	if len(f.matches) == 0 {
		return
	}
	b := editor_buffer(editor)
	repl := textfield_str(&f.replace)
	count := len(f.matches)
	edit_open(b, .Atomic)
	#reverse for m in f.matches {
		edit_delete(b, {m.row, m.from}, {m.row, m.to})
		edit_insert(b, {m.row, m.from}, repl)
	}
	buffer_undo_commit(b)
	f.origin = b.cursor
	find_scan(editor)
	find_jump(editor)
	editor_set_message(editor, fmt.tprintf("Replaced %d match%s", count, "" if count == 1 else "es"))
}

find_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	f := &editor.find
	if ev_alt(ev) && ev.ch != 0 {
		switch ev.ch {
		case 'c', 'C':
			f.case_sensitive = !f.case_sensitive
			find_scan(editor)
			find_jump(editor)
		case 'r', 'R':
			f.regex = !f.regex
			find_scan(editor)
			find_jump(editor)
		case 'a', 'A':
			if f.replacing {
				find_replace_all(editor)
			}
		}
		return
	}
	#partial switch ev.key {
	case .Esc:
		find_close(editor)
		return
	case .Ctrl_F:
		f.focus_replace = false
		textfield_select_all(&f.field)
		return
	case .Ctrl_H:
		f.replacing = !f.replacing
		if !f.replacing {
			f.focus_replace = false
		}
		return
	case .Ctrl_Z:
		cmd_undo(editor)
		f.origin = editor_buffer(editor).cursor
		find_scan(editor)
		find_jump(editor)
		return
	case .Ctrl_Y:
		cmd_redo(editor)
		f.origin = editor_buffer(editor).cursor
		find_scan(editor)
		find_jump(editor)
		return
	case .Tab:
		if f.replacing {
			f.focus_replace = !f.focus_replace
		}
		return
	case .Enter:
		if f.replacing {
			find_replace_current(editor)
		} else {
			find_step(editor, 1)
		}
		return
	case .Arrow_Down:
		find_step(editor, 1)
		return
	case .Arrow_Up:
		find_step(editor, -1)
		return
	}
	target := &f.replace if f.replacing && f.focus_replace else &f.field
	if textfield_key(target, ev) && target == &f.field {
		find_scan(editor)
		find_jump(editor)
	}
}

find_paste :: proc(editor: ^Editor, text: string) {
	f := &editor.find
	target := &f.replace if f.replacing && f.focus_replace else &f.field
	if textfield_insert_flat(target, text) && target == &f.field {
		find_scan(editor)
		find_jump(editor)
	}
}

find_row_spans :: proc(editor: ^Editor, row: int) -> [][2]int {
	f := &editor.find
	out := make([dynamic][2]int, context.temp_allocator)
	for m in f.matches {
		if m.row == row {
			append(&out, [2]int{m.from, m.to})
		} else if m.row > row {
			break
		}
	}
	return out[:]
}

find_box :: proc(editor: ^Editor) -> Rect {
	sw := int(tb2.width())
	rows := 2 if editor.find.replacing else 1
	w := min(FIND_BOX_WIDTH, sw)
	x := max(0, sw - w - 2)
	return {x, 1, w, rows + 2}
}

find_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	if ev.key != .Mouse_Left {
		return
	}
	f := &editor.find
	box := find_box(editor)
	if !mouse_in_rect(ev, box) {
		if !ev_motion(ev) {
			find_close(editor)
		}
		return
	}
	tx := box.x + 1 + len(FIND_LABEL)
	tw := box.x + box.w - 1 - tx
	if int(ev.y) == box.y + 1 {
		f.focus_replace = false
		textfield_mouse(&f.field, tx, box.y + 1, tw, ev)
	} else if f.replacing && int(ev.y) == box.y + 2 {
		f.focus_replace = true
		textfield_mouse(&f.replace, tx, box.y + 2, tw, ev)
	}
}

find_status :: proc(f: ^Find) -> string {
	if f.invalid {
		return "bad regex"
	}
	if len(textfield_str(&f.field)) == 0 {
		return ""
	}
	if len(f.matches) == 0 {
		return "no match"
	}
	human := f.current + 1 if f.current >= 0 else 0
	if len(f.matches) >= FIND_MAX_MATCHES {
		return fmt.tprintf("%d/%d+", human, FIND_MAX_MATCHES)
	}
	return fmt.tprintf("%d/%d", human, len(f.matches))
}

find_render_field :: proc(editor: ^Editor, label: string, y, fw: int, field: ^TextField, focused: bool) {
	box := find_box(editor)
	inner_x := box.x + 1
	pane_text(inner_x, y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner_x + len(label)
	if focused {
		textfield_render(tx, y, fw, field)
	} else {
		pane_text(tx, y, fw, textfield_str(field), COLOR_PANE_FG, COLOR_PANE_BG)
	}
}

find_render :: proc(editor: ^Editor) {
	f := &editor.find
	box := find_box(editor)
	inner := pane_draw_box(box)
	fw := max(1, inner.w - len(FIND_LABEL) - FIND_STATUS_W)

	find_render_field(editor, FIND_LABEL, inner.y, fw, &f.field, !f.focus_replace)

	sx := inner.x + inner.w - FIND_STATUS_W + 1
	rx := sx
	regex_fg := COLOR_PANE_PROMPT_FG if f.regex else COLOR_PANE_SHORTCUT_FG
	pane_text(rx, inner.y, 2, ".*", regex_fg, COLOR_PANE_BG)
	rx += 3
	case_fg := COLOR_PANE_PROMPT_FG if f.case_sensitive else COLOR_PANE_SHORTCUT_FG
	pane_text(rx, inner.y, 2, "Aa", case_fg, COLOR_PANE_BG)
	rx += 3
	pane_text(rx, inner.y, FIND_STATUS_W, find_status(f), COLOR_PANE_FG, COLOR_PANE_BG)

	if f.replacing {
		find_render_field(editor, FIND_RLABEL, inner.y + 1, fw, &f.replace, f.focus_replace)
	}
}

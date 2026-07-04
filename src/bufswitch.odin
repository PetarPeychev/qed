package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

BufSwitch :: struct {
	active:   bool,
	query:    [dynamic]u8,
	names:    [dynamic]string,
	matches:  [dynamic]int,
	selected: int,
	scroll:   int,
	fuzzy:    Fuzzy,
}

bufswitch_clear_names :: proc(p: ^BufSwitch) {
	for s in p.names {
		delete(s)
	}
	clear(&p.names)
}

bufswitch_destroy :: proc(p: ^BufSwitch) {
	fuzzy_end(&p.fuzzy)
	bufswitch_clear_names(p)
	delete(p.names)
	delete(p.query)
	delete(p.matches)
}

bufswitch_label :: proc(editor: ^Editor, b: ^Buffer) -> string {
	if b.path == "" {
		return strings.clone("[No Name]")
	}
	root := editor.working_root
	if root != "" && strings.has_prefix(b.path, root) {
		rest := b.path[len(root):]
		if len(rest) > 0 && rest[0] == '/' {
			return strings.clone(rest[1:])
		}
	}
	return strings.clone(b.path)
}

bufswitch_open :: proc(editor: ^Editor) {
	if editor.welcome || len(editor.buffers) <= 1 {
		editor_set_message(editor, "No other buffers")
		return
	}
	p := &editor.bufswitch
	p.active = true
	clear(&p.query)
	p.scroll = 0
	editor_set_message(editor, "")

	bufswitch_clear_names(p)
	for &b in editor.buffers {
		append(&p.names, bufswitch_label(editor, &b))
	}
	p.fuzzy = fuzzy_begin(p.names[:])
	bufswitch_filter(editor)
	p.selected = editor.current
	if p.selected >= PALETTE_MAX_ROWS {
		p.scroll = p.selected - PALETTE_MAX_ROWS + 1
	}
}

bufswitch_close :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	p.active = false
	fuzzy_end(&p.fuzzy)
	bufswitch_clear_names(p)
}

bufswitch_filter :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	clear(&p.matches)
	p.selected = 0
	p.scroll = 0
	ranked := fuzzy_rank(&p.fuzzy, string(p.query[:]))
	for idx in ranked {
		append(&p.matches, idx)
	}
}

bufswitch_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.bufswitch
	n := len(p.matches)
	if n == 0 {
		return
	}
	p.selected = clamp(p.selected + delta, 0, n - 1)
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if p.selected >= p.scroll + PALETTE_MAX_ROWS {
		p.scroll = p.selected - PALETTE_MAX_ROWS + 1
	}
}

bufswitch_select :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	if len(p.matches) == 0 {
		bufswitch_close(editor)
		return
	}
	idx := p.matches[p.selected]
	bufswitch_close(editor)
	editor_switch_to(editor, idx)
}

bufswitch_jump_number :: proc(editor: ^Editor, ch: rune) {
	idx := int(ch - '1')
	if idx < 0 || idx >= len(editor.buffers) {
		return
	}
	bufswitch_close(editor)
	editor_switch_to(editor, idx)
}

bufswitch_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.bufswitch
	#partial switch ev.key {
	case .Esc, .Ctrl_E:
		bufswitch_close(editor)
	case .Enter:
		bufswitch_select(editor)
	case .Arrow_Down:
		bufswitch_move(editor, 1)
	case .Arrow_Up:
		bufswitch_move(editor, -1)
	case .Pgdn:
		bufswitch_move(editor, PALETTE_MAX_ROWS)
	case .Pgup:
		bufswitch_move(editor, -PALETTE_MAX_ROWS)
	case .Backspace, .Backspace2:
		if len(p.query) > 0 {
			resize(&p.query, len(p.query) - 1)
			bufswitch_filter(editor)
		}
	case:
		if len(p.query) == 0 && ev.ch >= '1' && ev.ch <= '9' {
			bufswitch_jump_number(editor, ev.ch)
		} else if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&p.query, ..bytes[:n])
			bufswitch_filter(editor)
		}
	}
}

bufswitch_render :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	rows := min(len(p.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, 2, "> ", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_text(inner.x + 3, inner.y, inner.w - 4, string(p.query[:]), COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := p.scroll + i
		bufidx := p.matches[idx]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		num_fg := COLOR_PANE_SHORTCUT_FG
		if idx == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			num_fg = COLOR_PANE_SEL_FG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, 3, fmt.tprintf("%d", bufidx + 1), num_fg, bg)
		label := p.names[bufidx]
		if editor.buffers[bufidx].modified {
			label = fmt.tprintf("%s [*]", label)
		}
		pane_text(inner.x + 4, y, inner.w - 5, label, fg, bg)
	}

	cx := min(inner.x + 3 + len(p.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}

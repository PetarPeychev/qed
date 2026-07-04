package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

BufSwitch :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
}

bufswitch_clear_names :: proc(p: ^BufSwitch) {
	for s in p.names {
		delete(s)
	}
	clear(&p.names)
}

bufswitch_destroy :: proc(p: ^BufSwitch) {
	fuzzy_list_destroy(&p.list)
	bufswitch_clear_names(p)
	delete(p.names)
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
	fuzzy_list_reset(&p.list)
	editor_set_message(editor, "")

	bufswitch_clear_names(p)
	for &b in editor.buffers {
		append(&p.names, bufswitch_label(editor, &b))
	}
	p.fuzzy = fuzzy_begin(p.names[:])
	fuzzy_list_refilter(&p.list)
	p.selected = editor.current
	fuzzy_list_scroll(&p.list, PALETTE_MAX_ROWS)
}

bufswitch_close :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	p.active = false
	fuzzy_end(&p.fuzzy)
	bufswitch_clear_names(p)
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
		fuzzy_list_move_wrap(&p.list, 1, PALETTE_MAX_ROWS)
	case .Arrow_Up:
		fuzzy_list_move_wrap(&p.list, -1, PALETTE_MAX_ROWS)
	case:
		if len(p.query) == 0 && ev.ch >= '1' && ev.ch <= '9' {
			bufswitch_jump_number(editor, ev.ch)
		} else if query_edit_key(&p.query, ev) {
			fuzzy_list_refilter(&p.list)
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

	overlay_cursor(inner, len(p.query))
}

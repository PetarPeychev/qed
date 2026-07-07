package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

BufSwitch :: struct {
	using list:    FuzzyList,
	names:         [dynamic]string,
	preview:       [dynamic]string,
	preview_start: int,
	preview_focus: int,
	colors:        [dynamic][dynamic]tb2.Color,
}

bufswitch_clear_names :: proc(p: ^BufSwitch) {
	for s in p.names {
		delete(s)
	}
	clear(&p.names)
}

bufswitch_clear_preview :: proc(p: ^BufSwitch) {
	for s in p.preview {
		delete(s)
	}
	clear(&p.preview)
	for &row in p.colors {
		delete(row)
	}
	clear(&p.colors)
}

bufswitch_destroy :: proc(p: ^BufSwitch) {
	fuzzy_list_destroy(&p.list)
	bufswitch_clear_names(p)
	bufswitch_clear_preview(p)
	delete(p.names)
	delete(p.preview)
	delete(p.colors)
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
	fuzzy_list_scroll(&p.list, overlay_layout(editor).body_h)
	bufswitch_load_preview(editor)
}

bufswitch_close :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	p.active = false
	fuzzy_end(&p.fuzzy)
	bufswitch_clear_names(p)
	bufswitch_clear_preview(p)
}

bufswitch_load_preview :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	bufswitch_clear_preview(p)
	if len(p.matches) == 0 {
		return
	}
	b := &editor.buffers[p.matches[p.selected]]
	h := max(1, overlay_layout(editor).body_h)
	focus := clamp(b.cursor.row, 0, len(b.lines) - 1)
	start := max(0, focus - h / 2)
	end := min(len(b.lines), start + h)
	p.preview_start = start + 1
	p.preview_focus = focus + 1

	lines := make([dynamic]string, context.temp_allocator)
	total := 0
	for i in 0 ..< end {
		s := string(b.lines[i].text[:])
		append(&lines, s)
		total += len(s) + 1
	}

	// Parse from line 1 so multi-line strings/comments opening above the window
	// color correctly; above the async gate, color only the window to bound latency.
	if b.big || total >= HIGHLIGHT_ASYNC_BYTES {
		for s in lines[start:] {
			append(&p.preview, strings.clone(s))
		}
		if !b.big {
			highlight_lines(b.language, p.preview[:], &p.colors)
		}
		return
	}

	tmp: [dynamic][dynamic]tb2.Color
	highlight_lines(b.language, lines[:], &tmp)
	for row, i in tmp {
		if i < start {
			delete(row)
			continue
		}
		append(&p.preview, strings.clone(lines[i]))
		append(&p.colors, row)
	}
	delete(tmp)
}

bufswitch_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.bufswitch
	fuzzy_list_move(&p.list, delta, overlay_layout(editor).body_h)
	bufswitch_load_preview(editor)
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
	case:
		if len(p.field.text) == 0 && ev.ch >= '1' && ev.ch <= '9' {
			bufswitch_jump_number(editor, ev.ch)
		} else if textfield_key(&p.field, ev) {
			fuzzy_list_refilter(&p.list)
			bufswitch_load_preview(editor)
		}
	}
}

bufswitch_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.bufswitch
	idx, activate := overlay_list_mouse(editor, ev, overlay_layout(editor), len(p.matches), &p.scroll, &p.field, bufswitch_close)
	if idx < 0 {
		return
	}
	p.selected = idx
	bufswitch_load_preview(editor)
	if activate {
		bufswitch_select(editor)
	}
}

bufswitch_render :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	lay := overlay_layout(editor)
	inner := pane_draw_box(lay.box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &p.field)
	pane_hline(lay.box, lay.title_sep_y)

	end := min(p.scroll + lay.body_h, len(p.matches))
	for i in p.scroll ..< end {
		bufidx := p.matches[i]
		y := lay.body_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		num_fg := COLOR_PANE_SHORTCUT_FG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			num_fg = COLOR_PANE_SEL_FG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		pane_text(inner.x + 1, y, 3, fmt.tprintf("%d", bufidx + 1), num_fg, bg)
		label := p.names[bufidx]
		if editor.buffers[bufidx].modified {
			label = fmt.tprintf("%s ●", label)
		}
		pane_text(inner.x + 4, y, lay.left_w - 4, label, fg, bg)
	}

	numw := digit_count(p.preview_start + len(p.preview))
	for line, i in p.preview {
		if i >= lay.body_h {
			break
		}
		lineno := p.preview_start + i
		y := lay.body_top + i
		label := linefind_label(numw, lineno - 1, line)
		if lineno == p.preview_focus {
			pane_text(lay.right_x + 1, y, lay.right_w - 1, label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
			continue
		}
		colors := p.colors[i][:] if i < len(p.colors) else nil
		pane_text_colored(lay.right_x + 1, y, lay.right_w - 1, label, colors, len(label) - len(line), COLOR_PANE_FG, COLOR_PANE_BG)
	}

	overlay_divider(lay)
}

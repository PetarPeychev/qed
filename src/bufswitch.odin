package main

import "core:fmt"
import "core:strings"
import "lib:tb2"

BufSwitch :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
	preview:    Preview,
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
	preview_destroy(&p.preview)
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
		editor_log(editor, .Info, "", "No other buffers")
		return
	}
	p := &editor.bufswitch
	p.active = true
	fuzzy_list_reset(&p.list)
	editor_clear_message(editor)

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
	preview_reset(&p.preview)
}

bufswitch_load_preview :: proc(editor: ^Editor) {
	p := &editor.bufswitch
	if len(p.matches) == 0 {
		preview_reset(&p.preview)
		return
	}
	b := &editor.buffers[p.matches[p.selected]]
	focus := clamp(b.cursor.row, 0, max(0, len(b.lines) - 1)) + 1
	preview_set_buffer(&p.preview, b, focus, overlay_layout(editor).body_h)
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
	if command_matches(ev, "Switch Buffer") {
		bufswitch_close(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
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

bufswitch_paste :: proc(editor: ^Editor, text: string) {
	p := &editor.bufswitch
	if textfield_insert_flat(&p.field, text) {
		fuzzy_list_refilter(&p.list)
		bufswitch_load_preview(editor)
	}
}

bufswitch_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.bufswitch
	lay := overlay_layout(editor)
	if preview_wheel(&p.preview, ev, {lay.right_x, lay.body_top, lay.right_w, lay.body_h}, lay.body_h) {
		return
	}
	idx, activate := overlay_list_mouse(editor, ev, lay, len(p.matches), &p.scroll, &p.field, bufswitch_close)
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
			label = fmt.tprintf("%s %s", label, ICON_MODIFIED)
		}
		pane_text(inner.x + 4, y, lay.left_w - 4, label, fg, bg)
	}

	preview_render(&p.preview, lay.right_x + 1, lay.body_top, lay.right_w - 1, lay.body_h)

	overlay_divider(lay, p.scroll, len(p.matches))
}

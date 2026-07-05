package main

import "core:fmt"
import "lib:tb2"

IndentPick :: struct {
	using list: FuzzyList,
	names:      [dynamic]string,
}

INDENT_OPTIONS :: []string{"Auto-detect", "Tabs", "Spaces:4", "Spaces:3", "Spaces:2", "Spaces:1"}

indentpick_destroy :: proc(ip: ^IndentPick) {
	fuzzy_list_destroy(&ip.list)
	delete(ip.names)
}

indentpick_open :: proc(editor: ^Editor) {
	ip := &editor.indentpick
	ip.active = true
	fuzzy_list_reset(&ip.list)
	editor_set_message(editor, "")
	clear(&ip.names)
	for opt in INDENT_OPTIONS {
		append(&ip.names, opt)
	}
	ip.fuzzy = fuzzy_begin(ip.names[:])
	fuzzy_list_refilter(&ip.list)
}

indentpick_close :: proc(editor: ^Editor) {
	editor.indentpick.active = false
	fuzzy_end(&editor.indentpick.fuzzy)
}

indentpick_execute :: proc(editor: ^Editor) {
	ip := &editor.indentpick
	if len(ip.matches) == 0 {
		return
	}
	choice := ip.names[ip.matches[ip.selected]]
	indentpick_close(editor)

	b := editor_buffer(editor)
	switch choice {
	case "Auto-detect":
		buffer_detect_indent(b)
	case "Tabs":
		b.indent = .Tabs
	case:
		b.indent = .Spaces
		b.indent_width = int(choice[len("Spaces:")] - '0')
	}
	label := "Tabs" if b.indent == .Tabs else fmt.tprintf("Spaces:%d", b.indent_width)
	editor_set_message(editor, fmt.tprintf("Indentation: %s", label))
}

indentpick_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	ip := &editor.indentpick
	#partial switch ev.key {
	case .Esc:
		indentpick_close(editor)
	case .Enter:
		indentpick_execute(editor)
	case .Arrow_Down:
		fuzzy_list_move_wrap(&ip.list, 1, PALETTE_MAX_ROWS)
	case .Arrow_Up:
		fuzzy_list_move_wrap(&ip.list, -1, PALETTE_MAX_ROWS)
	case:
		if query_edit_key(&ip.query, ev) {
			fuzzy_list_refilter(&ip.list)
		}
	}
}

indentpick_render :: proc(editor: ^Editor) {
	ip := &editor.indentpick
	rows := min(len(ip.matches), PALETTE_MAX_ROWS)
	box := pane_center(editor, PALETTE_WIDTH, 2 + rows)
	inner := pane_draw_box(box)

	pane_text(inner.x + 1, inner.y, 2, "> ", COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_text(inner.x + 3, inner.y, inner.w - 4, string(ip.query[:]), COLOR_PANE_FG, COLOR_PANE_BG)
	pane_hline(box, inner.y + 1)

	for i in 0 ..< rows {
		idx := ip.scroll + i
		name := ip.names[ip.matches[idx]]
		y := inner.y + 2 + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if idx == ip.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		pane_text(inner.x + 1, y, inner.w - 2, name, fg, bg)
	}

	overlay_cursor(inner, len(ip.query))
}

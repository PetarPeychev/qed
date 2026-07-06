package main

import "core:unicode/utf8"
import "lib:tb2"

Rename :: struct {
	active: bool,
	input:  [dynamic]u8,
	caret:  int,
}

rename_destroy :: proc(r: ^Rename) {
	delete(r.input)
}

rename_open :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if _, ok := lsp_rename_ready(editor, b); !ok {
		return
	}
	from, to := word_range_at(b, b.cursor)
	word := buffer_text_range(b, from, to)
	r := &editor.rename
	r.active = true
	clear(&r.input)
	append(&r.input, ..transmute([]u8)word)
	r.caret = len(r.input)
	editor_set_message(editor, "")
}

rename_close :: proc(editor: ^Editor) {
	editor.rename.active = false
}

rename_submit :: proc(editor: ^Editor) {
	r := &editor.rename
	name := string(r.input[:])
	rename_close(editor)
	if len(name) == 0 {
		editor_set_message(editor, "Empty name", true)
		return
	}
	lsp_rename_send(editor, name)
}

rename_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	r := &editor.rename
	#partial switch ev.key {
	case .Esc:
		rename_close(editor)
	case .Enter:
		rename_submit(editor)
	case .Arrow_Left:
		if r.caret > 0 {
			r.caret = grapheme_prev(r.input[:], r.caret)
		}
	case .Arrow_Right:
		if r.caret < len(r.input) {
			r.caret = grapheme_next(r.input[:], r.caret)
		}
	case .Backspace, .Backspace2:
		if r.caret > 0 {
			prev := grapheme_prev(r.input[:], r.caret)
			remove_range(&r.input, prev, r.caret)
			r.caret = prev
		}
	case .Delete:
		if r.caret < len(r.input) {
			remove_range(&r.input, r.caret, grapheme_next(r.input[:], r.caret))
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			inject_at(&r.input, r.caret, ..bytes[:n])
			r.caret += n
		}
	}
}

rename_render :: proc(editor: ^Editor) {
	r := &editor.rename
	box := pane_center(editor, PALETTE_WIDTH, 1)
	inner := pane_draw_box(box)

	label := "Rename to: "
	pane_text(inner.x + 1, inner.y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	input_line_render(tx, inner.y, tw, r.input[:], r.caret)
}

package main

import "core:unicode/utf8"
import "lib:tb2"

AiEdit :: struct {
	active: bool,
	input:  [dynamic]u8,
	caret:  int,
	from:   Cursor,
	to:     Cursor,
}

aiedit_destroy :: proc(a: ^AiEdit) {
	delete(a.input)
}

aiedit_open :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	from, to, ok := selection_range(b)
	if !ok {
		editor_set_message(editor, "AI edit: select a block first", true)
		return
	}
	a := &editor.aiedit
	a.active = true
	a.from = from
	a.to = to
	clear(&a.input)
	a.caret = 0
	editor_set_message(editor, "")
}

aiedit_close :: proc(editor: ^Editor) {
	editor.aiedit.active = false
}

aiedit_submit :: proc(editor: ^Editor) {
	a := &editor.aiedit
	instruction := string(a.input[:])
	from, to := a.from, a.to
	aiedit_close(editor)
	if len(instruction) == 0 {
		editor_set_message(editor, "AI edit: empty instruction", true)
		return
	}
	llm_chat_send(editor, instruction, from, to)
}

aiedit_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	a := &editor.aiedit
	#partial switch ev.key {
	case .Esc:
		aiedit_close(editor)
	case .Enter:
		aiedit_submit(editor)
	case .Arrow_Left:
		if a.caret > 0 {
			a.caret = grapheme_prev(a.input[:], a.caret)
		}
	case .Arrow_Right:
		if a.caret < len(a.input) {
			a.caret = grapheme_next(a.input[:], a.caret)
		}
	case .Home:
		a.caret = 0
	case .End:
		a.caret = len(a.input)
	case .Backspace, .Backspace2:
		if a.caret > 0 {
			prev := grapheme_prev(a.input[:], a.caret)
			remove_range(&a.input, prev, a.caret)
			a.caret = prev
		}
	case .Delete:
		if a.caret < len(a.input) {
			remove_range(&a.input, a.caret, grapheme_next(a.input[:], a.caret))
		}
	case:
		if ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			inject_at(&a.input, a.caret, ..bytes[:n])
			a.caret += n
		}
	}
}

aiedit_render :: proc(editor: ^Editor) {
	a := &editor.aiedit
	box := pane_center(editor, PALETTE_WIDTH, 1)
	inner := pane_draw_box(box)

	label := "AI edit: "
	pane_text(inner.x + 1, inner.y, len(label), label, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	tx := inner.x + 1 + len(label)
	tw := inner.x + inner.w - 1 - tx
	input_line_render(tx, inner.y, tw, a.input[:], a.caret)
}

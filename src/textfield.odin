package main

import "core:unicode/utf8"
import "lib:tb2"

TextField :: struct {
	text:   [dynamic]u8,
	caret:  int,
	anchor: int, // selection start; -1 = none. cursor (caret) is the moving end.
}

textfield_destroy :: proc(f: ^TextField) {
	delete(f.text)
}

textfield_reset :: proc(f: ^TextField) {
	clear(&f.text)
	f.caret = 0
	f.anchor = -1
}

textfield_set :: proc(f: ^TextField, s: string) {
	clear(&f.text)
	append(&f.text, ..transmute([]u8)s)
	f.caret = len(f.text)
	f.anchor = -1
}

textfield_str :: proc(f: ^TextField) -> string {
	return string(f.text[:])
}

textfield_select_all :: proc(f: ^TextField) {
	f.anchor = 0
	f.caret = len(f.text)
}

textfield_selection :: proc(f: ^TextField) -> (lo, hi: int, ok: bool) {
	if f.anchor < 0 || f.anchor == f.caret {
		return 0, 0, false
	}
	if f.anchor < f.caret {
		return f.anchor, f.caret, true
	}
	return f.caret, f.anchor, true
}

textfield_delete_selection :: proc(f: ^TextField) -> bool {
	lo, hi, ok := textfield_selection(f)
	if !ok {
		return false
	}
	remove_range(&f.text, lo, hi)
	f.caret = lo
	f.anchor = -1
	return true
}

textfield_insert :: proc(f: ^TextField, bytes: []u8) {
	textfield_delete_selection(f)
	inject_at(&f.text, f.caret, ..bytes)
	f.caret += len(bytes)
	f.anchor = -1
}

textfield_copy :: proc(f: ^TextField) {
	if lo, hi, ok := textfield_selection(f); ok {
		clipboard_set(string(f.text[lo:hi]))
	}
}

textfield_cut :: proc(f: ^TextField) -> bool {
	if lo, hi, ok := textfield_selection(f); ok {
		clipboard_set(string(f.text[lo:hi]))
		return textfield_delete_selection(f)
	}
	return false
}

textfield_paste :: proc(f: ^TextField) -> bool {
	text := clipboard_get(context.temp_allocator)
	if len(text) == 0 {
		return false
	}
	// A field is single-line: flatten any pasted line/tab breaks to spaces.
	buf := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for i := 0; i < len(text); {
		r, n := utf8.decode_rune(text[i:])
		i += n
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			append(&buf, ' ')
		case r >= 0x20:
			bytes, m := utf8.encode_rune(r)
			append(&buf, ..bytes[:m])
		}
	}
	if len(buf) == 0 {
		return false
	}
	textfield_insert(f, buf[:])
	return true
}

// Handles the same editing binds as the main buffer (grapheme/word motion,
// smart home/end, shift-select, Ctrl+A/C/X/V, insert). Returns whether the
// text content changed, so a fuzzy caller re-filters. Navigation keys the field
// doesn't own (Enter/Esc/Up/Down) fall through unhandled for the caller.
textfield_key :: proc(f: ^TextField, ev: tb2.Event) -> bool {
	ctrl := (u8(ev.mod) & u8(tb2.Mod.Ctrl)) != 0
	shift := (u8(ev.mod) & u8(tb2.Mod.Shift)) != 0
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
	text := f.text[:]

	#partial switch ev.key {
	case .Ctrl_A:
		textfield_select_all(f)
		return false
	case .Ctrl_C:
		textfield_copy(f)
		return false
	case .Ctrl_X:
		return textfield_cut(f)
	case .Ctrl_V:
		return textfield_paste(f)
	case .Arrow_Left, .Arrow_Right:
		lo, hi, had := textfield_selection(f)
		if shift {
			if f.anchor < 0 {
				f.anchor = f.caret
			}
		} else {
			f.anchor = -1
		}
		collapse := had && !shift && !ctrl && !alt
		if ev.key == .Arrow_Left {
			switch {
			case alt:
				f.caret = home_smart_col(text, f.caret)
			case collapse:
				f.caret = lo
			case ctrl:
				f.caret = word_left_col(text, f.caret)
			case f.caret > 0:
				f.caret = grapheme_prev(text, f.caret)
			}
		} else {
			switch {
			case alt:
				f.caret = len(text)
			case collapse:
				f.caret = hi
			case ctrl:
				f.caret = word_right_col(text, f.caret)
			case f.caret < len(text):
				f.caret = grapheme_next(text, f.caret)
			}
		}
		return false
	case .Backspace, .Backspace2:
		if textfield_delete_selection(f) {
			return true
		}
		if f.caret > 0 {
			prev := grapheme_prev(text, f.caret)
			remove_range(&f.text, prev, f.caret)
			f.caret = prev
			return true
		}
		return false
	case .Delete:
		if textfield_delete_selection(f) {
			return true
		}
		if f.caret < len(text) {
			remove_range(&f.text, f.caret, grapheme_next(text, f.caret))
			return true
		}
		return false
	case:
		if !alt && ev.ch >= 0x20 {
			bytes, n := utf8.encode_rune(ev.ch)
			textfield_insert(f, bytes[:n])
			return true
		}
	}
	return false
}

// Single-line input in the column span [x, x+w), scrolled horizontally so the
// caret stays visible, with the selection inverted and the hardware cursor placed.
textfield_render :: proc(x, y, w: int, f: ^TextField) {
	if w <= 0 {
		return
	}
	text := f.text[:]
	start := 0
	for start < f.caret && visual_width(text[start:f.caret]) >= w {
		start = grapheme_next(text, start)
	}
	pane_text(x, y, w, string(text[start:]), COLOR_PANE_FG, COLOR_PANE_BG)
	if lo, hi, ok := textfield_selection(f); ok {
		slo := max(lo, start)
		if slo < hi {
			sx := x + visual_width(text[start:slo])
			sw := x + w - sx
			pane_text(sx, y, sw, string(text[slo:hi]), COLOR_PANE_BG, COLOR_PANE_FG)
		}
	}
	tb2.set_cursor(i32(x + visual_width(text[start:f.caret])), i32(y))
}

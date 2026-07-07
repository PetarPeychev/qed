package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "lib:tb2"

Completion :: struct {
	active:     bool,
	items:      [dynamic]CompletionItem,
	matches:    [dynamic]int,
	selected:   int,
	scroll:     int,
	anchor_row: int,
	anchor_col: int,
	incomplete: bool,
	want:       bool,
	pending:    bool,
	request_at: time.Tick,
}

CompletionItem :: struct {
	label:  string,
	insert: string,
	detail: string,
	filter: string,
	add:    [dynamic]CompletionEdit,
}

CompletionEdit :: struct {
	from_line, from_char, to_line, to_char: int,
	text:                                   string,
}

completion_destroy :: proc(c: ^Completion) {
	completion_clear_items(c)
	delete(c.items)
	delete(c.matches)
}

completion_clear_items :: proc(c: ^Completion) {
	for &it in c.items {
		delete(it.label)
		delete(it.insert)
		delete(it.detail)
		delete(it.filter)
		for ae in it.add {
			delete(ae.text)
		}
		delete(it.add)
	}
	clear(&c.items)
	clear(&c.matches)
}

completion_dismiss :: proc(editor: ^Editor) {
	c := &editor.completion
	c.active = false
	c.want = false
	completion_clear_items(c)
}

completion_queue :: proc(editor: ^Editor) {
	c := &editor.completion
	c.want = true
	c.request_at = time.tick_now()
}

completion_due :: proc(editor: ^Editor) -> bool {
	c := &editor.completion
	if !c.want {
		return false
	}
	return time.duration_milliseconds(time.tick_since(c.request_at)) >= f64(COMPLETION_DEBOUNCE_MS)
}

completion_word_start :: proc(b: ^Buffer, at: Cursor) -> int {
	text := b.lines[at.row].text[:]
	col := min(at.col, len(text))
	for col > 0 {
		p := grapheme_prev(text, col)
		if grapheme_class(text, p) != .Word {
			break
		}
		col = p
	}
	return col
}

completion_is_trigger :: proc(lsp: ^Lsp, r: rune) -> bool {
	if r >= 0x80 {
		return false
	}
	for t in lsp.completion_triggers {
		if t == u8(r) {
			return true
		}
	}
	return false
}

completion_request :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	if b.big {
		return
	}
	lsp, ok := lsp_ready(b)
	if !ok || !lsp.cap_completion {
		return
	}
	lsp_ensure_synced(editor, b)
	c := &editor.completion
	c.anchor_row = b.cursor.row
	c.anchor_col = completion_word_start(b, b.cursor)
	c.pending = true
	id := lsp_pending_add(lsp, .Completion, b)
	ch := col_to_utf16(b.lines[b.cursor.row].text[:], b.cursor.col)
	lsp_send(
		editor,
		lsp,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"textDocument/completion","params":{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}}}`,
			id,
			lsp_json_string(lsp_uri(b.path)),
			b.cursor.row,
			ch,
		),
	)
}

// A snippet's plain-text prefix: everything up to the first tab-stop ($1/${…}),
// with backslash escapes unwrapped. Turns `foo(${1:a}, ${2:b})$0` into `foo(`.
snippet_prefix :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] == '\\' && i + 1 < len(s) {
			strings.write_byte(&sb, s[i + 1])
			i += 2
			continue
		}
		if s[i] == '$' {
			break
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

completion_apply :: proc(editor: ^Editor, p: LspPending, obj: json.Object) -> bool {
	c := &editor.completion
	c.pending = false
	if editor_buffer(editor).path != p.path {
		return false
	}

	items_arr: json.Array
	incomplete := false
	#partial switch r in obj["result"] {
	case json.Array:
		items_arr = r
	case json.Object:
		items_arr, _ = r["items"].(json.Array)
		if v, ok := r["isIncomplete"].(json.Boolean); ok {
			incomplete = bool(v)
		}
	case:
		completion_dismiss(editor)
		return true
	}

	completion_clear_items(c)
	c.incomplete = incomplete
	for item in items_arr {
		io := item.(json.Object) or_continue
		label := strings.trim_space(io["label"].(string) or_else "")
		if label == "" {
			continue
		}
		fmt_kind := 1
		if n, ok := lsp_num(io["insertTextFormat"]); ok {
			fmt_kind = n
		}
		raw := ""
		if te, ok := io["textEdit"].(json.Object); ok {
			raw = te["newText"].(string) or_else ""
		} else if it, ok := io["insertText"].(string); ok {
			raw = it
		}
		if raw == "" {
			raw = label
		}
		insert := snippet_prefix(raw) if fmt_kind == 2 else raw
		ci := CompletionItem {
			label  = strings.clone(label),
			insert = strings.clone(insert),
			detail = strings.clone(strings.trim_space(io["detail"].(string) or_else "")),
			filter = strings.clone(io["filterText"].(string) or_else label),
		}
		if ates, ok := io["additionalTextEdits"].(json.Array); ok {
			for ae in ates {
				aeo := ae.(json.Object) or_continue
				rng := aeo["range"].(json.Object) or_continue
				s := rng["start"].(json.Object) or_continue
				en := rng["end"].(json.Object) or_continue
				sl, _ := lsp_num(s["line"])
				sc, _ := lsp_num(s["character"])
				el, _ := lsp_num(en["line"])
				ec, _ := lsp_num(en["character"])
				append(&ci.add, CompletionEdit{sl, sc, el, ec, strings.clone(aeo["newText"].(string) or_else "")})
			}
		}
		append(&c.items, ci)
	}

	if len(c.items) == 0 || !completion_valid(editor) {
		completion_dismiss(editor)
		return true
	}
	c.selected = 0
	c.scroll = 0
	completion_filter(editor)
	if len(c.matches) == 0 {
		completion_dismiss(editor)
		return true
	}
	c.active = true
	return true
}

completion_valid :: proc(editor: ^Editor) -> bool {
	c := &editor.completion
	b := editor_buffer(editor)
	if selection_active(b) {
		return false
	}
	if b.cursor.row != c.anchor_row || b.cursor.col < c.anchor_col {
		return false
	}
	text := b.lines[b.cursor.row].text[:]
	if c.anchor_col > len(text) || b.cursor.col > len(text) {
		return false
	}
	for i := c.anchor_col; i < b.cursor.col; i = grapheme_next(text, i) {
		if grapheme_class(text, i) != .Word {
			return false
		}
	}
	return true
}

completion_filter :: proc(editor: ^Editor) {
	c := &editor.completion
	b := editor_buffer(editor)
	prefix := string(b.lines[b.cursor.row].text[c.anchor_col:b.cursor.col])
	clear(&c.matches)
	if len(prefix) == 0 {
		for _, i in c.items {
			append(&c.matches, i)
		}
	} else {
		Scored :: struct {
			score, idx: int,
		}
		scored := make([dynamic]Scored, context.temp_allocator)
		for it, i in c.items {
			if s, ok := fuzzy_match(prefix, it.filter); ok {
				append(&scored, Scored{s, i})
			}
		}
		slice.sort_by(scored[:], proc(a, b: Scored) -> bool {
			if a.score != b.score {
				return a.score > b.score
			}
			return a.idx < b.idx
		})
		for e in scored {
			append(&c.matches, e.idx)
		}
	}
	if c.selected >= len(c.matches) {
		c.selected = max(0, len(c.matches) - 1)
	}
	completion_scroll_fix(c)
}

completion_scroll_fix :: proc(c: ^Completion) {
	if c.selected < c.scroll {
		c.scroll = c.selected
	}
	if c.selected >= c.scroll + COMPLETION_MAX_ROWS {
		c.scroll = c.selected - COMPLETION_MAX_ROWS + 1
	}
	c.scroll = max(0, c.scroll)
}

completion_move :: proc(editor: ^Editor, delta: int) {
	c := &editor.completion
	n := len(c.matches)
	if n == 0 {
		return
	}
	c.selected = (c.selected + delta + n) % n
	completion_scroll_fix(c)
}

completion_accept :: proc(editor: ^Editor) {
	c := &editor.completion
	if len(c.matches) == 0 {
		completion_dismiss(editor)
		return
	}
	item := &c.items[c.matches[c.selected]]
	b := editor_buffer(editor)

	Ranged :: struct {
		from, to: Cursor,
		text:     string,
	}
	list := make([dynamic]Ranged, context.temp_allocator)
	main_from := Cursor{c.anchor_row, c.anchor_col}
	append(&list, Ranged{main_from, b.cursor, item.insert})
	delta_rows := 0
	for ae in item.add {
		from := Cursor{clamp(ae.from_line, 0, len(b.lines) - 1), 0}
		from.col = col_from_utf16(b.lines[from.row].text[:], ae.from_char)
		to := Cursor{clamp(ae.to_line, 0, len(b.lines) - 1), 0}
		to.col = col_from_utf16(b.lines[to.row].text[:], ae.to_char)
		append(&list, Ranged{from, to, ae.text})
		if ae.from_line < c.anchor_row {
			delta_rows += strings.count(ae.text, "\n") - (to.row - from.row)
		}
	}
	slice.sort_by(list[:], proc(a, b: Ranged) -> bool {
		if a.from.row != b.from.row {
			return a.from.row > b.from.row
		}
		return a.from.col > b.from.col
	})

	edit_open(b, .Atomic)
	for e in list {
		removed := buffer_delete(b, e.from, e.to)
		append(&b.open.edits, Edit{.Insert, e.from, removed})
		buffer_insert(b, e.from, e.text)
		append(&b.open.edits, Edit{.Delete, e.from, strings.clone(e.text)})
	}
	buffer_undo_commit(b)

	end := cursor_advance(main_from, item.insert)
	row := clamp(end.row + delta_rows, 0, len(b.lines) - 1)
	b.cursor = {row, clamp(end.col, 0, len(b.lines[row].text))}
	b.selection = nil
	cursor_goal_sync(b)
	completion_dismiss(editor)
	editor_scroll(editor)
}

completion_keeps :: proc(ev: tb2.Event) -> bool {
	if u8(ev.mod) & (u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Alt)) != 0 {
		return false
	}
	if ev.ch >= 0x20 {
		return true
	}
	#partial switch ev.key {
	case .Backspace, .Backspace2:
		return true
	}
	return false
}

completion_key :: proc(editor: ^Editor, ev: tb2.Event) -> bool {
	mod := u8(ev.mod) & (u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Alt))
	#partial switch ev.key {
	case .Tab:
		completion_accept(editor)
		return true
	case .Esc:
		completion_dismiss(editor)
		return true
	case .Arrow_Down:
		if mod != 0 {
			return false
		}
		completion_move(editor, +1)
		return true
	case .Arrow_Up:
		if mod != 0 {
			return false
		}
		completion_move(editor, -1)
		return true
	}
	return false
}

completion_after :: proc(editor: ^Editor, ev: tb2.Event) {
	c := &editor.completion
	if c.active {
		if completion_valid(editor) {
			completion_filter(editor)
			if c.incomplete {
				completion_queue(editor)
			}
			if len(c.matches) == 0 && !c.want {
				completion_dismiss(editor)
			}
			return
		}
		completion_dismiss(editor)
	}
	completion_maybe_open(editor, ev)
}

completion_maybe_open :: proc(editor: ^Editor, ev: tb2.Event) {
	b := editor_buffer(editor)
	if b.big || selection_active(b) || ev.ch == 0 {
		return
	}
	if u8(ev.mod) & (u8(tb2.Mod.Ctrl) | u8(tb2.Mod.Alt)) != 0 {
		return
	}
	lsp, ok := lsp_ready(b)
	if !ok || !lsp.cap_completion {
		return
	}
	if completion_is_trigger(lsp, ev.ch) {
		completion_queue(editor)
		return
	}
	if char_class(ev.ch) == .Word {
		start := completion_word_start(b, b.cursor)
		if b.cursor.col - start >= COMPLETION_MIN_CHARS {
			completion_queue(editor)
		}
	}
}

completion_render :: proc(editor: ^Editor, cx, cy: int) {
	c := &editor.completion
	if len(c.matches) == 0 {
		return
	}
	b := editor_buffer(editor)
	gutter := editor_gutter_width(editor)
	_, vh := editor_viewport(editor)
	sw := int(tb2.width())
	rows := min(len(c.matches), COMPLETION_MAX_ROWS)

	content_w := 0
	for m in c.matches {
		it := &c.items[m]
		w := len(it.label)
		if it.detail != "" {
			w += 2 + len(it.detail)
		}
		content_w = max(content_w, w)
	}
	content_w = clamp(content_w, 10, COMPLETION_MAX_WIDTH)
	pane_w := content_w + 4
	pane_h := rows + 2

	atext := b.lines[c.anchor_row].text[:]
	ax: int
	if b.wrap && b.wrap_width > 0 {
		seg := wrap_seg_start(atext, b.wrap_width, c.anchor_col)
		ax = gutter + visual_col(atext, c.anchor_col) - visual_col(atext, seg)
	} else {
		ax = gutter + visual_col(atext, c.anchor_col) - editor.scroll_col
	}
	x := clamp(ax, 0, max(0, sw - pane_w))
	y := cy + 1
	if y + pane_h > vh {
		y = cy - pane_h
	}
	if y < 0 {
		return
	}

	box := pane_draw_box({x, y, pane_w, pane_h})
	for i in 0 ..< rows {
		idx := c.scroll + i
		it := &c.items[c.matches[idx]]
		ry := box.y + i
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		dfg := COLOR_PANE_SHORTCUT_FG
		if idx == c.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			dfg = COLOR_PANE_SEL_FG
			pane_fill_row(box.x, ry, box.w, fg, bg)
		}
		pane_text(box.x + 1, ry, box.w - 2, it.label, fg, bg)
		if it.detail != "" {
			dw := min(len(it.detail), box.w - 2 - len(it.label) - 1)
			if dw > 0 {
				pane_text(box.x + box.w - 1 - dw, ry, dw, it.detail, dfg, bg)
			}
		}
	}
}

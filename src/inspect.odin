package main

import "core:fmt"
import "core:strings"
import "lib:tb2"
import ts "lib:tree_sitter"

INSPECT_BOX_WIDTH :: 54

Inspect :: struct {
	active: bool,
}

InspectLine :: struct {
	text: string,
	fg:   tb2.Color,
}

inspect_toggle :: proc(editor: ^Editor) {
	editor.inspect.active = !editor.inspect.active
	editor_set_message(editor, fmt.tprintf("Inspect tokens: %s", "on" if editor.inspect.active else "off"))
}

inspect_close :: proc(editor: ^Editor) {
	editor.inspect.active = false
}

// Passive on-demand inspection: re-runs the highlight query over the cursor's
// line/region (never the paint path) to report node ancestry, the capture stack
// with each capture's resolution chain, and predicate near-misses. Recomputed
// every render while toggled on; zero cost when off.
inspect_render :: proc(editor: ^Editor) {
	b := editor_buffer(editor)
	lines := make([dynamic]InspectLine, context.temp_allocator)
	append(&lines, InspectLine{"Inspect Tokens", COLOR_PANE_PROMPT_FG})

	if b.big {
		append(&lines, InspectLine{"  unavailable (big file)", COLOR_PANE_SHORTCUT_FG})
		inspect_draw(editor, lines[:])
		return
	}
	if !syntax_ensure(b.language) || b.hl.tree == nil {
		append(&lines, InspectLine{"  unavailable (no syntax tree)", COLOR_PANE_SHORTCUT_FG})
		inspect_draw(editor, lines[:])
		return
	}

	cur := b.cursor
	host := syntax_for(b.language)

	target, sr, sc, er, ec, injected := inspect_injection(b, host, cur)
	if injected && syntax_ensure(target) {
		t := syntax_for(target)
		slice := buffer_text_span(b, sr, sc, er, ec)
		tree := ts.parser_parse_string(t.parser, nil, raw_data(slice), u32(len(slice)))
		if tree != nil {
			defer ts.tree_delete(tree)
			lcr := cur.row - sr
			lcc := cur.col - (sc if cur.row == sr else 0)
			root := ts.tree_root_node(tree)
			inspect_ancestry(&lines, root, LANGUAGES[target].name, b.language, true, lcr, lcc)
			inspect_scan(&lines, t, root, NodeText{src = slice}, LANGUAGES[target].name, {0, 0}, {max(u32), 0}, lcr, lcc)
			inspect_draw(editor, lines[:])
			return
		}
	}

	root := ts.tree_root_node(b.hl.tree)
	inspect_ancestry(&lines, root, LANGUAGES[b.language].name, b.language, false, cur.row, cur.col)
	inspect_scan(&lines, host, root, NodeText{buffer = b}, LANGUAGES[b.language].name, {u32(cur.row), 0}, {u32(cur.row) + 1, 0}, cur.row, cur.col)
	inspect_draw(editor, lines[:])
}

// The innermost injection region covering the cursor, mirroring highlight_inject's
// region + language resolution but scoped to the cursor's row.
inspect_injection :: proc(b: ^Buffer, s: ^Syntax, cur: Cursor) -> (target: Language, sr, sc, er, ec: int, ok: bool) {
	if s.inj_query == nil || b.hl.tree == nil {
		return
	}
	nt := NodeText{buffer = b}
	ts.query_cursor_set_point_range(s.inj_cursor, {u32(cur.row), 0}, {u32(cur.row) + 1, 0})
	ts.query_cursor_exec(s.inj_cursor, s.inj_query, ts.tree_root_node(b.hl.tree))
	match: ts.QueryMatch
	for ts.query_cursor_next_match(s.inj_cursor, &match) {
		if int(match.pattern_index) < len(s.inj_preds) &&
		   !predicate_pass(s.inj_preds[match.pattern_index], &match, nt) {
			continue
		}
		content_ok := false
		csr, csc, cer, cec := 0, 0, 0, 0
		lang_name := ""
		for i in 0 ..< int(match.capture_count) {
			cap := match.captures[i]
			if int(cap.index) >= len(s.inj_names) {
				continue
			}
			sp := ts.node_start_point(cap.node)
			ep := ts.node_end_point(cap.node)
			switch s.inj_names[cap.index] {
			case "injection.content":
				csr, csc, cer, cec = int(sp.row), int(sp.column), int(ep.row), int(ep.column)
				content_ok = true
			case "injection.language":
				lang_name = buffer_text_span(b, int(sp.row), int(sp.column), int(ep.row), int(ep.column))
			}
		}
		if !content_ok || !inspect_covers(csr, csc, cer, cec, cur.row, cur.col) {
			continue
		}
		if lang_name == "" && int(match.pattern_index) < len(s.inj_preds) {
			if set_lang, has := pattern_injection_language(s.inj_preds[match.pattern_index]); has {
				lang_name = set_lang
			}
		}
		tl := injection_language(lang_name)
		if tl == .Plain {
			continue
		}
		return tl, csr, csc, cer, cec, true
	}
	return
}

inspect_ancestry :: proc(lines: ^[dynamic]InspectLine, root: ts.Node, lang_name: string, host: Language, injected: bool, r, c: int) {
	pt := ts.Point{u32(r), u32(c)}
	node := ts.node_named_descendant_for_point_range(root, pt, pt)
	sb := strings.builder_make(context.temp_allocator)
	if ts.node_is_null(node) {
		strings.write_string(&sb, "(none)")
	} else {
		cur := node
		for count := 0; !ts.node_is_null(cur) && count < 4; count += 1 {
			if count > 0 {
				strings.write_string(&sb, " ← ")
			}
			fmt.sbprintf(&sb, "(%s)", string(ts.node_type(cur)))
			cur = ts.node_parent(cur)
		}
	}
	if injected {
		fmt.sbprintf(&sb, "   [%s ← %s]", lang_name, LANGUAGES[host].name)
	} else {
		fmt.sbprintf(&sb, "   [%s]", lang_name)
	}
	append(lines, InspectLine{strings.to_string(sb), COLOR_PANE_FG})
}

@(private = "file")
StackEntry :: struct {
	name: string,
	idx:  u32,
}

inspect_scan :: proc(
	lines: ^[dynamic]InspectLine,
	s: ^Syntax,
	root: ts.Node,
	nt: NodeText,
	lang_name: string,
	pr_start, pr_end: ts.Point,
	cr, cc: int,
) {
	ts.query_cursor_set_point_range(s.cursor, pr_start, pr_end)
	ts.query_cursor_exec(s.cursor, s.query, root)

	stack := make([dynamic]StackEntry, context.temp_allocator)
	misses := make([dynamic]InspectLine, context.temp_allocator)

	match: ts.QueryMatch
	for ts.query_cursor_next_match(s.cursor, &match) {
		report := PredicateReport {
			passed = true,
		}
		if int(match.pattern_index) < len(s.preds) {
			report = predicate_report(s.preds[match.pattern_index], &match, nt)
		}
		if report.passed {
			for i in 0 ..< int(match.capture_count) {
				cap := match.captures[i]
				sp := ts.node_start_point(cap.node)
				ep := ts.node_end_point(cap.node)
				if inspect_covers(int(sp.row), int(sp.column), int(ep.row), int(ep.column), cr, cc) {
					append(&stack, StackEntry{inspect_capture_name(s.query, cap.index), cap.index})
				}
			}
			continue
		}
		name := ""
		for i in 0 ..< int(match.capture_count) {
			cap := match.captures[i]
			sp := ts.node_start_point(cap.node)
			ep := ts.node_end_point(cap.node)
			if inspect_covers(int(sp.row), int(sp.column), int(ep.row), int(ep.column), cr, cc) {
				name = inspect_capture_name(s.query, cap.index)
				break
			}
		}
		if name != "" {
			append(&misses, InspectLine{fmt.tprintf("  @%s ✗ %s", name, predicate_describe(report.failed)), COLOR_PANE_SHORTCUT_FG})
		}
	}

	winner := -1
	for e, i in stack {
		if int(e.idx) < len(s.paint) && s.paint[e.idx] {
			winner = i
		}
	}

	if len(stack) == 0 {
		append(lines, InspectLine{"  (no capture here)", COLOR_PANE_SHORTCUT_FG})
	}
	for e, i in stack {
		tried := make([dynamic]string, context.temp_allocator)
		color_key, color, attrs, mapped, resolved := capture_resolve_verbose(g_captures, g_theme_colors, lang_name, e.name, &tried)
		mark := "▸ " if i == winner else "  "
		fg := COLOR_PANE_PROMPT_FG if i == winner else COLOR_PANE_FG
		chain := "unmapped"
		if mapped && resolved {
			chain = fmt.tprintf("%s → %s → #%06x%s", strings.join(tried[:], " ", context.temp_allocator), color_key, u64(color) & 0xffffff, inspect_attrs(attrs))
		} else if mapped {
			chain = fmt.tprintf("%s → %s → (unresolved)", strings.join(tried[:], " ", context.temp_allocator), color_key)
		}
		append(lines, InspectLine{fmt.tprintf("%s@%s  %s", mark, e.name, chain), fg})
	}
	for m in misses {
		append(lines, m)
	}
}

inspect_covers :: proc(sr, sc, er, ec, r, c: int) -> bool {
	if r < sr || r > er {
		return false
	}
	if r == sr && c < sc {
		return false
	}
	if r == er && c >= ec {
		return false
	}
	return true
}

inspect_capture_name :: proc(q: ^ts.Query, id: u32) -> string {
	length: u32
	ptr := ts.query_capture_name_for_id(q, id, &length)
	return string(ptr[:length])
}

inspect_attrs :: proc(attrs: u64) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if attrs & u64(tb2.Color.Bold) != 0 {
		strings.write_string(&sb, " bold")
	}
	if attrs & u64(tb2.Color.Italic) != 0 {
		strings.write_string(&sb, " italic")
	}
	if attrs & u64(tb2.Color.Underline) != 0 {
		strings.write_string(&sb, " underline")
	}
	if attrs & u64(tb2.Color.Reverse) != 0 {
		strings.write_string(&sb, " reverse")
	}
	return strings.to_string(sb)
}

inspect_draw :: proc(editor: ^Editor, lines: []InspectLine) {
	sw := int(tb2.width())
	content_w := 0
	for l in lines {
		content_w = max(content_w, visual_width(transmute([]u8)l.text))
	}
	inner_w := clamp(content_w, 1, INSPECT_BOX_WIDTH)
	box_w := min(inner_w + 2, sw)
	max_rows := max(1, int(tb2.height()) - STATUS_ROWS - 3)
	n := min(len(lines), max_rows)
	x := max(0, sw - box_w - 2)
	box := pane_draw_box({x, 1, box_w, n + 2})
	for i in 0 ..< n {
		pane_text(box.x, box.y + i, box.w, lines[i].text, lines[i].fg, COLOR_PANE_BG)
	}
}

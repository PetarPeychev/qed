package main

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "lib:tb2"

Match :: struct {
	path: string,
	row:  int,
	col:  int,
	text: string,
}

ProjSearch :: struct {
	active:        bool,
	field:         TextField,
	matches:       [dynamic]Match,
	selected:      int,
	scroll:        int,
	preview:       [dynamic]string,
	preview_start: int,
	preview_focus: int,
	colors:        [dynamic][dynamic]tb2.Color,
}

projsearch_clear_matches :: proc(p: ^ProjSearch) {
	for m in p.matches {
		delete(m.path)
		delete(m.text)
	}
	clear(&p.matches)
}

projsearch_clear_preview :: proc(p: ^ProjSearch) {
	for s in p.preview {
		delete(s)
	}
	clear(&p.preview)
	for &row in p.colors {
		delete(row)
	}
	clear(&p.colors)
}

projsearch_destroy :: proc(p: ^ProjSearch) {
	projsearch_clear_matches(p)
	projsearch_clear_preview(p)
	delete(p.matches)
	delete(p.preview)
	textfield_destroy(&p.field)
	delete(p.colors)
}

projsearch_open :: proc(editor: ^Editor) {
	p := &editor.projsearch
	editor_set_message(editor, "")
	if !shell_command_exists("rg") {
		editor_set_message(editor, "ripgrep (rg) not found", true)
		projsearch_clear_matches(p)
		projsearch_clear_preview(p)
		return
	}
	p.active = true
	textfield_select_all(&p.field)
	keep := p.selected
	projsearch_run(editor)
	p.selected = clamp(keep, 0, max(0, len(p.matches) - 1))
	body_h := overlay_layout(editor).body_h
	p.scroll = max(0, p.selected - body_h / 2)
	projsearch_load_preview(editor)
}

projsearch_close :: proc(editor: ^Editor) {
	p := &editor.projsearch
	p.active = false
	projsearch_clear_matches(p)
	projsearch_clear_preview(p)
}

projsearch_run :: proc(editor: ^Editor) {
	p := &editor.projsearch
	projsearch_clear_matches(p)
	p.selected = 0
	p.scroll = 0
	query := textfield_str(&p.field)
	if len(query) < PROJSEARCH_MIN_QUERY {
		return
	}
	cmd := fmt.ctprintf(
		"cd %s && rg --sort path --vimgrep -F -S -e %s 2>/dev/null | head -n %d",
		shell_quote(editor.working_root),
		shell_quote(query),
		PROJSEARCH_MAX,
	)
	out, ok := shell_capture(cmd)
	if !ok {
		return
	}
	for line in strings.split_lines_iterator(&out) {
		c1 := strings.index_byte(line, ':')
		if c1 < 0 {
			continue
		}
		rest1 := line[c1 + 1:]
		c2 := strings.index_byte(rest1, ':')
		if c2 < 0 {
			continue
		}
		rest2 := rest1[c2 + 1:]
		c3 := strings.index_byte(rest2, ':')
		if c3 < 0 {
			continue
		}
		row, row_ok := strconv.parse_int(rest1[:c2], 10)
		col, col_ok := strconv.parse_int(rest2[:c3], 10)
		if !row_ok || !col_ok {
			continue
		}
		append(
			&p.matches,
			Match {
				path = strings.clone(line[:c1]),
				row = max(0, row - 1),
				col = max(0, col - 1),
				text = strings.clone(rest2[c3 + 1:]),
			},
		)
	}
}

projsearch_load_preview :: proc(editor: ^Editor) {
	p := &editor.projsearch
	projsearch_clear_preview(p)
	if len(p.matches) == 0 {
		return
	}
	m := p.matches[p.selected]
	full, _ := filepath.join({editor.working_root, m.path}, context.temp_allocator)
	h := max(1, overlay_layout(editor).body_h)
	start := max(1, (m.row + 1) - h / 2)
	end := start + h - 1
	// Parse from the file's first line so multi-line strings/comments opening
	// above the window color correctly; content below the window can't affect it.
	cmd := fmt.ctprintf("sed -n '1,%dp' %s 2>/dev/null", end, shell_quote(full))
	out, ok := shell_capture(cmd)
	if !ok {
		return
	}
	p.preview_start = start
	p.preview_focus = m.row + 1

	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&out) {
		append(&lines, line)
	}
	off := min(start - 1, len(lines))

	// Above the inline-parse gate, skip the from-top pass and color only the
	// window (occasionally imprecise at the top edge) to bound keypress latency.
	if len(out) >= HIGHLIGHT_ASYNC_BYTES {
		for line in lines[off:] {
			append(&p.preview, strings.clone(line))
		}
		highlight_lines(language_of(m.path), p.preview[:], &p.colors)
		return
	}

	tmp: [dynamic][dynamic]tb2.Color
	highlight_lines(language_of(m.path), lines[:], &tmp)
	for row, i in tmp {
		if i < off {
			delete(row)
			continue
		}
		append(&p.preview, strings.clone(lines[i]))
		append(&p.colors, row)
	}
	delete(tmp)
}

projsearch_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.projsearch
	n := len(p.matches)
	if n == 0 {
		return
	}
	p.selected = clamp(p.selected + delta, 0, n - 1)
	body_h := overlay_layout(editor).body_h
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if body_h > 0 && p.selected >= p.scroll + body_h {
		p.scroll = p.selected - body_h + 1
	}
	projsearch_load_preview(editor)
}

projsearch_execute :: proc(editor: ^Editor) {
	p := &editor.projsearch
	if len(p.matches) == 0 {
		projsearch_close(editor)
		return
	}
	m := p.matches[p.selected]
	full, _ := filepath.join({editor.working_root, m.path}, context.temp_allocator)
	projsearch_close(editor)
	editor_open_path(editor, full)

	b := editor_buffer(editor)
	buffer_undo_commit(b)
	row := clamp(m.row, 0, len(b.lines) - 1)
	col := clamp(m.col, 0, len(b.lines[row].text))
	b.selection = nil
	b.cursor = {row, col}
	cursor_goal_sync(b)
	_, h := editor_viewport(editor)
	editor.scroll_row = row - h / 2
	editor.scroll_sub = 0
	editor_scroll(editor)
}

projsearch_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	alt := (u8(ev.mod) & u8(tb2.Mod.Alt)) != 0
	if alt && ev.ch == 'F' {
		projsearch_close(editor)
		return
	}
	#partial switch ev.key {
	case .Esc:
		projsearch_close(editor)
	case .Enter:
		projsearch_execute(editor)
	case .Arrow_Down:
		projsearch_move(editor, 1)
	case .Arrow_Up:
		projsearch_move(editor, -1)
	case:
		if textfield_key(&p.field, ev) {
			projsearch_run(editor)
			projsearch_load_preview(editor)
		}
	}
}

projsearch_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	idx, activate := overlay_list_mouse(editor, ev, overlay_layout(editor), len(p.matches), &p.scroll, &p.field, projsearch_close)
	if idx < 0 {
		return
	}
	p.selected = idx
	projsearch_load_preview(editor)
	if activate {
		projsearch_execute(editor)
	}
}

projsearch_render :: proc(editor: ^Editor) {
	p := &editor.projsearch
	lay := overlay_layout(editor)
	inner := pane_draw_box(lay.box)

	overlay_prompt_render(inner.x + 1, inner.y, inner.w - 2, &p.field)
	pane_hline(lay.box, lay.title_sep_y)

	if len(p.field.text) < PROJSEARCH_MIN_QUERY {
		hint := fmt.tprintf("Type at least %d characters to search", PROJSEARCH_MIN_QUERY)
		pane_text(inner.x + 1, lay.body_top, lay.left_w - 1, hint, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}

	end := min(p.scroll + lay.body_h, len(p.matches))
	for i in p.scroll ..< end {
		m := p.matches[i]
		y := lay.body_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, lay.left_w, fg, bg)
		}
		text := strings.trim_left(m.text, " \t")
		label := fmt.tprintf("%s:%d  %s", m.path, m.row + 1, text)
		pane_text(inner.x + 1, y, lay.left_w - 1, label, fg, bg)
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

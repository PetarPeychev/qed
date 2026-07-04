package main

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "lib:tb2"

Match :: struct {
	path: string,
	row:  int,
	col:  int,
	text: string,
}

ProjSearch :: struct {
	active:        bool,
	query:         [dynamic]u8,
	matches:       [dynamic]Match,
	selected:      int,
	scroll:        int,
	preview:       [dynamic]string,
	preview_start: int,
	preview_focus: int,
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
}

projsearch_destroy :: proc(p: ^ProjSearch) {
	projsearch_clear_matches(p)
	projsearch_clear_preview(p)
	delete(p.matches)
	delete(p.preview)
	delete(p.query)
}

projsearch_open :: proc(editor: ^Editor) {
	p := &editor.projsearch
	editor_set_message(editor, "")
	projsearch_clear_matches(p)
	projsearch_clear_preview(p)
	if !shell_command_exists("rg") {
		editor_set_message(editor, "ripgrep (rg) not found", true)
		return
	}
	p.active = true
	clear(&p.query)
	p.selected = 0
	p.scroll = 0
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
	query := string(p.query[:])
	if len(query) < PROJSEARCH_MIN_QUERY {
		return
	}
	cmd := fmt.ctprintf(
		"cd %s && rg --vimgrep -F -S -e %s 2>/dev/null | head -n %d",
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
	h := max(1, picker_layout(editor).preview_h)
	start := max(1, (m.row + 1) - h / 2)
	cmd := fmt.ctprintf("sed -n '%d,%dp' %s 2>/dev/null", start, start + h - 1, shell_quote(full))
	out, ok := shell_capture(cmd)
	if !ok {
		return
	}
	p.preview_start = start
	p.preview_focus = m.row + 1
	for line in strings.split_lines_iterator(&out) {
		append(&p.preview, strings.clone(line))
	}
}

projsearch_move :: proc(editor: ^Editor, delta: int) {
	p := &editor.projsearch
	if len(p.matches) == 0 {
		return
	}
	p.selected = clamp(p.selected + delta, 0, len(p.matches) - 1)
	list_h := picker_layout(editor).list_h
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if list_h > 0 && p.selected >= p.scroll + list_h {
		p.scroll = p.selected - list_h + 1
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
	case .Pgdn:
		projsearch_move(editor, picker_layout(editor).list_h)
	case .Pgup:
		projsearch_move(editor, -picker_layout(editor).list_h)
	case .Backspace, .Backspace2:
		if len(p.query) > 0 {
			resize(&p.query, len(p.query) - 1)
			projsearch_run(editor)
			projsearch_load_preview(editor)
		}
	case:
		if ev.ch >= 0x20 && !alt {
			bytes, n := utf8.encode_rune(ev.ch)
			append(&p.query, ..bytes[:n])
			projsearch_run(editor)
			projsearch_load_preview(editor)
		}
	}
}

projsearch_render :: proc(editor: ^Editor) {
	p := &editor.projsearch
	lay := picker_layout(editor)
	inner := pane_draw_box(lay.box)

	prompt := fmt.tprintf("> %s", string(p.query[:]))
	pane_text(inner.x + 1, inner.y, inner.w - 2, prompt, COLOR_PANE_PROMPT_FG, COLOR_PANE_BG)
	pane_hline(lay.box, inner.y + 1)

	if len(p.query) < PROJSEARCH_MIN_QUERY {
		hint := fmt.tprintf("Type at least %d characters to search", PROJSEARCH_MIN_QUERY)
		pane_text(inner.x + 1, lay.list_top, inner.w - 2, hint, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}

	end := min(p.scroll + lay.list_h, len(p.matches))
	for i in p.scroll ..< end {
		m := p.matches[i]
		y := lay.list_top + (i - p.scroll)
		fg, bg := COLOR_PANE_FG, COLOR_PANE_BG
		if i == p.selected {
			fg, bg = COLOR_PANE_SEL_FG, COLOR_PANE_SEL_BG
			pane_fill_row(inner.x, y, inner.w, fg, bg)
		}
		text := strings.trim_left(m.text, " \t")
		label := fmt.tprintf("%s:%d  %s", m.path, m.row + 1, text)
		pane_text(inner.x + 1, y, inner.w - 2, label, fg, bg)
	}

	pane_hline(lay.box, lay.sep_y)

	numw := linefind_number_width(p.preview_start + len(p.preview))
	for line, i in p.preview {
		if i >= lay.preview_h {
			break
		}
		lineno := p.preview_start + i
		y := lay.preview_top + i
		fg := COLOR_PANE_FG
		if lineno == p.preview_focus {
			fg = COLOR_PANE_PROMPT_FG
		}
		pane_text(inner.x + 1, y, inner.w - 2, linefind_label(numw, lineno - 1, line), fg, COLOR_PANE_BG)
	}

	cx := min(inner.x + 3 + len(p.query), inner.x + inner.w - 1)
	tb2.set_cursor(i32(cx), i32(inner.y))
}

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
	active:   bool,
	field:    TextField,
	matches:  [dynamic]Match,
	selected: int,
	scroll:   int,
	preview:  Preview,
}

projsearch_clear_matches :: proc(p: ^ProjSearch) {
	for m in p.matches {
		delete(m.path)
		delete(m.text)
	}
	clear(&p.matches)
}

projsearch_destroy :: proc(p: ^ProjSearch) {
	projsearch_clear_matches(p)
	preview_destroy(&p.preview)
	delete(p.matches)
	textfield_destroy(&p.field)
}

projsearch_open :: proc(editor: ^Editor) {
	p := &editor.projsearch
	editor_clear_message(editor)
	if !shell_command_exists("rg") {
		editor_log(editor, .Error, "Find", "ripgrep (rg) not found")
		projsearch_clear_matches(p)
		preview_reset(&p.preview)
		return
	}
	p.active = true
	keep := p.selected
	if text, ok := selection_single_line(editor_buffer(editor)); ok {
		textfield_set(&p.field, text)
		keep = 0
	}
	textfield_select_all(&p.field)
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
	preview_reset(&p.preview)
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
	if len(p.matches) == 0 {
		preview_reset(&p.preview)
		return
	}
	m := p.matches[p.selected]
	full, _ := filepath.join({editor.working_root, m.path}, context.temp_allocator)
	preview_set_file(&p.preview, full, m.row + 1, overlay_layout(editor).body_h)
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
	if !editor_open_path(editor, full) {
		return
	}

	buffer_undo_commit(editor_buffer(editor))
	editor_goto(editor, m.row, m.col)
}

projsearch_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	alt := ev_alt(ev)
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

projsearch_paste :: proc(editor: ^Editor, text: string) {
	p := &editor.projsearch
	if textfield_insert_flat(&p.field, text) {
		projsearch_run(editor)
		projsearch_load_preview(editor)
	}
}

projsearch_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	lay := overlay_layout(editor)
	if preview_wheel(&p.preview, ev, {lay.right_x, lay.body_top, lay.right_w, lay.body_h}, lay.body_h) {
		return
	}
	idx, activate := overlay_list_mouse(editor, ev, lay, len(p.matches), &p.scroll, &p.field, projsearch_close)
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

	preview_render(&p.preview, lay.right_x + 1, lay.body_top, lay.right_w - 1, lay.body_h)

	overlay_divider(lay)
}

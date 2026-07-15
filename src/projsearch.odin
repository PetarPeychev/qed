package main

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "lib:tb2"

PROJSEARCH_MAX :: 500
PROJSEARCH_DEBOUNCE_MS :: 120

Match :: struct {
	path: string,
	row:  int,
	col:  int,
	text: string,
}

ProjSearch :: struct {
	active:       bool,
	field:        TextField,
	matches:      [dynamic]Match,
	selected:     int,
	scroll:       int,
	scope:        [dynamic]string,
	from_tree:    bool,
	preview:      Preview,
	sub:          Subprocess,
	want:         bool,
	request_at:   time.Tick,
	pending_keep: int,
}

projsearch_clear_matches :: proc(p: ^ProjSearch) {
	for m in p.matches {
		delete(m.path)
		delete(m.text)
	}
	clear(&p.matches)
}

projsearch_clear_scope :: proc(p: ^ProjSearch) {
	for s in p.scope {
		delete(s)
	}
	clear(&p.scope)
}

projsearch_destroy :: proc(p: ^ProjSearch) {
	subprocess_kill(&p.sub)
	projsearch_clear_matches(p)
	projsearch_clear_scope(p)
	preview_destroy(&p.preview)
	delete(p.matches)
	delete(p.scope)
	textfield_destroy(&p.field)
}

projsearch_open :: proc(editor: ^Editor) {
	p := &editor.projsearch
	projsearch_clear_scope(p)
	p.from_tree = false
	projsearch_begin(editor)
}

projsearch_open_scoped :: proc(editor: ^Editor, paths: []string) {
	p := &editor.projsearch
	projsearch_clear_scope(p)
	for path in paths {
		append(&p.scope, strings.clone(path))
	}
	p.from_tree = true
	projsearch_begin(editor)
}

projsearch_begin :: proc(editor: ^Editor) {
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
	p.pending_keep = keep
	projsearch_queue(editor)
}

projsearch_close :: proc(editor: ^Editor) {
	p := &editor.projsearch
	p.active = false
	p.want = false
	subprocess_kill(&p.sub)
	projsearch_clear_matches(p)
	preview_reset(&p.preview)
}

projsearch_queue :: proc(editor: ^Editor) {
	p := &editor.projsearch
	p.want = true
	p.request_at = time.tick_now()
}

projsearch_edited :: proc(editor: ^Editor) {
	p := &editor.projsearch
	p.pending_keep = 0
	if len(textfield_str(&p.field)) < PROJSEARCH_MIN_QUERY {
		p.want = false
		subprocess_kill(&p.sub)
		projsearch_clear_matches(p)
		p.selected = 0
		p.scroll = 0
		preview_reset(&p.preview)
		return
	}
	projsearch_queue(editor)
}

projsearch_due :: proc(editor: ^Editor) -> bool {
	p := &editor.projsearch
	if !p.want {
		return false
	}
	return time.duration_milliseconds(time.tick_since(p.request_at)) >= f64(PROJSEARCH_DEBOUNCE_MS)
}

projsearch_running :: proc(editor: ^Editor) -> bool {
	p := &editor.projsearch
	return p.sub.running || p.want
}

projsearch_run_async :: proc(editor: ^Editor) {
	p := &editor.projsearch
	p.want = false
	subprocess_kill(&p.sub)
	query := textfield_str(&p.field)
	if len(query) < PROJSEARCH_MIN_QUERY {
		return
	}
	scope_args := ""
	if len(p.scope) > 0 {
		sb := strings.builder_make(context.temp_allocator)
		for path in p.scope {
			strings.write_byte(&sb, ' ')
			strings.write_string(&sb, shell_quote(path))
		}
		scope_args = strings.to_string(sb)
	}
	// stdin is the subprocess runner's (empty) body temp file, so without an
	// explicit </dev/null rg would search that empty stdin instead of the tree.
	cmd := fmt.tprintf(
		"rg --vimgrep -F -S -e %s%s </dev/null 2>/dev/null | head -n %d",
		shell_quote(query),
		scope_args,
		PROJSEARCH_MAX,
	)
	sub, serr, ok := subprocess_start(cmd, nil, editor.working_root)
	if ok {
		p.sub = sub
	} else {
		editor_log(editor, .Debug, "Find", fmt.tprintf("search spawn failed (%v)", serr))
	}
}

projsearch_pump :: proc(editor: ^Editor) -> bool {
	p := &editor.projsearch
	if !p.sub.running || !subprocess_drain(&p.sub) {
		return false
	}
	out := subprocess_output(&p.sub)
	projsearch_clear_matches(p)
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
	subprocess_destroy(&p.sub)
	slice.sort_by(p.matches[:], proc(a, b: Match) -> bool {
		if a.path != b.path {
			return a.path < b.path
		}
		if a.row != b.row {
			return a.row < b.row
		}
		return a.col < b.col
	})
	p.selected = clamp(p.pending_keep, 0, max(0, len(p.matches) - 1))
	p.pending_keep = 0
	body_h := overlay_layout(editor).body_h
	p.scroll = max(0, p.selected - body_h / 2)
	projsearch_load_preview(editor)
	return true
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
	from_tree := p.from_tree
	full, _ := filepath.join({editor.working_root, m.path}, context.temp_allocator)
	projsearch_close(editor)
	if !editor_open_path(editor, full) {
		return
	}
	if from_tree {
		filetree_close(editor)
	}

	buffer_undo_commit(editor_buffer(editor))
	editor_goto(editor, m.row, m.col)
}

projsearch_dispatch_key :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	if command_matches(ev, "Find in Files") {
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
			projsearch_edited(editor)
		}
	}
}

projsearch_paste :: proc(editor: ^Editor, text: string) {
	p := &editor.projsearch
	if textfield_insert_flat(&p.field, text) {
		projsearch_edited(editor)
	}
}

projsearch_dispatch_mouse :: proc(editor: ^Editor, ev: tb2.Event) {
	p := &editor.projsearch
	lay := overlay_layout(editor)
	if preview_wheel(&p.preview, ev, {lay.right_x, lay.inner.y, lay.right_w, lay.inner.h}, lay.inner.h) {
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

	prompt_w := lay.left_w - 1
	count := ""
	if len(p.matches) >= PROJSEARCH_MAX {
		count = fmt.tprintf("%d+", PROJSEARCH_MAX)
	} else if len(p.matches) > 0 {
		count = fmt.tprintf("%d", len(p.matches))
	}
	if count != "" {
		prompt_w = max(1, prompt_w - len(count) - 1)
	}
	overlay_prompt_render(inner.x + 1, inner.y, prompt_w, &p.field)
	if count != "" {
		pane_text(lay.div_x - len(count), inner.y, len(count), count, COLOR_PANE_SHORTCUT_FG, COLOR_PANE_BG)
	}

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

	preview_render(&p.preview, lay.right_x + 1, inner.y, lay.right_w - 1, inner.h)

	bottom := lay.box.y + lay.box.h - 1
	for y in lay.box.y + 1 ..< bottom {
		tb2.set_cell(i32(lay.div_x), i32(y), '│', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.box.y), '┬', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.div_x), i32(bottom), '┴', COLOR_PANE_BORDER, COLOR_PANE_BG)
	tb2.set_cell(i32(lay.box.x), i32(lay.title_sep_y), '├', COLOR_PANE_BORDER, COLOR_PANE_BG)
	for x in inner.x ..< lay.div_x {
		tb2.set_cell(i32(x), i32(lay.title_sep_y), '─', COLOR_PANE_BORDER, COLOR_PANE_BG)
	}
	tb2.set_cell(i32(lay.div_x), i32(lay.title_sep_y), '┤', COLOR_PANE_BORDER, COLOR_PANE_BG)
	pane_draw_scrollbar(lay.div_x, lay.body_top, lay.body_h, p.scroll, len(p.matches))
}

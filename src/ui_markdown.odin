package main

import "core:math"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"

// a markdown render runs in slices of this many milliseconds; the last finished render stays up meanwhile
md_slice_ms := 10

UiMarkdownJob :: struct {
	arena: vmem.Arena,
	job:   MdJob,
	w:     int,
}

UiMarkdown :: struct {
	source:  string,
	dir:     string,
	lang:    Language,
	w:       int,
	lines:   []MdLine,
	lines_w: int,
	rows:    int,
	arena:   vmem.Arena,
	job:     ^UiMarkdownJob,
}

ui_markdown_of :: proc(editor: ^Editor, node: ^UiNode) -> ^UiMarkdown {
	ui := &editor.ui
	md, found := ui.markdowns[node.identity]
	if !found {
		md = new(UiMarkdown)
		md.w = -1
		ui.markdowns[strings.clone(node.identity)] = md
	}
	if md.source != node.source || md.dir != node.path || md.lang != node.md_lang {
		delete(md.source)
		delete(md.dir)
		md.source, md.dir, md.lang = strings.clone(node.source), strings.clone(node.path), node.md_lang
		md.rows = strings.count(md.source, "\n") + 1
		ui_markdown_reset(md)
	}
	return md
}

// the last finished render stays on screen while a newer one runs in md_slice_ms steps
ui_markdown_lines :: proc(md: ^UiMarkdown, w: int) -> []MdLine {
	if md.w == w {
		return md.lines
	}
	if md.job != nil && md.job.w != w {
		ui_markdown_reset(md)
	}
	if md.job == nil {
		job := new(UiMarkdownJob)
		job.w = w
		context.temp_allocator = vmem.arena_allocator(&job.arena)
		md_job_start(&job.job, strings.clone(md.source, context.temp_allocator), w, md.lang, strings.clone(md.dir, context.temp_allocator))
		md.job = job
		ui_markdown_step(md, md_slice_ms)
	}
	return md.lines
}

ui_markdown_step :: proc(md: ^UiMarkdown, ms: int) -> (done: bool) {
	job := md.job
	if job == nil {
		return false
	}
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond) if ms >= 0 else time.Tick{}
	context.temp_allocator = vmem.arena_allocator(&job.arena)
	lines := md_job_step(&job.job, deadline)
	if !job.job.done {
		return false
	}
	vmem.arena_destroy(&md.arena)
	md.arena = job.arena
	md.lines, md.w, md.lines_w = lines, job.w, job.w
	free(job)
	md.job = nil
	return true
}

ui_markdown_reset :: proc(md: ^UiMarkdown) {
	md.w = -1
	if md.job != nil {
		vmem.arena_destroy(&md.job.arena)
		free(md.job)
		md.job = nil
	}
}

ui_markdown_free :: proc(md: ^UiMarkdown) {
	ui_markdown_reset(md)
	vmem.arena_destroy(&md.arena)
	delete(md.source)
	delete(md.dir)
	free(md)
}

ui_markdowns_busy :: proc(editor: ^Editor) -> bool {
	for _, md in editor.ui.markdowns {
		if md.job != nil {
			return true
		}
	}
	return false
}

ui_markdowns_sweep :: proc(editor: ^Editor) {
	ui := &editor.ui
	gone := make([dynamic]string, context.temp_allocator)
	for identity in ui.markdowns {
		if node := ui_find(ui, identity); node == nil || node.kind != .Markdown {
			append(&gone, identity)
		}
	}
	for identity in gone {
		key, md := delete_key(&ui.markdowns, identity)
		ui_markdown_free(md)
		delete(key)
	}
}

ui_markdowns_free :: proc(editor: ^Editor) {
	for key, md in editor.ui.markdowns {
		ui_markdown_free(md)
		delete(key)
	}
	delete(editor.ui.markdowns)
}

// the scroll holding a markdown: its offset is the markdown's scroll position
ui_markdown_scroller :: proc(editor: ^Editor, node: ^UiNode) -> ^UiState {
	if node.parent == nil || node.parent.kind != .Scroll {
		return nil
	}
	return ui_node_state(&editor.ui, node.parent)
}

// a pending source row or heading moves the holding scroll once lines for this width exist; view is its content rect
ui_markdown_resolve :: proc(md: ^UiMarkdown, state, scroller: ^UiState, view: Rect) {
	// a render for another width is still running: resolve against its lines, not the old ones
	if md.w < 0 || md.job != nil || scroller == nil {
		return
	}
	if state.md_heading != "" {
		for line, i in md.lines {
			if line.slug == state.md_heading {
				scroller.offset = i
				state.md_found = line.src + 1
				break
			}
		}
		delete(state.md_heading)
		state.md_heading = ""
	}
	if state.md_source > 0 {
		index := int(math.floor(ui_markdown_line_of_source(md, state.md_source - 1) + 0.5))
		// md_at is a terminal row: the line lands there, or as near as the document allows
		scroller.offset = index - clamp(state.md_at - 1 - view.y, 0, max(view.h - 1, 0)) if state.md_at > 0 else index
		state.md_source, state.md_at = 0, 0
	}
	scroller.offset = clamp(scroller.offset, 0, max(0, len(md.lines) - view.h))
	scroller.at_end = scroller.offset >= max(0, len(md.lines) - view.h)
}

// a block is a run of lines sharing a source row (a separating blank belongs to the block above); a source row inside
// one is placed proportionally between its first line and the next block's, so both directions interpolate alike
ui_markdown_line_of_source :: proc(md: ^UiMarkdown, source: f64) -> f64 {
	from_src, from_line := 0, 0
	for line, i in md.lines {
		if (i > 0 && line.src == md.lines[i - 1].src) || (i > 0 && line.src <= from_src) {
			continue
		}
		if f64(line.src) > source {
			return f64(from_line) + (source - f64(from_src)) / f64(line.src - from_src) * f64(i - from_line)
		}
		from_src, from_line = line.src, i
	}
	end_src := max(md.rows, from_src + 1)
	return f64(from_line) + clamp((source - f64(from_src)) / f64(end_src - from_src), 0, 1) * f64(len(md.lines) - from_line)
}

ui_markdown_source_of_line :: proc(md: ^UiMarkdown, line_index: int) -> f64 {
	// the top shows source row 0 even when the first rows render nothing (blanks, link references, comments)
	if line_index <= 0 {
		return 0
	}
	from_src, from_line := 0, 0
	for line, i in md.lines {
		if (i > 0 && line.src == md.lines[i - 1].src) || (i > 0 && line.src <= from_src) {
			continue
		}
		if i > line_index {
			return f64(from_src) + f64(line_index - from_line) / f64(i - from_line) * f64(line.src - from_src)
		}
		from_src, from_line = line.src, i
	}
	end_src := max(md.rows, from_src + 1)
	span := max(len(md.lines) - from_line, 1)
	return f64(from_src) + clamp(f64(line_index - from_line) / f64(span), 0, 1) * f64(end_src - from_src)
}

ui_render_markdown :: proc(editor: ^Editor, paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	md := ui_markdown_of(editor, node)
	lines := ui_markdown_lines(md, rect.w)
	first := clamp(paint.clip.y - rect.y, 0, len(lines))
	last := clamp(paint.clip.y + paint.clip.h - rect.y, first, len(lines))
	stale := false
	for i in first ..< last {
		line := lines[i]
		if line.image.id != 0 && !image_show(line.image) && len(line.spans) > 0 {
			state, known := image_state(line.image.id)
			stale ||= !known || state == .Failed
			spans := slice.clone(line.spans, context.temp_allocator)
			spans[len(spans) - 1] = line.loading
			line.spans = spans
		}
		md_draw_line(rect.x, rect.y + i, rect.w, line, paint.bg)
	}
	// an entry dropped or reprobed to a failure since this render: render again to re-resolve the path
	if stale && md.job == nil {
		ui_markdown_reset(md)
	}
}

ui_markdown_click :: proc(editor: ^Editor, node: ^UiNode, cell_x, cell_y: int) {
	md := ui_markdown_of(editor, node)
	row := cell_y - node.rect.y
	if row < 0 || row >= len(md.lines) {
		return
	}
	target := md_line_link(md.lines[row], cell_x - node.rect.x)
	if target == "" {
		return
	}
	target = strings.clone(target, context.temp_allocator)
	if node.handlers[.Link] != 0 && ui_handler_call(editor, node.owner, node.handlers[.Link], {target = target}) {
		return
	}
	if target[0] == '#' {
		state := ui_node_state(&editor.ui, node)
		delete(state.md_heading)
		state.md_heading = strings.clone(target[1:])
		ui_markdown_resolve(md, state, ui_markdown_scroller(editor, node), node.clip)
	}
}

// a re-wrap keeps the source row at the holding scroll's top, not its row count
ui_markdown_rewrap :: proc(editor: ^Editor, node: ^UiNode, md: ^UiMarkdown, w: int) {
	scroller := ui_markdown_scroller(editor, node)
	state := ui_node_state(&editor.ui, node)
	// the lines on screen may be older than a pending render, which reset `w`
	if md.lines_w == w || scroller == nil || state.md_source > 0 || len(md.lines) == 0 {
		return
	}
	state.md_source = ui_markdown_source_of_line(md, clamp(scroller.offset, 0, len(md.lines) - 1)) + 1
	state.md_at = 0
}

// the source row (0-based, fractional) at the holding scroll's top
ui_markdown_top_source :: proc(editor: ^Editor, node: ^UiNode) -> (f64, bool) {
	md, found := editor.ui.markdowns[node.identity]
	if !found || md.w < 0 || len(md.lines) == 0 {
		return 0, false
	}
	top := node.clip.y - node.rect.y
	if node.parent != nil && node.parent.kind == .Scroll {
		top = ui_node_state_peek(&editor.ui, node.parent).offset
	}
	return ui_markdown_source_of_line(md, clamp(top, 0, len(md.lines) - 1)), true
}

// the source rows (0-based) of the visible lines, nil before the first render
ui_markdown_sources :: proc(editor: ^Editor, node: ^UiNode) -> (sources: []int, rows: int) {
	md, found := editor.ui.markdowns[node.identity]
	if !found || md.w < 0 {
		return nil, 0
	}
	// the holding scroll's offset, not the last layout: a heading jump since then counts
	top := node.clip.y - node.rect.y
	if node.parent != nil && node.parent.kind == .Scroll {
		top = ui_node_state_peek(&editor.ui, node.parent).offset
	}
	first := clamp(top, 0, len(md.lines))
	last := clamp(top + node.clip.h, first, len(md.lines))
	sources = make([]int, last - first, context.temp_allocator)
	for line, i in md.lines[first:last] {
		sources[i] = line.src
	}
	return sources, len(md.lines)
}

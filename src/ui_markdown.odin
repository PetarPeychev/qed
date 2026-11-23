package main

import vmem "core:mem/virtual"
import "core:strings"
import "core:time"

UiMarkdownJob :: struct {
	arena: vmem.Arena,
	job:   MdJob,
	w:     int,
}

UiMarkdown :: struct {
	source: string,
	dir:    string,
	w:      int,
	lines:  []MdLine,
	arena:  vmem.Arena,
	job:    ^UiMarkdownJob,
}

ui_markdown_of :: proc(editor: ^Editor, node: ^UiNode) -> ^UiMarkdown {
	ui := &editor.ui
	md, found := ui.markdowns[node.identity]
	if !found {
		md = new(UiMarkdown)
		md.w = -1
		ui.markdowns[strings.clone(node.identity)] = md
	}
	if md.source != node.source || md.dir != node.path {
		delete(md.source)
		delete(md.dir)
		md.source, md.dir = strings.clone(node.source), strings.clone(node.path)
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
		md_job_start(&job.job, strings.clone(md.source, context.temp_allocator), w, .Plain, strings.clone(md.dir, context.temp_allocator))
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
	md.lines, md.w = lines, job.w
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

// a pending source row or heading resolves once the lines for this width exist
ui_markdown_settle :: proc(md: ^UiMarkdown, state: ^UiState, rect: Rect) {
	height := rect.h
	if md.w < 0 {
		return
	}
	if state.md_heading != "" {
		for line, i in md.lines {
			if line.slug == state.md_heading {
				state.scroll_row = i
				state.md_found = line.src + 1
				break
			}
		}
		delete(state.md_heading)
		state.md_heading = ""
	}
	if state.md_source > 0 {
		index := len(md.lines)
		for line, i in md.lines {
			if line.src >= state.md_source - 1 {
				index = i
				break
			}
		}
		// md_at is a terminal row: the line lands there, or as near as the document allows
		state.scroll_row = index - clamp(state.md_at - 1 - rect.y, 0, max(height - 1, 0)) if state.md_at > 0 else index
		state.md_source, state.md_at = 0, 0
	}
	state.scroll_row = clamp(state.scroll_row, 0, max(0, len(md.lines) - height))
}

ui_render_markdown :: proc(editor: ^Editor, paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	md := ui_markdown_of(editor, node)
	lines := ui_markdown_lines(md, rect.w)
	state := ui_node_state(&editor.ui, node)
	ui_markdown_settle(md, state, rect)
	for i in 0 ..< min(rect.h, len(lines) - state.scroll_row) {
		line := lines[state.scroll_row + i]
		if line.image.id != 0 {
			image_show(line.image)
		}
		md_draw_line(rect.x, rect.y + i, rect.w, line, paint.bg)
	}
}

ui_markdown_scroll :: proc(editor: ^Editor, node: ^UiNode, step: int) {
	md := ui_markdown_of(editor, node)
	state := ui_node_state(&editor.ui, node)
	state.scroll_row = clamp(state.scroll_row + step, 0, max(0, len(md.lines) - node.rect.h))
}

ui_markdown_key :: proc(editor: ^Editor, node: ^UiNode, chord: string) -> bool {
	page := max(node.rect.h - 1, 1)
	switch chord {
	case "Up":
		ui_markdown_scroll(editor, node, -1)
	case "Down":
		ui_markdown_scroll(editor, node, 1)
	case "PgUp":
		ui_markdown_scroll(editor, node, -page)
	case "PgDn", "Space":
		ui_markdown_scroll(editor, node, page)
	case "Home":
		ui_markdown_scroll(editor, node, -max(int))
	case "End":
		ui_markdown_scroll(editor, node, max(int) / 2)
	case:
		return false
	}
	return true
}

ui_markdown_click :: proc(editor: ^Editor, node: ^UiNode, cell_x, cell_y: int) {
	md := ui_markdown_of(editor, node)
	state := ui_node_state(&editor.ui, node)
	row := state.scroll_row + cell_y - node.rect.y
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
		for line, i in md.lines {
			if line.slug != "" && line.slug == target[1:] {
				state.scroll_row = i
				break
			}
		}
	}
}

// the source rows (0-based) of the visible lines, nil before the first render
ui_markdown_sources :: proc(editor: ^Editor, node: ^UiNode) -> (sources: []int, rows: int) {
	md, found := editor.ui.markdowns[node.identity]
	if !found || md.w < 0 {
		return nil, 0
	}
	state := ui_node_state_peek(&editor.ui, node)
	top := clamp(state.scroll_row, 0, len(md.lines))
	visible := md.lines[top:min(len(md.lines), top + node.rect.h)]
	sources = make([]int, len(visible), context.temp_allocator)
	for line, i in visible {
		sources[i] = line.src
	}
	return sources, len(md.lines)
}

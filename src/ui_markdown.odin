package main

import "core:math"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

md_wait_ms := 60
MD_POLL_MS :: 4

UiMarkdownJob :: struct {
	thread:     ^thread.Thread,
	arena:      vmem.Arena,
	code_arena: vmem.Arena,
	md:         MdJob,
	gen, w:     int,
}

UiMarkdown :: struct {
	source:     string,
	dir:        string,
	lang:       Language,
	rows:       int,
	gen:        int,
	open:       [dynamic]int,
	// the pieces on screen; a running job reads them, so they change only when it is adopted
	chunks:     []^MdChunk,
	// pieces a cancelled job finished, offered to the next one
	spare:      [dynamic]^MdChunk,
	code:       map[string][]string,
	code_arena: vmem.Arena,
	doc:        ^MdDoc,
	doc_w:      int,
	doc_gen:    int,
	doc_arena:  vmem.Arena,
	shown:      int,
	waited:     bool,
	flush:      bool,
	job:        ^UiMarkdownJob,
}

ui_markdown_get :: proc(editor: ^Editor, identity, source, dir: string, lang: Language) -> ^UiMarkdown {
	ui := &editor.ui
	md, found := ui.markdowns[identity]
	if !found {
		md = new(UiMarkdown)
		md.gen = 1
		ui.markdowns[strings.clone(identity)] = md
	}
	if md.source != source || md.dir != dir || md.lang != lang {
		delete(md.source)
		delete(md.dir)
		md.source, md.dir, md.lang = strings.clone(source), strings.clone(dir), lang
		md.rows = strings.count(md.source, "\n") + 1
		md.gen += 1
	}
	return md
}

ui_markdown_of :: proc(editor: ^Editor, node: ^UiNode) -> ^UiMarkdown {
	return ui_markdown_get(editor, node.identity, node.source, node.path, node.md_lang)
}

ui_markdown_job_run :: proc(t: ^thread.Thread) {
	job := (^UiMarkdownJob)(t.data)
	context.allocator = vmem.arena_allocator(&job.arena)
	context.temp_allocator = context.allocator
	md_layout(&job.md)
	md_input_free(&job.md.input)
}

ui_markdown_job_make :: proc(md: ^UiMarkdown, w: int) -> ^UiMarkdownJob {
	job := new(UiMarkdownJob)
	job.gen, job.w = md.gen, w
	allocator := vmem.arena_allocator(&job.arena)
	job.md.input = md_input_make(md.source, md.dir, md.lang, w, md.open[:], allocator)
	job.md.code_allocator = vmem.arena_allocator(&job.code_arena)
	if !md.flush {
		prev := make([dynamic]^MdChunk, 0, len(md.chunks) + len(md.spare), allocator)
		append(&prev, ..md.chunks)
		append(&prev, ..md.spare[:])
		job.md.prev = prev[:]
		job.md.prev_code = md.code
	}
	md.flush = false
	return job
}

ui_markdown_start :: proc(md: ^UiMarkdown, w: int) {
	job := ui_markdown_job_make(md, w)
	job.thread = thread.create(ui_markdown_job_run)
	job.thread.data = job
	md.job = job
	thread.start(job.thread)
}

ui_markdown_assemble :: proc(md: ^UiMarkdown, job: ^MdJob, count: int) {
	vmem.arena_destroy(&md.doc_arena)
	context.allocator = vmem.arena_allocator(&md.doc_arena)
	md.doc = md_doc_assemble(job.pieces[:count], job.chunks[:count])
}

ui_markdown_finish :: proc(md: ^UiMarkdown, job: ^UiMarkdownJob) {
	chunks := job.md.chunks[:job.md.ready]
	if sync.atomic_load(&job.md.cancel) || job.md.pieces == nil {
		for chunk in chunks {
			if !slice.contains(md.chunks, chunk) && !slice.contains(md.spare[:], chunk) {
				append(&md.spare, chunk)
			}
		}
		vmem.arena_destroy(&job.code_arena)
	} else {
		for old in md.chunks {
			if !slice.contains(chunks, old) {
				md_chunk_free(old)
			}
		}
		for old in md.spare {
			if !slice.contains(chunks, old) {
				md_chunk_free(old)
			}
		}
		clear(&md.spare)
		delete(md.chunks)
		md.chunks = slice.clone(chunks)
		md.shown = 0
		ui_markdown_assemble(md, &job.md, len(chunks))
		md.doc_w, md.doc_gen = job.w, job.gen
		vmem.arena_destroy(&md.code_arena)
		md.code_arena = job.code_arena
		md.code = job.md.code
	}
	vmem.arena_destroy(&job.arena)
	free(job)
}

ui_markdown_adopt :: proc(md: ^UiMarkdown) -> bool {
	job := md.job
	if job == nil {
		return false
	}
	if !thread.is_done(job.thread) {
		ready := sync.atomic_load(&job.md.ready)
		if len(md.chunks) > 0 || ready <= md.shown || sync.atomic_load(&job.md.cancel) {
			return false
		}
		md.shown = ready
		ui_markdown_assemble(md, &job.md, ready)
		md.doc_w, md.doc_gen = job.w, 0
		return true
	}
	thread.destroy(job.thread)
	md.job = nil
	ui_markdown_finish(md, job)
	return true
}

ui_markdown_render_now :: proc(md: ^UiMarkdown, w: int) -> ^MdDoc {
	if md.job != nil {
		sync.atomic_store(&md.job.md.cancel, true)
		thread.join(md.job.thread)
		ui_markdown_adopt(md)
	}
	job := ui_markdown_job_make(md, w)
	{
		context.allocator = vmem.arena_allocator(&job.arena)
		md_layout(&job.md)
		md_input_free(&job.md.input)
	}
	ui_markdown_finish(md, job)
	return md.doc
}

ui_markdown_doc :: proc(md: ^UiMarkdown, w: int) -> ^MdDoc {
	if w <= 0 || (md.doc != nil && md.doc_gen == md.gen && md.doc_w == w) {
		return md.doc
	}
	ui_markdown_adopt(md)
	if job := md.job; job != nil && (job.gen != md.gen || job.w != w) {
		sync.atomic_store(&job.md.cancel, true)
	}
	if md.job == nil && !(md.doc != nil && md.doc_gen == md.gen && md.doc_w == w) {
		ui_markdown_start(md, w)
	}
	if md.job != nil && md.doc == nil && !md.waited {
		md.waited = true
		deadline := time.tick_add(time.tick_now(), time.Duration(md_wait_ms) * time.Millisecond)
		for !thread.is_done(md.job.thread) && time.tick_diff(time.tick_now(), deadline) > 0 {
			time.sleep(200 * time.Microsecond)
		}
		ui_markdown_adopt(md)
	}
	return md.doc
}

ui_markdown_rows :: proc(md: ^UiMarkdown, w: int) -> int {
	doc := ui_markdown_doc(md, w)
	return len(doc.rows) if doc != nil else 0
}

ui_markdown_ready :: proc(md: ^UiMarkdown) -> bool {
	return md.doc != nil && md.doc_gen == md.gen && md.job == nil
}

ui_markdown_reset :: proc(md: ^UiMarkdown) {
	md.gen += 1
}

ui_markdown_free :: proc(md: ^UiMarkdown) {
	if job := md.job; job != nil {
		sync.atomic_store(&job.md.cancel, true)
		thread.join(job.thread)
		thread.destroy(job.thread)
		md.job = nil
		ui_markdown_finish(md, job)
	}
	for chunk in md.chunks {
		md_chunk_free(chunk)
	}
	for chunk in md.spare {
		md_chunk_free(chunk)
	}
	delete(md.chunks)
	delete(md.spare)
	vmem.arena_destroy(&md.code_arena)
	vmem.arena_destroy(&md.doc_arena)
	delete(md.source)
	delete(md.dir)
	delete(md.open)
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

ui_markdowns_done :: proc(editor: ^Editor) -> bool {
	for _, md in editor.ui.markdowns {
		if job := md.job; job != nil && (thread.is_done(job.thread) || (len(md.chunks) == 0 && sync.atomic_load(&job.md.ready) > md.shown)) {
			return true
		}
	}
	return false
}

ui_markdowns_adopt :: proc(editor: ^Editor) {
	for _, md in editor.ui.markdowns {
		ui_markdown_adopt(md)
	}
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

ui_markdown_anchor :: proc(doc: ^MdDoc, name: string) -> (int, bool) {
	if row, ok := doc.anchors[name]; ok {
		return row, true
	}
	decoded := name
	if strings.index_byte(name, '%') >= 0 {
		sb := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(name); i += 1 {
			if name[i] == '%' && i + 2 < len(name) {
				hi, lo := hex_digit(name[i + 1]), hex_digit(name[i + 2])
				if hi >= 0 && lo >= 0 {
					strings.write_byte(&sb, u8(hi * 16 + lo))
					i += 2
					continue
				}
			}
			strings.write_byte(&sb, name[i])
		}
		decoded = strings.to_string(sb)
	}
	for key, row in doc.anchors {
		if strings.equal_fold(key, decoded) {
			return row, true
		}
	}
	return 0, false
}

@(private = "file")
hex_digit :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

ui_markdown_resolve :: proc(md: ^UiMarkdown, state, scroller: ^UiState, view: Rect) {
	if !ui_markdown_ready(md) || scroller == nil {
		return
	}
	doc := md.doc
	if state.md_heading != "" {
		if row, ok := ui_markdown_anchor(doc, state.md_heading); ok {
			scroller.offset = row
			state.md_found = (doc.src[row] if row < len(doc.src) else 0) + 1
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
	scroller.offset = clamp(scroller.offset, 0, max(0, len(doc.rows) - view.h))
	scroller.at_end = scroller.offset >= max(0, len(doc.rows) - view.h)
}

// a block is a run of rows sharing a source row; a source row inside one is placed proportionally between its first
// row and the next block's, so both directions interpolate alike
ui_markdown_line_of_source :: proc(md: ^UiMarkdown, source: f64) -> f64 {
	src := md.doc.src
	from_src, from_line := 0, 0
	for s, i in src {
		if (i > 0 && s == src[i - 1]) || (i > 0 && s <= from_src) {
			continue
		}
		if f64(s) > source {
			return f64(from_line) + (source - f64(from_src)) / f64(s - from_src) * f64(i - from_line)
		}
		from_src, from_line = s, i
	}
	end_src := max(md.rows, from_src + 1)
	return f64(from_line) + clamp((source - f64(from_src)) / f64(end_src - from_src), 0, 1) * f64(len(src) - from_line)
}

ui_markdown_source_of_line :: proc(md: ^UiMarkdown, line_index: int) -> f64 {
	// the top shows source row 0 even when the first rows render nothing (blanks, link references, comments)
	if line_index <= 0 {
		return 0
	}
	src := md.doc.src
	from_src, from_line := 0, 0
	for s, i in src {
		if (i > 0 && s == src[i - 1]) || (i > 0 && s <= from_src) {
			continue
		}
		if i > line_index {
			return f64(from_src) + f64(line_index - from_line) / f64(i - from_line) * f64(s - from_src)
		}
		from_src, from_line = s, i
	}
	end_src := max(md.rows, from_src + 1)
	span := max(len(src) - from_line, 1)
	return f64(from_src) + clamp(f64(line_index - from_line) / f64(span), 0, 1) * f64(end_src - from_src)
}

ui_render_markdown :: proc(editor: ^Editor, paint: ^UiPaint, node: ^UiNode) {
	rect := node.rect
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	md := ui_markdown_of(editor, node)
	doc := ui_markdown_doc(md, rect.w)
	if doc == nil {
		return
	}
	first := clamp(paint.clip.y - rect.y, 0, len(doc.rows))
	last := clamp(paint.clip.y + paint.clip.h - rect.y, first, len(doc.rows))
	for i in first ..< last {
		md_draw_row(doc, i, rect.x, rect.y + i, rect.w, paint.bg)
	}
	stale := false
	dim := COLOR_PANE_SHORTCUT_FG
	for img in doc.images {
		rows := int(img.ref.rows)
		top, bottom := max(img.y, first), min(img.y + rows, last)
		if top >= bottom {
			continue
		}
		cols := min(int(img.ref.cols), rect.w - img.x)
		// the cache refused a file the render could size (a decode failure): its alt text, never another render
		if img.ref.id == 0 {
			if img.y >= first && img.y < last {
				text := strings.concatenate({"[image: ", img.alt, "]"}, context.temp_allocator) if img.alt != "" else "[image]"
				x := rect.x + img.x
				for cluster in md_clusters(text) {
					width := cluster_width(transmute([]u8)cluster)
					if x + width > rect.x + rect.w {
						break
					}
					cell_put_cluster(x, rect.y + img.y, transmute([]u8)cluster, dim, paint.bg)
					x += width
				}
			}
			continue
		}
		shown := image_show(img.ref)
		if !shown {
			state, known := image_state(img.ref.id)
			stale ||= !known || state == .Failed
		}
		for row in top ..< bottom {
			y := rect.y + row
			if shown {
				for col in 0 ..< cols {
					md_put_placeholder(rect.x + img.x + col, y, row - img.y, col, img.ref.id, paint.bg)
				}
				continue
			}
			text := image_box_row(row - img.y, int(img.ref.cols), rows, img.alt)
			x := rect.x + img.x
			for cluster in md_clusters(text) {
				if x >= rect.x + img.x + cols {
					break
				}
				cell_put_cluster(x, y, transmute([]u8)cluster, dim, paint.bg)
				x += cluster_width(transmute([]u8)cluster)
			}
		}
	}
	// an entry dropped or reprobed to a failure: a fresh render resolves the path again
	if stale && md.job == nil {
		md.flush = true
		ui_markdown_reset(md)
	}
}

ui_markdown_click :: proc(editor: ^Editor, node: ^UiNode, cell_x, cell_y: int) {
	md := ui_markdown_of(editor, node)
	doc := md.doc
	if doc == nil {
		return
	}
	col, row := cell_x - node.rect.x, cell_y - node.rect.y
	if index, ok := md_summary_at(doc, col, row); ok {
		if at, found := slice.linear_search(md.open[:], index); found {
			unordered_remove(&md.open, at)
		} else {
			append(&md.open, index)
		}
		ui_markdown_reset(md)
		editor.ui.dirty = true
		return
	}
	target := md_link_at(doc, col, row)
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
	if md.doc == nil || md.doc_w == w || scroller == nil || state.md_source > 0 || len(md.doc.rows) == 0 {
		return
	}
	if md.job != nil && md.job.w == w {
		return
	}
	state.md_source = ui_markdown_source_of_line(md, clamp(scroller.offset, 0, len(md.doc.rows) - 1)) + 1
	state.md_at = 0
}

// the source row (0-based, fractional) at the holding scroll's top
ui_markdown_top_source :: proc(editor: ^Editor, node: ^UiNode) -> (f64, bool) {
	md, found := editor.ui.markdowns[node.identity]
	if !found || md.doc == nil || len(md.doc.rows) == 0 {
		return 0, false
	}
	top := node.clip.y - node.rect.y
	if node.parent != nil && node.parent.kind == .Scroll {
		top = ui_node_state_peek(&editor.ui, node.parent).offset
	}
	return ui_markdown_source_of_line(md, clamp(top, 0, len(md.doc.rows) - 1)), true
}

// the source rows (0-based) of the visible rows, nil before the first render
ui_markdown_sources :: proc(editor: ^Editor, node: ^UiNode) -> (sources: []int, rows: int) {
	md, found := editor.ui.markdowns[node.identity]
	if !found || md.doc == nil {
		return nil, 0
	}
	// the holding scroll's offset, not the last layout: a heading jump since then counts
	top := node.clip.y - node.rect.y
	if node.parent != nil && node.parent.kind == .Scroll {
		top = ui_node_state_peek(&editor.ui, node.parent).offset
	}
	src := md.doc.src
	first := clamp(top, 0, len(src))
	last := clamp(top + node.clip.h, first, len(src))
	return slice.clone(src[first:last], context.temp_allocator), len(src)
}

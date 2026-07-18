package main

import "core:fmt"
import "core:strings"

LlmRequest :: struct {
	sub:      Subprocess,
	buf_path: string,
	original: string,
	from:     Cursor,
}

Llm :: struct {
	requests: [dynamic]LlmRequest,
}

llm_running :: proc(editor: ^Editor) -> bool {
	return len(editor.llm.requests) > 0
}

// Row ranges [lo, hi] that in-flight requests currently cover in buffer `b`,
// located live by the same content search the apply uses — so the highlight
// tracks edits above/below instead of going stale.
llm_active_rows :: proc(editor: ^Editor, b: ^Buffer, allocator := context.temp_allocator) -> [][2]int {
	rows := make([dynamic][2]int, allocator)
	for &req in editor.llm.requests {
		if req.buf_path != b.path {
			continue
		}
		from, to, ok := llm_locate(b, req.original, req.from)
		if !ok {
			continue
		}
		append(&rows, [2]int{from.row, selection_last_row(from, to)})
	}
	return rows[:]
}

llm_build_prompt :: proc(
	b: ^Buffer,
	instruction: string,
	from, to: Cursor,
	allocator := context.temp_allocator,
) -> string {
	last := len(b.lines) - 1
	selection := buffer_text_range(b, from, to, context.temp_allocator)
	prefix := buffer_text_range(b, {0, 0}, from, context.temp_allocator)
	suffix := buffer_text_range(b, to, {last, len(b.lines[last].text)}, context.temp_allocator)
	marked := fmt.tprintf("%s<<<SELECT\n%s\nSELECT>>>%s", prefix, selection, suffix)
	path := b.path if b.path != "" else "(unsaved buffer)"

	prompt, _ := strings.replace_all(LLM_EDIT_PROMPT, "{path}", path, context.temp_allocator)
	prompt, _ = strings.replace_all(prompt, "{instruction}", instruction, context.temp_allocator)
	prompt, _ = strings.replace_all(prompt, "{file}", marked, context.temp_allocator)
	prompt, _ = strings.replace_all(prompt, "{selection}", selection, allocator)
	return prompt
}

llm_chat_send :: proc(editor: ^Editor, instruction: string, from, to: Cursor) {
	if !module_enabled(.Ai) {
		return
	}
	if strings.trim_space(LLM_CHAT_COMMAND) == "" {
		editor_log(editor, .Error, "", "AI edit: llm.chat_command is empty")
		return
	}
	b := editor_buffer(editor)
	selection := buffer_text_range(b, from, to, context.temp_allocator)
	prompt := llm_build_prompt(b, instruction, from, to)
	editor_log(editor, .Debug, "AI", fmt.tprintf("prompt (%dB):\n%s", len(prompt), prompt))

	cmd := fmt.tprintf("%s 2>/dev/null", LLM_CHAT_COMMAND)
	sub, serr, ok := subprocess_start(cmd, transmute([]u8)prompt, editor.working_root)
	if !ok {
		editor_log(editor, .Error, "", "AI edit: could not start command")
		editor_log(editor, .Debug, "AI", fmt.tprintf("spawn failed: %s (%v)", LLM_CHAT_COMMAND, serr))
		return
	}

	append(
		&editor.llm.requests,
		LlmRequest{sub = sub, buf_path = strings.clone(b.path), original = strings.clone(selection), from = from},
	)
	editor_log(editor, .Debug, "AI", fmt.tprintf("request sent: %s (%dB prompt)", LLM_CHAT_COMMAND, len(prompt)))
	editor_log(editor, .Info, "", fmt.tprintf("AI edit sent (%d running)", len(editor.llm.requests)))
}

llm_pump :: proc(editor: ^Editor) -> bool {
	changed := false
	for i := 0; i < len(editor.llm.requests); {
		req := &editor.llm.requests[i]
		if subprocess_drain(&req.sub) {
			llm_apply(editor, req)
			llm_request_destroy(req)
			ordered_remove(&editor.llm.requests, i)
			changed = true
			continue
		}
		i += 1
	}
	return changed
}

llm_apply :: proc(editor: ^Editor, req: ^LlmRequest) {
	raw := subprocess_output(&req.sub)
	editor_log(editor, .Debug, "AI", fmt.tprintf("response (%dB):\n%s", len(raw), raw))
	if req.sub.exit_code != 0 {
		editor_log(editor, .Debug, "AI", fmt.tprintf("command exited %d (%dB reply)", req.sub.exit_code, len(raw)))
	}
	core := strings.trim_space(llm_extract_code(raw))
	if core == "" {
		editor_log(editor, .Debug, "AI", fmt.tprintf("no usable code block in reply (%dB raw)", len(raw)))
		editor_log(editor, .Error, "", "AI edit: empty result, discarded")
		return
	}
	idx := editor_find_buffer(editor, req.buf_path)
	if idx < 0 {
		editor_log(editor, .Error, "", "AI edit: buffer closed, discarded")
		return
	}
	b := &editor.buffers[idx]
	from, to, ok := llm_locate(b, req.original, req.from)
	if !ok {
		editor_log(editor, .Error, "", "AI edit discarded: block changed")
		return
	}
	editor_log(editor, .Debug, "AI", fmt.tprintf("applied at %d:%d (%dB)", from.row, from.col, len(core)))
	output := llm_reframe(core, req.original, context.temp_allocator)

	edit_open(b, .Atomic)
	edit_delete(b, from, to)
	end := edit_insert(b, from, output)
	buffer_undo_commit(b)

	b.cursor = cursor_translate_after_edit(b.cursor, from, to, end)
	if anchor, has := b.selection.?; has {
		b.selection = cursor_translate_after_edit(anchor, from, to, end)
	}
	cursor_goal_sync(b)

	if idx == editor.current {
		editor_scroll(editor)
	}
	editor_log(editor, .Info, "", "AI edit applied")
}

// Cancel any in-flight request whose block was edited (llm_locate can no longer
// find it): kill the subprocess right away so it stops burning tokens, and the
// highlight drops with it. Called after each edit.
llm_prune_edited :: proc(editor: ^Editor) {
	for i := 0; i < len(editor.llm.requests); {
		req := &editor.llm.requests[i]
		idx := editor_find_buffer(editor, req.buf_path)
		if idx >= 0 {
			if _, _, ok := llm_locate(&editor.buffers[idx], req.original, req.from); !ok {
				llm_request_kill(req)
				ordered_remove(&editor.llm.requests, i)
				editor_log(editor, .Info, "", "AI edit cancelled: block edited")
				continue
			}
		}
		i += 1
	}
}

llm_request_kill :: proc(req: ^LlmRequest) {
	subprocess_kill(&req.sub)
	delete(req.buf_path)
	delete(req.original)
}

llm_cancel_all :: proc(editor: ^Editor) {
	n := len(editor.llm.requests)
	for &req in editor.llm.requests {
		llm_request_kill(&req)
	}
	clear(&editor.llm.requests)
	if n > 0 {
		editor_log(editor, .Info, "", fmt.tprintf("Cancelled %d AI edit(s)", n))
	}
}

llm_request_destroy :: proc(req: ^LlmRequest) {
	subprocess_destroy(&req.sub)
	delete(req.buf_path)
	delete(req.original)
}

// Reattach the original selection's leading/trailing whitespace to the model's
// content, so an over-selected trailing newline or a leading indent survives the
// edit instead of being flattened by whatever the model chose to return.
llm_reframe :: proc(core, original: string, allocator := context.temp_allocator) -> string {
	left := strings.trim_left_space(original)
	lead := original[:len(original) - len(left)]
	if len(left) == 0 {
		return strings.concatenate({lead, core}, allocator)
	}
	right := strings.trim_right_space(original)
	trail := original[len(right):]
	return strings.concatenate({lead, core, trail}, allocator)
}

// Pull the replacement out of the model's reply. The model may reason/preamble
// first, then wrap the answer in a fenced code block; take the LAST fenced block
// (so example snippets inside the reasoning don't win). No fence -> best-effort
// whole reply. The leading "```lang" line and the closing fence are dropped.
llm_extract_code :: proc(s: string) -> string {
	close := strings.last_index(s, "```")
	if close < 0 {
		return strings.trim_space(s)
	}
	inner := s
	if open := strings.last_index(s[:close], "```"); open >= 0 {
		inner = s[open + 3:close]
	} else {
		inner = s[close + 3:]
	}
	if nl := strings.index_byte(inner, '\n'); nl >= 0 {
		inner = inner[nl + 1:]
	}
	return strings.trim_space(inner)
}

llm_locate :: proc(b: ^Buffer, original: string, hint: Cursor) -> (from, to: Cursor, ok: bool) {
	if len(original) == 0 {
		return {}, {}, false
	}
	last := len(b.lines) - 1
	text := buffer_text_range(b, {0, 0}, {last, len(b.lines[last].text)}, context.temp_allocator)

	starts := make([]int, len(b.lines), context.temp_allocator)
	acc := 0
	for r in 0 ..< len(b.lines) {
		starts[r] = acc
		acc += len(b.lines[r].text) + 1
	}
	hint_off := starts[hint.row] + hint.col

	best := -1
	best_dist := len(text) + 1
	at := 0
	for {
		idx := strings.index(text[at:], original)
		if idx < 0 {
			break
		}
		m := at + idx
		d := m - hint_off
		if d < 0 {
			d = -d
		}
		if d < best_dist {
			best_dist = d
			best = m
		}
		at = m + 1
	}
	if best < 0 {
		return {}, {}, false
	}
	return offset_to_cursor(starts, best), offset_to_cursor(starts, best + len(original)), true
}

cursor_translate_after_edit :: proc(c, from, to, new_end: Cursor) -> Cursor {
	if c.row < from.row || (c.row == from.row && c.col <= from.col) {
		return c
	}
	if c.row < to.row || (c.row == to.row && c.col <= to.col) {
		return new_end
	}
	out := c
	if c.row == to.row {
		out.col = new_end.col + (c.col - to.col)
	}
	out.row += new_end.row - to.row
	return out
}

offset_to_cursor :: proc(starts: []int, off: int) -> Cursor {
	row := 0
	for r in 0 ..< len(starts) {
		if starts[r] <= off {
			row = r
		} else {
			break
		}
	}
	return {row, off - starts[row]}
}

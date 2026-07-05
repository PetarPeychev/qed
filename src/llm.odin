package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

LlmRequest :: struct {
	process:  os.Process,
	stdout:   ^os.File,
	out:      strings.Builder,
	buf_path: string,
	original: string,
	from:     Cursor,
}

Llm :: struct {
	requests: [dynamic]LlmRequest,
}

@(private = "file")
g_llm_counter: int

llm_running :: proc(editor: ^Editor) -> bool {
	return len(editor.llm.requests) > 0
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
	if strings.trim_space(LLM_CHAT_COMMAND) == "" {
		editor_set_message(editor, "AI edit: llm.chat_command is empty", true)
		return
	}
	b := editor_buffer(editor)
	selection := buffer_text_range(b, from, to, context.temp_allocator)
	prompt := llm_build_prompt(b, instruction, from, to)
	if os.get_env("QED_LLM_DEBUG", context.temp_allocator) != "" {
		_ = os.write_entire_file("/tmp/qed-llm-prompt.txt", transmute([]u8)prompt)
	}

	g_llm_counter += 1
	tmp := fmt.tprintf("/tmp/qed-ai-%d-%d.tmp", posix.getpid(), g_llm_counter)
	fd, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		editor_set_message(editor, "AI edit: temp file failed", true)
		return
	}
	os.write(fd, transmute([]u8)prompt)
	os.close(fd)

	in_file, ierr := os.open(tmp, {.Read})
	if ierr != nil {
		os.remove(tmp)
		editor_set_message(editor, "AI edit: temp file failed", true)
		return
	}
	out_r, out_w, perr := os.pipe()
	if perr != nil {
		os.close(in_file)
		os.remove(tmp)
		editor_set_message(editor, "AI edit: pipe failed", true)
		return
	}

	posix.sigignore(.SIGPIPE)
	process, serr := os.process_start(
		{
			command = {"sh", "-c", fmt.tprintf("%s 2>/dev/null", LLM_CHAT_COMMAND)},
			working_dir = editor.working_root,
			stdin = in_file,
			stdout = out_w,
		},
	)
	os.close(in_file)
	os.close(out_w)
	os.remove(tmp)
	if serr != nil {
		os.close(out_r)
		editor_set_message(editor, "AI edit: could not start command", true)
		return
	}

	nfd := posix.FD(os.fd(out_r))
	flags := posix.fcntl(nfd, .GETFL)
	posix.fcntl(nfd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})

	append(
		&editor.llm.requests,
		LlmRequest {
			process = process,
			stdout = out_r,
			out = strings.builder_make(),
			buf_path = strings.clone(b.path),
			original = strings.clone(selection),
			from = from,
		},
	)
	editor_set_message(editor, fmt.tprintf("AI edit sent (%d running)", len(editor.llm.requests)))
}

llm_pump :: proc(editor: ^Editor) -> bool {
	changed := false
	for i := 0; i < len(editor.llm.requests); {
		req := &editor.llm.requests[i]
		fd := posix.FD(os.fd(req.stdout))
		buf: [16384]u8
		done := false
		for {
			n := posix.read(fd, &buf[0], len(buf))
			if n > 0 {
				strings.write_bytes(&req.out, buf[:n])
				continue
			}
			if n == 0 || posix.errno() != .EAGAIN {
				done = true
			}
			break
		}
		if done {
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
	os.close(req.stdout)
	_, _ = os.process_wait(req.process, time.Second)

	raw := strings.to_string(req.out)
	if os.get_env("QED_LLM_DEBUG", context.temp_allocator) != "" {
		_ = os.write_entire_file("/tmp/qed-llm-response.txt", transmute([]u8)raw)
	}
	core := strings.trim_space(llm_extract_code(raw))
	if core == "" {
		editor_set_message(editor, "AI edit: empty result, discarded", true)
		return
	}
	idx := editor_find_buffer(editor, req.buf_path)
	if idx < 0 {
		editor_set_message(editor, "AI edit: buffer closed, discarded", true)
		return
	}
	b := &editor.buffers[idx]
	from, to, ok := llm_locate(b, req.original, req.from)
	if !ok {
		editor_set_message(editor, "AI edit discarded: block changed", true)
		return
	}
	output := llm_reframe(core, req.original, context.temp_allocator)

	edit_open(b, .Atomic)
	removed := buffer_delete(b, from, to)
	append(&b.open.edits, Edit{.Insert, from, removed})
	end := buffer_insert(b, from, output)
	append(&b.open.edits, Edit{.Delete, from, strings.clone(output)})
	buffer_undo_commit(b)

	b.cursor = cursor_translate_after_edit(b.cursor, from, to, end)
	if anchor, has := b.selection.?; has {
		b.selection = cursor_translate_after_edit(anchor, from, to, end)
	}
	cursor_goal_sync(b)

	if idx == editor.current {
		editor_scroll(editor)
	}
	editor_set_message(editor, "AI edit applied")
}

llm_cancel_all :: proc(editor: ^Editor) {
	n := len(editor.llm.requests)
	for &req in editor.llm.requests {
		_ = os.process_kill(req.process)
		llm_request_destroy(&req)
	}
	clear(&editor.llm.requests)
	if n > 0 {
		editor_set_message(editor, fmt.tprintf("Cancelled %d AI edit(s)", n))
	}
}

llm_request_destroy :: proc(req: ^LlmRequest) {
	strings.builder_destroy(&req.out)
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

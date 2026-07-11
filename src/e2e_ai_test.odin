package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "lib:tb2"

// A model reply the chat command emits: prose framing a single fenced block, whose
// inner content is what the apply relocates and inserts (the last fence wins).
E2E_AI_REPLY :: "printf 'Sure, here is the rewrite:\\n```odin\\nreplaced_line := 42\\n```\\nDone.\\n'"

e2e_llm_await :: proc(e: ^E2E) -> bool {
	start := time.tick_now()
	for llm_running(&e.ed) {
		llm_pump(&e.ed)
		if time.duration_seconds(time.tick_since(start)) > 5 {
			return false
		}
		thread.yield()
	}
	return true
}

e2e_fim_await :: proc(e: ^E2E) -> bool {
	start := time.tick_now()
	for e.ed.fim.sub.running {
		fim_pump(&e.ed)
		if time.duration_seconds(time.tick_since(start)) > 5 {
			return false
		}
		thread.yield()
	}
	return true
}

// Select rows [from_row, to_row] whole-line and open Ctrl+K with `instruction`.
e2e_ai_send :: proc(e: ^E2E, from_row, to_row: int, instruction: string) {
	b := editor_buffer(&e.ed)
	b.selection = Cursor{from_row, 0}
	b.cursor = Cursor{to_row, len(b.lines[to_row].text)}
	e2e_key(e, .Ctrl_K)
	e2e_type(e, instruction)
	e2e_key(e, .Enter)
}

@(test)
e2e_ai_edit_applies_fenced_block :: proc(t: ^testing.T) {
	e := e2e_start("alpha\n    target line\ngamma")
	defer e2e_stop(&e)

	stub := e2e_stub_script(E2E_AI_REPLY)
	defer {
		os.remove(stub)
		delete(stub)
	}
	old := LLM_CHAT_COMMAND
	LLM_CHAT_COMMAND = stub
	defer LLM_CHAT_COMMAND = old

	b := editor_buffer(&e.ed)
	e2e_ai_send(&e, 1, 1, "rewrite")
	testing.expect(t, llm_running(&e.ed), "Ctrl+K should launch the chat command")

	testing.expect(t, e2e_llm_await(&e), "chat subprocess should finish")
	// The fenced block replaced the selection, with the line's leading indent reframed.
	testing.expect_value(t, string(b.lines[1].text[:]), "    replaced_line := 42")
	testing.expect_value(t, len(b.lines), 3)
	testing.expect_value(t, e.ed.message, "AI edit applied")

	// The whole apply is one undo group.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[1].text[:]), "    target line")
	testing.expect_value(t, len(b.lines), 3)
}

@(test)
e2e_ai_edit_relocates_to_nearest :: proc(t: ^testing.T) {
	e := e2e_start("    target line\nmiddle\n    target line\nend")
	defer e2e_stop(&e)

	stub := e2e_stub_script(E2E_AI_REPLY)
	defer {
		os.remove(stub)
		delete(stub)
	}
	old := LLM_CHAT_COMMAND
	LLM_CHAT_COMMAND = stub
	defer LLM_CHAT_COMMAND = old

	b := editor_buffer(&e.ed)
	// Two identical candidate lines; the edit must land on the selected one (row 2).
	e2e_ai_send(&e, 2, 2, "rewrite")
	testing.expect(t, e2e_llm_await(&e), "chat subprocess should finish")

	testing.expect_value(t, string(b.lines[0].text[:]), "    target line")
	testing.expect_value(t, string(b.lines[2].text[:]), "    replaced_line := 42")
}

@(test)
e2e_ai_edit_editing_range_cancels :: proc(t: ^testing.T) {
	e := e2e_start("    target line\ngamma")
	defer e2e_stop(&e)

	stub := e2e_stub_script(E2E_AI_REPLY)
	defer {
		os.remove(stub)
		delete(stub)
	}
	old := LLM_CHAT_COMMAND
	LLM_CHAT_COMMAND = stub
	defer LLM_CHAT_COMMAND = old

	b := editor_buffer(&e.ed)
	e2e_ai_send(&e, 0, 0, "rewrite")
	testing.expect(t, llm_running(&e.ed), "request in flight")

	// Editing the pending range (selection still covers row 0) mutates its content,
	// so llm_prune_edited can no longer locate it and drops the request.
	e2e_step(&e, tb2.Event{type = .Key, ch = 'Z'})
	testing.expect(t, !llm_running(&e.ed), "editing the range cancels the request")
	testing.expect_value(t, e.ed.message, "AI edit cancelled: block edited")

	testing.expect(t, e2e_llm_await(&e), "no request left to pump")
	testing.expect_value(t, string(b.lines[0].text[:]), "Z")
	testing.expect(t, !strings.contains(string(b.lines[0].text[:]), "replaced_line"), "no AI edit applied")
}

@(test)
e2e_ai_edit_no_block_untouched :: proc(t: ^testing.T) {
	e := e2e_start("hello\nworld")
	defer e2e_stop(&e)

	// Reply with no fenced block and nothing but whitespace: extraction yields
	// empty, so the buffer is left untouched and an error is shown.
	stub := e2e_stub_script("printf '   \\n'")
	defer {
		os.remove(stub)
		delete(stub)
	}
	old := LLM_CHAT_COMMAND
	LLM_CHAT_COMMAND = stub
	defer LLM_CHAT_COMMAND = old

	b := editor_buffer(&e.ed)
	e2e_ai_send(&e, 0, 0, "rewrite")
	testing.expect(t, e2e_llm_await(&e), "chat subprocess should finish")

	testing.expect_value(t, string(b.lines[0].text[:]), "hello")
	testing.expect_value(t, string(b.lines[1].text[:]), "world")
	testing.expect_value(t, e.ed.message, "AI edit: empty result, discarded")
	testing.expect(t, e.ed.message_level == .Error, "empty result is an error")
}

FimStub :: struct {
	json_path:      string,
	endpoint:       string,
	saved_endpoint: string,
	saved_debounce: int,
}

// Point the FIM curl at a local file:// URL serving `canned` JSON (curl reads the
// file and ignores the POST body), with a zero debounce and a dummy key present.
fim_stub_install :: proc(canned: string) -> FimStub {
	e2e_seq += 1
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.aprintf("%s/qed_e2e_fim_%d.json", tmp, e2e_seq)
	_ = os.write_entire_file(path, transmute([]u8)canned)

	s := FimStub {
		json_path      = path,
		endpoint       = fmt.aprintf("file://%s", path),
		saved_endpoint = LLM_COMPLETION_ENDPOINT,
		saved_debounce = LLM_COMPLETION_DEBOUNCE_MS,
	}
	LLM_COMPLETION_ENDPOINT = s.endpoint
	LLM_COMPLETION_DEBOUNCE_MS = 0
	os.set_env(LLM_COMPLETION_API_KEY_ENV, "dummy")
	return s
}

fim_stub_restore :: proc(s: FimStub) {
	LLM_COMPLETION_ENDPOINT = s.saved_endpoint
	LLM_COMPLETION_DEBOUNCE_MS = s.saved_debounce
	os.unset_env(LLM_COMPLETION_API_KEY_ENV)
	os.remove(s.json_path)
	delete(s.json_path)
	delete(s.endpoint)
}

// Arm and land a ghost: type `seed`, fire the request, pump to completion. Leaves
// the ghost showing at the cursor. Unwrapped so fim_render draws at the caret.
e2e_fim_ghost :: proc(t: ^testing.T, e: ^E2E, seed: string) {
	b := editor_buffer(&e.ed)
	b.wrap = false
	e.ed.fim.enabled = true
	e2e_type(e, seed)
	testing.expect(t, fim_due(&e.ed), "debounce satisfied, request due")
	fim_request(&e.ed)
	testing.expect(t, e2e_fim_await(e), "fim subprocess should finish")
}

@(test)
e2e_fim_ghost_renders_dimmed :: proc(t: ^testing.T) {
	if !shell_command_exists("curl") {
		return
	}
	e := e2e_start("")
	defer e2e_stop(&e)
	s := fim_stub_install(`{"choices":[{"message":{"content":"AAA\nBBB"}}]}`)
	defer fim_stub_restore(s)
	defer fim_dismiss(&e.ed)

	e2e_fim_ghost(t, &e, "ab")
	testing.expect_value(t, e.ed.fim.ghost, "AAA\nBBB")
	testing.expect(t, fim_ghost_active(&e.ed), "ghost active at cursor")

	e2e_render(&e)
	gutter := editor_gutter_width(&e.ed)
	// First ghost line inline at the caret (col 2), dimmed with COLOR_GHOST_FG.
	testing.expect_value(t, e2e_cell(&e, gutter + 2, 0), 'A')
	testing.expect_value(t, e2e_cell_fg(&e, gutter + 2, 0), COLOR_GHOST_FG)
	// The second line lands on the row below (reserved by the ghost gap).
	testing.expect_value(t, e2e_cell(&e, gutter, 1), 'B')
	testing.expect_value(t, e2e_cell_fg(&e, gutter, 1), COLOR_GHOST_FG)
}

@(test)
e2e_fim_tab_accepts_all :: proc(t: ^testing.T) {
	if !shell_command_exists("curl") {
		return
	}
	e := e2e_start("")
	defer e2e_stop(&e)
	s := fim_stub_install(`{"choices":[{"message":{"content":"AAA\nBBB"}}]}`)
	defer fim_stub_restore(s)
	defer fim_dismiss(&e.ed)

	b := editor_buffer(&e.ed)
	e2e_fim_ghost(t, &e, "ab")

	e2e_key(&e, .Tab)
	testing.expect_value(t, string(b.lines[0].text[:]), "abAAA")
	testing.expect_value(t, len(b.lines), 2)
	testing.expect_value(t, string(b.lines[1].text[:]), "BBB")
	testing.expect(t, !fim_ghost_active(&e.ed), "ghost consumed by accept")

	// The whole accept is one undo group.
	e2e_key(&e, .Ctrl_Z)
	testing.expect_value(t, string(b.lines[0].text[:]), "ab")
	testing.expect_value(t, len(b.lines), 1)
}

@(test)
e2e_fim_ctrl_right_accepts_word :: proc(t: ^testing.T) {
	if !shell_command_exists("curl") {
		return
	}
	e := e2e_start("")
	defer e2e_stop(&e)
	s := fim_stub_install(`{"choices":[{"message":{"content":"AAA\nBBB"}}]}`)
	defer fim_stub_restore(s)
	defer fim_dismiss(&e.ed)

	b := editor_buffer(&e.ed)
	e2e_fim_ghost(t, &e, "ab")

	e2e_key(&e, .Arrow_Right, .Ctrl)
	// Only the first word landed; the remainder stays as a live ghost.
	testing.expect_value(t, string(b.lines[0].text[:]), "abAAA")
	testing.expect_value(t, len(b.lines), 1)
	testing.expect(t, fim_ghost_active(&e.ed), "remaining ghost still shown")
}

@(test)
e2e_fim_edit_dismisses :: proc(t: ^testing.T) {
	if !shell_command_exists("curl") {
		return
	}
	e := e2e_start("")
	defer e2e_stop(&e)
	s := fim_stub_install(`{"choices":[{"message":{"content":"AAA\nBBB"}}]}`)
	defer fim_stub_restore(s)
	defer fim_dismiss(&e.ed)

	b := editor_buffer(&e.ed)
	e2e_fim_ghost(t, &e, "ab")

	// Any non-accept edit dismisses the ghost; only the typed char lands.
	e2e_type(&e, "z")
	testing.expect(t, !fim_ghost_active(&e.ed), "edit dismisses the ghost")
	testing.expect_value(t, string(b.lines[0].text[:]), "abz")
	testing.expect_value(t, len(b.lines), 1)
}

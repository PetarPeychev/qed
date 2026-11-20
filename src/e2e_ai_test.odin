package main

import "core:strings"
import "core:testing"

@(private = "file")
pred_both :: proc(e: ^E2E) -> bool {
	return e.ed.completion.active && inline_active(&e.ed)
}

@(private = "file")
pred_ready :: proc(e: ^E2E) -> bool {
	return len(editor_buffer(&e.ed).diags) > 0
}

@(private = "file")
coexist_start :: proc(t: ^testing.T) -> (E2E, bool) {
	if !shell_command_exists("python3") {
		return {}, false
	}
	e := e2e_lsp_start("top\n\n\n\n\n\n\n\n\n\n\n")
	e2e_plugin_config(&e, "ai", `{"completion_enabled": true, "completion_debounce_ms": 0, "completion_api_key_env": "HOME"}`)
	e2e_spawn_fake(&e, "curl", `{"choices":[{"message":{"content":"ha\nGHOST"}}]}`)
	testing.expect(t, e2e_lsp_wait(&e, pred_ready), "server should be ready")
	b := editor_buffer(&e.ed)
	b.wrap = false
	b.cursor = {10, 0}
	plugin_flush(&e.ed)
	e2e_type(&e, "alp")
	testing.expect(t, e2e_lsp_wait(&e, pred_both), "the popup and the ghost both show")
	return e, true
}

@(test)
e2e_ai_ghost_and_completion_tab :: proc(t: ^testing.T) {
	e, ok := coexist_start(t)
	if !ok {
		return
	}
	defer e2e_lsp_stop(&e)
	e2e_render(&e)
	testing.expect(t, e2e_grid_has(&e, "alphabet"), "the popup renders")
	testing.expect(t, e2e_grid_has(&e, "alpha"), "the ghost renders inline")
	testing.expect(t, e2e_grid_has(&e, "GHOST"), "its second line renders below")
	popup := -1
	for y in 0 ..< 10 {
		if strings.contains(e2e_row_text(&e, y), "alphabet") {
			popup = y
		}
	}
	testing.expect(t, popup >= 0, "a multi-line ghost floats the popup above the caret")
	testing.expect(t, strings.contains(e2e_row_text(&e, 11), "GHOST"), "the ghost's second line stays visible")

	e2e_key(&e, .Tab)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, string(b.lines[10].text[:]), "alpha")
	testing.expect_value(t, string(b.lines[11].text[:]), "GHOST")
	testing.expect(t, !e.ed.completion.active, "Tab closes the popup")
}

@(test)
e2e_ai_ghost_and_completion_enter :: proc(t: ^testing.T) {
	e, ok := coexist_start(t)
	if !ok {
		return
	}
	defer e2e_lsp_stop(&e)
	e2e_key(&e, .Enter)
	b := editor_buffer(&e.ed)
	testing.expect_value(t, string(b.lines[0].text[:]), "import added")
	testing.expect_value(t, string(b.lines[11].text[:]), "alphabet")
	testing.expect(t, !inline_active(&e.ed), "Enter takes the menu item and drops the ghost")
}

package main

import "core:strings"
import "core:testing"

@(private = "file")
e2e_screen :: proc(e: ^E2E) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for y in 0 ..< E2E_H {
		for x in 0 ..< E2E_W {
			strings.write_rune(&sb, e2e_cell(e, x, y))
		}
		strings.write_rune(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(test)
e2e_inspect_tokens :: proc(t: ^testing.T) {
	e := e2e_lang_start("x = foo\n", "insp.py")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	testing.expect_value(t, b.language, Language.Python)
	b.cursor = {0, 5} // inside the `foo` identifier

	// Toggle the passive inspector on and render.
	cmd_inspect_tokens(&e.ed)
	testing.expect(t, e.ed.inspect.active, "command toggles the inspector on")
	e2e_render(&e)
	testing.expect(t, !highlight_busy(b), "small python buffer parses synchronously")

	screen := e2e_screen(&e)
	testing.expect(t, strings.contains(screen, "Inspect Tokens"), "pane header renders")
	testing.expect(t, strings.contains(screen, "(identifier)"), "node ancestry line renders")
	testing.expect(t, strings.contains(screen, "python"), "effective language shown")
	testing.expect(t, strings.contains(screen, "@variable"), "winning capture shown")
	// @constant's #match? rejects the lowercase identifier — a predicate near-miss.
	testing.expect(t, strings.contains(screen, "@constant"), "near-miss capture shown")
	testing.expect(t, strings.contains(screen, "match?"), "the rejecting predicate is named")

	// Passive proof: a buffer keystroke still edits the buffer while the pane is open.
	b.cursor = {0, len(b.lines[0].text)}
	e2e_type(&e, "Z")
	testing.expect_value(t, string(b.lines[0].text[:]), "x = fooZ")
	testing.expect(t, e.ed.inspect.active, "typing does not close the passive pane")

	// Esc closes it (last in the cascade), and the pane clears.
	e2e_key(&e, .Esc)
	testing.expect(t, !e.ed.inspect.active, "Esc closes the inspector")
	e2e_render(&e)
	testing.expect(t, !strings.contains(e2e_screen(&e), "Inspect Tokens"), "pane gone after close")
}

@(test)
e2e_inspect_toggle_off :: proc(t: ^testing.T) {
	e := e2e_lang_start("x = foo\n", "insp2.py")
	defer e2e_stop(&e)

	cmd_inspect_tokens(&e.ed)
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_screen(&e), "Inspect Tokens"), "pane visible when on")

	cmd_inspect_tokens(&e.ed)
	testing.expect(t, !e.ed.inspect.active, "second toggle turns it off")
	e2e_render(&e)
	testing.expect(t, !strings.contains(e2e_screen(&e), "Inspect Tokens"), "pane cleared when off")
}

@(test)
e2e_inspect_big_unavailable :: proc(t: ^testing.T) {
	e := e2e_lang_start("x = 1\n", "insp3.py")
	defer e2e_stop(&e)

	b := editor_buffer(&e.ed)
	b.big = true
	cmd_inspect_tokens(&e.ed)
	e2e_render(&e)
	testing.expect(t, strings.contains(e2e_screen(&e), "unavailable"), "big file degrades to unavailable")
}

package main

import "core:fmt"
import "core:os"
import "lib:tb2"

print_help :: proc() {
	fmt.println("Usage: qed [FILE]")
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.println("Error: Too many arguments.")
		print_help()
		os.exit(1)
	}

	path := ""
	if len(os.args) == 2 {
		path = os.args[1]
	}
	editor := editor_init(path)
	defer editor_shutdown(&editor)


	ev: tb2.Event
	for !editor.quit {
		lsp_sync(&editor)
		if !editor.pasting {
			editor_render(&editor)
		}
		got_event := false
		for !got_event {
			if lsp_running() {
				if tb2.peek_event(&ev, LSP_POLL_MS) == .Ok {
					got_event = true
				}
				if lsp_pump(&editor) && !got_event {
					break
				}
				if !got_event {
					free_all(context.temp_allocator)
				}
			} else {
				tb2.poll_event(&ev)
				got_event = true
			}
		}
		if got_event {
			if !editor.pasting &&
			   ev.type == .Key &&
			   ev.key == .Esc &&
			   ev.ch == 0 &&
			   u8(ev.mod) == 0 {
				next: tb2.Event
				if tb2.peek_event(&next, ALT_ESC_TIMEOUT_MS) == .Ok && next.type == .Key && next.ch != 0 {
					next.mod = tb2.Mod(u8(next.mod) | u8(tb2.Mod.Alt))
					ev = next
				}
			}
			editor_dispatch(&editor, ev)
		}
		free_all(context.temp_allocator)
	}
}

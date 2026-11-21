package main

import "core:fmt"
import "core:os"
import "lib:tb2"

VERSION :: #config(QED_VERSION, "dev")

LSP_POLL_MS :: 30

print_help :: proc() {
	fmt.println("Usage: qed [PATH]      PATH is a file to open or a directory to work in")
	fmt.println("       qed --version")
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.println("Error: Too many arguments.")
		print_help()
		os.exit(1)
	}

	path := ""
	if len(os.args) == 2 {
		arg := os.args[1]
		switch arg {
		case "--version", "-v":
			fmt.printfln("qed %s", VERSION)
			os.exit(0)
		case "--help", "-h":
			print_help()
			os.exit(0)
		case:
			if len(arg) > 0 && arg[0] == '-' {
				fmt.printfln("Error: Unknown option '%s'.", arg)
				print_help()
				os.exit(1)
			}
			path = arg
		}
	}
	config_message, config_error := config_load()
	editor := editor_init(path)
	defer editor_shutdown(&editor)

	if config_message != "" {
		editor_log(&editor, .Warn if config_error else .Info, "", config_message)
	}


	ev: tb2.Event
	for !editor.quit {
		lsp_sync(&editor)
		if !editor.pasting {
			editor_render(&editor)
		}
		got_event := false
		for !got_event {
			if lsp_running() || highlight_jobs_busy(&editor) || term_alive(&editor) || pane_stack_pending(&editor) || walk_busy(&editor) || plugin_busy(&editor) || plugin_gc_due(&editor.plugins) {
				if tb2.peek_event(&ev, i32(plugin_timeout_ms(&editor, 0 if pane_stepping(&editor) || editor.terminal.more else LSP_POLL_MS))) == .Ok {
					got_event = true
				}
				redraw := false
				if lsp_running() && lsp_pump(&editor) {
					redraw = true
				}
				if term_pump(&editor) {
					redraw = true
				}
				if walk_pump(&editor) {
					redraw = true
				}
				if pane_stack_pump(&editor) {
					redraw = true
				}
				if completion_due(&editor) {
					editor.completion.want = false
					completion_request(&editor)
				}
				if highlight_jobs_pump(&editor) {
					redraw = true
				}
				if editor_maybe_poll_disk(&editor) {
					redraw = true
				}
				if plugin_pump(&editor) {
					redraw = true
				}
				if redraw && !got_event {
					break
				}
				if !got_event {
					free_all(context.temp_allocator)
				}
			} else {
				if tb2.peek_event(&ev, i32(plugin_timeout_ms(&editor, editor_poll_wait_ms(&editor)))) == .Ok {
					got_event = true
				} else {
					pumped := plugin_pump(&editor)
					if editor_maybe_poll_disk(&editor) || pumped {
						break
					}
					free_all(context.temp_allocator)
				}
			}
		}
		if got_event {
			editor_step(&editor, ev, main_peek)
			if plugin_due(&editor) {
				plugin_pump(&editor)
			}
		}
		free_all(context.temp_allocator)
	}
	editor_plugins_quit(&editor)
}

main_peek :: proc(ms: int) -> (tb2.Event, bool) {
	ev: tb2.Event
	if tb2.peek_event(&ev, i32(ms)) == .Ok {
		return ev, true
	}
	return {}, false
}

editor_step :: proc(editor: ^Editor, ev: tb2.Event, peek: proc(ms: int) -> (tb2.Event, bool)) {
	ev := ev
	pending: tb2.Event
	pending_ok := false
	if !editor.pasting && ev.type == .Key && ev.key == .Esc && ev.ch == 0 && u8(ev.mod) == 0 {
		if next, ok := peek(ALT_ESC_TIMEOUT_MS); ok {
			if next.type == .Key && next.ch != 0 {
				next.mod = tb2.Mod(u8(next.mod) | u8(tb2.Mod.Alt))
				ev = next
			} else {
				pending = next
				pending_ok = true
			}
		}
	}
	count := 1
	if ev.type == .Mouse && (ev.key == .Mouse_Wheel_Up || ev.key == .Mouse_Wheel_Down) {
		for {
			next, ok := peek(0)
			if !ok {
				break
			}
			if next.type == ev.type && next.key == ev.key && next.x == ev.x && next.y == ev.y && next.mod == ev.mod {
				count += 1
				continue
			}
			pending = next
			pending_ok = true
			break
		}
	}
	for _ in 0 ..< count {
		editor_dispatch(editor, ev)
	}
	if pending_ok {
		editor_dispatch(editor, pending)
	}
	pane_stack_sync(editor)
	if !editor.pasting {
		plugin_flush(editor)
	}
	plugin_gc_step(editor)
}

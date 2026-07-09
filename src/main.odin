package main

import "core:fmt"
import "core:os"
import "lib:tb2"

VERSION :: #config(QED_VERSION, "dev")

print_help :: proc() {
	fmt.println("Usage: qed [FILE]")
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

	editor_set_message(&editor, config_message, config_error)


	ev: tb2.Event
	for !editor.quit {
		lsp_sync(&editor)
		if !editor.pasting {
			editor_render(&editor)
		}
		got_event := false
		for !got_event {
			if lsp_running() || llm_running(&editor) || fim_active(&editor) || highlight_busy(editor_buffer(&editor)) || term_alive(&editor) || filetree_scanning(&editor) || git_stat_running(&editor) {
				if tb2.peek_event(&ev, i32(LSP_POLL_MS)) == .Ok {
					got_event = true
				}
				redraw := false
				if lsp_running() && lsp_pump(&editor) {
					redraw = true
				}
				if term_pump(&editor) {
					redraw = true
				}
				if llm_running(&editor) && llm_pump(&editor) {
					redraw = true
				}
				if fim_pump(&editor) {
					redraw = true
				}
				if filetree_scan_pump(&editor) {
					redraw = true
				}
				if git_stat_pump(&editor) {
					redraw = true
				}
				if fim_due(&editor) {
					fim_request(&editor)
				}
				if completion_due(&editor) {
					editor.completion.want = false
					completion_request(&editor)
				}
				if highlight_ready(editor_buffer(&editor)) {
					redraw = true
				}
				if editor_maybe_poll_disk(&editor) {
					redraw = true
				}
				if redraw && !got_event {
					break
				}
				if !got_event {
					free_all(context.temp_allocator)
				}
			} else {
				if tb2.peek_event(&ev, i32(DISK_POLL_MS)) == .Ok {
					got_event = true
				} else if editor_maybe_poll_disk(&editor) {
					break
				} else {
					free_all(context.temp_allocator)
				}
			}
		}
		if got_event {
			pending: tb2.Event
			pending_ok := false
			if !editor.pasting &&
			   ev.type == .Key &&
			   ev.key == .Esc &&
			   ev.ch == 0 &&
			   u8(ev.mod) == 0 {
				next: tb2.Event
				if tb2.peek_event(&next, i32(ALT_ESC_TIMEOUT_MS)) == .Ok {
					if next.type == .Key && next.ch != 0 {
						next.mod = tb2.Mod(u8(next.mod) | u8(tb2.Mod.Alt))
						ev = next
					} else {
						// Not an ALT-tagged printable: the Esc stands alone, but the
						// peeked event is already dequeued — dispatch it too.
						pending = next
						pending_ok = true
					}
				}
			}
			editor_dispatch(&editor, ev)
			if pending_ok {
				editor_dispatch(&editor, pending)
			}
			if llm_running(&editor) {
				llm_prune_edited(&editor)
			}
		}
		free_all(context.temp_allocator)
	}
}

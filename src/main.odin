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
			if lsp_running() || llm_running(&editor) || fim_active(&editor) || highlight_busy(editor_buffer(&editor)) || term_alive(&editor) || filetree_scanning(&editor) || git_stat_running(&editor) || projsearch_running(&editor) || filetree_filter_pending(&editor) || filetree_prewarming(&editor) {
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
				filetree_prewarm_pump(&editor)
				if git_stat_pump(&editor) {
					redraw = true
				}
				if projsearch_pump(&editor) {
					redraw = true
				}
				if projsearch_due(&editor) {
					projsearch_run_async(&editor)
				}
				if filetree_filter_due(&editor) {
					filetree_filter_flush(&editor)
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
			editor_step(&editor, ev, main_peek)
		}
		free_all(context.temp_allocator)
	}
}

main_peek :: proc(ms: int) -> (tb2.Event, bool) {
	ev: tb2.Event
	if tb2.peek_event(&ev, i32(ms)) == .Ok {
		return ev, true
	}
	return {}, false
}

// One iteration's post-event handling, split out of the main loop so the e2e
// harness can drive it with synthetic events: after a bare Esc the ALT retag
// peeks the next event (real peek_event in main, a queued event in tests) and
// re-tags a buffered printable as Alt; a non-printable peek dispatches on its own.
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
	editor_dispatch(editor, ev)
	if pending_ok {
		editor_dispatch(editor, pending)
	}
	if llm_running(editor) {
		llm_prune_edited(editor)
	}
}

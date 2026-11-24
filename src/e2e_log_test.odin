package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "lib:tb2"

log_open_now :: proc(e: ^E2E) {
	e2e_step(e, tb2.Event{type = .Key, ch = 'l', mod = tb2.Mod.Alt})
	e2e_ui_settle(e)
}

@(test)
e2e_log_opens_filters_and_closes :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	editor_log(&e.ed, .Info, "Git", "branch main", show = false)
	editor_log(&e.ed, .Debug, "LSP", "spawned ols", show = false)
	editor_log(&e.ed, .Error, "", "boom", show = false)
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Message Log") >= 0, "Alt+l opens the log")
	testing.expect(t, e2e_ui_find_row(&e, "branch main") >= 0, "info shows")
	testing.expect(t, e2e_ui_find_row(&e, "spawned ols") < 0, "debug is off by default")
	error_row := e2e_ui_find_row(&e, "boom")
	boom_x := visual_width(transmute([]u8)e2e_row_text(&e, error_row)[:max(strings.index(e2e_row_text(&e, error_row), "boom"), 0)]) if error_row >= 0 else 0
	testing.expect(t, error_row >= 0 && e2e_rgb(e2e_cell_fg(&e, boom_x, error_row)) == e2e_rgb(COLOR_ERROR_FG), "errors are colored")
	e2e_type(&e, "d")
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "spawned ols") >= 0, "d toggles debug")
	e2e_type(&e, "i")
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "branch main") < 0, "i toggles info")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Message Log") < 0, "Esc closes")
	e2e_type(&e, "i")
	e2e_ui_settle(&e)
	testing.expect_value(t, string(editor_buffer(&e.ed).lines[0].text[:]), "ix")
}

@(test)
e2e_log_select_copy_and_full_text :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	saved := clipboard_register
	clipboard_register = ""
	defer {
		delete(clipboard_register)
		clipboard_register = saved
	}
	for i in 0 ..< 5 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %d", i), show = false)
	}
	editor_log(&e.ed, .Warn, "Fmt", "first line\nsecond line", show = false)
	log_open_now(&e)
	e2e_key(&e, .Arrow_Up)
	e2e_key(&e, .Arrow_Up, tb2.Mod.Shift)
	e2e_ui_settle(&e)
	e2e_key(&e, .Ctrl_C, tb2.Mod.Ctrl)
	e2e_ui_settle(&e)
	testing.expect_value(t, clipboard_register, "entry 3\nentry 4")
	for _ in 0 ..< 10 {
		e2e_key(&e, .Arrow_Down)
	}
	e2e_key(&e, .Arrow_Up)
	e2e_key(&e, .Enter)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "second line") >= 0, "Enter shows the full text")
	e2e_key(&e, .Esc)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "second line") < 0, "Esc goes back to the list")
	testing.expect(t, e2e_ui_find_row(&e, "Message Log") >= 0, "the list stays")
}

@(test)
e2e_log_follows_new_entries_and_eviction :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	for i in 0 ..< LOG_MAX {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, fmt.tprintf("entry %04d", LOG_MAX - 1)) >= 0, "opens at the end")
	editor_log(&e.ed, .Info, "", "late arrival", show = false)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "late arrival") >= 0, "a new entry shows while at the end")
	testing.expect(t, e2e_ui_find_row(&e, "entry 0000") < 0, "evicted entries leave")
	count := 0
	for list in e.ed.ui.lists {
		if list.feed.active {
			count = len(list.records)
		}
	}
	testing.expect_value(t, count, LOG_MAX)
}

@(test)
e2e_log_history_and_source :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	editor_log(&e.ed, .Info, "Alpha", "from alpha", show = false)
	editor_log(&e.ed, .Info, "Beta", "from beta", show = false)
	message := ut_plugin_run(&e, `return {setup = function()
	qed.command{name = "Run", run = function()
		local only = qed.messages{source = "Alpha"}
		local all = qed.messages{levels = {info = true}}
		qed.message(("%d %s"):format(only:count(), tostring(all:count() >= 2)))
	end}
end}`)
	testing.expect(t, strings.has_prefix(message, "1 true"), message)
}

@(test)
e2e_log_outside_click_closes :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Message Log") >= 0, "the log opens")
	e2e_mouse(&e, 0, 0)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "Message Log") < 0, "an outside click closes it")
}

@(private = "file")
log_click_text :: proc(e: ^E2E, text: string) -> bool {
	y := e2e_ui_find_row(e, text)
	if y < 0 {
		return false
	}
	row := e2e_row_text(e, y)
	x := strings.rune_count(row[:strings.index(row, text)])
	e2e_mouse(e, x, y)
	e2e_ui_settle(e)
	return true
}

@(test)
e2e_log_chips_click_persist_and_follow_binds :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	editor_log(&e.ed, .Debug, "LSP", "spawned ols", show = false)
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "spawned ols") < 0, "debug is off by default")
	testing.expect(t, log_click_text(&e, "debug"), "the debug chip shows")
	testing.expect(t, e2e_ui_find_row(&e, "spawned ols") >= 0, "a chip click toggles its filter")
	e2e_key(&e, .Esc)
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "spawned ols") >= 0, "filters persist across reopening")
	e2e_key(&e, .Esc)
	e2e_plugin_config(&e, "log", `{"keybinds": {"Toggle Debug": "F7"}}`)
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "F7 debug") >= 0, "the chip shows the rebound key")
}

@(test)
e2e_log_wheel_unsticks_follow :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	for i in 0 ..< 200 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %04d", i), show = false)
	}
	log_open_now(&e)
	y := e2e_ui_find_row(&e, "entry 0199")
	testing.expect(t, y >= 0, "opens at the end")
	for _ in 0 ..< 5 {
		e2e_mouse(&e, 20, y, .Mouse_Wheel_Up)
	}
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "entry 0199") < 0, "the wheel scrolls up")
	editor_log(&e.ed, .Info, "", "late arrival", show = false)
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "late arrival") < 0, "scrolled up, a new entry does not pull the view down")
}

@(test)
e2e_log_history_toggle_and_range_survive :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_new_ui(&e)
	editor_log(&e.ed, .Info, "", "from a past session", show = false)
	e.ed.log[len(e.ed.log) - 1].seeded = true
	for i in 0 ..< 4 {
		editor_log(&e.ed, .Info, "", fmt.tprintf("entry %d", i), show = false)
	}
	log_open_now(&e)
	testing.expect(t, e2e_ui_find_row(&e, "past session") < 0, "history is off by default")
	e2e_type(&e, "h")
	e2e_ui_settle(&e)
	testing.expect(t, e2e_ui_find_row(&e, "past session") >= 0, "h shows past sessions")
	e2e_type(&e, "h")
	e2e_ui_settle(&e)
	e2e_key(&e, .Arrow_Up)
	e2e_step(&e, tb2.Event{type = .Key, key = .Arrow_Up, mod = tb2.Mod.Shift})
	node := ui_find(&e.ed.ui, "#log/log_rows")
	from := ui_node_state_peek(&e.ed.ui, node).extend_from
	testing.expect(t, from != "", "a range is selected")
	editor_log(&e.ed, .Info, "", "late arrival", show = false)
	e2e_ui_settle(&e)
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, node).extend_from, from)
}

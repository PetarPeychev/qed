package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "lib:tb2"

GATE_W :: 160
GATE_H :: 48
GATE_ITERS :: 20
GATE_CAP_MS :: 3000.0

GateRow :: struct {
	name:          string,
	budget, limit: f64,
	value:         f64,
	skipped:       string,
}

@(private = "file")
gate_rows: [dynamic]GateRow

@(private = "file")
gate_dir: string

@(private = "file")
gate_record :: proc(budget, value: f64, name: string, skipped := "") {
	limit := budget * (3 if budget < 50 else 2)
	append(&gate_rows, GateRow{strings.clone(name), budget, limit, value, strings.clone(skipped)})
}

@(private = "file")
gate_open :: proc(path: string, wrap := true) -> (E2E, f64) {
	e2e_enter()
	e2e_apply_size(GATE_W, GATE_H)
	saved := LINE_WRAP
	LINE_WRAP = wrap
	start := time.tick_now()
	ed := editor_init(path, headless = true)
	editor_render(&ed)
	ms := ms_since(start)
	LINE_WRAP = saved
	free_all(context.temp_allocator)
	return E2E{ed = ed, path = strings.clone(path), resized = true}, ms
}

@(private = "file")
gate_close :: proc(e: ^E2E) {
	editor_shutdown(&e.ed)
	json.destroy_value(e.cfg)
	delete(e.path)
	e2e_apply_size(E2E_W, E2E_H)
	sync.mutex_unlock(&e2e_lock)
	free_all(context.temp_allocator)
}

@(private = "file")
gate_settle :: proc(e: ^E2E, max_ms := 20000.0) -> f64 {
	start := time.tick_now()
	for ms_since(start) < max_ms {
		busy := highlight_busy(editor_buffer(&e.ed)) || walk_busy(&e.ed) || pane_stack_pending(&e.ed) || plugin_busy(&e.ed) || e2e_plugin_yielding(e)
		highlight_ready(editor_buffer(&e.ed))
		walk_pump(&e.ed)
		pane_stack_pump(&e.ed, true)
		plugin_pump(&e.ed)
		free_all(context.temp_allocator)
		if !busy {
			break
		}
		if os.get_env("QED_GATE_DEBUG", context.temp_allocator) != "" && int(ms_since(start)) % 1000 == 0 {
			fmt.eprintfln("settle busy: hl %v walk %v pane %v plugin %v yield %v", highlight_busy(editor_buffer(&e.ed)), walk_busy(&e.ed), pane_stack_pending(&e.ed), plugin_busy(&e.ed), e2e_plugin_yielding(e))
		}
		time.sleep(time.Millisecond)
	}
	editor_render(&e.ed)
	free_all(context.temp_allocator)
	return ms_since(start)
}

@(private = "file")
gate_frame :: proc(e: ^E2E, ev: tb2.Event) {
	e2e_step(e, ev)
	pane_stack_pump(&e.ed, true)
	editor_render(&e.ed)
	free_all(context.temp_allocator)
}

@(private = "file")
gate_mean :: proc(e: ^E2E, ev: tb2.Event, undo := false) -> f64 {
	total := 0.0
	n := 0
	for n < GATE_ITERS && total < GATE_CAP_MS {
		start := time.tick_now()
		gate_frame(e, ev)
		total += ms_since(start)
		n += 1
	}
	if undo {
		for _ in 0 ..< n {
			e2e_key(e, .Backspace)
		}
		editor_render(&e.ed)
		free_all(context.temp_allocator)
	}
	return total / f64(n)
}

@(private = "file")
key :: proc(k: tb2.Key, mod: tb2.Mod = {}) -> tb2.Event {
	return tb2.Event{type = .Key, key = k, mod = mod}
}

@(private = "file")
char :: proc(ch: rune, mod: tb2.Mod = {}) -> tb2.Event {
	return tb2.Event{type = .Key, ch = ch, mod = mod}
}

@(private = "file")
wheel :: proc(down: bool) -> tb2.Event {
	return tb2.Event{type = .Mouse, key = .Mouse_Wheel_Down if down else .Mouse_Wheel_Up, x = 40, y = 10}
}

@(private = "file")
gate_place :: proc(e: ^E2E, row, col: int) {
	b := editor_buffer(&e.ed)
	b.cursor = {min(row, len(b.lines) - 1), col}
	b.selection = nil
	editor_scroll(&e.ed)
	editor_render(&e.ed)
	free_all(context.temp_allocator)
}

@(private = "file")
gate_file :: proc(name: string, highlight := false) {
	path := fmt.tprintf("%s/%s", gate_dir, name)
	saved_big := BIG_FILE_BYTES
	if highlight {
		BIG_FILE_BYTES = max(int)
	}
	defer BIG_FILE_BYTES = saved_big
	e, open_ms := gate_open(path)
	defer gate_close(&e)
	b := editor_buffer(&e.ed)
	tag := fmt.aprintf("%s, no big cutoff", name) if highlight else fmt.aprintf("%s", name)
	defer delete(tag)
	label := fmt.tprintf("%s (%d lines%s)", tag, len(b.lines), ", big" if b.big else "")
	gate_record(300, open_ms, fmt.tprintf("open %s", label))
	gate_settle(&e)
	gate_place(&e, len(b.lines) / 2, 0)
	gate_record(16, gate_mean(&e, char('x'), undo = true), fmt.tprintf("keystroke %s", tag))
	gate_record(16, gate_mean(&e, wheel(true)), fmt.tprintf("scroll step %s", tag))
	gate_place(&e, len(b.lines) / 2, 0)
	gate_record(16, gate_mean(&e, key(.Arrow_Down)), fmt.tprintf("arrow down %s", tag))
}

@(private = "file")
gate_long :: proc(name: string, row: int, wrap: bool) {
	path := fmt.tprintf("%s/%s", gate_dir, name)
	e, open_ms := gate_open(path, wrap)
	defer gate_close(&e)
	b := editor_buffer(&e.ed)
	tag := fmt.aprintf("%s wrap %s", name, "on" if wrap else "off")
	defer delete(tag)
	gate_record(300, open_ms, fmt.tprintf("open %s", tag))
	gate_settle(&e)
	mid := len(b.lines[row].text) / 2
	gate_place(&e, row, mid)
	gate_record(50, gate_mean(&e, char('x'), undo = true), fmt.tprintf("type %s", tag))
	gate_record(50, gate_mean(&e, key(.Arrow_Right)), fmt.tprintf("arrow right %s", tag))
	gate_record(50, gate_mean(&e, key(.Arrow_Down)), fmt.tprintf("arrow down %s", tag))
	gate_place(&e, row, mid)
	gate_record(50, gate_mean(&e, key(.Arrow_Right, .Shift)), fmt.tprintf("select %s", tag))
	gate_place(&e, max(row - 5, 0), 0)
	gate_record(50, gate_mean(&e, wheel(true)), fmt.tprintf("scroll step %s", tag))
	gate_place(&e, row, mid)
	gate_frame(&e, key(.Ctrl_F))
	total := 0.0
	for r in "functi" {
		start := time.tick_now()
		gate_frame(&e, char(r))
		total += ms_since(start)
	}
	gate_record(50, total / 6, fmt.tprintf("search keystroke %s", tag))
	e2e_key(&e, .Esc)
}

@(private = "file")
gate_pane_filter :: proc(e: ^E2E, text: string) -> f64 {
	total := 0.0
	for r in text {
		start := time.tick_now()
		gate_frame(e, char(r))
		gate_settle(e, 5000)
		total += ms_since(start)
	}
	return total / f64(len(text))
}

@(private = "file")
gate_panes :: proc(has_rg: bool) {
	repo := fmt.tprintf("%s/repo", gate_dir)
	cwd, _ := os.get_working_directory(context.allocator)
	defer delete(cwd)
	os.change_directory(repo)
	defer os.change_directory(cwd)

	{
		test_slice_on = true
		clear(&test_slice_max)
		e, _ := gate_open("")
		defer gate_close(&e)
		gate_settle(&e)
		start := time.tick_now()
		filetree_open_all(&e.ed)
		editor_render(&e.ed)
		gate_record(300, ms_since(start), "file tree open (100k files)")
		gate_settle(&e)
		gate_record(300, ms_since(start), "file tree walk landed (100k files)")
		gate_record(50, gate_pane_filter(&e, "file0123"), "file tree filter keystroke")
		gate_record(16, gate_mean(&e, key(.Arrow_Down)), "file tree arrow")
		gate_frame(&e, key(.Esc))
		gate_settle(&e)

		start = time.tick_now()
		gate_frame(&e, char('g', .Alt))
		gate_record(300, ms_since(start), "Git tab open (50k changed)")
		gate_settle(&e)
		gate_record(16, gate_mean(&e, key(.Arrow_Down)), "Git tab arrow")
		gate_record(50, test_slice_max["filetree"], "plugin slice filetree (repo)")
		gate_record(50, test_slice_max["git"], "plugin slice git (repo)")
		test_slice_on = false
		gate_frame(&e, key(.Esc))
		gate_settle(&e)

		start = time.tick_now()
		gate_frame(&e, key(.Ctrl_P))
		gate_record(300, ms_since(start), "palette open")
		gate_record(50, gate_pane_filter(&e, "togg"), "palette filter keystroke")
		gate_frame(&e, key(.Esc))

		if has_rg {
			start = time.tick_now()
			gate_frame(&e, char('F', .Alt))
			gate_record(300, ms_since(start), "find in files open")
			gate_record(50, gate_pane_filter(&e, "file 4"), "find in files keystroke")
			gate_frame(&e, key(.Esc))
		} else {
			gate_record(300, 0, "find in files open", "no rg")
			gate_record(50, 0, "find in files keystroke", "no rg")
		}
	}
	{
		e, _ := gate_open(fmt.tprintf("%s/lines1m.txt", gate_dir))
		defer gate_close(&e)
		gate_settle(&e)
		start := time.tick_now()
		gate_frame(&e, key(.Ctrl_G))
		gate_record(300, ms_since(start), "go to line open (1M lines)")
		gate_record(50, gate_pane_filter(&e, "5000"), "go to line filter keystroke (1M lines)")
		gate_frame(&e, key(.Esc))
		start = time.tick_now()
		gate_frame(&e, key(.Ctrl_P))
		gate_record(300, ms_since(start), "palette open (1M lines)")
		gate_frame(&e, key(.Esc))
	}
}

@(private = "file")
gate_plugins :: proc() {
	{
		test_slice_on = true
		clear(&test_slice_max)
		e, _ := gate_open(fmt.tprintf("%s/conflicts.lua", gate_dir))
		defer gate_close(&e)
		gate_settle(&e)
		gate_place(&e, 9 * 1000 + 2, 0)
		gate_record(16, gate_mean(&e, char('z'), undo = true), "keystroke in conflict block (2000 blocks)")
		gate_settle(&e)
		gate_record(50, test_slice_max["conflict"], "plugin slice conflict (2000 blocks)")
		test_slice_on = false
	}
	{
		e, _ := gate_open(fmt.tprintf("%s/huge.md", gate_dir))
		defer gate_close(&e)
		gate_settle(&e)
		test_slice_on = true
		clear(&test_slice_max)
		start := time.tick_now()
		gate_frame(&e, char('p', .Alt))
		gate_record(300, ms_since(start), "markdown preview open (100k lines)")
		gate_settle(&e)
		gate_place(&e, 50_000, 0)
		gate_record(16, gate_mean(&e, char('x'), undo = true), "keystroke with markdown preview")
		gate_settle(&e)
		gate_record(50, test_slice_max["markdown"], "plugin slice markdown (100k lines)")
		test_slice_on = false
	}
	{
		src := fmt.tprintf("%s/lines100k.c", gate_dir)
		data, _ := os.read_entire_file(src, context.allocator)
		dst := fmt.tprintf("%s/format-save.c", gate_dir)
		_ = os.write_entire_file(dst, data)
		delete(data)
		e, _ := gate_open(dst)
		defer gate_close(&e)
		gate_settle(&e)
		e2e_plugin_config(&e, "format", `{"trim_whitespace_on_save": true, "final_newline_on_save": true}`)
		gate_settle(&e)
		test_slice_on = true
		clear(&test_slice_max)
		start := time.tick_now()
		gate_frame(&e, key(.Ctrl_S))
		gate_settle(&e)
		gate_record(50, ms_since(start), "save with format fixups (100k lines)")
		gate_record(50, test_slice_max["format"], "plugin slice format (100k lines)")
		test_slice_on = false
	}
}

@(test)
bench_gate :: proc(t: ^testing.T) {
	gate_dir = os.get_env("QED_GATE", context.allocator)
	defer delete(gate_dir)
	if gate_dir == "" {
		return
	}
	defer {
		for r in gate_rows {
			delete(r.name)
			delete(r.skipped)
		}
		clear(&gate_rows)
	}
	only := os.get_env("QED_GATE_ONLY", context.temp_allocator)
	want :: proc(only, part: string) -> bool {
		if only == "" {
			return true
		}
		for tok in strings.split(only, ",", context.temp_allocator) {
			if tok == part {
				return true
			}
		}
		return false
	}
	_, rg_err := os.stat("/usr/bin/rg", context.temp_allocator)
	has_rg := e2e_run("command -v rg >/dev/null 2>&1") || rg_err == nil

	if want(only, "files") {
		names := []string{"lines100k.c", "lines100k.py", "lines100k.js", "lines100k.odin", "mixed10mb.c", "huge.md", "odd.txt", "lines1m.txt"}
		if pick := os.get_env("QED_GATE_FILES", context.allocator); pick != "" {
			names = strings.split(pick, ",", context.allocator)
		}
		for name in names {
			gate_file(name)
		}
		if len(names) > 2 {
			gate_file("lines100k.c", highlight = true)
			gate_file("mixed10mb.c", highlight = true)
		}
	}
	if want(only, "long") || want(only, "longoff") {
		gate_long("minified5mb.js", 0, false)
		gate_long("longline1mb.json", 1003, false)
	}
	if want(only, "long") || want(only, "longon") {
		gate_long("minified5mb.js", 0, true)
		gate_long("longline1mb.json", 1003, true)
	}
	if want(only, "panes") {
		gate_panes(has_rg)
	}
	if want(only, "plugins") {
		gate_plugins()
	}

	fmt.eprintfln("\n%-56s %8s %8s %10s  %s", "measure", "budget", "limit", "ms", "result")
	num :: proc(v: f64, prec := 0) -> string {return fmt.tprintf("%.*f", prec, v)}
	for r in gate_rows {
		if r.skipped != "" {
			fmt.eprintfln("%-56s %8s %8s %10s  SKIP (%s)", r.name, num(r.budget), num(r.limit), "-", r.skipped)
			continue
		}
		verdict := "ok" if r.value <= r.budget else ("over budget" if r.value <= r.limit else "FAIL")
		fmt.eprintfln("%-56s %8s %8s %10s  %s", r.name, num(r.budget), num(r.limit), num(r.value, 2), verdict)
		testing.expectf(t, r.value <= r.limit, "%s: %.2f ms > limit %.0f ms", r.name, r.value, r.limit)
	}
}

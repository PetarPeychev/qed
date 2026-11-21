package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "lib:tb2"

GATE_W :: 160
GATE_H :: 48
GATE_ITERS :: 20
GATE_CAP_MS :: 3000.0

// .Open rows are known over budget (tracked in TODO.md): reported, not enforced; flip to .Gate once fixed
GateMode :: enum {
	Gate,
	Open,
	Info,
}

GateStat :: struct {
	mean, p95, max: f64,
	n:              int,
}

GateRow :: struct {
	name:          string,
	budget, limit: f64,
	stat:          GateStat,
	skipped:       string,
	mode:          GateMode,
}

@(private = "file")
gate_rows: [dynamic]GateRow

@(private = "file")
gate_dir: string

@(private = "file")
gate_record :: proc(budget: f64, stat: GateStat, name: string, mode := GateMode.Gate, skipped := "") {
	limit := budget * (3 if budget < 50 else 2)
	append(&gate_rows, GateRow{strings.clone(name), budget, limit, stat, strings.clone(skipped), mode})
	fmt.eprintfln("gate: %s: mean %.2f p95 %.2f max %.2f ms", name, stat.mean, stat.p95, stat.max)
}

@(private = "file")
one :: proc(ms: f64) -> GateStat {
	return GateStat{ms, ms, ms, 1}
}

@(private = "file")
gate_stat :: proc(samples: []f64) -> GateStat {
	if len(samples) == 0 {
		return {}
	}
	slice.sort(samples)
	sum := 0.0
	for v in samples {
		sum += v
	}
	return GateStat{sum / f64(len(samples)), samples[min(len(samples) - 1, int(f64(len(samples)) * 0.95))], samples[len(samples) - 1], len(samples)}
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
gate_mean :: proc(e: ^E2E, ev: tb2.Event, undo := false) -> GateStat {
	samples := make([dynamic]f64, context.allocator)
	defer delete(samples)
	total := 0.0
	for len(samples) < GATE_ITERS && total < GATE_CAP_MS {
		start := time.tick_now()
		gate_frame(e, ev)
		ms := ms_since(start)
		append(&samples, ms)
		total += ms
	}
	if undo {
		for _ in 0 ..< len(samples) {
			e2e_key(e, .Backspace)
		}
		editor_render(&e.ed)
		free_all(context.temp_allocator)
	}
	return gate_stat(samples[:])
}

@(private = "file")
gate_keys :: proc(e: ^E2E, text: string, settle := false) -> GateStat {
	samples := make([dynamic]f64, context.allocator)
	defer delete(samples)
	for r in text {
		start := time.tick_now()
		gate_frame(e, char(r))
		if settle {
			gate_settle(e, 5000)
		}
		append(&samples, ms_since(start))
	}
	return gate_stat(samples[:])
}

@(private = "file")
gate_adopt :: proc(e: ^E2E) -> f64 {
	b := editor_buffer(&e.ed)
	worst := 0.0
	start := time.tick_now()
	for ms_since(start) < 20000 {
		for highlight_busy(b) && !highlight_ready(b) && ms_since(start) < 20000 {
			time.sleep(time.Millisecond)
		}
		at := time.tick_now()
		editor_render(&e.ed)
		free_all(context.temp_allocator)
		worst = max(worst, ms_since(at))
		if !highlight_busy(b) {
			break
		}
	}
	return worst
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
	gate_record(300, one(open_ms), fmt.tprintf("open %s", label), .Open if name == "lines1m.txt" else .Gate)
	gate_settle(&e)
	gate_place(&e, len(b.lines) / 2, 0)
	gate_record(16, gate_mean(&e, char('x'), undo = true), fmt.tprintf("keystroke %s", tag))
	gate_record(16, gate_mean(&e, wheel(true)), fmt.tprintf("scroll step %s", tag))
	gate_place(&e, len(b.lines) / 2, 0)
	gate_record(16, gate_mean(&e, key(.Arrow_Down)), fmt.tprintf("arrow down %s", tag))
	gate_frame(&e, key(.Ctrl_F))
	gate_record(50, gate_keys(&e, "§§§"), fmt.tprintf("search keystroke, no match %s", tag))
	gate_frame(&e, key(.Esc))
}

@(private = "file")
gate_long :: proc(name: string, row: int, wrap: bool) {
	path := fmt.tprintf("%s/%s", gate_dir, name)
	e, open_ms := gate_open(path, wrap)
	defer gate_close(&e)
	b := editor_buffer(&e.ed)
	tag := fmt.aprintf("%s wrap %s", name, "on" if wrap else "off")
	defer delete(tag)
	open_wrap := GateMode.Gate
	gate_record(300, one(open_ms), fmt.tprintf("open %s", tag))
	gate_settle(&e)
	mid := len(b.lines[row].text) / 2
	gate_place(&e, row, mid)
	gate_record(50, gate_mean(&e, char('x'), undo = true), fmt.tprintf("type %s", tag), open_wrap)
	gate_record(50, one(gate_adopt(&e)), fmt.tprintf("frame adopting a reparse %s", tag))
	gate_record(50, gate_mean(&e, key(.Arrow_Right)), fmt.tprintf("arrow right %s", tag))
	gate_record(50, gate_mean(&e, key(.Arrow_Down)), fmt.tprintf("arrow down %s", tag))
	gate_place(&e, row, len(b.lines[row].text))
	gate_record(50, gate_mean(&e, key(.Arrow_Left)), fmt.tprintf("arrow left from line end %s", tag))
	gate_place(&e, row, mid)
	gate_record(50, gate_mean(&e, key(.Arrow_Right, .Shift)), fmt.tprintf("select %s", tag))
	gate_place(&e, max(row - 5, 0), 0)
	gate_record(50, gate_mean(&e, wheel(true)), fmt.tprintf("scroll step %s", tag))
	gate_place(&e, row, mid)
	gate_frame(&e, key(.Ctrl_F))
	gate_record(50, gate_keys(&e, "functi"), fmt.tprintf("search keystroke %s", tag), open_wrap)
	e2e_key(&e, .Esc)
}

@(private = "file")
gate_pane_filter :: proc(e: ^E2E, text: string) -> GateStat {
	return gate_keys(e, text, settle = true)
}

// rows stream in over frames: every frame while it runs carries an arrow, as a held key would
@(private = "file")
gate_expand_all :: proc(e: ^E2E) {
	clear(&test_slice_max)
	frames := make([dynamic]f64, context.allocator)
	defer delete(frames)
	rss := test_rss_mb("VmRSS")
	start := time.tick_now()
	gate_frame(e, char('e', .Alt))
	append(&frames, ms_since(start))
	p := ft_pane(&e.ed)
	for p != nil && pane_tree_loading(p) && ms_since(start) < 20000 {
		at := time.tick_now()
		e2e_step(e, key(.Arrow_Down))
		walk_pump(&e.ed)
		pane_stack_pump(&e.ed)
		plugin_pump(&e.ed)
		editor_render(&e.ed)
		free_all(context.temp_allocator)
		append(&frames, ms_since(at))
		p = ft_pane(&e.ed)
	}
	rows := len(p.list.source.entries) if p != nil else 0
	gate_record(16, gate_stat(frames[:]), fmt.tprintf("file tree expand all, per frame (%d frames)", len(frames)))
	gate_record(300, one(ms_since(start)), fmt.tprintf("file tree expand all complete (%d rows)", rows), .Info)
	gate_record(64, one(test_rss_mb("VmRSS") - rss), "file tree expand all, RSS growth in MB")
	gate_settle(e)
	gate_record(50, one(test_slice_max["filetree"]), "plugin slice filetree, expand all")
	gate_record(16, gate_mean(e, key(.Arrow_Down)), "file tree arrow, all expanded")
	if p := ft_pane(&e.ed); p != nil {
		p.list.sel, p.list.scroll = 0, 0
	}
	gate_record(16, gate_mean(e, key(.Enter)), "file tree toggle a dir, all expanded")
	start = time.tick_now()
	gate_frame(e, char('e', .Alt))
	gate_record(16, one(ms_since(start)), "file tree collapse all")
	gate_settle(e)
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
		defer test_slice_on = false
		clear(&test_slice_max)
		test_gc_max = 0
		e, _ := gate_open("")
		defer gate_close(&e)
		gate_settle(&e)
		gate_record(50, one(test_slice_max["git"]), "plugin slice git, startup (50k changed)", .Gate)
		gate_record(50, one(test_slice_max["filetree"]), "plugin slice filetree, startup")

		clear(&test_slice_max)
		start := time.tick_now()
		filetree_open_all(&e.ed)
		editor_render(&e.ed)
		gate_record(300, one(ms_since(start)), "file tree open (100k files)")
		for walk_busy(&e.ed) && ms_since(start) < 20000 {
			walk_pump(&e.ed)
			time.sleep(time.Millisecond)
		}
		gate_record(300, one(ms_since(start)), "file tree walk landed (100k files)", .Info)
		gate_settle(&e)
		gate_record(50, one(test_slice_max["filetree"]), "plugin slice filetree, tree open (100k files)")
		gate_record(50, one(test_slice_max["git"]), "plugin slice git, tree open (50k changed)", .Gate)
		gate_record(50, gate_pane_filter(&e, "file0123"), "file tree filter keystroke")
		gate_record(16, gate_mean(&e, key(.Arrow_Down)), "file tree arrow")
		// this Esc only clears the filter: the tree stays open, so the next chord switches tabs as it always did
		gate_frame(&e, key(.Esc))
		gate_settle(&e)
		gate_expand_all(&e)

		clear(&test_slice_max)
		start = time.tick_now()
		gate_frame(&e, char('g', .Alt))
		gate_record(300, one(ms_since(start)), "Git tab open (50k changed)")
		gate_settle(&e)
		gate_record(300, one(ms_since(start)), "Git tab populated (50k changed)", .Info)
		gate_record(16, gate_mean(&e, key(.Arrow_Down)), "Git tab arrow")
		gate_record(50, one(test_slice_max["filetree"]), "plugin slice filetree, Git tab (50k changed)", .Gate)
		gate_record(50, one(test_slice_max["git"]), "plugin slice git, Git tab (50k changed)")
		gate_frame(&e, key(.Esc))
		gate_settle(&e)
		gate_record(16, one(test_gc_max), "plugin GC step, repo panes (50k changed)")

		start = time.tick_now()
		gate_frame(&e, key(.Ctrl_P))
		gate_record(300, one(ms_since(start)), "palette open")
		gate_record(50, gate_pane_filter(&e, "togg"), "palette filter keystroke")
		gate_frame(&e, key(.Esc))

		if has_rg {
			start = time.tick_now()
			gate_frame(&e, char('F', .Alt))
			gate_record(300, one(ms_since(start)), "find in files open")
			gate_record(50, gate_keys(&e, "file 4"), "find in files keystroke")
			gate_frame(&e, key(.Esc))
		} else {
			gate_record(300, {}, "find in files open", skipped = "no rg")
			gate_record(50, {}, "find in files keystroke", skipped = "no rg")
		}
	}
	{
		e, _ := gate_open(fmt.tprintf("%s/lines1m.txt", gate_dir))
		defer gate_close(&e)
		gate_settle(&e)
		start := time.tick_now()
		gate_frame(&e, key(.Ctrl_G))
		gate_record(300, one(ms_since(start)), "go to line open (1M lines)")
		gate_record(50, gate_pane_filter(&e, "5000"), "go to line filter keystroke (1M lines)")
		gate_frame(&e, key(.Esc))
		start = time.tick_now()
		gate_frame(&e, key(.Ctrl_P))
		gate_record(300, one(ms_since(start)), "palette open (1M lines)")
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
		// the first incremental reparse runs inline and, being slow, moves the buffer off-thread (Highlight.slow)
		gate_frame(&e, char('z'))
		e2e_key(&e, .Backspace)
		gate_settle(&e)
		gate_record(16, gate_mean(&e, char('z'), undo = true), "keystroke in conflict block (2000 blocks)")
		gate_settle(&e)
		gate_record(50, one(test_slice_max["conflict"]), "plugin slice conflict (2000 blocks)")
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
		gate_record(300, one(ms_since(start)), "markdown preview open (100k lines)", .Gate)
		gate_settle(&e)
		gate_record(300, one(ms_since(start)), "markdown preview rendered (100k lines)", .Info)
		gate_place(&e, 50_000, 0)
		gate_record(16, gate_mean(&e, char('x'), undo = true), "keystroke with markdown preview")
		gate_settle(&e)
		gate_record(50, one(test_slice_max["markdown"]), "plugin slice markdown (100k lines)", .Gate)
		test_slice_on = false
	}
	{
		src := fmt.tprintf("%s/lines100k.c", gate_dir)
		data, _ := os.read_entire_file(src, context.allocator)
		tmp, _ := os.temp_dir(context.temp_allocator)
		dst := fmt.aprintf("%s/qed-gate-format-%d.c", tmp, os.get_pid())
		defer delete(dst)
		defer os.remove(dst)
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
		gate_record(50, one(ms_since(start)), "save with format fixups (100k lines)", .Gate)
		gate_record(50, one(test_slice_max["format"]), "plugin slice format (100k lines)", .Gate)
		test_slice_on = false
	}
}

@(test)
bench_gate :: proc(t: ^testing.T) {
	// the runner's per-test rollback stack is neither thread-safe (walk workers share context.allocator) nor what qed runs on
	context.allocator = runtime.heap_allocator()
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
	if data, err := os.read_entire_file("/proc/loadavg", context.temp_allocator); err == nil {
		load, _ := strconv.parse_f64(strings.fields(string(data), context.temp_allocator)[0])
		cores := os.get_processor_core_count()
		fmt.eprintfln("gate: load average %.2f on %d cores", load, cores)
		if load > f64(cores) && os.get_env("QED_GATE_ANY_LOAD", context.temp_allocator) == "" {
			testing.expectf(t, false, "load average %.2f exceeds %d cores: timings would be noise (QED_GATE_ANY_LOAD=1 to run anyway)", load, cores)
			return
		}
	}
	// the parts run free_all(context.temp_allocator)
	only := os.get_env("QED_GATE_ONLY", context.allocator)
	defer delete(only)
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

	fmt.eprintfln("\n%-60s %6s %6s %9s %9s %9s  %s", "measure", "budget", "limit", "mean", "p95", "max", "result")
	num :: proc(v: f64, prec := 0) -> string {return fmt.tprintf("%.*f", prec, v)}
	for r in gate_rows {
		if r.skipped != "" {
			fmt.eprintfln("%-60s %6s %6s %9s %9s %9s  SKIP (%s)", r.name, num(r.budget), num(r.limit), "-", "-", "-", r.skipped)
			continue
		}
		v := r.stat.p95
		verdict := "ok" if v <= r.budget else ("over budget" if v <= r.limit else "FAIL")
		switch r.mode {
		case .Gate:
		case .Open:
			verdict = fmt.tprintf("open (%s)", verdict)
		case .Info:
			verdict = "info"
		}
		fmt.eprintfln("%-60s %6s %6s %9s %9s %9s  %s", r.name, num(r.budget), num(r.limit), num(r.stat.mean, 2), num(v, 2), num(r.stat.max, 2), verdict)
		testing.expectf(t, r.mode != .Gate || v <= r.limit, "%s: p95 %.2f ms > limit %.0f ms", r.name, v, r.limit)
	}
}

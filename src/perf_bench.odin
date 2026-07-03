package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "lib:tb2"

PERF_FILE :: "lib/tree_sitter/c/parser.c"
PERF_VIEWPORT :: 60
HIGHLIGHT_BUDGET_MS :: 50.0

// One test owns the process-global parser cache teardown (syntax_shutdown), so
// it must be the only test that drives highlighting — hence correctness and the
// perf budget live together here.
@(test)
test_highlight_incremental :: proc(t: ^testing.T) {
	defer syntax_shutdown()
	highlight_queries_compile(t)
	highlight_injection(t)
	highlight_correctness(t)
	highlight_perf(t)
}

// Markdown injection: inline formatting (via the markdown_inline grammar) and
// fenced-code (via the named language's grammar) must paint their own colors over
// the host markdown colors, with the correct row/col offset.
highlight_injection :: proc(t: ^testing.T) {
	b := buffer_new()
	defer buffer_destroy(&b)
	delete(b.path)
	b.path = strings.clone("test.md")
	buffer_insert(&b, Cursor{0, 0}, "# Title\n\n- [ ] todo\n- [x] done\n\nSome **bold**, `code`, and a [link](http://x).\n\n```ts\nconst n: number = 1;\n```\n")
	highlight_update(&b, 0, len(b.lines) - 1)

	row_has :: proc(b: ^Buffer, row: int, color: tb2.Color) -> bool {
		for c in highlight_colors(b, row) {
			if c == color {
				return true
			}
		}
		return false
	}

	testing.expect(t, row_has(&b, 0, COLOR_SYN_KEYWORD), "heading marker + text should be the title color")
	testing.expect(t, row_has(&b, 2, COLOR_SYN_KEYWORD), "unchecked [ ] should be the keyword color")
	testing.expect(t, row_has(&b, 3, COLOR_SYN_STRING), "checked [x] should be the string/green color")
	testing.expect(t, row_has(&b, 5, COLOR_SYN_ATTRIBUTE), "**bold** should be injected (strong)")
	testing.expect(t, row_has(&b, 5, COLOR_SYN_CODE), "`code` span should be the subtle code gray")
	testing.expect(t, row_has(&b, 5, COLOR_SYN_TYPE), "[link](url) should be injected blue")
	testing.expect(t, row_has(&b, 7, COLOR_SYN_CODE), "```ts fence + info string should be the code gray")
	testing.expect(t, row_has(&b, 8, COLOR_SYN_KEYWORD), "fenced ts `const` should be injected as a keyword")
	testing.expect(t, row_has(&b, 8, COLOR_SYN_TYPE), "fenced ts `number` should be injected as a type")
}

// Every language that declares a grammar must have a query that compiles against
// it; a bad node name would make syntax_ensure fail silently and disable coloring.
// Runs here (not a standalone test) because this test owns the syntax cache.
highlight_queries_compile :: proc(t: ^testing.T) {
	for info, lang in LANGUAGES {
		if info.grammar == nil {
			continue
		}
		testing.expectf(t, syntax_ensure(lang), "syntax_ensure failed for %v", lang)
	}
}

// The incremental-parse + viewport-scoped path must paint exactly what a fresh
// full parse of the same final text would.
highlight_correctness :: proc(t: ^testing.T) {
	base := "int main(void) {\n\tint count = 42;\n\treturn count;\n}\n"

	inc := c_buffer(base)
	defer buffer_destroy(&inc)
	highlight_full(&inc)

	// A sequence of edits that exercises insert, multi-line insert, and delete.
	buffer_insert(&inc, Cursor{1, 1}, "unsigned ")
	highlight_full(&inc)
	buffer_insert(&inc, Cursor{0, 0}, "// header comment\n")
	highlight_full(&inc)
	del := buffer_delete(&inc, Cursor{3, 1}, Cursor{3, 7}) // remove "return"
	delete(del)
	highlight_full(&inc)
	buffer_insert(&inc, Cursor{3, 1}, "return /* ok */")
	highlight_full(&inc)

	final := buffer_snapshot(&inc)
	defer delete(final)

	ref := c_buffer(final)
	defer buffer_destroy(&ref)
	highlight_full(&ref)

	if !testing.expect(t, len(inc.lines) == len(ref.lines), "line counts diverged") {
		return
	}
	for r in 0 ..< len(ref.lines) {
		ic := highlight_colors(&inc, r)
		rc := highlight_colors(&ref, r)
		testing.expectf(t, len(ic) == len(rc), "row %d length %d != %d", r, len(ic), len(rc))
		for c in 0 ..< min(len(ic), len(rc)) {
			testing.expectf(
				t,
				ic[c] == rc[c],
				"row %d col %d: incremental %v != full %v",
				r,
				c,
				ic[c],
				rc[c],
			)
		}
	}
}

highlight_perf :: proc(t: ^testing.T) {
	b: Buffer
	if buffer_open(&b, PERF_FILE) != .None {
		testing.fail_now(t, "perf: cannot open " + PERF_FILE)
	}
	defer buffer_destroy(&b)
	testing.expect(t, len(b.lines) > 50_000, "perf fixture should be a large file")

	mid := len(b.lines) / 2
	highlight_update(&b, mid, mid + PERF_VIEWPORT) // cold: spawns async parse
	testing.expect(t, highlight_busy(&b), "a large cold parse should run in the background, not block")
	highlight_settle(&b, mid, mid + PERF_VIEWPORT)

	testing.expect(t, highlight_painted(&b, mid), "adopted background parse should paint real syntax colors in the viewport")

	// Each edit on a large buffer must dispatch a background reparse and return
	// without blocking on the parse itself (the ~hundreds-of-ms cost is off the
	// keystroke path now).
	per_edit := bench_avg(20, proc(b: ^Buffer) {
		bench_touch(b)
		row := len(b.lines) / 2
		highlight_update(b, row, row + PERF_VIEWPORT)
	}, &b)
	testing.expect(t, highlight_busy(&b), "an edit on a large buffer should reparse in the background, not block")

	testing.expectf(
		t,
		per_edit < HIGHLIGHT_BUDGET_MS,
		"highlight_update per edit on %d lines was %.2f ms, budget %.2f ms (regression: async reparse blocking on the keystroke?)",
		len(b.lines),
		per_edit,
		HIGHLIGHT_BUDGET_MS,
	)

	// After the edits settle, the async incremental path must adopt its tree and
	// repaint real colors — not leave the viewport blank.
	highlight_settle(&b, mid, mid + PERF_VIEWPORT)
	testing.expect(t, highlight_painted(&b, mid), "async incremental reparse should repaint real colors after edits settle")
}

@(private = "file")
highlight_painted :: proc(b: ^Buffer, mid: int) -> bool {
	for r in mid ..= mid + PERF_VIEWPORT {
		for c in highlight_colors(b, r) {
			if c != COLOR_FG {
				return true
			}
		}
	}
	return false
}

@(test)
bench_large_file :: proc(t: ^testing.T) {
	env := os.get_env("QED_BENCH", context.temp_allocator)
	if env == "" {
		return
	}
	defer syntax_shutdown()

	path := PERF_FILE
	if env != "1" {
		path = env
	}

	b: Buffer
	if err := buffer_open(&b, path); err != .None {
		fmt.eprintfln("bench: cannot open %s: %v", path, err)
		return
	}
	defer buffer_destroy(&b)

	fmt.eprintfln("=== qed perf bench: %s (%d lines) ===", path, len(b.lines))

	// cold open path: what blocks the first interactive frame
	open_t := time.tick_now()
	ob: Buffer
	buffer_open(&ob, path)
	fmt.eprintfln("buffer_open (read+split+clone+saved snapshot): %.2f ms", ms_since(open_t))
	gc := time.tick_now()
	git_gutter_update(&ob)
	fmt.eprintfln("git_gutter_update COLD (git show HEAD subprocess + hash + diff): %.2f ms", ms_since(gc))
	buffer_destroy(&ob)

	mid := len(b.lines) / 2

	snap_ns := bench_avg(10, proc(b: ^Buffer) {
		s := buffer_snapshot(b)
		delete(s)
	}, &b)
	fmt.eprintfln("buffer_snapshot (LSP didChange payload build): %.2f ms", snap_ns)

	// edit at the bottom: recompute_modified scans everything above it
	last := len(b.lines) - 1
	mod_ns := bench_avg(20, proc(b: ^Buffer) {
		row := len(b.lines) - 1
		buffer_insert(b, Cursor{row, 0}, "x")
		s := buffer_delete(b, Cursor{row, 0}, Cursor{row, 1})
		delete(s)
	}, &b)
	fmt.eprintfln("buffer edit at EOF (incl. 2x recompute_modified full scan): %.2f ms", mod_ns)
	_ = last

	cold := time.tick_now()
	highlight_update(&b, mid, mid + PERF_VIEWPORT)
	highlight_settle(&b, mid, mid + PERF_VIEWPORT)
	fmt.eprintfln("highlight_update COLD (async parse wall time; off the main thread): %.2f ms", ms_since(cold))

	hl_ns := bench_avg(20, proc(b: ^Buffer) {
		bench_touch(b)
		row := len(b.lines) / 2
		highlight_update(b, row, row + PERF_VIEWPORT)
	}, &b)
	fmt.eprintfln("highlight_update per edit (incremental + viewport): %.2f ms", hl_ns)

	git_gutter_update(&b)
	git_ns := bench_avg(20, proc(b: ^Buffer) {
		bench_touch(b)
		git_gutter_update(b)
	}, &b)
	fmt.eprintfln("git_gutter_update per edit (hash + Myers): %.2f ms", git_ns)

	fmt.eprintfln(
		"--- combined per-keystroke (snapshot+hl+git, excl. LSP IPC): %.2f ms ---",
		snap_ns + hl_ns + git_ns,
	)
}

@(private = "file")
c_buffer :: proc(content: string) -> Buffer {
	b := buffer_new()
	delete(b.path)
	b.path = strings.clone("test.c")
	buffer_insert(&b, Cursor{0, 0}, content)
	return b
}

@(private = "file")
highlight_full :: proc(b: ^Buffer) {
	highlight_update(b, 0, len(b.lines) - 1)
}

@(private = "file")
highlight_settle :: proc(b: ^Buffer, top, bot: int) {
	for highlight_busy(b) {
		highlight_update(b, top, bot)
		thread.yield()
	}
}

@(private = "file")
bench_touch :: proc(b: ^Buffer) {
	row := len(b.lines) / 2
	buffer_insert(b, Cursor{row, 0}, "x")
	s := buffer_delete(b, Cursor{row, 0}, Cursor{row, 1})
	delete(s)
}

@(private = "file")
bench_avg :: proc(iters: int, work: proc(b: ^Buffer), b: ^Buffer) -> f64 {
	start := time.tick_now()
	for _ in 0 ..< iters {
		work(b)
	}
	total := time.tick_since(start)
	return time.duration_milliseconds(total) / f64(iters)
}

@(private = "file")
ms_since :: proc(t: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(t))
}

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
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
	// The g_syntaxes cache (parser/query/cursor per language) is process-global and
	// shared with the e2e harness, which serializes its render sessions on e2e_lock.
	// This test drives highlighting directly (bypassing the harness), so it must take
	// the same lock or it races an e2e session painting the same language.
	sync.mutex_lock(&e2e_lock)
	defer sync.mutex_unlock(&e2e_lock)
	defer syntax_shutdown()
	highlight_queries_compile(t)
	// A prior test may have left a syntax cache recolored to a transient palette
	// (config/theme reload bakes s.colors but syntax_ensure won't rebake a cached
	// language). Rebake from the current globals so color assertions are stable —
	// this mirrors editor_retheme, which always recolors after a palette change.
	syntax_recolor()
	highlight_injection(t)
	highlight_predicates(t)
	highlight_correctness(t)
	highlight_perf(t)
}

// End-to-end proof that the query predicate evaluator is live and the capture
// mapping is applied. Name-shape heuristics still fire (Capitalized -> @type,
// builtin-function lists -> @function.builtin), while a name that fails the
// predicate is left plain. SCREAMING_CASE / flag names match @constant, but the
// default theme maps bare @constant -> foreground, so those render plain; literal
// values (@constant.builtin, @number) keep the constant color — the contrast is
// asserted per language below.
highlight_predicates :: proc(t: ^testing.T) {
	at :: proc(b: ^Buffer, row, col: int) -> tb2.Color {
		cs := highlight_colors(b, row)
		if col >= len(cs) {
			return COLOR_FG
		}
		return cs[col]
	}
	Chk :: struct {
		row, col: int,
		color:    tb2.Color,
		want:     bool,
		msg:      string,
	}
	probe :: proc(t: ^testing.T, lang: Language, path, content: string, checks: []Chk) {
		b := buffer_new()
		defer buffer_destroy(&b)
		delete(b.path)
		b.path = strings.clone(path)
		b.language = lang
		buffer_insert(&b, Cursor{0, 0}, content)
		highlight_update(&b, 0, len(b.lines) - 1)
		for c in checks {
			got := at(&b, c.row, c.col) == c.color
			testing.expectf(t, got == c.want, "%v: %s (row %d col %d)", lang, c.msg, c.row, c.col)
		}
	}

	// Python: MAX (SCREAMING @constant) -> plain fg; the `1` literal (@number) keeps
	// the constant color; foo (lowercase) -> plain.
	probe(t, .Python, "p.py", "MAX = 1\nfoo = 2\n", []Chk{
		{0, 0, COLOR_FG, true, "MAX (SCREAMING) is default-fg (constant -> foreground)"},
		{0, 0, COLOR_SYN_CONSTANT, false, "MAX is NOT constant-colored anymore"},
		{0, 6, COLOR_SYN_CONSTANT, true, "the 1 literal (@number) stays constant-colored"},
		{1, 0, COLOR_SYN_CONSTANT, false, "lowercase foo is NOT constant-colored"},
	})
	// C: FOO (SCREAMING @constant) -> plain fg; the `1` literal (@number) keeps the
	// constant color; bar -> plain.
	probe(t, .C, "c.c", "int FOO = 1;\nint bar = 2;\n", []Chk{
		{0, 4, COLOR_FG, true, "FOO (SCREAMING) is default-fg (constant -> foreground)"},
		{0, 4, COLOR_SYN_CONSTANT, false, "FOO is NOT constant-colored anymore"},
		{0, 10, COLOR_SYN_CONSTANT, true, "the 1 literal (@number) stays constant-colored"},
		{1, 4, COLOR_SYN_CONSTANT, false, "lowercase bar is NOT constant-colored"},
	})
	// C++: the cpp-only `namespace` keyword (additions query) fires, and the inlined
	// C base's SCREAMING predicate paints MSG while lowercase bar is rejected. Plus
	// string/comment paint.
	probe(t, .Cpp, "cpp.cpp", "// note\nnamespace ns {}\nconst char* MSG = \"hi\";\nvoid* p = nullptr;\nint bar = 2;\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "line comment is comment-colored"},
		{1, 0, COLOR_SYN_KEYWORD, true, "cpp namespace keyword is keyword-colored"},
		{2, 12, COLOR_FG, true, "SCREAMING MSG is default-fg (constant -> foreground)"},
		{2, 18, COLOR_SYN_STRING, true, "string literal is string-colored"},
		{3, 10, COLOR_SYN_CONSTANT, true, "nullptr literal (@constant.builtin) stays constant-colored"},
		{4, 4, COLOR_SYN_CONSTANT, false, "lowercase bar is NOT constant-colored"},
	})
	// JavaScript: FOO (SCREAMING @constant) -> plain fg; the `1` literal keeps the
	// constant color; bar -> plain.
	probe(t, .JavaScript, "j.js", "const FOO = 1;\nconst bar = 2;\n", []Chk{
		{0, 6, COLOR_FG, true, "FOO (SCREAMING) is default-fg (constant -> foreground)"},
		{0, 6, COLOR_SYN_CONSTANT, false, "FOO is NOT constant-colored anymore"},
		{0, 12, COLOR_SYN_CONSTANT, true, "the 1 literal (@number) stays constant-colored"},
		{1, 6, COLOR_SYN_CONSTANT, false, "lowercase bar is NOT constant-colored"},
	})
	// TypeScript: capitalized identifier reference -> @type; lowercase -> plain.
	probe(t, .TypeScript, "t.ts", "let x = Bar;\nlet y = baz;\n", []Chk{
		{0, 8, COLOR_SYN_TYPE, true, "capitalized Bar is type-colored"},
		{1, 8, COLOR_SYN_TYPE, false, "lowercase baz is NOT type-colored"},
	})
	// Odin: MAX (SCREAMING @constant) -> plain fg now, Foo -> @type (lua-match),
	// bar -> plain. The proc-declaration name `f` is tagged @type then @function;
	// @function maps to `foreground` (explicit plain) and overwrites the @type paint,
	// so the proc name renders in the default color.
	probe(t, .Odin, "o.odin", "package p\nf :: proc() {\n\tx := MAX\n\ty := Foo\n\tz := bar\n}\n", []Chk{
		{1, 0, COLOR_FG, true, "proc name f is default-fg (function -> foreground overwrites type)"},
		{1, 0, COLOR_SYN_TYPE, false, "proc name f is NOT type-colored anymore"},
		{2, 6, COLOR_FG, true, "SCREAMING MAX is default-fg (constant -> foreground)"},
		{2, 6, COLOR_SYN_CONSTANT, false, "SCREAMING MAX is NOT constant-colored anymore"},
		{3, 6, COLOR_SYN_TYPE, true, "Capitalized Foo is type-colored"},
		{4, 6, COLOR_SYN_CONSTANT, false, "lowercase bar is NOT constant-colored"},
		{4, 6, COLOR_SYN_TYPE, false, "lowercase bar is NOT type-colored"},
	})
	// Lua: MAX (SCREAMING @constant) -> plain fg; print -> @function.builtin (any-of)
	// -> keyword; foo plain. A `{}` table constructor's braces are captured
	// @constructor, but the per-language override maps lua/constructor -> foreground,
	// so the braces render plain instead of the (blueish) type color.
	probe(t, .Lua, "l.lua", "MAX = 1\nfoo = 2\nprint(foo)\nt = {}\n", []Chk{
		{0, 0, COLOR_FG, true, "SCREAMING MAX is default-fg (constant -> foreground)"},
		{0, 0, COLOR_SYN_CONSTANT, false, "SCREAMING MAX is NOT constant-colored anymore"},
		{1, 0, COLOR_SYN_CONSTANT, false, "lowercase foo is NOT constant-colored"},
		{2, 0, COLOR_SYN_KEYWORD, true, "builtin print (#any-of?) is keyword-colored"},
		{3, 4, COLOR_FG, true, "table-constructor { is plain (lua/constructor -> foreground)"},
		{3, 4, COLOR_SYN_TYPE, false, "table-constructor { is NOT type-colored"},
	})
	// Go: builtin len (#match list) -> @function.builtin -> keyword; a user call
	// (identifier) @function stays plain. Plus keyword/string/comment paint.
	probe(t, .Go, "g.go", "package main\n// note\nvar s = \"hi\"\nfunc f() { len(s); g() }\n", []Chk{
		{0, 0, COLOR_SYN_KEYWORD, true, "package keyword is keyword-colored"},
		{1, 0, COLOR_SYN_COMMENT, true, "line comment is comment-colored"},
		{2, 8, COLOR_SYN_STRING, true, "string literal is string-colored"},
		{3, 11, COLOR_SYN_KEYWORD, true, "builtin len (#match) is keyword-colored"},
		{3, 19, COLOR_SYN_KEYWORD, false, "user call g is NOT keyword-colored"},
	})
	// Rust: uppercase Foo -> @constructor (#match ^[A-Z]) -> type; lowercase bar in a
	// call stays plain. Plus keyword/string/comment paint. (The upstream @constant
	// SCREAMING regex carries a typo and never matches — see PATCHES.md.)
	probe(t, .Rust, "r.rs", "// note\nfn f() {\n\tlet s = \"hi\";\n\tlet x = Foo;\n\tbar();\n}\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "line comment is comment-colored"},
		{1, 0, COLOR_SYN_KEYWORD, true, "fn keyword is keyword-colored"},
		{2, 9, COLOR_SYN_STRING, true, "string literal is string-colored"},
		{3, 9, COLOR_SYN_TYPE, true, "uppercase Foo (#match ^[A-Z]) is type-colored"},
		{4, 1, COLOR_SYN_TYPE, false, "lowercase bar is NOT type-colored"},
	})
	// Bash: -la flag matches @constant (#match ^-) but bare @constant -> foreground,
	// so it renders plain; foo arg -> plain.
	probe(t, .Shell, "s.sh", "ls -la foo\n", []Chk{
		{0, 3, COLOR_FG, true, "-la flag is default-fg (constant -> foreground)"},
		{0, 3, COLOR_SYN_CONSTANT, false, "-la flag is NOT constant-colored anymore"},
		{0, 7, COLOR_SYN_CONSTANT, false, "non-flag arg foo is NOT constant-colored"},
	})
	// SQL: the #match? "%d" number rule can never match (Lua class under a regex),
	// so a numeric literal keeps @string, not @number/@constant.
	probe(t, .Sql, "q.sql", "SELECT 42 FROM t;\n", []Chk{
		{0, 7, COLOR_SYN_STRING, true, "numeric literal stays string-colored (number rule rejected)"},
		{0, 7, COLOR_SYN_CONSTANT, false, "numeric literal is NOT constant-colored"},
	})
	// HTML: predicate-free query, so basic paints. @tag -> keyword (qed maps the
	// tag bucket to keyword), @attribute, @string, @constant (doctype), @comment.
	probe(t, .Html, "h.html", "<!DOCTYPE html>\n<div class=\"x\">hi</div>\n<!-- c -->\n", []Chk{
		{0, 0, COLOR_SYN_CONSTANT, false, "doctype is no longer constant-colored (constant -> foreground)"},
		{1, 1, COLOR_SYN_KEYWORD, true, "tag name div is keyword-colored (tag->keyword)"},
		{1, 5, COLOR_SYN_ATTRIBUTE, true, "attribute name is attribute-colored"},
		{1, 12, COLOR_SYN_STRING, true, "attribute value is string-colored"},
		{2, 0, COLOR_SYN_COMMENT, true, "comment is comment-colored"},
	})
	// CSS: one coherent scheme via the css/ capture overrides. Selector tokens read
	// as the keyword family — element/universal/nesting (@tag) and pseudo/attribute
	// selectors (css/attribute -> keyword) — while name identifiers (css/property ->
	// attribute: class/id/namespace/property/feature) read as the attribute color.
	// The grammar captures class-selector names AND property names both as @property,
	// so they unavoidably share one color. Values stay their own colors (@number ->
	// constant, @unit -> type). @media at-rule stays keyword.
	probe(t, .Css, "c.css", "/* c */\n.cls { color: red; }\ndiv:hover {}\n@media (x) {}\na { width: 10px; }\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "comment is comment-colored"},
		{1, 1, COLOR_SYN_ATTRIBUTE, true, "class selector name -> attribute color (was plain)"},
		{1, 7, COLOR_SYN_ATTRIBUTE, true, "property name -> attribute color (was plain)"},
		{2, 0, COLOR_SYN_KEYWORD, true, "type selector div is keyword-colored (tag->keyword)"},
		{2, 4, COLOR_SYN_KEYWORD, true, "pseudo-class :hover name -> keyword (selector family)"},
		{3, 0, COLOR_SYN_KEYWORD, true, "@media at-rule is keyword-colored"},
		{4, 11, COLOR_SYN_CONSTANT, true, "integer value is number/constant-colored"},
		{4, 13, COLOR_SYN_TYPE, true, "unit px is type-colored"},
	})
	// TOML: every (bare_key) is @type, which the toml/type override maps to
	// foreground — pair keys (and [table] header names, same capture) render plain.
	// Values keep their colors: quoted @string, integer @number -> constant.
	probe(t, .Toml, "x.toml", "# note\nkey = \"value\"\nnum = 42\n[tbl]\nx = 1\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "comment is comment-colored"},
		{1, 0, COLOR_FG, true, "bare key is default-fg (toml/type -> foreground)"},
		{1, 0, COLOR_SYN_TYPE, false, "bare key is NOT type-colored anymore"},
		{1, 6, COLOR_SYN_STRING, true, "quoted value is string-colored"},
		{2, 6, COLOR_SYN_CONSTANT, true, "integer is constant-colored"},
		{3, 1, COLOR_SYN_TYPE, false, "table header name is NOT type-colored either (same @type capture)"},
	})
	// YAML: predicate-free query, so a plain paint check. Scalars: integer/boolean
	// -> constant, a double-quoted scalar -> string.
	probe(t, .Yaml, "x.yaml", "# note\nnum: 42\nflag: true\nq: \"hi\"\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "comment is comment-colored"},
		{1, 5, COLOR_SYN_CONSTANT, true, "integer scalar is constant-colored"},
		{2, 6, COLOR_SYN_CONSTANT, true, "boolean scalar is constant-colored"},
		{3, 3, COLOR_SYN_STRING, true, "double-quoted scalar is string-colored"},
	})
	// Dockerfile: has a #match? predicate — a SCREAMING $HOME expansion variable
	// matches @constant but bare @constant -> foreground, so it renders plain; a
	// lowercase ${low} is rejected -> plain too. Plus keyword/comment/string.
	probe(t, .Dockerfile, "Dockerfile", "# note\nFROM alpine\nENV X=$HOME\nUSER ${low}\nCMD [\"run\"]\n", []Chk{
		{0, 0, COLOR_SYN_COMMENT, true, "comment is comment-colored"},
		{1, 0, COLOR_SYN_KEYWORD, true, "FROM instruction is keyword-colored"},
		{2, 7, COLOR_FG, true, "SCREAMING $HOME var is default-fg (constant -> foreground)"},
		{2, 7, COLOR_SYN_CONSTANT, false, "SCREAMING $HOME var is NOT constant-colored anymore"},
		{3, 7, COLOR_SYN_CONSTANT, false, "lowercase ${low} var is NOT constant-colored"},
		{4, 5, COLOR_SYN_STRING, true, "json string is string-colored"},
	})
	// JSX (.jsx, javascript grammar): element tag names and attribute names get the
	// keyword/tag color, matching the HTML look (upstream ships no JSX captures).
	probe(t, .Jsx, "c.jsx", "const x = <div className=\"c\">hi</div>;\n", []Chk{
		{0, 11, COLOR_SYN_KEYWORD, true, "JSX opening tag div is keyword-colored (tag)"},
		{0, 15, COLOR_SYN_KEYWORD, true, "JSX attribute className is keyword-colored (tag.attribute)"},
	})
	// TSX (.tsx, tsx grammar): the JSX captures are appended to the shared typescript
	// query only for .tsx, so the same tag paint applies.
	probe(t, .Tsx, "c.tsx", "const x = <div className=\"c\">hi</div>;\n", []Chk{
		{0, 11, COLOR_SYN_KEYWORD, true, "TSX opening tag div is keyword-colored (tag)"},
		{0, 15, COLOR_SYN_KEYWORD, true, "TSX attribute className is keyword-colored (tag.attribute)"},
	})
}

// Markdown injection: inline formatting (via the markdown_inline grammar) and
// fenced-code (via the named language's grammar) must paint their own colors over
// the host markdown colors, with the correct row/col offset.
highlight_injection :: proc(t: ^testing.T) {
	b := buffer_new()
	defer buffer_destroy(&b)
	delete(b.path)
	b.path = strings.clone("test.md")
	b.language = .Markdown
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

	testing.expect(t, row_has(&b, 0, color_attr(COLOR_SYN_KEYWORD, .Bold)), "heading text should be the bold title color")
	// The `#` heading marker is @punctuation.special; the markdown per-language
	// override maps it to the (plain, non-bold) keyword color.
	testing.expect(t, row_has(&b, 0, COLOR_SYN_KEYWORD), "the # heading marker should be the keyword color")
	testing.expect(t, row_has(&b, 2, COLOR_SYN_KEYWORD), "unchecked [ ] should be the keyword color")
	testing.expect(t, row_has(&b, 3, COLOR_SYN_STRING), "checked [x] should be the string/green color")
	testing.expect(t, row_has(&b, 5, color_attr(COLOR_SYN_ATTRIBUTE, .Bold)), "**bold** should be injected (strong)")
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
	b.language = .C
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

	languages_reset_defaults()
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

@(test)
bench_filetree_walk :: proc(t: ^testing.T) {
	env := os.get_env("QED_BENCH", context.temp_allocator)
	if env == "" {
		return
	}
	root := env
	if env == "1" {
		root = os.get_env("HOME", context.temp_allocator)
	}

	run :: proc(root: string, dotfiles, ignored: bool, label: string) {
		ft: FileTree
		ft.show_dotfiles = dotfiles
		ft.show_ignored = ignored
		out := make([dynamic]FileEntry)
		start := time.tick_now()
		filetree_collect(&ft, root, &out)
		fmt.eprintfln("filetree_collect %s (%s): %.2f ms, %d candidates", root, label, ms_since(start), len(out))
		for e in out {
			delete(e.path)
		}
		delete(out)
	}

	run(root, false, false, "default: dotfiles+ignored hidden")
	run(root, true, true, "everything shown")
}

@(private = "file")
c_buffer :: proc(content: string) -> Buffer {
	b := buffer_new()
	delete(b.path)
	b.path = strings.clone("test.c")
	b.language = .C
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

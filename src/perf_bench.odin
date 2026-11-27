package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import lua "lib:lua"
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
	highlight_error_heavy(t)
	highlight_slow_flag(t)
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
	testing.expect(t, row_has(&b, 5, color_attr(COLOR_FG, .Bold)), "**bold** should be injected (strong, plain fg so it differs from headings)")
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

// conflict markers are Lua parse errors; the scanner's recovery once scanned to EOF per step (~29 s/keystroke)
highlight_error_heavy :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 2000 {
		fmt.sbprintf(&sb, "local a%d = %d\n<<<<<<< HEAD\nlocal v%d = %d\nshared\n=======\nlocal v%d = %d + 1\nshared\n>>>>>>> b\n\n", i, i, i, i, i, i)
	}
	b := buffer_new()
	defer buffer_destroy(&b)
	delete(b.path)
	b.path = strings.clone("c.lua")
	b.language = .Lua
	buffer_insert(&b, Cursor{0, 0}, strings.to_string(sb))
	highlight_settle(&b, 0, 60)
	highlight_update(&b, 0, 60)
	start := time.tick_now()
	buffer_insert(&b, Cursor{9002, 0}, "z")
	highlight_update(&b, 8990, 9050)
	highlight_settle(&b, 8990, 9050)
	ms := ms_since(start)
	testing.expectf(t, ms < 2000, "error-heavy Lua reparse took %.0f ms", ms)

	b.hl.slow = true
	buffer_insert(&b, Cursor{9002, 0}, "z")
	highlight_update(&b, 8990, 9050)
	testing.expect(t, highlight_busy(&b), "a buffer whose inline parse was slow reparses in the background")
	highlight_settle(&b, 8990, 9050)
	testing.expect(t, b.hl.valid && b.hl.tree != nil, "the background reparse is adopted")
}

highlight_slow_flag :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; strings.builder_len(sb) < 150 * 1024; i += 1 {
		fmt.sbprintf(&sb, "static int helper_%d(struct state *s) {{\n    return s->table[%d]; // c\n}}\n\n", i, i % 251)
	}
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/qed-test-slow-flag-%d.c", tmp, posix.getpid())
	testing.expect(t, os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil)
	defer os.remove(path)
	b: Buffer
	testing.expect_value(t, buffer_open(&b, path), BufferOpenError.None)
	defer buffer_destroy(&b)
	b.language = .C
	mid := len(b.lines) / 2
	highlight_update(&b, mid, mid + 60)
	highlight_settle(&b, mid, mid + 60)
	testing.expect(t, !b.hl.slow, "a cold parse does not mark the buffer slow")

	// parse_ms is wall time on a worker thread: one descheduling under a loaded runner can exceed the budget
	for _ in 0 ..< 3 {
		b.hl.slow = true
		buffer_insert(&b, Cursor{mid, 0}, "x")
		highlight_update(&b, mid, mid + 60)
		testing.expect(t, highlight_busy(&b), "a slow buffer reparses in the background")
		highlight_settle(&b, mid, mid + 60)
		if !b.hl.slow {
			break
		}
	}
	testing.expect(t, !b.hl.slow, "an adopted incremental parse under budget clears slow")

	b.hl.slow = true
	testing.expect_value(t, buffer_reload(&b), BufferOpenError.None)
	testing.expect(t, !b.hl.slow, "a reload drops the tree and the slow mark")
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
	sync.lock(&e2e_lock)
	defer sync.unlock(&e2e_lock)
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
	blob, _ := shell_capture(fmt.ctprintf("git -C %s show HEAD:./%s 2>/dev/null", shell_quote(filepath.dir(path)), shell_quote(filepath.base(path))))
	diffbase_set(&ob, "git", blob)
	diffbase_update(&ob)
	fmt.eprintfln("diff base COLD (git show HEAD subprocess + hash + diff, async in the git plugin): %.2f ms", ms_since(gc))
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

	diffbase_set(&b, "git", blob)
	diffbase_update(&b)
	git_ns := bench_avg(20, proc(b: ^Buffer) {
		bench_touch(b)
		diffbase_update(b)
	}, &b)
	fmt.eprintfln("diffbase_update per edit (hash + Myers): %.2f ms", git_ns)

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

	run :: proc(root: string, threads: int, label: string) {
		admit: WalkAdmit
		out := make([dynamic]FileEntry)
		start := time.tick_now()
		walk_run(&admit, root, &out, threads)
		fmt.eprintfln("filetree_walk %s (%s): %.2f ms, %d candidates", root, label, ms_since(start), len(out))
		walk_entries_free(&out)
		delete(out)
	}

	cores := os.get_processor_core_count()
	fmt.eprintfln("=== filetree walk bench (%d cores) ===", cores)
	run(root, 1, "serial")
	run(root, 0, fmt.tprintf("parallel auto (%d threads)", cores))

	// First-filter-after-open latency: without prewarm the keystroke pays the whole
	// parallel walk; with prewarm it pays only the adopt once the background walk lands.
	editor := Editor{headless = true}
	editor.working_root = root
	w := walk_acquire(&editor, root, false, false)
	walk_prewarm(&editor, w)
	for !sync.atomic_load(&w.pw.done) {
		thread.yield()
	}
	adopt_at := time.tick_now()
	walk_prewarm_finish(&editor, w)
	fmt.eprintfln("prewarm adopt (first-filter cost when walk already landed): %.3f ms, %d candidates", ms_since(adopt_at), len(w.cands))
	walk_destroy_all(&editor)
}

@(test)
bench_plugin_startup :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	run :: proc(label: string, bundled: []PluginFile) {
		ed := Editor{headless = true}
		start := time.tick_now()
		editor_plugins_start(&ed, bundled, "", PLUGIN_MEMORY_MB * 1024 * 1024)
		total := ms_since(start)
		fmt.eprintfln("%s: Lua init %.3f ms, %d plugin(s), total %.3f ms", label, ed.plugins.init_ms, len(ed.plugins.list), total)
		for pl in ed.plugins.list {
			if pl.state == .Errored {
				fmt.eprintfln("  %s errored: %s", pl.name, pl.last_error)
			}
		}
		plugins_shutdown(&ed.plugins)
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}
	fmt.eprintln("=== plugin startup bench (budget: 5 ms before first paint) ===")
	run("bundled set", g_bundled_plugins)
	synthetic := make([]PluginFile, 20, context.temp_allocator)
	for &f, i in synthetic {
		f.path = fmt.tprintf("p%02d.lua", i)
		f.data = fmt.tprintf(`
			return {{
				setup = function()
					qed.options{{a = {{type = "int", default = 1}}, nested = {{type = "record", fields = {{b = {{type = "int", default = 2}}}}}}}}
					for k = 1, 5 do
						qed.command{{id = "bench_" .. k, name = "Bench %02d: " .. k, key = "", run = function() qed.message("x") end}}
					end
				end,
			}}`, i)
	}
	run("20 synthetic plugins x 5 commands", synthetic)
}

@(test)
bench_plugin_poll :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	ROUNDS :: 200
	run :: proc(files, dir_files: int) {
		dir := reload_dir()
		defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(dir)))
		for i in 0 ..< files {
			reload_write(dir, fmt.tprintf("p%03d.lua", i), "return {}")
		}
		for i in 0 ..< dir_files {
			reload_write(dir, fmt.tprintf("big/sub%d/f%03d.lua", i % 4, i), "return {}")
		}
		if dir_files > 0 {
			reload_write(dir, "big/init.lua", "return {}")
		}
		ed := Editor{headless = true}
		editor_plugins_start(&ed, g_bundled_plugins, dir, PLUGIN_MEMORY_MB * 1024 * 1024)
		start := time.tick_now()
		for _ in 0 ..< ROUNDS {
			plugins_poll(&ed)
			free_all(context.temp_allocator)
		}
		fmt.eprintfln("%d user plugin file(s) + dir plugin with %d file(s): %.3f ms/poll", files, dir_files, ms_since(start) / ROUNDS)
		plugins_shutdown(&ed.plugins)
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}
	fmt.eprintln("=== plugin file poll bench (runs once per disk poll, 1 s) ===")
	run(0, 0)
	run(10, 0)
	run(50, 0)
	run(200, 0)
	run(10, 100)
}

@(test)
bench_plugin_keystroke :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	KEYS :: 20000
	run :: proc(label: string, bundled: []PluginFile) {
		ed := Editor{headless = true}
		append(&ed.buffers, buffer_new())
		editor_plugins_start(&ed, bundled, "", PLUGIN_MEMORY_MB * 1024 * 1024)
		plugin_pump(&ed)
		b := &ed.buffers[0]
		start := time.tick_now()
		for i in 0 ..< KEYS {
			buffer_insert_rune(b, 'x' if i % 80 != 79 else '\n')
			plugin_flush(&ed)
		}
		total := ms_since(start)
		fmt.eprintfln("%s: %.3f us/keystroke (insert + flush), %d Lua entries", label, total * 1000 / KEYS, ed.plugins.resumes)
		plugins_shutdown(&ed.plugins)
		buffer_destroy(b)
		delete(ed.buffers)
		editor_log_destroy(&ed)
		delete(ed.message_store)
	}
	fmt.eprintln("=== plugin per-keystroke bench ===")
	run("no plugins", {})
	run("plugin, no subscribers", {{"q.lua", `return {setup = function() qed.command{id = "q_cmd", name = "Q: Cmd", run = function() end} end}`}})
	run("one buf_changed subscriber", {{"s.lua", `
		n = 0
		return {setup = function() qed:on("buf_changed", function(b, rev) n = n + 1 end) end}`}})
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

@(test)
bench_decorations :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	LINES :: 10000
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< LINES {
		fmt.sbprintf(&sb, "line %d with some text to draw\n", i)
	}
	fmt.eprintln("=== decorations bench ===")
	for n in ([?]int{0, 1000, 10000, 50000}) {
		e := e2e_start(strings.to_string(sb))
		b := editor_buffer(&e.ed)
		color := plugin_color_id(&e.ed.plugins, "git_added")
		for i in 0 ..< n {
			row := (i * 7) % LINES
			switch i % 4 {
			case 0:
				deco_add(b, Deco{kind = .Gutter, ns = 1, from = {row, 0}, to = {row, 0}, glyph = '●', color = color})
			case 1:
				deco_add(b, Deco{kind = .Tint, ns = 1, from = {row, 0}, to = {row + 1, 0}, color = color, alpha = 0.1})
			case 2:
				deco_add(b, Deco{kind = .Eol, ns = 1, from = {row, 0}, to = {row, 0}, text = "note", color = color})
			case 3:
				deco_add(b, Deco{kind = .Span, ns = 1, from = {row, 2}, to = {row, 6}, color = color, bold = true})
			}
		}
		for i in 0 ..< n / 100 {
			row := (i * 97) % LINES
			deco_add(b, Deco{kind = .Ghost, ns = 1, from = {row, 0}, to = {row, 0}, text = "ghost", lines = 1})
		}
		b.cursor = {LINES / 2, 0}
		KEYS :: 2000
		start := time.tick_now()
		for i in 0 ..< KEYS {
			buffer_insert(b, b.cursor, "x" if i % 40 != 39 else "\n")
			b.cursor = {b.cursor.row + (1 if i % 40 == 39 else 0), 0 if i % 40 == 39 else b.cursor.col + 1}
		}
		key_us := ms_since(start) * 1000 / KEYS
		FRAMES :: 200
		e2e_render(&e)
		start = time.tick_now()
		for _ in 0 ..< FRAMES {
			editor_render(&e.ed)
			free_all(context.temp_allocator)
		}
		frame_ms := ms_since(start) / FRAMES
		fmt.eprintfln("%d decorations (+%d ghosts): %.3f us/keystroke (insert + anchor shift), %.3f ms/frame", n, n / 100, key_us, frame_ms)
		e2e_stop(&e)
	}
}

@(test)
bench_filetree_render :: proc(t: ^testing.T) {
	// the runner's rollback stack is not thread-safe and the walk workers share context.allocator
	context.allocator = runtime.heap_allocator()
	root := os.get_env("QED_BENCH_TREE", context.temp_allocator)
	if root == "" {
		return
	}
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin_config(&e, "git", `{"enabled": false}`)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(root)
	plugin_flush(&e.ed)
	open_at := time.tick_now()
	filetree_open_all(&e.ed)
	e2e_render(&e)
	fmt.eprintfln("tree open + first frame: %.2f ms", ms_since(open_at))
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
		thread.yield()
	}
	fmt.eprintfln("tree open until the walk landed: %.2f ms", ms_since(open_at))
	FRAMES :: 200
	start := time.tick_now()
	for _ in 0 ..< FRAMES {
		e2e_render(&e)
	}
	fmt.eprintfln("tree browse render: %.3f ms/frame", ms_since(start) / FRAMES)
	at := time.tick_now()
	e2e_type(&e, "x")
	fmt.eprintfln("tree type x + flush: %.2f ms", ms_since(at))
	start = time.tick_now()
	for _ in 0 ..< FRAMES {
		e2e_render(&e)
	}
	fmt.eprintfln("tree filtered render: %.3f ms/frame", ms_since(start) / FRAMES)
	start = time.tick_now()
	for _ in 0 ..< FRAMES {
		e2e_key(&e, .Arrow_Down)
		e2e_render(&e)
	}
	fmt.eprintfln("tree arrow + render: %.3f ms/step", ms_since(start) / FRAMES)
	e2e_key(&e, .Esc)
	e2e_render(&e)
	start = time.tick_now()
	nav_alt(&e, 'e')
	e2e_render(&e)
	frames := make([dynamic]f64, context.temp_allocator)
	append(&frames, ms_since(start))
	for walk_trees_busy(&e.ed) {
		at := time.tick_now()
		walk_pump(&e.ed)
		e2e_render(&e)
		append(&frames, ms_since(at))
	}
	total := ms_since(start)
	slice.sort(frames[:])
	fmt.eprintfln("tree expand all: %d rows in %.0f ms, %d frames, p95 %.2f max %.2f ms", len(ft_entries(&e.ed)), total, len(frames), frames[len(frames) * 95 / 100], frames[len(frames) - 1])
	at = time.tick_now()
	e2e_key(&e, .Arrow_Down)
	e2e_render(&e)
	fmt.eprintfln("tree arrow, all expanded: %.2f ms", ms_since(at))
	ft_set_sel(&e.ed, 0)
	at = time.tick_now()
	e2e_key(&e, .Enter)
	e2e_render(&e)
	fmt.eprintfln("tree toggle a dir, all expanded: %.2f ms", ms_since(at))
	fmt.eprintfln("rss %.0f MB, peak %.0f MB", test_rss_mb("VmRSS"), test_rss_mb("VmHWM"))
}

@(private = "file")
bench_n: int

@(private = "file")
bench_pushes: int

// every push moves the sizes, like an edit under a large change set
@(private = "file")
bench_push :: proc(e: ^E2E) {
	bench_pushes += 1
	sb := strings.builder_make()
	for i in 0 ..< bench_n {
		fmt.sbprintf(&sb, "%d\t1\td%03d/f%03d.txt\n", bench_pushes, i / 300, i % 300)
	}
	for &f in e.ed.plugins.fakes {
		if f.pattern == "diff HEAD --numstat" {
			delete(f.stdout)
			f.stdout = strings.to_string(sb)
		}
	}
}

@(private = "file")
bench_refresh :: proc(e: ^E2E) {
	bench_push(e)
	plugin_queue(&e.ed, {event = .Custom, a = "filetree:refresh", data = lua.REFNIL})
	plugin_flush(&e.ed)
}

@(private = "file")
bench_step :: proc(e: ^E2E, label: string, run: proc(e: ^E2E)) {
	test_slice_on = true
	clear(&test_slice_max)
	at := time.tick_now()
	run(e)
	for i := 0; i < 20000 && (plugin_busy(&e.ed) || e2e_plugin_yielding(e)); i += 1 {
		plugin_pump(&e.ed)
		free_all(context.temp_allocator)
		time.sleep(time.Millisecond)
	}
	e2e_render(e)
	fmt.eprintfln("changed %d %-14s wall %8.1f ms  max slice filetree %6.1f ms  git %6.1f ms  %v %v", bench_n, label, ms_since(at), test_slice_max["filetree"], test_slice_max["git"], plugin_find(&e.ed.plugins, "filetree").state, plugin_find(&e.ed.plugins, "git").state)
	test_slice_on = false
}

@(test)
bench_filetree_changed :: proc(t: ^testing.T) {
	ns := os.get_env("QED_BENCH_CHANGED", context.allocator)
	if ns == "" {
		return
	}
	for part in strings.split(strings.clone(ns), ",") {
		n := 0
		for ch in part {
			n = n * 10 + int(ch - '0')
		}
		e := e2e_root_start("x")
		for d in 0 ..< (n + 299) / 300 {
			os.make_directory(fmt.tprintf("%s/d%03d", e.dir, d))
			for f in 0 ..< 300 {
				if d * 300 + f < n {
					nav_write(fmt.tprintf("%s/d%03d/f%03d.txt", e.dir, d, f), "x\n")
				}
			}
		}
		bench_n, bench_pushes = n, 0
		status := strings.builder_make()
		for i in 0 ..< n {
			fmt.sbprintf(&status, " M d%03d/f%03d.txt\n", i / 300, i % 300)
		}
		top := strings.clone(fmt.tprintf("git -C %s rev-parse --show-toplevel", e.dir))
		dir := strings.clone(fmt.tprintf("%s\n", e.dir))
		append(&e.ed.plugins.fakes, PluginFake{pattern = top, stdout = dir})
		append(&e.ed.plugins.fakes, PluginFake{pattern = "status --porcelain", stdout = strings.to_string(status)})
		append(&e.ed.plugins.fakes, PluginFake{pattern = "diff HEAD --numstat", stdout = strings.clone("")})
		append(&e.ed.plugins.fakes, PluginFake{pattern = "ls-files -o"})
		bench_push(&e)
		bench_step(&e, "startup scan", proc(e: ^E2E) {plugin_flush(&e.ed)})
		bench_step(&e, "open All", proc(e: ^E2E) {filetree_open_all(&e.ed)})
		bench_step(&e, "push on All", bench_refresh)
		bench_step(&e, "tab Git", proc(e: ^E2E) {nav_alt(e, 'g')})
		bench_step(&e, "push on Git", bench_refresh)
		bench_step(&e, "arrow on Git", proc(e: ^E2E) {e2e_key(e, .Arrow_Down)})
		bench_step(&e, "tab All", proc(e: ^E2E) {nav_alt(e, 'f')})
		bench_step(&e, "close", proc(e: ^E2E) {e2e_key(e, .Esc)})
		bench_step(&e, "open Git", proc(e: ^E2E) {nav_alt(e, 'g')})
		fakes := e.ed.plugins.fakes[len(e.ed.plugins.fakes) - 4:]
		delete(fakes[1].stdout)
		delete(fakes[2].stdout)
		delete(top)
		delete(dir)
		e2e_stop(&e)
	}
	delete(test_slice_max)
}

@(test)
bench_conflict_keystroke :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	run :: proc(label: string, sections, blocks, filler, row: int, huge := -1, plugin := true) {
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< sections {
			if i < blocks {
				ours := fmt.tprintf("local v%d = %d", i, i)
				if i == huge {
					ours = strings.concatenate({ours, strings.repeat("x", 1 << 20, context.temp_allocator)}, context.temp_allocator)
				}
				fmt.sbprintf(&sb, "<<<<<<< HEAD\n%s\nshared\n=======\nlocal v%d = %d + 1\nshared\n>>>>>>> branch\n", ours, i, i)
			} else {
				for k in 0 ..< 7 {
					fmt.sbprintf(&sb, "plain %d of %d\n", k, i)
				}
			}
			for k in 0 ..< filler {
				fmt.sbprintf(&sb, "line %d of %d\n", k, i)
			}
		}
		e := e2e_start(strings.to_string(sb))
		defer e2e_stop(&e)
		if !plugin {
			plugin_unload(&e.ed, plugin_find(&e.ed.plugins, "conflict"))
		}
		plugin_pump(&e.ed)
		plugin_flush(&e.ed)
		b := editor_buffer(&e.ed)
		g_line_wrap = huge < 0
		b.cursor = {row, 0}
		KEYS := 50 if huge < 0 else 10
		test_slice_on = true
		clear(&test_slice_max)
		start := time.tick_now()
		for _ in 0 ..< KEYS {
			e2e_type(&e, "z")
			plugin_flush(&e.ed)
		}
		per := ms_since(start) / f64(KEYS)
		start = time.tick_now()
		for _ in 0 ..< KEYS {
			e2e_render(&e)
		}
		frame := ms_since(start) / f64(KEYS)
		fmt.eprintfln("%-34s %6d lines %5d decos  keystroke %6.2f ms  max slice %6.2f ms  frame %6.2f ms", label, len(b.lines), len(b.deco.items), per, test_slice_max["conflict"], frame)
		test_slice_on = false
	}
	fmt.eprintln("=== conflict plugin per-keystroke bench ===")
	run("no conflicts", 200, 0, 93, 10000)
	run("200 blocks, typing outside", 200, 200, 93, 10050)
	run("200 blocks, typing in a block", 200, 200, 93, 10001)
	run("2000 blocks, typing outside", 2000, 2000, 3, 10008)
	run("2000 blocks, typing in a block", 2000, 2000, 3, 10001)
	run("1 MB line, typing outside", 200, 200, 93, 10050, 100)
	run("1 MB line, in its block, no plugin", 200, 200, 93, 10004, 100, false)
	run("1 MB line, typing in its block", 200, 200, 93, 10004, 100)
	delete(test_slice_max)
}

@(test)
bench_text_hunks :: proc(t: ^testing.T) {
	if os.get_env("QED_BENCH", context.temp_allocator) == "" {
		return
	}
	text :: proc(n, every: int, changed, grow: bool, from := 0) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< n {
			if changed && i >= from && i % every == 50 {
				fmt.sbprintf(&sb, "changed line %d\n", i)
				if grow {
					fmt.sbprintf(&sb, "added line %d\n", i)
				}
			} else {
				fmt.sbprintf(&sb, "line %d of the file\n", i)
			}
		}
		return strings.to_string(sb)
	}
	run :: proc(label: string, every: int, grow: bool, from := 0) {
		saved_big := BIG_FILE_BYTES
		BIG_FILE_BYTES = max(int)
		defer BIG_FILE_BYTES = saved_big
		e := e2e_start(text(100_000, every, false, false))
		defer e2e_stop(&e)
		b := editor_buffer(&e.ed)
		next := text(100_000, every, true, grow, from)
		_ = os.write_entire_file(e.path, transmute([]u8)next)
		start := time.tick_now()
		buffer_reload(b)
		reload := ms_since(start)
		start = time.tick_now()
		buffer_undo(b)
		undo := ms_since(start)
		start = time.tick_now()
		buffer_redo(b)
		redo := ms_since(start)
		fmt.eprintfln("%-28s %6d lines  undo reload %8.2f ms  redo %8.2f ms", label, len(b.lines), undo, redo)
		orig := text(100_000, every, false, false)
		start = time.tick_now()
		hn := len(text_hunks(b, strings.split(orig, "\n", context.temp_allocator)))
		diff := ms_since(start)
		start = time.tick_now()
		buffer_set_text(b, orig)
		set := ms_since(start)
		fmt.eprintfln("%-28s %6d lines  reload %8.2f ms  set_text back %8.2f ms (%d hunks, diff alone %.2f ms)", label, len(b.lines), reload, set, hn, diff)
	}
	fmt.eprintln("=== 100k lines, scattered hunks (default build: -define:ODIN_TEST_TRACK_MEMORY=false) ===")
	run("1000 modified lines", 100, false)
	run("1000 modified + inserted lines", 100, true)
	run("200 modified lines", 500, false)
	run("200 modified + inserted lines", 500, true)
	run("200 modified in last 20k", 100, false, 80_000)
}

@(private = "file")
BenchPhases :: struct {
	dispatch, flush, prepare, render: f64,
	n:                                int,
}

@(private = "file")
bench_phase_step :: proc(e: ^E2E, ev: tb2.Event, phases: ^BenchPhases) {
	at := time.tick_now()
	editor_dispatch(&e.ed, ev)
	phases.dispatch += ms_since(at)
	at = time.tick_now()
	plugin_flush(&e.ed)
	phases.flush += ms_since(at)
	at = time.tick_now()
	ui_prepare(&e.ed)
	phases.prepare += ms_since(at)
	at = time.tick_now()
	editor_render(&e.ed)
	phases.render += ms_since(at)
	phases.n += 1
	free_all(context.temp_allocator)
}

@(private = "file")
bench_phase_print :: proc(label: string, phases: BenchPhases) {
	n := f64(max(phases.n, 1))
	fmt.eprintfln("%-16s dispatch %.3f  flush %.3f  prepare %.3f  render %.3f  total %.3f ms", label, phases.dispatch / n, phases.flush / n, phases.prepare / n, phases.render / n, (phases.dispatch + phases.flush + phases.prepare + phases.render) / n)
}

@(test)
bench_palette :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_render(&e)
	open, typing: BenchPhases
	for _ in 0 ..< 40 {
		bench_phase_step(&e, tb2.Event{type = .Key, key = .Ctrl_P}, &open)
		for ch in "togwrap" {
			bench_phase_step(&e, tb2.Event{type = .Key, ch = ch}, &typing)
		}
		e2e_key(&e, .Esc)
		e2e_render(&e)
	}
	bench_phase_print("palette open", open)
	bench_phase_print("palette typing", typing)
	fmt.eprintln("palette pieces", ft_lua(&e.ed, `
		local clock = os.clock
		local at = clock()
		for _ = 1, 100 do qed.commands() end
		local commands_ms = (clock() - at) * 10
		local list = qed.list.new{key = "name"}
		for _, command in ipairs(qed.commands()) do if command.scope == "global" then list:append{name = command.name, shortcut = command.shortcut} end end
		at = clock()
		for _ = 1, 100 do
			local fresh = qed.list.new{key = "name"}
			for _, command in ipairs(qed.commands()) do if command.scope == "global" then fresh:append{name = command.name, shortcut = command.shortcut} end end
		end
		local fill_ms = (clock() - at) * 10
		local fuzzy = qed.fuzzy.list(list, {field = "name"})
		at = clock()
		for i = 1, 100 do fuzzy:set_query(i % 2 == 0 and "tog" or "togw"); fuzzy:count() end
		local query_ms = (clock() - at) * 10
		return ("commands %.3f  fill %.3f  query %.3f  (#%d)"):format(commands_ms, fill_ms, query_ms, #qed.commands())`))
}

@(test)
bench_filetree_filter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	root := os.get_env("QED_BENCH_TREE", context.temp_allocator)
	if root == "" {
		return
	}
	e := e2e_start("x")
	defer e2e_stop(&e)
	e2e_plugin_config(&e, "git", `{"enabled": false}`)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(root)
	plugin_flush(&e.ed)
	filetree_open_all(&e.ed)
	for walk_busy(&e.ed) {
		walk_pump(&e.ed)
		thread.yield()
	}
	for ch in "file0123" {
		at := time.tick_now()
		e2e_type(&e, fmt.tprintf("%c", ch))
		typed := ms_since(at)
		ft_trees_settle(&e.ed)
		settled := ms_since(at)
		e2e_render(&e)
		fmt.eprintfln("first pass %c %.2f ms (typed %.2f, settled %.2f)  %d rows", ch, ms_since(at), typed, settled, len(ft_entries(&e.ed)))
	}
	for _ in 0 ..< 8 {
		e2e_key(&e, .Backspace2)
	}
	ft_trees_settle(&e.ed)
	queries := []string{"f", "fi", "fil", "file", "file0", "file01", "file012", "file0123", "m", "x"}
	previous := ""
	for q in queries {
		for _ in 0 ..< len(previous) {
			e2e_key(&e, .Backspace2)
		}
		ft_trees_settle(&e.ed)
		previous = q
		at := time.tick_now()
		e2e_type(&e, q)
		typed := ms_since(at)
		ft_trees_settle(&e.ed)
		settled := ms_since(at)
		e2e_render(&e)
		fmt.eprintfln("filter %-20s %.2f ms (typed %.2f, settled %.2f)  %d rows", q, ms_since(at), typed, settled, len(ft_entries(&e.ed)))
	}
}

@(test)
bench_goto_open :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	path := os.get_env("QED_BENCH_GOTO", context.temp_allocator)
	if path == "" {
		return
	}
	e := e2e_start("x")
	defer e2e_stop(&e)
	testing.expect(t, editor_open_path(&e.ed, path), "opens")
	e2e_ui_settle(&e)
	for round in 0 ..< 5 {
		at := time.tick_now()
		e2e_step(&e, tb2.Event{type = .Key, key = .Ctrl_G})
		stepped := ms_since(at)
		editor_render(&e.ed)
		fmt.eprintfln("goto open %d: %.1f ms (step %.1f)", round, ms_since(at), stepped)
		e2e_key(&e, .Esc)
		e2e_ui_settle(&e)
		free_all(context.temp_allocator)
	}
}

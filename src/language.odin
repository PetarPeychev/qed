package main

import "core:os"
import "core:slice"
import "core:strings"
import ts "lib:tree_sitter"

Language :: enum {
	Plain,
	Odin,
	C,
	JavaScript,
	Jsx,
	TypeScript,
	Tsx,
	Python,
	Shell,
	Lua,
	Sql,
	Yaml,
	Toml,
	Json,
	Markdown,
	MarkdownInline,
}

LanguageInfo :: struct {
	name:       string,
	comment:    string,
	lsp_server: string,
	lsp_id:     string,
	formatter:  string,
	grammar:    proc "c" () -> ts.Language,
	highlights: []u8,
	injections: []u8,
}

LANGUAGES := [Language]LanguageInfo {
	.Plain      = {"text", "//", "", "", "", nil, nil, nil},
	.Odin       = {"odin", "//", "ols", "odin", "", ts.tree_sitter_odin, #load("../lib/tree_sitter/odin/highlights.scm"), nil},
	.C          = {"c", "//", "clangd", "c", "", ts.tree_sitter_c, #load("../lib/tree_sitter/c/highlights.scm"), nil},
	.JavaScript = {"javascript", "//", "typescript-language-server --stdio", "javascript", "", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.Jsx        = {"jsx", "//", "typescript-language-server --stdio", "javascriptreact", "", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.TypeScript = {"typescript", "//", "typescript-language-server --stdio", "typescript", "", ts.tree_sitter_typescript, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Tsx        = {"tsx", "//", "typescript-language-server --stdio", "typescriptreact", "", ts.tree_sitter_tsx, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Python     = {"python", "#", "pyright-langserver --stdio", "python", "ruff format -", ts.tree_sitter_python, #load("../lib/tree_sitter/python/highlights.scm"), nil},
	.Shell      = {"shell", "#", "bash-language-server start", "shellscript", "", ts.tree_sitter_bash, #load("../lib/tree_sitter/bash/highlights.scm"), nil},
	.Lua        = {"lua", "--", "lua-language-server", "lua", "", ts.tree_sitter_lua, #load("../lib/tree_sitter/lua/highlights.scm"), nil},
	.Sql        = {"sql", "--", "", "", "", ts.tree_sitter_sql, #load("../lib/tree_sitter/sql/highlights.scm"), nil},
	.Yaml       = {"yaml", "#", "", "", "", nil, nil, nil},
	.Toml       = {"toml", "#", "", "", "", nil, nil, nil},
	.Json       = {"json", "", "", "", "", ts.tree_sitter_json, #load("../lib/tree_sitter/json/highlights.scm"), nil},
	.Markdown   = {"markdown", "", "", "", "", ts.tree_sitter_markdown, #load("../lib/tree_sitter/markdown/highlights.scm"), #load("../lib/tree_sitter/markdown/injections.scm")},
	.MarkdownInline = {"markdown_inline", "", "", "", "", ts.tree_sitter_markdown_inline, #load("../lib/tree_sitter/markdown_inline/highlights.scm"), nil},
}

LangRule :: struct {
	pattern:  string,
	language: Language,
}

DEFAULT_LANGUAGES := [?]LangRule {
	{"*.odin", .Odin},
	{"*.c", .C},
	{"*.h", .C},
	{"*.js", .JavaScript},
	{"*.mjs", .JavaScript},
	{"*.cjs", .JavaScript},
	{"*.jsx", .Jsx},
	{"*.ts", .TypeScript},
	{"*.mts", .TypeScript},
	{"*.cts", .TypeScript},
	{"*.tsx", .Tsx},
	{"*.py", .Python},
	{"*.pyw", .Python},
	{"*.sh", .Shell},
	{"*.bash", .Shell},
	{"*.zsh", .Shell},
	{".bashrc", .Shell},
	{".bash_profile", .Shell},
	{".bash_aliases", .Shell},
	{".profile", .Shell},
	{".zshrc", .Shell},
	{".zshenv", .Shell},
	{".zprofile", .Shell},
	{"PKGBUILD", .Shell},
	{"*.lua", .Lua},
	{".luacheckrc", .Lua},
	{"*.sql", .Sql},
	{"*.yaml", .Yaml},
	{"*.yml", .Yaml},
	{"*.toml", .Toml},
	{"*.json", .Json},
	{"*.md", .Markdown},
	{"*.markdown", .Markdown},
}

g_language_rules: [dynamic]LangRule

// Most-specific first (exact before glob, longer before shorter): language_of takes the first match.
// Backed by the OS heap, not context.allocator: this global outlives any single
// config-load call (and any per-test allocator that would otherwise reclaim it).
language_rules_set :: proc(rules: []LangRule) {
	if g_language_rules == nil {
		g_language_rules = make([dynamic]LangRule, 0, len(rules), os.heap_allocator())
	}
	clear(&g_language_rules)
	append(&g_language_rules, ..rules)
	slice.sort_by(g_language_rules[:], proc(a, b: LangRule) -> bool {
		aw := strings.contains_rune(a.pattern, '*')
		bw := strings.contains_rune(b.pattern, '*')
		if aw != bw {
			return !aw
		}
		if len(a.pattern) != len(b.pattern) {
			return len(a.pattern) > len(b.pattern)
		}
		return a.pattern < b.pattern
	})
}

languages_reset_defaults :: proc() {
	language_rules_set(DEFAULT_LANGUAGES[:])
}

language_is_default_pattern :: proc(pattern: string) -> bool {
	for def in DEFAULT_LANGUAGES {
		if def.pattern == pattern {
			return true
		}
	}
	return false
}

language_from_name :: proc(name: string) -> (Language, bool) {
	for info, lang in LANGUAGES {
		if info.name == name {
			return lang, true
		}
	}
	return .Plain, false
}

glob_match :: proc(pattern, s: string) -> bool {
	p, i := 0, 0
	star := -1
	mark := 0
	for i < len(s) {
		if p < len(pattern) && pattern[p] == s[i] {
			p += 1
			i += 1
		} else if p < len(pattern) && pattern[p] == '*' {
			star = p
			mark = i
			p += 1
		} else if star != -1 {
			p = star + 1
			mark += 1
			i = mark
		} else {
			return false
		}
	}
	for p < len(pattern) && pattern[p] == '*' {
		p += 1
	}
	return p == len(pattern)
}

language_of :: proc(path: string) -> Language {
	slash := strings.last_index_byte(path, '/')
	name := path[slash + 1:]
	for rule in g_language_rules {
		if glob_match(rule.pattern, name) {
			return rule.language
		}
	}
	return .Plain
}

// Map a fenced-code-block info string (```ts, ```python, …) to a Language for
// injection. Only languages qed has a grammar for are worth returning; anything
// else falls to .Plain and the injection is skipped.
language_of_name :: proc(name: string) -> Language {
	switch name {
	case "js", "javascript", "mjs", "cjs":
		return .JavaScript
	case "jsx":
		return .Jsx
	case "ts", "typescript":
		return .TypeScript
	case "tsx":
		return .Tsx
	case "py", "python":
		return .Python
	case "c", "h":
		return .C
	case "odin":
		return .Odin
	case "json":
		return .Json
	case "sh", "bash", "shell", "zsh":
		return .Shell
	case "lua":
		return .Lua
	case "sql":
		return .Sql
	}
	return .Plain
}

package main

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import ts "lib:tree_sitter"

Language :: enum {
	Plain,
	Odin,
	C,
	Cpp,
	JavaScript,
	Jsx,
	TypeScript,
	Tsx,
	Python,
	Go,
	Rust,
	Shell,
	Lua,
	Sql,
	Yaml,
	Toml,
	Dockerfile,
	Json,
	Html,
	Css,
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

// LANGUAGE_DEFAULTS is compiled-in wiring only (name, comment token, lsp id,
// grammar, queries); the user-facing fields — patterns, lsp_server, formatter —
// are seeded from the embedded config/config.json `languages` section.
LANGUAGE_DEFAULTS := [Language]LanguageInfo {
	.Plain      = {"text", "//", "", "", "", nil, nil, nil},
	.Odin       = {"odin", "//", "", "odin", "", ts.tree_sitter_odin, #load("../lib/tree_sitter/odin/highlights.scm"), nil},
	.C          = {"c", "//", "", "c", "", ts.tree_sitter_c, #load("../lib/tree_sitter/c/highlights.scm"), nil},
	.Cpp        = {"cpp", "//", "", "cpp", "", ts.tree_sitter_cpp, #load("../lib/tree_sitter/cpp/highlights.scm"), nil},
	.JavaScript = {"javascript", "//", "", "javascript", "", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.Jsx        = {"jsx", "//", "", "javascriptreact", "", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.TypeScript = {"typescript", "//", "", "typescript", "", ts.tree_sitter_typescript, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Tsx        = {"tsx", "//", "", "typescriptreact", "", ts.tree_sitter_tsx, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Python     = {"python", "#", "", "python", "", ts.tree_sitter_python, #load("../lib/tree_sitter/python/highlights.scm"), nil},
	.Go         = {"go", "//", "", "go", "", ts.tree_sitter_go, #load("../lib/tree_sitter/go/highlights.scm"), nil},
	.Rust       = {"rust", "//", "", "rust", "", ts.tree_sitter_rust, #load("../lib/tree_sitter/rust/highlights.scm"), nil},
	.Shell      = {"shell", "#", "", "shellscript", "", ts.tree_sitter_bash, #load("../lib/tree_sitter/bash/highlights.scm"), nil},
	.Lua        = {"lua", "--", "", "lua", "", ts.tree_sitter_lua, #load("../lib/tree_sitter/lua/highlights.scm"), nil},
	.Sql        = {"sql", "--", "", "", "", ts.tree_sitter_sql, #load("../lib/tree_sitter/sql/highlights.scm"), nil},
	.Yaml       = {"yaml", "#", "", "yaml", "", ts.tree_sitter_yaml, #load("../lib/tree_sitter/yaml/highlights.scm"), nil},
	.Toml       = {"toml", "#", "", "toml", "", ts.tree_sitter_toml, #load("../lib/tree_sitter/toml/highlights.scm"), nil},
	.Dockerfile = {"dockerfile", "#", "", "dockerfile", "", ts.tree_sitter_dockerfile, #load("../lib/tree_sitter/dockerfile/highlights.scm"), nil},
	.Json       = {"json", "", "", "", "", ts.tree_sitter_json, #load("../lib/tree_sitter/json/highlights.scm"), nil},
	.Html       = {"html", "", "", "html", "", ts.tree_sitter_html, #load("../lib/tree_sitter/html/highlights.scm"), #load("../lib/tree_sitter/html/injections.scm")},
	.Css        = {"css", "", "", "css", "", ts.tree_sitter_css, #load("../lib/tree_sitter/css/highlights.scm"), nil},
	.Markdown   = {"markdown", "", "", "", "", ts.tree_sitter_markdown, #load("../lib/tree_sitter/markdown/highlights.scm"), #load("../lib/tree_sitter/markdown/injections.scm")},
	.MarkdownInline = {"markdown_inline", "", "", "", "", ts.tree_sitter_markdown_inline, #load("../lib/tree_sitter/markdown_inline/highlights.scm"), nil},
}

LANGUAGES := LANGUAGE_DEFAULTS

LangRule :: struct {
	pattern:  string,
	language: Language,
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
	LANGUAGES = LANGUAGE_DEFAULTS
}

// Languages named in the embedded config's `languages` section, in enum order.
// This is the set materialized into the config `languages` section.
default_pattern_languages :: proc(allocator := context.temp_allocator) -> []Language {
	langs, _ := g_config_defaults["languages"].(json.Object)
	out := make([dynamic]Language, allocator)
	for info, lang in LANGUAGES {
		if info.name in langs {
			append(&out, lang)
		}
	}
	return out[:]
}

// Pattern strings point into g_config_defaults, which lives for the whole run.
append_default_patterns :: proc(rules: ^[dynamic]LangRule, lang: Language) {
	langs, _ := g_config_defaults["languages"].(json.Object)
	sub, _ := langs[LANGUAGES[lang].name].(json.Object)
	arr, _ := sub["patterns"].(json.Array)
	for e in arr {
		if s, is := e.(json.String); is {
			append(rules, LangRule{string(s), lang})
		}
	}
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
	case "go", "golang":
		return .Go
	case "rs", "rust":
		return .Rust
	case "c", "h":
		return .C
	case "cpp", "c++", "cxx", "cc", "hpp", "hh":
		return .Cpp
	case "odin":
		return .Odin
	case "json":
		return .Json
	case "html", "htm":
		return .Html
	case "css":
		return .Css
	case "sh", "bash", "shell", "zsh":
		return .Shell
	case "lua":
		return .Lua
	case "sql":
		return .Sql
	case "toml":
		return .Toml
	case "yaml", "yml":
		return .Yaml
	case "dockerfile", "docker":
		return .Dockerfile
	}
	return .Plain
}

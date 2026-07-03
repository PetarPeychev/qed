package main

import "core:strings"
import ts "lib:tree_sitter"

Language :: enum {
	Plain,
	Odin,
	C,
	Cpp,
	Go,
	Rust,
	JavaScript,
	TypeScript,
	Python,
	Shell,
	Lua,
	Sql,
	Yaml,
	Toml,
	Json,
	Markdown,
}

LanguageInfo :: struct {
	name:       string,
	comment:    string,
	lsp_server: string,
	lsp_id:     string,
	grammar:    proc "c" () -> ts.Language,
	highlights: []u8,
}

LANGUAGES := [Language]LanguageInfo {
	.Plain      = {"text", "//", "", "", nil, nil},
	.Odin       = {"odin", "//", "ols", "odin", ts.tree_sitter_odin, #load("../lib/tree_sitter/odin/highlights.scm")},
	.C          = {"c", "//", "clangd", "c", ts.tree_sitter_c, #load("../lib/tree_sitter/c/highlights.scm")},
	.Cpp        = {"c++", "//", "", "", nil, nil},
	.Go         = {"go", "//", "", "", nil, nil},
	.Rust       = {"rust", "//", "", "", nil, nil},
	.JavaScript = {"javascript", "//", "", "", nil, nil},
	.TypeScript = {"typescript", "//", "", "", nil, nil},
	.Python     = {"python", "#", "pyright-langserver --stdio", "python", ts.tree_sitter_python, #load("../lib/tree_sitter/python/highlights.scm")},
	.Shell      = {"shell", "#", "", "", nil, nil},
	.Lua        = {"lua", "--", "", "", nil, nil},
	.Sql        = {"sql", "--", "", "", nil, nil},
	.Yaml       = {"yaml", "#", "", "", nil, nil},
	.Toml       = {"toml", "#", "", "", nil, nil},
	.Json       = {"json", "", "", "", ts.tree_sitter_json, #load("../lib/tree_sitter/json/highlights.scm")},
	.Markdown   = {"markdown", "", "", "", nil, nil},
}

language_of :: proc(path: string) -> Language {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_byte(path, '/')
	if dot <= slash {
		return .Plain
	}
	switch path[dot + 1:] {
	case "odin":
		return .Odin
	case "c", "h":
		return .C
	case "cc", "cpp", "cxx", "hpp", "hh", "hxx":
		return .Cpp
	case "go":
		return .Go
	case "rs":
		return .Rust
	case "js", "jsx", "mjs", "cjs":
		return .JavaScript
	case "ts", "tsx":
		return .TypeScript
	case "py", "pyw":
		return .Python
	case "sh", "bash", "zsh":
		return .Shell
	case "lua":
		return .Lua
	case "sql":
		return .Sql
	case "yaml", "yml":
		return .Yaml
	case "toml":
		return .Toml
	case "json":
		return .Json
	case "md", "markdown":
		return .Markdown
	}
	return .Plain
}

language_info :: proc(path: string) -> LanguageInfo {
	return LANGUAGES[language_of(path)]
}

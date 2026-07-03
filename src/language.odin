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
}

LANGUAGES := [Language]LanguageInfo {
	.Plain      = {"text", "//", "", "", nil},
	.Odin       = {"odin", "//", "ols", "odin", ts.tree_sitter_odin},
	.C          = {"c", "//", "", "", nil},
	.Cpp        = {"c++", "//", "", "", nil},
	.Go         = {"go", "//", "", "", nil},
	.Rust       = {"rust", "//", "", "", nil},
	.JavaScript = {"javascript", "//", "", "", nil},
	.TypeScript = {"typescript", "//", "", "", nil},
	.Python     = {"python", "#", "", "", nil},
	.Shell      = {"shell", "#", "", "", nil},
	.Lua        = {"lua", "--", "", "", nil},
	.Sql        = {"sql", "--", "", "", nil},
	.Yaml       = {"yaml", "#", "", "", nil},
	.Toml       = {"toml", "#", "", "", nil},
	.Json       = {"json", "", "", "", nil},
	.Markdown   = {"markdown", "", "", "", nil},
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

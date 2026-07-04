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
	grammar:    proc "c" () -> ts.Language,
	highlights: []u8,
	injections: []u8,
}

LANGUAGES := [Language]LanguageInfo {
	.Plain      = {"text", "//", "", "", nil, nil, nil},
	.Odin       = {"odin", "//", "ols", "odin", ts.tree_sitter_odin, #load("../lib/tree_sitter/odin/highlights.scm"), nil},
	.C          = {"c", "//", "clangd", "c", ts.tree_sitter_c, #load("../lib/tree_sitter/c/highlights.scm"), nil},
	.Cpp        = {"c++", "//", "", "", nil, nil, nil},
	.Go         = {"go", "//", "", "", nil, nil, nil},
	.Rust       = {"rust", "//", "", "", nil, nil, nil},
	.JavaScript = {"javascript", "//", "typescript-language-server --stdio", "javascript", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.Jsx        = {"jsx", "//", "typescript-language-server --stdio", "javascriptreact", ts.tree_sitter_javascript, #load("../lib/tree_sitter/javascript/highlights.scm"), nil},
	.TypeScript = {"typescript", "//", "typescript-language-server --stdio", "typescript", ts.tree_sitter_typescript, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Tsx        = {"tsx", "//", "typescript-language-server --stdio", "typescriptreact", ts.tree_sitter_tsx, #load("../lib/tree_sitter/typescript/highlights.scm"), nil},
	.Python     = {"python", "#", "pyright-langserver --stdio", "python", ts.tree_sitter_python, #load("../lib/tree_sitter/python/highlights.scm"), nil},
	.Shell      = {"shell", "#", "bash-language-server start", "shellscript", ts.tree_sitter_bash, #load("../lib/tree_sitter/bash/highlights.scm"), nil},
	.Lua        = {"lua", "--", "lua-language-server", "lua", ts.tree_sitter_lua, #load("../lib/tree_sitter/lua/highlights.scm"), nil},
	.Sql        = {"sql", "--", "", "", ts.tree_sitter_sql, #load("../lib/tree_sitter/sql/highlights.scm"), nil},
	.Yaml       = {"yaml", "#", "", "", nil, nil, nil},
	.Toml       = {"toml", "#", "", "", nil, nil, nil},
	.Json       = {"json", "", "", "", ts.tree_sitter_json, #load("../lib/tree_sitter/json/highlights.scm"), nil},
	.Markdown   = {"markdown", "", "", "", ts.tree_sitter_markdown, #load("../lib/tree_sitter/markdown/highlights.scm"), #load("../lib/tree_sitter/markdown/injections.scm")},
	.MarkdownInline = {"markdown_inline", "", "", "", ts.tree_sitter_markdown_inline, #load("../lib/tree_sitter/markdown_inline/highlights.scm"), nil},
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
	case "js", "mjs", "cjs":
		return .JavaScript
	case "jsx":
		return .Jsx
	case "ts", "mts", "cts":
		return .TypeScript
	case "tsx":
		return .Tsx
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

language_info :: proc(path: string) -> LanguageInfo {
	return LANGUAGES[language_of(path)]
}

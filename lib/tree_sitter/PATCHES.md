# Vendored tree-sitter (runtime + grammars)

This directory carries a pinned copy of the tree-sitter C runtime and each
vendored grammar, plus the Odin FFI bindings and the highlight queries qed uses.
Everything is vendored so the build is self-contained and reproducible — same
approach as `lib/tb2/`.

## Provenance (exact pins)

| Component | Source | Pin |
|-----------|--------|-----|
| Runtime   | `github.com/tree-sitter/tree-sitter` | `v0.26.10` (`3fc4cd21bca378f8acf8c823809de4706b1808f6`) |
| Odin grammar | `github.com/tree-sitter-grammars/tree-sitter-odin` | `d2ca8efb4487e156a60d5bd6db2598b872629403` (v1.3.0) |
| JSON grammar | `github.com/tree-sitter/tree-sitter-json` | `ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24` (v0.24.8) |
| Python grammar | `github.com/tree-sitter/tree-sitter-python` | `d326e4cad262cf681656e130960e49dfc04c03ea` (v0.25.0) |
| C grammar | `github.com/tree-sitter/tree-sitter-c` | `7fa1be1b694b6e763686793d97da01f36a0e5c12` (v0.24.1) |
| JavaScript grammar | `github.com/tree-sitter/tree-sitter-javascript` | `44c892e0be055ac465d5eeddae6d3e194424e7de` (v0.25.0) |
| TypeScript grammar | `github.com/tree-sitter/tree-sitter-typescript` | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` (v0.23.2) — provides `typescript`/`tsx` |
| Markdown grammar | `github.com/tree-sitter-grammars/tree-sitter-markdown` | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5` (v0.5.3) — provides `markdown` (block) + `markdown_inline` |
| Bash grammar | `github.com/tree-sitter/tree-sitter-bash` | `56b54c61fb48bce0c63e3dfa2240b5d274384763` (v0.25.0) |
| Lua grammar | `github.com/tree-sitter-grammars/tree-sitter-lua` | `10fe0054734eec83049514ea2e718b2a56acd0c9` (v0.5.0) |
| SQL grammar | `github.com/DerekStride/tree-sitter-sql` | `7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8` (v0.3.11) — `parser.c` is gitignored upstream, generated with `tree-sitter generate` (CLI v0.25.10) |

Each grammar's `src/parser.c` (Odin's is ~15 MB) and `src/scanner.c` (Odin,
Python; JSON and C have none) are **generated** artifacts committed upstream; we
vendor them as-is (no `tree-sitter generate` step is needed or run).

## Layout

One directory per grammar, each holding its parser, optional scanner, private
headers, and its own highlight query:

```
runtime/include/  tree_sitter/api.h          runtime public header
runtime/src/      lib.c + the amalgamated .c  compiled into libtreesitter.a
odin/             parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (ABI 14)
json/             parser.c,           tree_sitter/*.h, highlights.scm
python/           parser.c, scanner.c, tree_sitter/*.h, highlights.scm
c/                parser.c,           tree_sitter/*.h, highlights.scm
javascript/       parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (used for .js/.jsx)
typescript/       parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (used for .ts and .tsx)
tsx/              parser.c, scanner.c, tree_sitter/*.h                    (.tsx grammar; shares typescript's query)
common/           scanner.h                  shared TS/TSX external scanner (from the TS repo)
markdown/         parser.c, scanner.c, tree_sitter/*.h, highlights.scm, injections.scm   (block)
markdown_inline/  parser.c, scanner.c, tree_sitter/*.h, highlights.scm    (inline, injection-only)
bash/             parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (.sh/.bash/.zsh)
lua/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm
sql/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm
ts.odin           Odin FFI bindings          the ~15 procs qed calls
```

The `typescript` and `tsx` grammars share one external scanner living in the TS
repo's `common/scanner.h`. Upstream each `<lang>/src/scanner.c` includes it as
`../../common/scanner.h`; qed's layout drops the `src/` level, so the include was
**patched** to `../common/scanner.h`. `build.sh` compiles each with `-I` on its own
dir so `tree_sitter/parser.h` resolves. The two scanners export distinct
`tree_sitter_typescript_*` / `tree_sitter_tsx_*` symbols (no link clash); all
helpers in `common/scanner.h` are `static`.

`build.sh` compiles `runtime/src/lib.c` plus each grammar's `parser.c`/
`scanner.c` into `libtreesitter.a`; `ts.odin`'s `foreign import "libtreesitter.a"`
links it and declares one `tree_sitter_<lang>` entry point per grammar. The
`.scm` queries are `#load`ed by Odin (`LANGUAGES[…].highlights` in
`src/language.odin`), not compiled.

WASM support is **off**: `lib.c` `#include`s `wasm_store.c`, but that file is
gated behind `TREE_SITTER_FEATURE_WASM` (undefined here), so it compiles empty
and pulls in no wasmtime dependency. The `runtime/src/wasm*` files are therefore
inert dead weight kept only so `lib.c`'s include resolves.

## Patches to the queries

Every grammar's upstream `highlights.scm` is the same story: predicate-gated
rules the tree-sitter **C core does not evaluate** must be removed, because qed
does **structural-only** highlighting (real syntax-tree facts, no name-shape
guessing — precise type/constant *usage* coloring is deferred to LSP semantic
tokens). An unevaluated gating predicate means the rule matches unconditionally.
If any query is re-vendored, re-apply the removals below (or add a predicate
evaluator).

### `json/highlights.scm`

Predicate-free upstream — vendored **verbatim**, no removals.

### `python/highlights.scm`

Three `#match?`-gated identifier heuristics removed (each would otherwise match
*every* identifier):

- `((identifier) @constructor (#match? … "^[A-Z]"))` — **removed** (the most
  harmful: `@constant` below would color every identifier).
- `((identifier) @constant (#match? … "^[A-Z][A-Z_]*$"))` — **removed**.
- `((call function: (identifier) @function.builtin) (#match? …))` builtin-call
  list — **removed**.

Everything predicate-free is kept: keywords, operators, `(type (identifier)
@type)`, function/decorator/definition names (`@function`/`@property` are
unmapped, so they render plain), strings, comments, numbers, `(none)/(true)/
(false)` constants, escapes.

### `c/highlights.scm`

One `#match?`-gated identifier heuristic removed (it would otherwise match
*every* identifier):

- `((identifier) @constant (#match? … "^[A-Z][A-Z\d_]*$"))` — **removed** (would
  paint every identifier in the constant color).

Everything predicate-free is kept: keywords, preproc directives, operators,
delimiters, strings/system-lib strings, `(null)`/number/char constants, type
identifiers / primitive & sized types, function-call and declarator names
(`@function`/`@function.special` are unmapped, so they render plain),
`(identifier) @variable` (unmapped → plain), comments.

### `javascript/highlights.scm`

Upstream JS query minus its four predicate-gated rules (qed's core doesn't
evaluate predicates, so a gated rule matches unconditionally):

- `((identifier) @constant (#match? … "^[A-Z_][A-Z\d_]+$"))` — **removed** (the
  harmful one: `@constant` is painted, so it would color *every* identifier).
- `((identifier) @constructor (#match? … "^[A-Z]"))` — **removed**.
- `((identifier) @variable.builtin (#match? …))` and `@function.builtin (#eq?
  "require")` — **removed**.

Everything predicate-free is kept: keywords, strings/template strings, regex
(`@string.special`), comments, numbers, `true`/`false`/`null`/`undefined`,
operators/punctuation (unmapped → plain), and the `@function`/`@property`/
`@variable` structural captures (unmapped → plain). No JSX-tag rules added — qed
has no `@tag` color bucket, so JSX tags render plain by design.

### `typescript/highlights.scm`

The JavaScript base **inlined** (upstream TS is `; inherits: javascript`, which
qed can't express) plus the TS additions, curated the same way. Used by **both**
the `typescript` and `tsx` grammars (`.tsx` JSX nodes are already covered by the
inlined JS rules; qed maps no JSX-specific captures). Removed the two
predicate-gated identifier heuristics:

- `((identifier) @type (#match? … "^[A-Z]"))` — **removed** (would paint every
  identifier as a type).
- (plus the four inherited JS `#match?`/`#eq?` rules above.)

Kept predicate-free: `(type_identifier) @type`, `(predefined_type) @type.builtin`,
type-argument brackets, parameter identifiers (unmapped → plain), and the TS
keyword set (`interface`, `type`, `enum`, `readonly`, …).

### `markdown/` + `markdown_inline/` (block + inline, injected)

Markdown is qed's one **injected** language: the block grammar parses structure,
and `highlight.odin`'s injection pass re-parses `(inline)` nodes with the
`markdown_inline` grammar and fenced code blocks with the language named by their
info string (`language_of_name`). See DESIGN.md §"Multiple servers / grammars".

Both `highlights.scm` are predicate-free upstream (nvim-flavored `@text.*` capture
names) and vendored near-verbatim; the capture→color choices are Petar's taste,
made by re-labeling captures to qed's vocabulary rather than by touching shared
code:
- Headings, list/heading/quote markers, thematic breaks → `@keyword` (yellow).
- `@text.strong` → attribute (yellow), `@text.emphasis` → comment (orange).
- Links: real `[text](url)` brackets + text + destination/label → blue
  (`@text.uri`/`@text.reference`). A bare `shortcut_link` `[text]` is left
  **uncolored** so stray brackets and malformed checkboxes don't read as links.
- GFM task checkboxes: `(task_list_marker_unchecked)` → `@keyword` (yellow),
  `(task_list_marker_checked)` → `@string` (green).
- Inline `code_span` + its backticks, and the `fenced_code_block_delimiter` +
  `info_string` (```lang) → `@text.code`, mapped to `COLOR_SYN_CODE`.
- `fenced_code_block`/`code_fence_content` stay unmapped so the injected language
  paints the body.

`injections.scm` is **rewritten** (not vendored): upstream encodes the target with
`(#set! injection.language …)` predicates the C core doesn't evaluate, so qed
can't read them. Instead the target is encoded by **capture name** — `@inline`
means the `markdown_inline` grammar, `@language`+`@content` means the language
named by `@language`'s text. Only `(paragraph (inline))` is injected (not
`atx_heading` inlines, so headings keep their solid title color); the html/yaml/
toml metadata injections are dropped (no grammar for them).

The new `@text.*` / `@text.code` capture names are mapped in
`src/highlight.odin`'s `syntax_capture_color` (see below).

### `bash/highlights.scm`

One `#match?`-gated rule removed:

- `((command (_) @constant) (#match? @constant "^-"))` — **removed** (would paint
  every command argument, not just `-`-prefixed flags, in the constant color).

Everything predicate-free is kept: strings/heredocs, `(command_name)`/function
names (`@function` unmapped → plain), `(variable_name)` (`@property` → plain),
the keyword set, comments, `(file_descriptor)` numbers, command/process/expansion
substitutions (`@embedded` → plain), operators (`@operator` → plain).

### `lua/highlights.scm`

Three predicate-gated rules removed (qed's core doesn't evaluate predicates, so a
gated rule matches unconditionally):

- `((identifier) @constant (#match? … "^[A-Z][A-Z_0-9]*$"))` — **removed** (the
  harmful one: `@constant` is painted, so it would color *every* identifier).
- `((identifier) @variable.builtin (#eq? … "self"))` — **removed** (`@variable.builtin`
  is unmapped → plain, so cosmetically harmless, but dropped for consistency).
- `((function_call (identifier) @function.builtin) (#any-of? …))` builtin list —
  **removed** (`@function.builtin` unmapped → plain; dropped for consistency).

Kept predicate-free: keywords/conditionals/repeats (all → keyword color),
`(nil)`/`(vararg_expression)`/booleans (constant), strings + escapes, numbers,
comments, `(hash_bang_line)` (`@preproc` → attribute). Structural `@function`/
`@field`/`@method`/`@parameter`/`@variable`/`@operator`/`@punctuation.*` are
unmapped → plain (qed's "identifiers stay plain" scope).

### `sql/highlights.scm`

Two `#match?`-gated `(literal)` rules removed:

- `((literal) @number (#match? … "^[-+]?%d+$"))` — **removed**.
- `((literal) @float (#match? … "^[-+]?%d*\.%d*$"))` — **removed**.

The grammar exposes numbers and strings as the same `(literal)` node, split only
by these regexes; with no predicate evaluator both would match unconditionally and
overwrite `(literal) @string` — painting *all* literals (including strings) the
constant color. Removing them leaves `(literal) @string`, so numeric literals
render in the string color (acceptable: the tree has no structural number node).
Everything else is kept: the large `keyword_*` set (→ keyword), `keyword_*`
type-qualifier/builtin/storageclass/conditional/operator groups, `(object_reference
… @type)`, `(invocation … @function.call)` (unmapped → plain), comments, booleans,
`(field … @field)`/`(parameter) @parameter`/`(relation alias) @variable` (plain).

### `odin/highlights.scm`

The upstream query is **Neovim-flavored**: several rules gate a capture behind
predicates the tree-sitter **C core does not evaluate** — `#lua-match?`,
`#not-has-parent?` (Neovim extensions), and the standard `#any-of?`/`#set!`
(core-known but only enforced if the *caller* checks them, which qed does not).
An unevaluated gating predicate means the rule matches unconditionally, so e.g.
`((identifier) @type (#lua-match? …))` would paint *every* identifier as a type.

qed does **structural-only** highlighting (real syntax-tree facts, no
name-shape guessing — precise type/constant *usage* coloring is deferred to LSP
semantic tokens). So the predicate-gated rules were removed:

- `(#lua-match? … "^[A-Z]…")` → identifier-as-type heuristic — **removed**.
- `(#lua-match? … "^_*[A-Z][A-Z0-9_]*$")` → identifier-as-constant and
  call-as-macro heuristics — **removed**.
- `(#any-of? @type.builtin …)` builtin-type list and `(#any-of? @variable.builtin
  "context" "self")` — **removed** (the core wouldn't filter them, so they'd
  mis-tag; declared/annotated builtin types still color via `(type (identifier)
  @type)`).
- `(#set! "priority" 105)` on the ternary rule — **removed** (qed's paint order
  is document order with later/more-specific captures overwriting; no priority
  engine).
- `(procedure_declaration (identifier) @type)` — **removed**. Upstream tags a
  proc-declaration name `@type` and then overwrites it with `@function`; qed
  leaves `@function` unmapped (procedures render plain), so without removing this
  the `@type` paint would stick and proc names would show in the type color.

Everything predicate-free is kept and works: keywords, declared/annotated types,
proc declarations, call targets, strings, comments, numbers, booleans, escapes,
attributes, punctuation. If this query is ever re-vendored, re-apply these
removals (or add a predicate evaluator).

## Capture → color mapping

Lives in `src/highlight.odin` (`syntax_capture_color`), mapping capture-name
prefixes to the `COLOR_SYN_*` constants in `src/config.odin`. Captures with no
mapping (e.g. `@function`, `@variable`, `@parameter`, `@field`, `@operator`,
`@punctuation.*`) render as default text — this is the "Rich but procedures/
operators/identifiers stay plain" scope.

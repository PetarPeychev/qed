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
ts.odin           Odin FFI bindings          the ~15 procs qed calls
```

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

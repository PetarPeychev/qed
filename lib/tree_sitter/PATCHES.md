# Vendored tree-sitter (runtime + Odin grammar)

This directory carries a pinned copy of the tree-sitter C runtime and the
tree-sitter Odin grammar, plus the Odin FFI bindings and highlight query qed
uses. Everything is vendored so the build is self-contained and reproducible —
same approach as `lib/tb2/`.

## Provenance (exact pins)

| Component | Source | Pin |
|-----------|--------|-----|
| Runtime   | `github.com/tree-sitter/tree-sitter` | `v0.26.10` (`3fc4cd21bca378f8acf8c823809de4706b1808f6`) |
| Grammar   | `github.com/tree-sitter-grammars/tree-sitter-odin` | `d2ca8efb4487e156a60d5bd6db2598b872629403` (v1.3.0) |

The grammar's `src/parser.c` (~15 MB) and `src/scanner.c` are **generated**
artifacts committed upstream; we vendor them as-is (no `tree-sitter generate`
step is needed or run).

## Layout

```
runtime/include/  tree_sitter/api.h          runtime public header
runtime/src/      lib.c + the amalgamated .c  compiled into libtreesitter.a
odin/             parser.c, scanner.c         the Odin grammar (ABI 14)
odin/tree_sitter/ parser.h, array.h, alloc.h  grammar-private headers
highlights.scm    the highlight query        (patched — see below)
ts.odin           Odin FFI bindings          the ~15 procs qed calls
```

`build.sh` compiles `runtime/src/lib.c`, `odin/parser.c`, and `odin/scanner.c`
into `libtreesitter.a`; `ts.odin`'s `foreign import "libtreesitter.a"` links it.

WASM support is **off**: `lib.c` `#include`s `wasm_store.c`, but that file is
gated behind `TREE_SITTER_FEATURE_WASM` (undefined here), so it compiles empty
and pulls in no wasmtime dependency. The `runtime/src/wasm*` files are therefore
inert dead weight kept only so `lib.c`'s include resolves.

## Patches to `highlights.scm`

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

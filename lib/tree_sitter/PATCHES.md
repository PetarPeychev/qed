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
| Go grammar | `github.com/tree-sitter/tree-sitter-go` | `6048bfc6e5238eaf062c2221bd934489c39fbb61` (v0.25.0) — no external scanner |
| Rust grammar | `github.com/tree-sitter/tree-sitter-rust` | `77a3747266f4d621d0757825e6b11edcbf991ca5` (v0.24.2) — C scanner |
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
go/               parser.c,           tree_sitter/*.h, highlights.scm   (no scanner)
rust/             parser.c, scanner.c, tree_sitter/*.h, highlights.scm
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

## Queries: vendored verbatim + the predicate evaluator

Every grammar's `highlights.scm` is now vendored **verbatim** from upstream at the
pin in the provenance table. This works because qed evaluates query predicates
(`src/predicate.odin`) instead of stripping the predicate-gated rules — so the
name-shape heuristics upstream relies on (SCREAMING_CASE → `@constant`,
Capitalized → `@type`/`@constructor`, `-flag` → `@constant`, builtin lists) are
live. The tree-sitter **C core parses but does not evaluate** predicates; the
evaluator reads them via `ts_query_predicates_for_pattern` /
`ts_query_string_value_for_id`, caches them per pattern at query-build time, and
runs them per match on the paint path, discarding matches whose predicates fail.

### The evaluator

Predicates are parsed once (`query_predicates_build`) alongside each `Syntax`
query (host + injection) and cached per pattern index; regexes are compiled once
there, not per match. `predicate_pass` runs a pattern's filter predicates against
a match's captured node texts (extracted from the buffer or the parsed source
slice) at every query-execution site: the main paint (`highlight_query_paint`),
the injection pass (`highlight_inject`), injected sub-language paint
(`highlight_inject_region`), and the preview path (`highlight_lines`).

Supported predicates:

- `#eq?` / `#not-eq?` / `#any-eq?` / `#any-not-eq?` — capture-vs-string and
  capture-vs-capture.
- `#match?` / `#not-match?` / `#any-match?` / `#any-not-match?` — regex via Odin's
  `core:text/regex`.
- `#any-of?` / `#not-any-of?`.
- `#lua-match?` / `#not-lua-match?` — Lua patterns via `core:text/match` (used by
  the Odin query).
- `#has-parent?` / `#not-has-parent?` / `#has-ancestor?` / `#not-has-ancestor?` —
  Neovim extensions; tree-walk checks of the captured node's parent/ancestor
  types against the listed type names (the Odin query uses `#not-has-parent?`).
- `#set!` — a directive, not a filter: **ignored** for highlighting, *except*
  `#set! injection.language <name>`, which the injection pass reads to pick the
  embedded language.

**Unknown-predicate policy.** A predicate name the evaluator doesn't recognize
(e.g. `#is-not? local`, a Neovim locals-scope extension qed doesn't track) is
**skipped** — the pattern still matches, and its other, known predicates are still
enforced. Unknown predicates never reject a whole pattern. **A regex that fails to
compile** is treated as a failed predicate (the match is discarded), which
reproduces the old "stripped" behavior for that one pattern.

### Remaining deviations from upstream-verbatim

- **`typescript/highlights.scm`** — the upstream `typescript` query is
  `; inherits: javascript` (a directive qed can't express), so the file is the
  upstream **javascript** query verbatim followed by the upstream **typescript**
  additions verbatim, concatenated. Used by **both** the `typescript` and `tsx`
  grammars. Layout only; no rules changed.
- **`markdown/highlights.scm`** — upstream verbatim **plus** two GFM task-list
  checkbox rules appended (`(task_list_marker_unchecked) @keyword`,
  `(task_list_marker_checked) @string`); nvim-treesitter ships these in a separate
  query, and upstream's block `highlights.scm` at this pin has none, so verbatim
  alone would drop checkbox coloring. Everything else is verbatim.
- **`common/scanner.h` include path** — layout patch (drops the `src/` level),
  documented above; not a query.
- **`rust/highlights.scm`** — vendored verbatim, including an upstream typo on the
  SCREAMING-constant rule: `(#match? @constant "^[A-Z][A-Z\d_]+$'")` has a stray
  `'` after the `$` end anchor, so under a real regex it can never match. The
  evaluator therefore discards every `@constant` match; an all-caps name instead
  falls through to the `@constructor` rule (`#match? "^[A-Z]"`) and renders in the
  **type** color (constructor → type). Faithful verbatim behavior — no fix applied.
- **`sql/highlights.scm`** — vendored verbatim. Its two `#match?` number/float
  rules use Lua-style `%d` classes (nvim heritage): under a real regex `%d` is a
  literal `%` + `d`, so `^[-+]?%d+$` never matches a digit run. The evaluator
  therefore discards those `@number`/`@float` matches and the numeric `(literal)`
  keeps `(literal) @string` — i.e. numbers render in the **string** color, exactly
  the old stripped behavior. No special-casing; it falls out of correct regex
  evaluation.

### Injection (markdown)

`injections.scm` is now vendored **verbatim**. It uses the upstream convention:
`@injection.content` marks the region, and the target language comes from either
an `@injection.language` capture (its node text — fenced code blocks) or a
`#set! injection.language <name>` directive (the `(inline)` → `markdown_inline`
case). The injection pass (`highlight_inject`) reads both. Languages qed has no
grammar for — the upstream `html` / `yaml` / `toml` metadata injections — resolve
to `.Plain` and no-op.

**Look note:** upstream injects *all* `(inline)` nodes, including a heading's, so
heading inlines now also run through `markdown_inline` (full fidelity — the old
query injected only `(paragraph (inline))`). This is visually inert for plain
headings (plain text produces no inline captures, so the `@text.title` color
stays); only a heading that contains `**bold**` / `` `code` `` / a link now picks
up that inline styling over the title.

## Capture → color mapping

Lives in `src/highlight.odin` (`syntax_capture_color`), mapping capture names /
prefixes to the `COLOR_SYN_*` constants. With the heuristics live, the newly-firing
captures are mapped as:

- `@constant*` (incl. `@constant.builtin`), `@number`, `@float`, `@boolean`,
  `@variable.builtin` → constant color.
- `@type*` (incl. `@type.builtin`) and `@constructor` → type color.
- `@function.builtin` → keyword color (builtin functions read as language-level).
- `@comment*` (prefix) → comment color, so Rust `@comment.documentation` (`///`
  doc comments) paints like a normal comment instead of falling through to plain.
- Markdown: `@text.title` → bold keyword; `@text.literal`/`@text.code` → code
  gray; `@text.uri`/`@text.reference` → type (blue); `@text.strong` → bold
  attribute; `@text.emphasis` → italic comment.

Captures with no mapping (e.g. `@function`, `@variable`, `@property`, `@parameter`,
`@field`, `@operator`, `@namespace`, `@label`, `@escape`, `@punctuation.*`,
`@punctuation.special`) render as default text — the "rich but procedures /
operators / identifiers / markdown markers stay plain" scope. Go and Rust both tag
escape sequences with a bare `@escape` (not `@string.escape`), left plain exactly
like JSON's and Python's — so `\n` inside a Go/Rust string reads in the default
color, matching the established behavior for those grammars. `@punctuation.special`
is deliberately left plain: mapping it would recolor Odin's `@`/`$` sigils and
Python/JS interpolation braces, so markdown heading/list markers render plain
(the heading *text* is still the bold title color).

**Known consequence — Odin proc names.** Upstream tags a proc-declaration name
`@type` (`(procedure_declaration (identifier) @type)`) and then re-tags it
`@function`. In Neovim `@function` wins (last match) and proc names get the
function color; qed leaves `@function` unmapped (no color contribution, so it does
**not** overwrite), and there is no function color bucket, so the earlier `@type`
paint stays — **Odin procedure-declaration names render in the type color.** This
is the faithful result within qed's palette (a function color would require a new
bucket); flagged here because it is a visible change to `.odin` files.

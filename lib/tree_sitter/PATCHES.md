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
| C++ grammar | `github.com/tree-sitter/tree-sitter-cpp` | `f41e1a044c8a84ea9fa8577fdd2eab92ec96de02` (v0.23.4) — C scanner |
| JavaScript grammar | `github.com/tree-sitter/tree-sitter-javascript` | `44c892e0be055ac465d5eeddae6d3e194424e7de` (v0.25.0) |
| TypeScript grammar | `github.com/tree-sitter/tree-sitter-typescript` | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` (v0.23.2) — provides `typescript`/`tsx` |
| Markdown grammar | `github.com/tree-sitter-grammars/tree-sitter-markdown` | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5` (v0.5.3) — provides `markdown` (block) + `markdown_inline` |
| Bash grammar | `github.com/tree-sitter/tree-sitter-bash` | `56b54c61fb48bce0c63e3dfa2240b5d274384763` (v0.25.0) |
| Lua grammar | `github.com/tree-sitter-grammars/tree-sitter-lua` | `10fe0054734eec83049514ea2e718b2a56acd0c9` (v0.5.0) |
| SQL grammar | `github.com/DerekStride/tree-sitter-sql` | `7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8` (v0.3.11) — `parser.c` is gitignored upstream, generated with `tree-sitter generate` (CLI v0.25.10) |
| HTML grammar | `github.com/tree-sitter/tree-sitter-html` | `5a5ca8551a179998360b4a4ca2c0f366a35acc03` (v0.23.2) — C scanner + `tag.h` |
| CSS grammar | `github.com/tree-sitter/tree-sitter-css` | `dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f` (v0.25.0) — C scanner |
| TOML grammar | `github.com/tree-sitter-grammars/tree-sitter-toml` | `64b56832c2cffe41758f28e05c756a3a98d16f41` (v0.7.0) — C scanner |
| YAML grammar | `github.com/tree-sitter-grammars/tree-sitter-yaml` | `7708026449bed86239b1cd5bce6e3c34dbca6415` (v0.7.2) — C scanner; `scanner.c` `#include`s `schema.core.c` (default `YAML_SCHEMA`) |
| Dockerfile grammar | `github.com/camdencheek/tree-sitter-dockerfile` | `868e44ce378deb68aac902a9db68ff82d2299dd0` (v0.2.0) — C scanner |

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
cpp/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (C scanner; query inlines the C base)
javascript/       parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (used for .js/.jsx)
typescript/       parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (used for .ts and .tsx)
tsx/              parser.c, scanner.c, tree_sitter/*.h                    (.tsx grammar; shares typescript's query)
common/           scanner.h                  shared TS/TSX external scanner (from the TS repo)
markdown/         parser.c, scanner.c, tree_sitter/*.h, highlights.scm, injections.scm   (block)
markdown_inline/  parser.c, scanner.c, tree_sitter/*.h, highlights.scm    (inline, injection-only)
bash/             parser.c, scanner.c, tree_sitter/*.h, highlights.scm   (.sh/.bash/.zsh)
lua/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm
sql/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm
html/             parser.c, scanner.c, tag.h, tree_sitter/*.h, highlights.scm, injections.scm
css/              parser.c, scanner.c, tree_sitter/*.h, highlights.scm
toml/             parser.c, scanner.c, tree_sitter/*.h, highlights.scm
yaml/             parser.c, scanner.c, schema.core.c, tree_sitter/*.h, highlights.scm
dockerfile/       parser.c, scanner.c, tree_sitter/*.h, highlights.scm
ts.odin           Odin FFI bindings          the ~15 procs qed calls
```

The `typescript` and `tsx` grammars share one external scanner living in the TS
repo's `common/scanner.h`. Upstream each `<lang>/src/scanner.c` includes it as
`../../common/scanner.h`; qed's layout drops the `src/` level, so the include was
**patched** to `../common/scanner.h`. `build.sh` compiles each with `-I` on its own
dir so `tree_sitter/parser.h` resolves. The two scanners export distinct
`tree_sitter_typescript_*` / `tree_sitter_tsx_*` symbols (no link clash); all
helpers in `common/scanner.h` are `static`.

HTML's `scanner.c` `#include "tag.h"` (a grammar-private header upstream at
`src/tag.h`); qed drops the `src/` level so `tag.h` sits at `html/tag.h` next to
`scanner.c` and the quoted include resolves with no patch.

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
- **`cpp/highlights.scm`** — the upstream `tree-sitter-cpp` query is
  additions-only (it relies on the tree-sitter `inherits: c` convention: only the
  C++-specific captures — `class`/`namespace`/`template`/… keywords, coroutine and
  concept keywords, `nullptr`, `auto`, `raw_string_literal`, qualified/template
  function names), so on its own a `.cpp` file would lose all the C-level paint
  (primitive types, strings, comments, preproc, the SCREAMING-constant heuristic).
  The vendored file is therefore the upstream **C** query verbatim followed by the
  upstream **C++** additions verbatim, concatenated — the same inline-the-base
  approach used for typescript. This works because tree-sitter-cpp is a superset of
  tree-sitter-c, so every node type the C query names exists in the C++ grammar.
  Layout only; no rules changed.
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
- **`toml/highlights.scm`**, **`yaml/highlights.scm`** — vendored verbatim,
  predicate-free (no removals, no deviations). TOML tags a `(pair (bare_key))` both
  `@type` (first) and `@property` (later, unmapped), so table/pair keys keep the
  earlier **type** color. YAML tags a plain-scalar mapping key both `(string_scalar)
  @string` (via the top-level scalar list) and `@property`; `@property` is unmapped
  and paint never overwrites, so YAML mapping keys render in the **string** color —
  same as scalar string values (an accepted consequence of verbatim vendoring, not
  a per-key color).
- **`dockerfile/highlights.scm`** — vendored verbatim. Its one predicate,
  `((variable) @constant (#match? @constant "^[A-Z][A-Z_0-9]*$"))`, is now live via
  the evaluator: a SCREAMING `$VAR` reference paints the **constant** color, a
  lowercase one stays plain.

The YAML scanner selects its schema at compile time through a `_file(YAML_SCHEMA)`
macro that `#include`s `schema.<name>.c`; qed vendors only the default (`core`)
`schema.core.c` next to `scanner.c`, and never defines `YAML_SCHEMA`, so `core` is
what compiles. Layout only; no source changes.

### Injection (markdown, html)

`injections.scm` is now vendored **verbatim**. It uses the upstream convention:
`@injection.content` marks the region, and the target language comes from either
an `@injection.language` capture (its node text — fenced code blocks) or a
`#set! injection.language <name>` directive (the `(inline)` → `markdown_inline`
case). The injection pass (`highlight_inject`) reads both. Languages qed has no
grammar for — the upstream `yaml` / `toml` metadata injections — resolve
to `.Plain` and no-op.

HTML ships the upstream `injections.scm` verbatim too: `(script_element (raw_text))`
→ `#set! injection.language "javascript"` and `(style_element (raw_text))` →
`"css"`. Both resolve through `language_of_name` to qed's existing grammars, so the
markdown injection machinery drives them unchanged — inline `<script>`/`<style>`
bodies paint as JS/CSS over the HTML host. No new infrastructure.

**Look note:** upstream injects *all* `(inline)` nodes, including a heading's, so
heading inlines now also run through `markdown_inline` (full fidelity — the old
query injected only `(paragraph (inline))`). This is visually inert for plain
headings (plain text produces no inline captures, so the `@text.title` color
stays); only a heading that contains `**bold**` / `` `code` `` / a link now picks
up that inline styling over the title.

## Capture → color mapping

The capture-name → color mapping is **theme-configurable**, not hardcoded. A theme
JSON's `captures` section maps a tree-sitter capture name (no `@` prefix) to a
**color key** — a key in the same theme's `colors` section, which is open to
user-defined extras (a theme may add `"syntax_numbers": "#e067ea"` and point a
capture at it). The value is `"<color_key>"` optionally followed by space-separated
display attrs (`bold`, `italic`, `underline`, `reverse`), e.g. `"text.title":
"syntax_keyword bold"`. The full default table lives in the bundled default theme
`config/themes/gruber-darker.json`; every other bundled theme inherits it through
the theme overlay chain (gruber-darker base → same-name bundled → user file, merged
per key by `theme_apply` in `src/settings.odin`) and may override individual entries
by restating them. Only gruber-darker ships a `captures` table.

**Per-language overrides.** A `captures` key that names a qed language (as used in
config.json's `languages` section) holds a nested capture→color-key object, e.g.
`"markdown": {"punctuation.special": "syntax_keyword"}`. Lookup for capture `C` in
language `L` walks prefix fallback (strip a trailing `.segment` each round), and at
each step tries the language-qualified entry before the global one — for
`comment.documentation` in rust the order is `rust/comment.documentation`,
`comment.documentation`, `rust/comment`, `comment`. Entries are stored flat in
`g_captures` keyed by `capture` (global) or `lang/capture` (override); `g_theme_colors`
holds the resolved `colors` section. `syntax_capture_color` (`src/highlight.odin`)
runs this lookup once per capture id at query-build / recolor time
(`syntax_load_colors`, rebuilt by `syntax_recolor` on theme change / hot-reload) and
caches the result into per-language capture-id → color arrays, so per-node paint
stays a plain array index — no string matching on the paint path.

A capture **mapped** to a color paints explicitly: mapping `function` to
`foreground` writes the default fg and thereby **overwrites** an earlier capture's
paint on the same node (distinct from an *unmapped* capture, which paints nothing
and leaves prior paint alone). A `captures` value pointing at a color key that
doesn't resolve, or a language-override object under an unknown language name, is
reported once on the message line (like any unknown theme key) and ignored — never
rewritten.

### The default table (gruber-darker)

Bucketing of the currently-firing captures (with predicate heuristics live):

- `@constant*` (incl. `@constant.builtin`), `@number`, `@float`, `@boolean`,
  `@variable.builtin` → constant color.
- `@type*` (incl. `@type.builtin`) and `@constructor` → type color.
- `@function.builtin` → keyword color (builtin functions read as language-level);
  `@function` (and `@function.call`, via the `function` prefix) → **`foreground`**
  (explicit plain — see the Odin note below).
- `@keyword*`/`@conditional`/`@repeat`/`@include`/`@storageclass`/`@tag*` → keyword
  color. HTML tag names, CSS type/nesting/universal selectors, and HTML's
  `@tag.error` all read as language-level structural vocabulary, so `@tag` → keyword
  rather than type (the CSS `&`/`*` selectors captured as `@tag` would look wrong as
  a "type"; keyword is the closest existing philosophy).
- `@string*`/`@character` → string color; `@comment*`/`@spell` → comment color, so
  Rust `@comment.documentation` (`///`) paints like a normal comment.
- `@attribute`/`@preproc*` → attribute color.
- Markdown: `@text.title` → bold keyword; `@text.literal`/`@text.code` → code gray;
  `@text.uri`/`@text.reference` → type (blue); `@text.strong` → bold attribute;
  `@text.emphasis` → italic comment.
- Per-language: `markdown` `@punctuation.special` → keyword, so markdown heading /
  list / block-quote markers render in the keyword color. It is left **global-plain**
  otherwise, so Odin's `@`/`$` sigils and Python/JS interpolation braces (also
  `@punctuation.special`) stay the default color.

HTML/CSS specifics: `(doctype) @constant`, `(attribute_value)`/`(string_value)` →
string, `(color_value) @string.special` → string (the `string` prefix), CSS
`(integer_value)`/`(float_value) @number` → constant, `(unit) @type` → type,
`@attribute` (attribute names, pseudo-selectors) → attribute, at-rules (`@media`,
`(at_keyword)`, `(important)`, `to`/`from`) `@keyword` → keyword. Left plain
(unmapped): CSS `@property` (class/id/property/feature names), `@operator`
(combinators + `and`/`or`/`not`/`only`), `@variable` (`--custom-props`, the only
predicate-gated capture in either query), and every `@punctuation.*` (HTML
`<`/`>`/`</`/`/>` brackets, CSS delimiters/brackets).

Captures with no entry (e.g. `@variable`, `@property`, `@parameter`, `@field`,
`@operator`, `@namespace`, `@label`, `@escape`, `@punctuation.delimiter`) render as
default text. Go and Rust tag escape sequences with a bare `@escape` (not
`@string.escape`), left plain like JSON's and Python's — so `\n` inside a Go/Rust
string reads in the default color. C++ adds no new bucket: its additions reuse
`@keyword` (class/namespace/template/coroutine/concept keywords), `@type` (`auto`,
uppercase namespace ids), `@constant` (`nullptr`), `@variable.builtin` (`this`) and
`@string` (`raw_string_literal`), all already mapped, and the inlined C base keeps
its mapping.

TOML, YAML and Dockerfile need **no new color key** — every painted capture already
falls into an existing one (`@type`, `@string`, `@string.special`, `@number`,
`@boolean`, `@constant.builtin`, `@constant`, `@comment`, `@keyword`, `@attribute`).
Left plain by design: YAML `@label` (anchors / aliases), TOML `@property` (pair keys
— but a bare key also gets the earlier `@type` paint), and the Dockerfile `@none` /
`@operator` / `@punctuation.special` markers. YAML mapping keys are `@property` but
paint in the string color because their scalar node also matches the top-level
`(string_scalar) @string`.

**Odin proc names.** Upstream tags a proc-declaration name `@type`
(`(procedure_declaration (identifier) @type)`) and then re-tags it `@function`. The
default table maps `@function` → `foreground`, so — matching Neovim's last-match-wins
— the later `@function` paint overwrites the earlier `@type` paint and
**procedure-declaration names render in the default color**. (Before the table was
theme-configurable, `@function` was unmapped and the `@type` paint stayed, so proc
names showed in the type color.) This is the only visible effect of the explicit
`@function` → `foreground` mapping: everywhere else `@function`/`@function.call`
lands on nodes with no prior paint, so an explicit fg write is identical to leaving
them plain.

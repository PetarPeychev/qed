# Note — language support endgame

How language support scales if qed opens up to other users. Decided direction
and sequence; delete sections as they ship. Context: today each language is a
`Language` enum variant + `LANGUAGE_DEFAULTS` row + vendored parser.c/queries +
FFI decl + build.sh line — fine at ~15 languages, gnarly at 50.

## Constraints

- Multi-user distribution: "download one binary, it works" — no C toolchain,
  no mandatory fetch step on the user's machine.
- POSIX only (4 release targets: linux/mac × x64/arm64).
- Trust model: users trust the qed release, nothing else. No auto-compiling
  third-party scanner.c on user machines (arbitrary native code).
- Queries are the contributor surface: improving a language's highlighting
  must not require touching Odin source or rebuilding.

## Options considered

| Model | Verdict |
|-------|---------|
| Fat vendored binary (bat/delta) | Best user UX; all costs maintainer-side (repo bloat, build time, 50–150 MB binary). Kept for the curated core. |
| User-compiled `.so` (helix/nvim) | Rejected: needs cc on user machine, runs unsandboxed third-party scanner code. |
| Prebuilt per-platform `.so` packs | Viable middle path; folded in as the dlopen tail below. |
| WASM grammars (Zed, tree-sitter+wasmtime) | Parked: portable + sandboxed, but drags wasmtime into a small editor and ~2–3× parse cost. Revisit only if qed grows a grammar-ecosystem ambition. |

## Decided shape: curated core baked in, everything else runtime data

Grammar **code**, **queries**, and **metadata** are three different
distribution problems:

- **Code**: curated set compiled into the binary; exotic tail via `dlopen`
  from the runtime dir (tree-sitter's `tree_sitter_<lang>` symbol convention).
- **Queries**: shipped as files in a runtime dir, compiled-in copies as
  fallback. Predicate evaluator lets upstream `.scm` files work verbatim.
- **Metadata**: already config data (globs/lsp/formatter/comment); moves fully
  into a shipped `languages.json` merged with user config.

## Sequence (each step useful alone)

1. **Language registry — kill the `Language` enum.** `LanguageId :: distinct
   int` indexing a runtime table built from compiled defaults + config;
   `[Language]Syntax` / `[Language]LanguageInfo` become parallel dynamic
   arrays. Flushes the remaining hardcoded per-language behaviors into table
   fields: Python colon-indent in `buffer_newline` (→ `indent_after_chars`),
   markdown injection wiring, `language_of_name` fenced-block aliases
   (→ `aliases`). Prerequisite for everything below; worth doing on its own.
2. **Query predicate evaluator** (`#match?`/`#eq?`/`#any-of?`…). Mandatory at
   scale: hand-stripping predicates (lib/tree_sitter/PATCHES.md) is the
   dominant per-language maintenance cost and caps highlight quality. Unlocks
   taking upstream query sets unmodified.
3. **Runtime dir** (helix-style; XDG + `QED_RUNTIME` override): queries +
   `languages.json` as files with compiled-in fallback for the core set.
   Contributors fix highlighting by editing `.scm`, no rebuild.
4. **Grammar lock-file build fetch.** Remove vendored parser.c from the repo:
   `grammars.lock` (repo URL + commit + sha256 per language), build fetches
   into a cache, compiles, generates the FFI decls; build.sh globs the cache.
   Repo shrinks to queries + lock file; adding a core language = one lock
   entry + one table row + queries.
5. **`dlopen` tail.** User-added languages: drop `<lang>.so` + queries +
   metadata into the runtime dir, no rebuild. Not a plugin system — data
   loading with a known symbol convention; the curated core stays compiled in
   so the bare binary always works.

## Non-goals

- WASM grammars (parked, see table).
- User-machine grammar compilation.
- Grammar marketplace / registry infrastructure.

## Open questions

- Curated-core size (~20–30?) and criteria for core vs runtime-dir tail.
- Whether release artifacts include a starter runtime dir or embed-and-
  materialize it like config.json.
- "Open to other users" also reopens non-language locked decisions
  (backwards-compat of config.json, single-author assumptions in CLAUDE.md) —
  separate think when it gets real.

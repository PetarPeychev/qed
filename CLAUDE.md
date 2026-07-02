# qed

`qed` is a personal terminal text editor written in Odin, in the spirit of
micro/nano but with GUI-style keybinds. It targets a single author (Petar) — so
there are **no plugins, no theming, no configuration files, and no
backwards-compatibility obligations**. Everything is hardcoded; we just keep the
knobs in one place.

This file is the durable guide loaded every session. The detailed architecture
and the working TODO list live in [docs/DESIGN.md](docs/DESIGN.md).

> **Start here, every session:** before doing any work, (1) read **both** this
> file (`CLAUDE.md`) and **[docs/DESIGN.md](docs/DESIGN.md)** in full — CLAUDE.md
> is auto-loaded, DESIGN.md is not, so open it yourself; and (2) skim the `src/`
> source files to see the current state of the code. The codebase is
> intentionally small, so reading all of it is cheap and expected.

**Task workflow:** work is tracked as the TODO list in `docs/DESIGN.md §10`.
Pick one unchecked task, implement it, and report when done (with how it was
verified). If you discover work that warrants its own task while developing, add
it to that list as a new unchecked item.

Finishing a ticket has a fixed close-out sequence:

1. Run `./build.sh` so the `qed` binary is fresh — Petar should only ever need
   to run `./qed` to test, never rebuild himself.
2. Tell him exactly what to **test manually** in the running editor (a concrete
   checklist), then explicitly prompt him to confirm it works.
3. A task is ticked off `[x]` **only after Petar verifies it** — never
   self-check before his confirmation. Once he confirms, *you* edit the
   `[ ]` → `[x]` in `docs/DESIGN.md`, then commit & push (direct to `master`).

## Build & run

```sh
./build.sh            # builds the vendored termbox2 static lib, then `qed`
./qed [PATH]          # PATH may be a file or a directory (see DESIGN.md)
odin test src -collection:lib=lib   # unit tests (buffer/edit/cursor/undo)
```

The `lib=` collection exposes `lib/` so `import "lib:tb2"` resolves to the
termbox2 bindings. termbox2 is POSIX-based and works on Linux and macOS.

## Programming philosophy

Compression-oriented programming (à la Casey Muratori). **Do not introduce an
abstraction until the same concrete pattern has appeared 2–3 times and the
duplication actually hurts.** Write the concrete, obvious code first; collapse
repetition only once it exists in front of you.

Concretely, this means:

- **No speculative generality.** We know we will eventually want panes, a file
  tree, an autocomplete dropdown, an rg/fzf overlay, LSP, tree-sitter, and a git
  gutter. We do **not** build a pane/compositor abstraction now. We build the
  single text buffer concretely and let the right abstraction reveal itself when
  2–3 of those features actually exist.
- **No premature data-structure optimization.** The buffer is a dynamic array of
  lines, each line a dynamic array of bytes. No gap buffer, no rope, no piece
  table — until profiling on real usage proves we need one.
- **Hardcode, but in one place.** Keybinds, colors, tab width, scroll margins,
  etc. live as named constants in `src/config.odin`. Hardcoding is fine; magic
  numbers scattered through the code are not.

## Code conventions

- **Language:** idiomatic Odin. `snake_case` for procedures and variables,
  `PascalCase` (ThisKindOfCase) for types/enums, `SCREAMING_SNAKE` for constants.
- **Comments:** don't add them. Let clear names and obvious structure carry the
  code. Write a comment only for something genuinely unintuitive that the code
  cannot imply on its own (e.g. a non-obvious invariant or a workaround for an
  external quirk) — never to restate what a line plainly does.
- **Naming:** procedures are `noun_verb` grouped by subject, e.g.
  `buffer_open`, `buffer_insert`, `editor_render`, `cursor_move_left`. The first
  parameter is the thing being acted on, usually a pointer for mutation
  (`buffer: ^Buffer`).
- **Procedure size:** a longer procedure that reads top-to-bottom (without deeply
  nested control flow) beats scattering the same logic across many small helpers
  called only once or twice. Don't extract a one-shot helper just to shorten a
  proc — having to jump between functions to follow one logical block is worse
  than reading it inline. Extract when logic is genuinely reused, or to flatten
  deep nesting, not by reflex.
- **Memory:**
  - Per-frame / per-render scratch goes through `context.temp_allocator` and is
    released with `free_all(context.temp_allocator)` once per main-loop
    iteration (already done in `main`).
  - Long-lived data (buffer lines, undo log) is explicitly owned and explicitly
    freed by the subsystem that created it. Every `make`/`append`-backed field
    has a clear owner and a matching teardown.
- **Errors:** return Odin `enum` error values and handle them explicitly at the
  call site. No panics / `os.exit` in normal editing flow — only for genuinely
  unrecoverable startup failures (e.g. terminal init).
- **Rendering:** full redraw per event. On each input event, redraw the whole
  visible state and call `tb2.present()`; termbox double-buffers and only flushes
  changed cells, so there is no need for dirty-region tracking.
- **Input:** an explicit `switch` on the key/mod (and mouse) event dispatches to
  action procedures. No data-driven keybind table until the switch genuinely
  becomes unwieldy.
- **Platform bits:** keep OS-specific code (clipboard tooling, path quirks)
  isolated in its own file (e.g. `src/clipboard.odin`) behind a small interface.
  Keybinds are CTRL-based on both platforms — terminals cannot see the Cmd/Super
  modifier, so "GUI keybinds" means CTRL+S, CTRL+C, etc.
- **Files grow organically.** Start with few files; split a new one out only when
  an existing file's responsibilities clearly diverge (same compression rule).

## Locked design decisions

| Area            | Decision |
|-----------------|----------|
| Platform        | Linux + macOS; OS-specific bits isolated. CTRL-based keybinds. |
| Core structure  | `Buffer` = `[dynamic]Line`; `Line` = `[dynamic]u8`. |
| Text/columns    | Byte offsets now; rune-awareness later (known limitation). |
| Long lines      | Horizontal scroll, no wrap. 1 buffer line = 1 screen row. |
| Cursor          | Single cursor + optional selection anchor (shift-select). |
| Undo/redo       | Inverse-op edit log, grouped into undo steps; all edits go through primitive ops. |
| Indent          | Spaces, width 4 (in `config.odin`). |
| Clipboard       | External tool (wl-copy/xclip · pbcopy/pbpaste), isolated. |
| Saving          | Atomic: write temp in same dir, then rename. |
| Line endings    | Detect & preserve LF/CRLF and trailing-newline per file. |
| Mouse           | Full from the start: click-position, drag-select, wheel-scroll. |
| Rendering       | Full redraw per event; termbox diffs internally. Truecolor output mode. |
| Colors          | gruber palette (ported from micro), hardcoded hex in `config.odin`. |
| Gutter          | Left line-number gutter in the text area; current line emphasized. |
| Commands        | Direct CTRL keybinds now; floating command palette later. |
| Status bar      | Filename + modified flag, plus a message line below for errors / prompts / status. |
| Search          | Deferred entirely (in-buffer and project-wide). |
| Tests           | `core:testing` unit tests for buffer/edit/cursor/undo. |
| Startup arg     | File → open it; directory → set working root + welcome screen. |

## Out of scope (deliberately)

Plugin system, configuration files, multiple color schemes, split panes, tabs,
multiple visible buffers, backwards compatibility. There is exactly one visible
text buffer; everything else (file tree, autocomplete, search overlay, inline
diagnostics) will be an auxiliary pane or floating window layered over it — but
only when we get there.

# qed

`qed` is a personal terminal text editor written in Odin, in the spirit of
micro/nano but with GUI-style keybinds. It targets a single author (Petar) — so
there are **no plugins and no backwards-compatibility obligations**. Tunable
knobs (colors, sizes, timeouts, keybinds) are compiled-in defaults in
`src/config.odin`; `~/.config/qed/config.json` overrides them at startup. Exactly
one place per knob.

## The docs

| File | What it is | Read when |
|------|-----------|-----------|
| `CLAUDE.md` (this file) | Timeless guide: philosophy, conventions, workflow. | Auto-loaded every session. |
| [docs/DESIGN.md](docs/DESIGN.md) | Living architecture reference, kept terse. What exists and how it fits. | Every session — open it yourself, it is not auto-loaded. |
| [docs/TODO.md](docs/TODO.md) | The task list: one line per item. | When picking work. |
| [docs/notes/](docs/notes/) | Deep-dives on individual subsystems (e.g. performance). | Only when working on that subsystem. |

> **Start here, every session:** read this file and **[docs/DESIGN.md](docs/DESIGN.md)**
> in full — they give you the philosophy, conventions, and the architecture +
> file map. Pull in a `docs/notes/*` file only if the task reaches that subsystem.

**Keep the docs short.** DESIGN.md is a living reference, not a changelog — when
you ship something, update the relevant line in place; do not append a session
write-up. TODO.md is one line per item, no exceptions. Git history and commit
messages are the record of *how* work was done. If a subsystem genuinely needs a
long explanation, it goes in a `docs/notes/*` file (or a `PATCHES.md` next to the
vendored code), never in DESIGN.md, TODO.md, or here.

## Task workflow

Work is tracked in [docs/TODO.md](docs/TODO.md) as a flat list of open items.
Pick one, implement it, report when done (with how it was verified). If you
discover work that warrants its own task, add it as a new one-liner. There is no
"done" section: a finished task is **deleted** from TODO.md, and its capability —
if user-facing or architectural — becomes/updates a line in DESIGN.md (the
Shipped list or the relevant section). Git history is the record of the work.

Closing a ticket has a fixed sequence:

1. Run `./build.sh` so the `qed` binary is fresh — Petar should only ever need to
   run `./qed` to test, never rebuild himself.
2. Tell him exactly what to **test manually** (a concrete checklist), then prompt
   him to confirm.
3. **Only after Petar verifies it** — never self-check first — *you* remove the
   item from `docs/TODO.md`, update DESIGN.md (Shipped list / architecture) if it
   changed anything, then commit & push (direct to `master`).

## Build & run

```sh
./build.sh            # builds the vendored termbox2 static lib, then `qed`
./qed [PATH]          # PATH may be a file or a directory (see DESIGN.md)
odin test src -collection:lib=lib   # unit tests
```

The `lib=` collection exposes `lib/` so `import "lib:tb2"` resolves to the
termbox2 bindings. termbox2 is POSIX-based and works on Linux and macOS.

## Programming philosophy

Compression-oriented programming (à la Casey Muratori). **Do not introduce an
abstraction until the same concrete pattern has appeared 2–3 times and the
duplication actually hurts.** Write the concrete, obvious code first; collapse
repetition only once it exists in front of you.

- **No speculative generality.** Build the concrete thing; let the right
  abstraction reveal itself when 2–3 real uses exist.
- **No premature data-structure optimization.** The buffer is a dynamic array of
  lines, each a dynamic array of bytes. No gap buffer / rope / piece table until
  profiling on real usage proves we need one.
- **Hardcode, but in one place.** Every tunable is a named constant in
  `src/config.odin`. Hardcoding is fine; scattered magic numbers are not.

## Code conventions

- **Language:** idiomatic Odin. `snake_case` for procs/variables, `PascalCase`
  for types/enums, `SCREAMING_SNAKE` for constants.
- **Comments:** don't add them. Let clear names and obvious structure carry the
  code. **Never write a comment that describes what a proc or struct does** — no
  function-header / doc comments summarizing behavior; the name and body already
  say it. Comment *only* something genuinely unintuitive the code cannot imply (a
  non-obvious invariant, an external-quirk workaround), and keep it to one terse
  line stating the *why* — never restate a line.
- **Naming:** procedures are `noun_verb` grouped by subject (`buffer_open`,
  `buffer_insert`, `editor_render`, `cursor_move_left`). The first parameter is
  the thing acted on, usually a pointer for mutation (`buffer: ^Buffer`).
- **Procedure size:** a longer proc that reads top-to-bottom beats scattering the
  same logic across single-use helpers. Extract to reuse or to flatten deep
  nesting, not by reflex.
- **Memory:** per-frame scratch goes through `context.temp_allocator`, freed once
  per main-loop iteration (already done in `main`). Long-lived data (buffer lines,
  undo log) is explicitly owned and freed by the subsystem that created it.
- **Errors:** return Odin `enum` error values, handled at the call site. No panics
  / `os.exit` in normal editing flow — only for unrecoverable startup failures.
- **Rendering:** full redraw per event; termbox double-buffers and flushes only
  changed cells, so no dirty-region tracking.
- **Input:** an explicit `switch` on the key/mod/mouse event dispatches to action
  procs. No data-driven keybind table until the switch is genuinely unwieldy.
- **Platform bits:** keep OS-specific code (clipboard, path quirks) isolated
  behind a small interface. Keybinds are CTRL-based on both platforms — terminals
  cannot see Cmd/Super, so "GUI keybinds" means CTRL+S, CTRL+C, etc.
- **Files grow organically.** Split a new file out only when an existing file's
  responsibilities clearly diverge (same compression rule).

## Locked design decisions

| Area           | Decision |
|----------------|----------|
| Platform       | Linux + macOS; OS-specific bits isolated. CTRL-based keybinds. |
| Core structure | `Buffer` = `[dynamic]Line`; `Line` = `[dynamic]u8`. |
| Text/columns   | `col` is a byte offset; movement/width is grapheme-cluster aware. |
| Long lines     | Horizontal scroll, no wrap. 1 buffer line = 1 screen row. |
| Cursor         | Single cursor + optional selection anchor (shift-select). |
| Undo/redo      | Inverse-op edit log, grouped into steps; all edits go through primitive ops. |
| Indent         | Spaces, width 4 (`config.odin`). |
| Clipboard      | External tool (wl-copy/xclip · pbcopy/pbpaste), isolated. |
| Saving         | Atomic: write temp in same dir, then rename. |
| Line endings   | Detect & preserve LF/CRLF and trailing-newline per file. |
| Mouse          | Full: click-position, drag-select, wheel-scroll. |
| Rendering      | Full redraw per event; termbox diffs internally. Truecolor output. |
| Colors         | gruber palette; default hex in `config.odin`, overridable via `theme`. |
| Gutter         | Left line-number gutter; current line emphasized; git-diff mark column. |
| Commands       | Direct CTRL keybinds (rebindable by name); floating command palette. |
| Config         | `config.odin` defaults; `~/.config/qed/config.json` overrides, auto-materialized with every key. |
| Status bar     | Filename + modified flag, plus a message line for errors / prompts / status. |
| Tests          | `core:testing` unit tests (buffer/edit/cursor/undo/…). |
| Startup arg    | File → open it; directory → set working root + welcome screen. |

## Out of scope (deliberately)

Plugin system, multiple switchable color schemes, split panes, tabs. There is
exactly one visible text buffer; everything else (file tree, autocomplete, search
overlay, inline diagnostics) is an auxiliary pane or floating window layered over
it — built only when we get there.

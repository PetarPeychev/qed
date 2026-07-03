# qed — Design & TODO

This is the detailed design behind the decisions summarized in
[../CLAUDE.md](../CLAUDE.md). It describes *how* the pieces fit and *in what
order* we build them. Read CLAUDE.md first for the philosophy and conventions.

The guiding rule throughout: **build concretely, abstract only when a pattern has
appeared 2–3 times.** Treat every "system" below as a description of behavior,
not a mandate to create a class/interface up front.

---

## 1. Data model

```odin
Buffer :: struct {
    path:        string,        // "" for an unsaved scratch buffer
    lines:       [dynamic]Line, // never empty: an empty file is one empty line
    cursor:      Cursor,
    selection:   Maybe(Cursor), // anchor; cursor is the moving end
    goal_col:    int,           // remembered x-position for vertical moves (§5)
    line_ending: LineEnding,    // .LF or .CRLF, detected on open
    final_newline: bool,        // did the file end with a trailing newline?
    modified:    bool,          // dirty flag for the status bar
    undo:        [dynamic]Edit, // inverse-op log (see §4)
    redo:        [dynamic]Edit,
}

Line :: struct {
    text: [dynamic]u8,          // raw bytes, no trailing newline stored
}

Cursor :: struct {
    row: int,                   // index into lines
    col: int,                   // BYTE offset into lines[row].text (see §2)
}

LineEnding :: enum { LF, CRLF }
```

Invariants:

- `lines` always has at least one element. An empty buffer is `[]Line{ {} }`.
- A `Line.text` holds the line's bytes **without** any `\n`/`\r\n`. Line breaks
  are structural (the array boundary), not stored characters.
- `cursor.row` ∈ `[0, len(lines))`; `cursor.col` ∈ `[0, len(lines[row].text)]`
  (one past the end is allowed — that's the caret after the last character).

### Why this structure

A dynamic array of lines is O(n) for a few operations a rope would make O(log n)
(e.g. inserting a line at the top of a huge file). We do not care yet: real files
are small, and the simplicity buys us correctness and speed of development. If
profiling on actual usage ever shows a line-array operation dominating, *that* is
the justification to revisit — not before.

---

## 2. Text encoding (bytes + grapheme clusters)

`col` is a **byte offset** into `Line.text` — this keeps every buffer mutation
(`buffer_insert`/`buffer_delete`, which slice by byte) trivial and correct. The
*interpretation* of that offset is Unicode-aware: cursor horizontal movement and
word-motion step whole **extended grapheme clusters** (UAX #29), backspace/delete
remove a whole cluster, and every screen↔buffer column mapping goes through
**display width**. This uses `core:unicode/utf8`'s grapheme iterator to find
cluster boundaries; no external library.

Display width is the one subtlety. termbox2 recomputes each cell's width in
`present()` via its own `tb_cluster_width`, so qed must advance by the *same*
value or the terminal cursor and termbox's cell model drift (corrupting the row).
So `cluster_width` in `cursor.odin` is a direct port of `tb_cluster_width` (max
rune `tb_wcwidth`, with VS16 / ZWJ / regional-indicator-pair → 2), used by both
the renderer and all column mapping. Multi-rune clusters render as one cell via
`tb_set_cell` + `tb_extend_cell` (EGC mode, enabled in `build.sh`).

**Known limitation:** a few emoji sequences (ZWJ-flags, keycaps) flicker
or misalign because some terminals — notably Windows Terminal — render them at a
width that contradicts the Unicode/`tb_wcwidth` width. There is no width qed can
assign that satisfies both termbox and such a terminal; every terminal editor
shows the same. CJK, combining Latin, simple emoji, composed ZWJ emoji, and Indic
conjuncts all work.

---

## 3. Rendering

Model: **full redraw per event.** termbox2 maintains a back buffer and only
flushes cells that actually changed on `present()`, so redrawing everything each
frame is cheap and removes any need for dirty tracking.

Each main-loop iteration:

1. Block on `tb2.poll_event`.
2. Dispatch the event (input → action; resize → recompute viewport).
3. Redraw: text area, then status bar, then any overlay; place the hardware
   cursor with `tb2.set_cursor`; call `tb2.present()`.
4. `free_all(context.temp_allocator)`.

Screen layout (top to bottom):

```
+--------------------------------------------------+
| gut | text area  (height - 2 rows)               |
| ter | ...                                        |
+--------------------------------------------------+
| status bar  (1 row): path  [*]                   |
| message line (1 row): errors / prompts / status  |
+--------------------------------------------------+
```

The text area carries a **left line-number gutter**. Its width is the digit
count of the last line number plus one column of padding; the text area and all
screen→buffer column mapping account for it. The current line's number is
emphasized (see palette).

The status bar shows only the file path and a modified flag. Below it is a
**message line**: a single general-purpose row for transient feedback (e.g.
"Saved", save failures, "no clipboard tool") and for interactive prompts (e.g.
the unsaved-quit confirmation, see §8). It is empty during ordinary editing.

A transient message **clears on the next input event** — the blocking poll loop
has no timers, so any subsequent keypress wipes the line. An active interactive
prompt is the exception: it owns the line and the input until it resolves.

**Color** uses termbox2's **truecolor** output mode (not the 256-palette). The
palette is the **gruber** scheme (ported from the author's micro config) and
lives as hardcoded 24-bit hex constants in `config.odin`:

| Element              | Color                          |
|----------------------|--------------------------------|
| Text area            | `#f4f4ff` on `#181818`         |
| Current line         | text on `#1B1B1B` background   |
| Gutter line number   | `#868686` on `#1B1B1B`         |
| Current line number  | `#ffdd33`                      |
| Status bar           | `#f4f4ff` on `#2b2b2b`         |
| Message line — error | `#D2A8A1`                      |
| Selection            | **inverted**: `#181818` text on `#f4f4ff` background |

Syntax colors (`COLOR_SYN_*` in `config.odin`) drive tree-sitter highlighting for
`.odin` files (§10 Done); other languages will reuse them as grammars land.

---

## 4. Editing & undo (inverse-op edit log)

All buffer mutation funnels through **two primitive operations**:

```odin
// Insert `text` (which may contain '\n' to create new lines) at `at`.
buffer_insert :: proc(b: ^Buffer, at: Cursor, text: string) -> Cursor
// Delete the text in [from, to) and return what was removed.
buffer_delete :: proc(b: ^Buffer, from, to: Cursor) -> string
```

Every higher-level action is expressed in terms of these:

- typing a printable rune → `buffer_insert` of that rune
- Enter → `buffer_insert` of `"\n"`
- Tab → `buffer_insert` of `TAB_WIDTH` spaces
- Backspace / Delete → `buffer_delete` of one position (or the selection)
- paste → `buffer_insert` of the clipboard text
- replacing a selection → `buffer_delete` then `buffer_insert`

Each primitive records its **inverse** as an `Edit`. Edits are collected into
**groups**, and one group is one undo step:

```odin
Edit :: struct {
    kind: enum { Insert, Delete },
    at:   Cursor,
    text: string,   // owned; freed when the edit is dropped from the log
}

EditGroup :: struct {
    edits:  [dynamic]Edit, // applied in reverse order to undo the group
    cursor: Cursor,        // cursor position to restore after undoing
}
```

The undo/redo stacks hold `EditGroup`s, not individual `Edit`s. Grouping serves
two purposes from the start:

- **Atomic compound actions.** Replace-selection (delete + insert), or any action
  that issues several primitives, lands as one group and undoes in one step.
- **Coalesced typing.** A run of printable insertions (and a run of deletions)
  merges into the current open group until a boundary closes it: a cursor move, a
  different kind of action, a newline, or a save. So Ctrl+Z removes a word/run,
  not a single keystroke.

Mechanically: the editor keeps a "currently open group." Primitives append their
inverse edit to it; an explicit `undo_commit` (called at boundaries) seals the
group onto the `undo` stack. Undo pops a group, applies its edits' inverses in
reverse, restores the cursor, and pushes the group onto `redo`. Any fresh edit
clears `redo`.

---

## 5. Cursor, selection, viewport

- **Movement:** arrows; Home/End (line start/end); PgUp/PgDn (viewport height);
  Ctrl+Left/Right (word-wise); Ctrl+Home/End (buffer start/end). A remembered
  "goal column" preserves the intended x-position across vertical moves over
  short lines.
- **Word boundaries** (for Ctrl+Left/Right): characters fall into three classes —
  alphanumeric (incl. `_`), punctuation, and whitespace. A word move stops at
  every boundary between two classes: one press advances to the end of the
  current run (i.e. the start of the next), so a whitespace gap and an adjacent
  word are never crossed in a single move, and punctuation and identifiers are
  separated.
- **Selection:** holding Shift with any movement sets `selection` (anchor) if
  unset and extends it. Any non-shift movement clears it. Editing while a
  selection exists replaces it — **except Tab/Shift+Tab**, which block-indent
  instead (below). Selected cells render **inverted** — the text and background
  colors swap (`#181818` text on `#f4f4ff`).
- **Tab with a selection** indents every line the selection touches by one
  `TAB_WIDTH`; **Shift+Tab** dedents, removing up to `TAB_WIDTH` leading spaces
  from each line (fewer only if the line has fewer), so indent and dedent are
  exact inverses even when lines start unaligned. A line whose selection ends at
  column 0 is not counted as touched. With no selection, Tab inserts `TAB_WIDTH`
  spaces as usual and Shift+Tab dedents the current line. A block indent/dedent
  is one undo group.
- **Viewport:** `scroll_row`/`scroll_col` track the top-left visible cell. After
  any cursor move, scroll the minimum amount to keep the cursor visible, honoring
  a `SCROLL_MARGIN` (config) of context rows/cols. Horizontal scrolling follows
  the cursor on long lines (no wrap).

Mouse (from the start): left-click positions the cursor (screen→buffer mapping
via the viewport offsets), drag extends the selection, wheel scrolls the
viewport.

---

## 6. Files: open, save, startup

**Open:** `buffer_open` reads the file, detects `LF` vs `CRLF` (presence of
`\r\n`), records whether a final newline was present, and splits into lines
without storing the terminators. A nonexistent path opens an empty buffer to be
created on first save (the existing `os.open` `.Create` flag already does this).

**Save (atomic):** write to a temp file in the *same directory* as the target
(so the rename is on one filesystem), then `rename` over the target. Reconstruct
the byte stream using the buffer's `line_ending` and `final_newline`. Saving a
pathless scratch buffer is out of scope for now — in practice a buffer only
exists when a file path was given, since opening a directory (or nothing) shows
the welcome screen rather than an editable buffer. (Preserving the original
file's permissions/ownership onto the new file is a possible later refinement.)

**Startup arg** (`qed [PATH]`):

- *file* → open it in the buffer.
- *directory* → set it as the working root (the future root for cross-file
  search / file tree); the editor shows a minimal welcome screen, no file open.
- *absent* → welcome screen (equivalent to opening the current directory).

The **welcome screen** is a minimal centered banner: the app name (and version)
plus a few key hints (e.g. Ctrl+S save, Ctrl+Q quit). It is non-interactive —
purely informational until file-tree / recent-files features arrive.

The working-root concept is recorded now but only *used* once cross-file features
exist.

---

## 7. Clipboard

Copy/cut/paste shell out to the platform clipboard tool, isolated in
`clipboard.odin`:

- Linux: `wl-copy`/`wl-paste` (Wayland) or `xclip` (X11).
- macOS: `pbcopy`/`pbpaste`.

A single pair of `clipboard_set(text)` / `clipboard_get() -> string` hides the OS
choice. If no tool is available, fall back to an in-process register so
copy/paste still works within qed.

---

## 8. Input & keybinds

An explicit `switch` on `(event.key, event.mod, event.ch)` maps to action
procedures. Keys are named via `config.odin` constants so the bindings read
clearly and retune in one place. Indicative default bindings (all CTRL-based):

| Key            | Action                          |
|----------------|---------------------------------|
| Ctrl+S         | Save                            |
| Ctrl+Q         | Quit (guard unsaved changes)    |
| Tab / Shift+Tab| Indent / dedent (block when selected) |
| Ctrl+Z / Ctrl+Y| Undo / Redo                     |
| Ctrl+C/X/V     | Copy / Cut / Paste              |
| Ctrl+A         | Select all                      |
| Arrows, Home/End, PgUp/PgDn | Movement (Shift extends selection) |

**Unsaved-quit guard:** if the buffer is modified, Ctrl+Q does not quit
immediately. It writes an interactive confirmation to the message line (§3) —
"Save before quitting? (y/n/esc)" — and the next keypress resolves it: `y` saves
and then quits (staying open with the error shown if the save fails), `n` quits
and discards the changes, `esc` (or any other key) cancels and clears the line.
On an unmodified buffer Ctrl+Q quits outright.

No keybind *table* abstraction until the switch is genuinely painful.

**ALT keybinds.** `Ctrl+letter` reaches the terminal as a single control byte
(`letter & 0x1f`) with no Shift bit, so `Ctrl+F` and `Ctrl+Shift+F` are
indistinguishable — but `Alt+letter` arrives as `ESC`+the literal letter, so
`Alt+f` and `Alt+F` *are* distinct. termbox's native ALT input mode is unusable
here (it withholds a lone `Esc` until the next key), so qed stays in `ESC` input
mode and reconstructs ALT itself in the main loop: after a bare `Esc` event it
`peek_event`s for `ALT_ESC_TIMEOUT_MS`; a printable key already buffered from the
same `ESC <ch>` burst is re-tagged with `Mod.Alt`, while a real lone `Esc` peeks
nothing and dispatches normally. ALT commands live in the same `commands` table
via an `alt_ch` field (`command_for_alt`), so they also show in the palette.

**Bracketed paste.** A terminal (or Windows Terminal / tmux) paste arrives as a
stream of individual keystrokes, which would land as many undo groups (one per
line) instead of one. To make a paste a single atomic action, the vendored
termbox2 is patched to enable bracketed-paste mode and surface `Paste_Begin` /
`Paste_End` events; qed accumulates the keys between them and inserts the whole
paste as one undo group (`editor_paste_accumulate` / `editor_paste_commit`). The
termbox2 modifications are documented in
[../lib/tb2/PATCHES.md](../lib/tb2/PATCHES.md). This is independent of the
in-app `Ctrl+C/X/V` clipboard, which many terminals never deliver because they
bind `Ctrl+V` to their own paste.

---

## 9. Suggested file layout

Start minimal and split as responsibilities diverge (don't create all of these
on day one):

```
src/
  main.odin       entry point, arg parsing, main loop
  editor.odin     Editor struct, top-level dispatch + render orchestration
  buffer.odin     Buffer/Line, open, save, line-ending detection
  config.odin     ALL tunable constants: keybinds, colors, tab width, margins
```

Likely later splits, each created when its file earns it:
`edit.odin` (primitive ops + undo log), `cursor.odin` (movement, selection),
`view.odin` (viewport + rendering), `input.odin` (event switch),
`clipboard.odin` (OS clipboard), `color.odin` (palette/helpers).

---

## 10. TODO

This is the working task list. **Workflow:**

- Pick one unchecked task, implement it, and report when it's done — including
  how it was verified (tests, a manual run).
- A task is ticked off (`[x]`) **only after Petar has verified it's done.** Do
  not check it off yourself on completion; leave it `[ ]` until then.
- If during development you find work that belongs in its own task, **add it
  here** as a new unchecked item rather than silently expanding the current one.

Open work is grouped by **category** below (bugs, features, polish); completed
work stays under **Done** as history. Categories are not a strict build order —
pick by priority; where a real dependency exists it's noted inline. One structural
thread to keep in mind: in-buffer find, the file-tree, and several LSP consumers
(completion, find-references, symbol search) all draw on the one rectangular
**floating pane** already built for the palette, fuzzy file-open, line-jump, and
project search. Keep that layer minimal (no compositor) and let it accrete as
those features land.

### Done (built and verified)

- [x] Vendored termbox2 build; static lib via `build.sh`.
- [x] Basic buffer open (naive line split).
- [x] Basic line rendering.
- [x] `buffer_insert` / `buffer_delete` primitives + unit tests.
- [x] Ensure `lines` is never empty.
- [x] Real main loop: poll → dispatch → render → quit; clean shutdown.
- [x] Cursor movement + goal column; viewport vertical & horizontal scroll with
  scroll margins.
- [x] Printable input, Enter, Backspace/Delete (incl. line join), Tab → 4 spaces.
- [x] Auto-indent on Enter: a new line carries the previous line's leading
  whitespace.
- [x] Undo/redo via the grouped inverse-op log (atomic compound actions +
  coalesced typing).
- [x] Selection (shift-movement, select-all) and selection-aware editing.
- [x] Clipboard copy/cut/paste via external tool (+ in-process fallback).
- [x] Atomic save, line-ending & final-newline preservation.
- [x] Startup handling: file vs directory vs none (welcome screen).
- [x] Status bar: path + modified flag (+ message line).
- [x] Left line-number gutter (current line emphasized); gutter width folded into
  the screen↔buffer column mapping used by cursor placement and mouse.
- [x] Mouse: click-to-position, drag-select, wheel-scroll, double/triple-click
  word/line select.
- [x] Quit guard for unsaved changes.
- [x] **Floating pane primitive** — rectangular overlay layer (position/size,
  background/border, focus, captured input).
- [x] **Command palette** — VSCode-style fuzzy command list in a floating pane;
  establishes the editable prompt/minibuffer; routes existing actions through a
  command list. Includes the palette-list scroll-offset fix.
- [x] **Fuzzy file-open + multiple buffers** — Ctrl+O near-fullscreen picker
  (file list + preview) rooted at the working root; opens each file into a new
  buffer, switches to an already-open file's live buffer, marks modified files
  `[*]`, and guards quit across every modified buffer.
- [x] **Close buffer (Ctrl+W)** — close current buffer with a save/discard/cancel
  guard when modified; switch to an adjacent buffer, else the welcome screen.
- [x] **Tab-character display** — render `\t` to the next tab stop with
  screen↔buffer column mapping; auto-detect tabs-vs-spaces per file, show it in
  the status bar, add a Ctrl+~ "Toggle Indent" command.
- [x] **Full Unicode support (grapheme clusters + display width).** `col` stays a
  byte offset; movement, word-motion, and backspace/delete step whole extended
  grapheme clusters (UAX #29 via `core:unicode/utf8`); all screen↔buffer column
  mapping goes through per-cluster display width, a port of termbox2's
  `tb_cluster_width` (`cluster_width` in `cursor.odin`) so the renderer and
  `present()` agree. See §2 for the ZWJ-flag / keycap terminal caveat.
- [x] **Fuzzy line jump** (`Alt+f`, "Find Line"). Near-fullscreen picker over the
  current buffer's lines (reuses the picker pane + `fuzzy_rank`); Enter jumps to
  the line's first non-blank column and centres it. Navigation only.
- [x] **Project-wide search** (`Alt+F`, "Find in Files"). Telescope `live_grep`
  picker driving `rg --vimgrep -F -S` live per keystroke over the working root
  (≥ `PROJSEARCH_MIN_QUERY` chars, capped at `PROJSEARCH_MAX`); Enter opens the
  file and jumps to the exact row+col. A content grep, not fuzzy-over-all-lines.
  `Alt+f`/`Alt+F` are distinguishable (see §8).
- [x] **Line / file / paragraph motion keybinds.** `Alt+Left` smart-home
  (first-non-blank ↔ column 0), `Alt+Right` end of line, `Alt+{` / `Alt+}` buffer
  start / end (also palette commands), `Ctrl+Up` / `Ctrl+Down` prev / next
  paragraph. Shift extends on the arrow binds; `Alt+{`/`}` move-and-clear.
- [x] **Move lines up / down** (`Alt+Up` / `Alt+Down`). `buffer_move_lines`
  reorders the current line — or every line a selection touches — as one atomic
  delete+insert (single undo group), carrying cursor and selection.
- [x] **Jump back / forward (navigation history)** (`Alt+,` / `Alt+.`, also
  palette). Browser-style global jump list (`src/jump.odin`) of `(path, row, col)`
  entries; `editor_dispatch` records a new entry when the destination changes
  buffer or moves the row by more than `JUMP_THRESHOLD` (10), and updates the
  current entry in place otherwise. A new jump truncates forward history; a
  `jump_lock` flag suppresses recording during navigation and buffer-close.
- [x] **Syntax highlighting — Odin (tree-sitter).** Vendored the tree-sitter C
  runtime + tree-sitter-odin grammar/query under `lib/tree_sitter/` (built into
  `libtreesitter.a`, FFI in `ts.odin`, engine in `src/highlight.odin`; pins and
  query patches in `lib/tree_sitter/PATCHES.md`). Gated to `.odin`; a per-buffer
  `rev` counter triggers a full reparse only on change, painting per-line
  `tb2.Color` arrays that `editor_render_text_row` looks up (selection inversion
  wins). Structural-only (predicate-free query); precise type/constant *usage*
  coloring deferred to LSP semantic tokens. Colors in `COLOR_SYN_*`.
- [x] **Drag-select auto-scroll.** During a drag, at the top/bottom viewport edge
  the cursor aims one row beyond the viewport and `editor_scroll` brings it in, so
  a selection can extend past the screen. No timers, so each nudge advances a step.
- [x] **LSP integration + diagnostics (ols).** JSON-RPC/stdio client in
  `src/lsp.odin`: spawns `ols` (rooted at the working root; the `lib` collection
  is declared in `ols.json` so `odin check` can resolve `lib:tb2`) once an
  `.odin` buffer exists; full-text `didOpen`/`didChange` per edit, `didSave` on
  save and once on open — syntax errors publish live while typing, semantic
  errors refresh on save because ols's checker reads disk. While the server
  runs, the main loop swaps `poll_event` for a `LSP_POLL_MS` (30ms) `peek_event`,
  draining the pipe non-blocking and re-rendering only when diagnostics change.
  Rendering: exact-range underline (syntax colors kept), severity-colored gutter
  line number + `●`, and an automatic floating pane under the cursor with the
  full message (word-wrapped to the screen width, `\n` preserved). LSP's UTF-16
  columns are converted to byte offsets.

**Terminal caveat (WT):** Windows Terminal swallows some `Ctrl+Shift`/`Alt`
arrow combos (`Ctrl+Shift+Up`/`Down`, `Alt+Up`/`Down`); they're supplied by
`sendInput` keybindings in WT's `settings.json` emitting the CSI bytes
(`^[[1;6A/B`, `^[[1;3A/B`), which tmux forwards and termbox parses.

### Bugs / correctness

_(none open)_

### Features

- [x] **Runtime configuration (load on startup).** `src/settings.odin` loads
  `~/.config/qed/config.json` (honoring `$XDG_CONFIG_HOME`) before `editor_init`;
  the `config.odin` constants became mutable typed globals (`::` → `:=`, except the
  structural `STATUS_ROWS`), with casts at a few call sites (`f64(DOUBLE_CLICK_MS)`,
  `i32(LSP_POLL_MS)` / `i32(ALT_ESC_TIMEOUT_MS)`). Scope: every non-structural
  scalar, all colors, and keybinds. **Always-materialized policy** (chosen over the
  original "missing file keeps defaults silently"): a missing file is created with
  every key; missing keys are written back with their defaults so the file always
  shows every knob; an invalid value (bad type / malformed hex / unparseable
  keybind) keeps the default at runtime, is named on the message line, and is left
  untouched in the file (never silently overwritten). A syntactically broken file
  falls back to defaults and is not rewritten. Colors live under a nested `theme`
  object with readable names (`foreground`, `background`, `syntax_keyword`,
  `git_added`, …) as `#rrggbb` strings. Keybinds bind command *name* → key string
  (`"Ctrl+s"`, `"Alt+f"`, `"Ctrl+/"`); `Ctrl+letter` is case-insensitive and shown
  lowercase (no Shift is visible to a terminal), `Alt+` case is significant. `""`
  is a valid binding meaning unbound / palette-only (e.g. Toggle Indent). Primitive
  editing/movement keys and the `Ctrl+P` palette launcher stay fixed. `commands`
  (`src/palette.odin`) is the rebindable surface; `parse_keybind` covers
  `Ctrl+letter`, `Ctrl+/` `~` `\`, and `Alt+<char>` — anything gnarlier is reported
  invalid and keeps its default.
- [ ] **In-buffer find**, then find & replace. Incremental search driven by the
  palette's prompt input: next/prev, wrap, match highlight; then replace one/all.
  (Reuses the floating pane.) Binds match the micro config: `Ctrl+F` opens find,
  `Alt+n` / `Alt+m` step to the previous / next match.
- [ ] **Configurable indent width + detection.** Today indent is hardcoded to
  `TAB_WIDTH` (4). Support other widths (1/2/3/4 spaces) and auto-detect the width
  from the file's existing indentation on open, the way tabs-vs-spaces is already
  detected. Surface it in the status bar alongside the indent style.
- [x] **Toggle line comment** (`Ctrl+/`, also palette "Toggle Comment").
  Comment / uncomment the current line — or every non-blank line a selection
  touches — with the language's line-comment token (`line_comment_token` in
  `edit.odin`: `//` default, `#` for py/sh/yaml/toml, `--` for lua/sql). Toggle
  semantics: if every touched non-blank line is already commented, strip the token
  (+ one trailing space); otherwise insert `<token> ` aligned at the least-indented
  touched line. Blank lines skipped; a selection ending at column 0 doesn't count
  that trailing line; cursor/selection columns carried through; one undo group.
- [ ] **Central language detection.** Today language dispatch is scattered:
  `highlight_update`/`lsp` gate on `has_suffix(".odin")` and `line_comment_token`
  runs its own extension switch. Introduce one place (extension → `Language`) that
  drives comment token, tree-sitter grammar, and LSP server selection, so adding a
  language is one table entry instead of edits across files. Do this once "More
  languages" makes the duplication real (compression rule), not before.
- [ ] **Open-buffer switcher.** A quick picker over the *currently open buffers*
  (by name/path), reusing the picker pane + `fuzzy_rank` (like the `Alt+f` line
  jump). Today the only way to switch buffers is the `Ctrl+O` workspace
  file-open, which is overkill for hopping between buffers that are already open —
  and it re-opens rather than jumping. Fuzzy-filter open buffer names, Enter
  switches to that buffer; show the modified `[*]` flag in the list; optionally
  order by most-recently-used. (Neovim's buffer picker / `:b`.) Binding TBD — e.g.
  `Alt+b` (confirm a free key at implementation).
- [ ] **File-tree pane.** A persistent browser pane over the working root
  (navigate, open files). Second structural use of the pane layer.

**Syntax highlighting** (tree-sitter). Odin shipped (§10 Done); the highlighter is
now per-language (`[Language]Syntax` in `src/highlight.odin`), so each new grammar
is one vendor+wire step. Adding a language = vendor `parser.c` (+`scanner.c`) and
its `highlights.scm` under `lib/tree_sitter/<lang>/`, add a `tree_sitter_<lang>`
FFI decl, a `build.sh` compile line, and fill the row in `LANGUAGES`
(`src/language.odin`) — highlight-only unless an LSP server is also wired. Tick
each grammar as it lands:

- [x] **JSON** (highlight).
- [x] **Python** (highlight + `pyright` LSP).
- [x] **C** (highlight + `clangd` LSP).
- [ ] **C++**
- [ ] **Go**
- [ ] **Rust**
- [ ] **JavaScript / TypeScript** — heavy (TS is a large, dual grammar).
- [ ] **Shell** (bash)
- [ ] **Lua**
- [ ] **SQL**
- [ ] **YAML**
- [ ] **TOML**
- [ ] **Markdown** — split block/inline grammar (two parsers).
- [ ] **Query predicate evaluator.** Every vendored `highlights.scm` has its
  Neovim-flavored predicate-gated rules (`#match?`/`#eq?`/`#any-of?`/`#lua-match?`)
  *manually stripped* (see `lib/tree_sitter/PATCHES.md`) because qed evaluates no
  predicates, so those rules would otherwise match unconditionally. Implement
  predicate evaluation (via `ts_query_predicates_for_pattern`) so upstream queries
  work unmodified and name-shape heuristics (identifier-as-type / -constant, builtin
  lists) light up — removing the per-language stripping step entirely.
- [ ] **Dynamic grammar loading (idea/exploration).** Add a language without
  vendoring source + rebuilding — e.g. `dlopen` a prebuilt grammar `.so` and load
  its `.scm` from a config-declared path at runtime. This is in tension with the
  vendored/reproducible, no-plugins philosophy, so treat it as an exploration:
  weigh reproducibility and self-containment against the friction of the
  vendor+rebuild loop before committing to it.
- [ ] **Incremental re-parse.** *(optional — only if the full reparse ever
  stutters.)* Tree-sitter's intended mode: feed each buffer edit as an `InputEdit`
  (byte + row/col ranges) so it reuses unchanged subtrees. The added work is
  translating our edits into that format and holding the old tree per buffer.

**LSP.** The client plumbing (spawn, initialize, `didOpen`/`didChange` sync)
shipped with diagnostics (§10 Done). It now runs **multiple servers concurrently**
(`g_lsps: map[string]^Lsp` keyed by the server command in `src/lsp.odin`), one per
language, each buffer routed to its own — so e.g. `ols` and `pyright` serve their
buffers side by side; server commands may carry args (`pyright-langserver --stdio`).
Each capability below is its own slice, ordered by how much they get used.

- [ ] **Inline diagnostic virtual text.** Dimmed end-of-line message text on
  diagnostic lines (the fast-follow split out of the shipped diagnostics ticket).
- [ ] **Go-to-definition.** Jump, opening into a buffer.
- [ ] **Find references.** Reference sites listed in a floating pane / picker.
- [ ] **Rename symbol.** Workspace-wide rename driven from the prompt.
- [ ] **Hover.** Type/docs popup on a key (or mouse).
- [ ] **Completion dropdown.** Reuses the floating pane; incremental requests as
  you type.
- [ ] **Symbol search (fuzzy).** Document/workspace symbols surfaced through the
  fuzzy picker (reuses `fuzzy_rank`), not plaintext — jump to a symbol by fuzzy
  query.
- [ ] **Signature help.** *(later)* Parameter hints while typing a call.
- [ ] **Inlay hints.** *(later)* Inline type/param-name hints (`inlayHint` — a
  distinct request from diagnostics).

**Git diff gutter.** No LSP/tree-sitter dependency, so it can come early.

- [x] **Change marks (live).** Added/modified/deleted vs `HEAD`, recomputed per
  edit (diff against the git blob), shown in the gutter. Base `HEAD` blob fetched
  once per open/save via `git show HEAD:./<file>` (gated by `rev-parse
  --show-toplevel`, so non-repo files stay unmarked), hashed per line; a
  per-`rev` in-process Myers line diff (`src/git.odin`) of the live buffer vs
  that base fills per-line marks. Gutter gains a leftmost mark column: green `▌`
  added, yellow `▌` modified, red `▁` deletion (on the surviving line above the
  gap). Colors in `COLOR_GIT_*`.
- [ ] **Hunk navigation.** Jump to next/prev change (palette commands / keybind).
- [ ] **Hunk preview + revert.** Show a hunk's old text and revert it.
- [ ] **Stage / unstage hunks.** *(later)* Stage or unstage an individual hunk
  from the gutter.
- *Undecided idea:* reuse the same gutter mechanism to mark lines changed since
  the last **save** (buffer vs the on-disk file), independent of git. Revisit once
  the git gutter exists.

### Polish

- [ ] **Context-filter the command list.** Some commands don't apply in every
  state — e.g. on the welcome screen (no open buffer) Save, Toggle Indent,
  Undo/Redo, Cut/Copy/Paste, Select All are meaningless. Filter the palette's
  command list by the current context so only applicable commands show.
- [ ] **Picker mouse support.** Click a list row to select/open; wheel to scroll
  the list. Keyboard-only for now.
- [ ] **Colored file preview.** Parse `bat --color=always` ANSI into pane cells
  (currently plain `head` text); best done alongside syntax highlighting.
- [ ] **Per-buffer viewport memory.** Remember each buffer's scroll position
  across switches (scroll currently re-centers on the cursor on switch).
- [ ] **Permission/ownership-preserving saves.** Carry the original file's
  mode/owner onto the atomically-written replacement.
- [ ] **LSP restart.** A crashed or failed-to-start `ols` stays down for the
  session (`.Failed` never retries); add a palette command to restart it.
- [x] **Large-file editing performance.** Profiled on the vendored `parser.c`
  (118k lines): per-keystroke was ~600 ms, of which `highlight_update`
  (`src/highlight.odin`) was ~98% — a full tree-sitter reparse (~305 ms) plus a
  whole-tree highlight query (~225 ms) plus a whole-buffer color-grid rebuild
  (~18 ms) every edit; `git.odin` (~9 ms) and the LSP snapshot (~2.7 ms) were
  noise. Fixed `highlight_update` on two axes: **incremental parse** — each buffer
  retains its `^ts.Tree` and `buffer_insert`/`buffer_delete` record a precise
  `ts.InputEdit` (byte + row/col deltas, via `buffer_byte_offset`) that is fed to
  `ts_tree_edit` before reparsing with the old tree; and **viewport-scoped query +
  grid** — the query cursor is range-limited (`ts_query_cursor_set_point_range`) to
  the visible rows and only those rows' color grid is rebuilt, recomputed on scroll
  via a visible-range cache key. Result: highlight per edit 585 ms → ~7.8 ms (~75×),
  combined per-keystroke ~600 ms → ~21 ms. A regression test
  (`test_highlight_incremental` in `src/perf_bench.odin`) proves the incremental +
  viewport path paints byte-identical colors to a full parse and asserts a per-edit
  budget on the 118k-line file; a `QED_BENCH`-gated bench prints the full breakdown.
  Follow-ups split into their own items below (coalesce feedback-only work; open
  latency); git-diff/LSP throttling and a size threshold proved unnecessary once
  highlight was fixed.
- [ ] **Coalesce feedback-only work off the per-keystroke path.** *(future — only
  if editing ever stutters again; measured, not urgent.)* **Update:** largely overtaken by the
  "Revisit large-file performance" work above — highlight's incremental reparse is now async, the
  LSP `didChange` is now an incremental diff (near-zero for incremental-capable servers), and both
  highlight and git are gated off entirely above the 2 MB big-file cutoff. What remains here is
  `buffer_recompute_modified` (still scans row 0 → first change per edit; a candidate for O(1)
  incremental dirty tracking) and the git-gutter algorithm for large-but-sub-cutoff files. Original
  note follows. After the highlight fix,
  the remaining per-keystroke cost on a 118k-line file (~24 ms, editing near EOF)
  is dominated by three *feedback-only* passes that don't need to run on the
  synchronous redraw or on every keystroke of a fast typing burst: `git_gutter_update`
  (~11 ms whole-buffer line hash + Myers diff), the LSP `didChange` send (~2.7 ms
  snapshot + pipe write + server churn — only the *receive* side is currently
  async), and `buffer_recompute_modified` (`buffer.odin`, ~3 ms; scans from row 0
  to the first change every edit just to set the `[*]` dirty flag). Idea: defer/coalesce
  these until input goes idle for ~a frame (single-threaded — cheaper and safer than a
  worker thread in the full-redraw model; the LSP's existing 30 ms `peek_event` loop is
  precedent). **Exception already taken:** the one-shot cold tree-sitter parse *is* now on a
  worker thread (see the open-latency item below) — but that's a single isolated parse with a
  handoff, not the recurring per-keystroke feedback passes, which stay single-threaded.
  `buffer_recompute_modified` could alternatively be made incremental (O(1)
  dirty tracking) rather than deferred. Highlight itself (~7.4 ms) is on the critical
  path since colors are needed to draw; decoupling it (render stale, recompute async)
  is lower priority. Per the compression rule the three consumers now justify one small
  idle-work mechanism — build it when the stutter actually returns, not before.
- [x] **Large-file open latency (time to first paint) — async cold parse.** Opening a
  118k-line file (`parser.c`) blocked ~700 ms on a blank screen: the first `editor_render` ran
  the cold `highlight_update` (~417 ms full tree-sitter parse) *before* `present()`. Fixed by
  moving the **cold parse to a background worker thread** (`src/highlight.odin`): `Highlight`
  gained a `job: ^HighlightJob` (owned text snapshot + `^thread.Thread` + result tree); on a
  cold parse of a file `≥ HIGHLIGHT_ASYNC_BYTES` (256 KB) `highlight_update` snapshots the text
  and spawns `highlight_job_run`, which parses on its **own private parser** (shares no
  tree-sitter state with the main thread) and returns immediately — the buffer renders as plain
  text but stays fully interactive. Edits during the parse accumulate as `pending` `InputEdit`s;
  on completion `highlight_job_adopt` takes the tree and `highlight_reparse` catches up
  incrementally, then the viewport query paints. Smaller files still parse inline synchronously
  (no thread overhead, no uncolored flash). The main loop swaps `poll_event` for the existing
  `LSP_POLL_MS` peek loop while `highlight_busy`, re-rendering when `highlight_ready` fires.
  Async fires once per large-file open; every reparse after is the ~7 ms synchronous incremental
  path. `highlight_destroy` joins a running job before freeing (clean close/quit mid-parse).
  Regression coverage in `src/perf_bench.odin` asserts a large cold parse goes async and paints
  real colors after adoption. **Still open (own items):** the cold `git_gutter_update` (~56 ms —
  `git show HEAD` subprocess) still runs synchronously before first paint, and the `buffer_open`
  floor (~224 ms: read + `strings.split` + ~118k per-line allocs + redundant `saved` snapshot —
  direction (b): an arena for line storage / lighter dirty-tracking, but it touches the core
  `Buffer`, so measure hard first) is untouched. Both fold into the item below.
- [x] **Revisit large-file performance on huge files (Odin grammar, sqlite).** Re-profiled the
  full open+edit pipeline on the 515k-line `lib/tree_sitter/odin/parser.c` (~14 MB) and, as a
  representative *real-code* case, the sqlite3 amalgamation (~260k lines, 9 MB). Findings: the
  viewport-scoped query is a non-issue (~0.1 ms, size-independent); the per-edit **incremental
  parse** is the highlight wall (~168 ms mid-file on the generated `parser.c`, a pathological
  single-giant-node file; ~110 ms position-independent on real sqlite code — sub-linear ~O(log n)
  with a large constant); and on a C file with clangd attached the true per-keystroke killer was
  the **LSP full-text `didChange`** (~307 ms of snapshot + JSON-escape + format, before the 14 MB
  blocking pipe write). Fixed on three axes: **(1) async incremental highlight** — the incremental
  reparse now runs on the background worker (same `HighlightJob` mechanism as the cold parse) via a
  cheap `ts_tree_copy` + replayed `pending` edits; `highlight_update` dispatches and returns,
  keeping the last painted colors (stale-but-colored) until the parse lands, then adopts + repaints,
  chaining another job if edits arrived meanwhile (converges on typing pause). Small buffers stay
  synchronous. Thread-safety rests on `ts_tree_copy` making the worker's `tree_edit`/`parse`
  copy-on-write against the retained tree, and the main thread doing no refcount-affecting op on a
  shared tree while the worker runs (returns early during a job; `thread.destroy` joins before any
  delete). Scrolling now requeries without reparsing. **(2) incremental LSP `didChange`** — every
  primitive edit records an `LspChange` (UTF-16 range + text) at the `buffer_insert`/`buffer_delete`
  choke points, and `didChange` sends only the batched diff (~100 bytes for a keystroke) instead of
  the whole file; gated on the server advertising Incremental `textDocumentSync` (parsed from the
  initialize response), else falls back to full-text. Reconstruction regression test in
  `src/lsp_test.odin` replays the changes and asserts byte-identity, including astral/surrogate and
  cross-line-break cases. **(3) big-file cutoff** — files ≥ `BIG_FILE_BYTES` (2 MB, a config knob)
  open with `buffer.big` set; `editor_render` skips highlight + git-gutter and `lsp_sync` skips the
  attach, so a monster file is a fast plain-text buffer (status bar shows `big`). Net per-keystroke
  on the 515k file: ~291 ms → ~82 ms with the fixes on, and ~0 (plain) in big-file mode. Perf test
  now asserts the async path dispatches without blocking and repaints after settling.
  **Still open (own items below):** the synchronous cold `git_gutter_update` before first paint and
  the `buffer_open` per-line-allocation floor are untouched (they only bite files *under* the 2 MB
  cutoff, so lower urgency now); the git-gutter *algorithm* (whole-buffer hash + Myers, ~45 ms on a
  14 MB file) is only gated off above the cutoff, not made cheaper for large-but-sub-cutoff files.

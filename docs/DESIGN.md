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

## 2. Text encoding (bytes now, runes later)

Columns are **byte offsets** for now. This is correct for ASCII and keeps every
movement/edit operation trivial. It is knowingly wrong for multibyte UTF-8:
moving the cursor across a multibyte rune will land mid-rune, and display width of
wide characters is ignored.

When we actually need to edit non-ASCII files, we upgrade in one place: cursor
horizontal movement decodes runes (`utf8.decode_rune`) to step whole runes, and
the renderer computes display width. The data stays raw bytes; only the
*interpretation* of `col` and the *advance* logic change. This is documented as a
known limitation rather than worked around prematurely.

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

Syntax colors (keywords/types `#ffdd33`, comments `#cc8c3c`, strings `#73c936`,
etc.) are recorded for when highlighting arrives but unused for now. The
`rgb`/`gray`/`style` helpers in `editor.odin` move to a `color.odin` once color
handling grows.

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

This is **one ordered list**, roughly sequenced so each item unlocks the ones
below it; completed core work stays at the top as history. Order is a guide, not
a mandate — items marked *(independent)* have no dependencies and can be pulled
forward whenever. The big lever is the **floating pane**: the command palette,
in-buffer find, fuzzy file-open, the file-tree, and a later autocomplete dropdown
are all consumers of one rectangular overlay layer, so that primitive is built
early — concretely, as the first step of the command palette — rather than
retrofitted. That's a deliberate, Petar-approved exception to "wait for 2–3
users": the users are already enumerated, so the substrate is earned, not
speculative. Keep it minimal (no compositor); let it accrete as those features
land.

**Done — core editor** (built and verified):

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

**Next — build order:**

- [x] **Floating pane primitive.** A rectangular overlay layer drawn over the
  buffer: position/size, background/border, focus, and its own captured input.
  First step of the command palette below, but shaped knowing find, fuzzy
  file-open, the file-tree, and a later autocomplete dropdown all reuse it. Keep
  it to exactly what the palette needs.
- [x] **Command palette.** VSCode-style fuzzy command list in a floating pane;
  the first pane consumer. Establishes the editable text-input line (the
  "prompt"/minibuffer) that find, go-to-line, and save-as later reuse. Routes the
  existing actions (save, quit, undo, …) through a command list.
    - [x] **Palette list scrolling (bug).** The palette renders only the first
      `PALETTE_MAX_ROWS` matches with no scroll offset, so once the command list
      exceeds the visible rows the selection can move below the window and vanish.
      Track a scroll offset that follows the selection (as the picker already
      does).
- [ ] **In-buffer find**, then find & replace. Incremental search driven by the
  palette's prompt input: next/prev, wrap, match highlight; then replace one/all.
- [x] **Fuzzy file-open + multiple buffers.** Ctrl+O opens a near-fullscreen
  floating picker (file list on top, plain-text preview of the selected file on
  the bottom) rooted at the working root. The file list is walked once on open
  (`fd`/`fdfind`, falling back to `find`, gitignore-aware) and filtered per
  keystroke through the shared `fuzzy_rank` (prefers `fzf --filter`, falls back to
  the built-in matcher — the command palette uses the same path). Enter opens the
  file into a **new buffer**, keeping the old one open so unsaved edits survive
  switching; re-picking an already-open file switches to its live buffer instead
  of reloading. Files with unsaved changes are marked `[*]` in the list. Quit
  (Ctrl+Q) guards **every** modified buffer via a combined Save-All / Discard-All
  / Cancel dialog. Follow-ups discovered while building this, each its own task:
    - [ ] **Picker mouse support.** Click a list row to select/open; wheel to
      scroll the list. Keyboard-only for now.
    - [ ] **Colored file preview.** Parse `bat --color=always` ANSI into pane
      cells (currently plain `head` text); best done alongside syntax highlighting.
    - [ ] **Per-buffer viewport memory.** Remember each buffer's scroll position
      across switches (scroll currently re-centers on the cursor on switch).
    - [ ] **Close buffer (Ctrl+W).** Close the current buffer; if it's modified,
      guard with a save/discard/cancel prompt first. Switch to an adjacent buffer
      afterward, falling back to the welcome screen when the last one closes.
- [ ] **File-tree pane.** A persistent browser pane over the working root
  (navigate, open files). Second structural use of the pane layer.
- [ ] **Project-wide search overlay** (rg + fzf): query, results list in a
  floating pane, jump to a hit.
- [x] **Tab-character display.** *(independent)* Render a literal `\t` out to the
  next tab stop and map screen↔buffer columns through it; today each byte is one
  cell, so opened files and pastes containing tabs misrender and mis-place the
  cursor. Also auto-detects tabs-vs-spaces indent per file, shows it in the status
  bar, and adds a Ctrl+~ "Toggle Indent" command.
- [ ] **Drag-select auto-scroll.** *(independent)* Scroll the viewport when a
  mouse drag-selection reaches the top or bottom edge (the target row is
  currently clamped into view, so a selection can't extend past what's visible).
- [ ] **Rune-aware cursor & display width (UTF-8).** *(independent)* Step whole
  runes on horizontal movement and compute display width in the renderer; data
  stays raw bytes — only `col` interpretation and the advance logic change.
- [ ] **Permission/ownership-preserving saves.** *(independent)* Carry the
  original file's mode/owner onto the atomically-written replacement.
- [ ] **Syntax highlighting** via tree-sitter.
- [ ] **LSP integration**: completion dropdown (reuses the floating pane),
  diagnostics, hover, go-to-definition.
- [ ] **Inline diagnostics/hints** rendered between lines.
- [ ] **Git diff gutter.**

# Note — end-to-end test coverage

Detail behind the **E2E test coverage** section in [TODO.md](../TODO.md). Each
`##`/`###` here maps to a TODO one-liner; delete the block when its item ships.

## What e2e tests are for

The harness (`src/e2e_test.odin`) drives the **real** `Editor` headless: termbox
comes up once on a fixed 80×24 PTS (no tty), synthetic `tb2.Event`s go straight
to `editor_dispatch`, `editor_render` draws into termbox's back buffer, and the
grid is read back cell-by-cell (`e2e_cell`). A session opens a real temp file
(`e2e_start(content)`), exactly the `qed FILE` entry path.

E2E covers the **wiring** the unit tests can't: keybind → action → buffer
mutation → render, and what actually lands on screen. It is *not* a place to
re-test primitives already covered in `buffer_test`/`edit_test`/`cursor_test`/
`wrap_test`/`conflict_test`/`format_test`/`git_test`/`lsp_test` — assert the
user-visible outcome of a real keystroke sequence, not the primitive.

Assertion surfaces: buffer state (`b.lines`, `b.cursor`, `b.selection`, `modified`),
overlay/pane state (`ed.find.active`, palette/picker rows), and the rendered grid
(`e2e_cell` → glyph; the returned `Cell_Raw.fg` also carries truecolor + the
underline/attr bits under `ATTR_W=64`, so color-of-a-cell and matching-bracket
underline are assertable).

## Harness extensions needed first

Several areas can't be driven until the harness grows a capability. These are
prerequisites, tracked as their own TODO items:

- **Mouse events** — `e2e_mouse(x, y, button, motion)` emitting `.Mouse` events:
  click-position, drag-select, wheel-scroll, double/triple-click. Unlocks mouse
  selection, every pane's mouse drive, terminal drag-copy.
- **Paste events** — `e2e_paste(text)` bracketing keys in `Paste_Begin`/`Paste_End`
  so the buffer/overlay/terminal paste routing is exercised (one undo group,
  newline flattening in fields).
- **Configurable size / resize** — sessions are locked to 80×24; soft-wrap and
  horizontal-scroll edge cases need narrow widths and a resize event.
- **Temp git repo fixture** — `git init` + commit a seed file in a scratch dir,
  open a file under it; for gutter marks, diff view, filetree git bars/tab.
- **Fake external subprocess** — a stub script (echo/filter) wired through config
  `llm.chat_command`, a language `formatter`, or the FIM endpoint command, so AI
  edit / format / FIM run with no real tool or network.
- **Main-loop coverage seam** — the ALT-timeout retag and paste accumulation live
  in `main`'s loop, not `editor_dispatch`. Factor the loop body into an
  `editor_step(events)` to bring them under e2e.
- **Fake stdio LSP** *(optional, heavy)* — a minimal JSON-RPC server answering
  `initialize` + a canned diagnostic/hover/definition/rename/completion, to e2e
  the LSP client paths without installing ols/pyright/clangd.

## Coverage checklist

### Core editing (no external deps)

- **Typing / newline / backspace** — *done* (`e2e_type_and_edit`).
- **Undo/redo** — type a run, `Ctrl+Z` removes the whole coalesced run (not one
  char), `Ctrl+Y` restores; a compound action (paste, block-indent) undoes atomically.
- **Selection** — Shift+arrows set/extend the anchor, non-shift move clears it,
  editing replaces the selection; selected cells render inverted (assert the
  swapped fg/bg via `e2e_cell`).
- **Block indent / dedent** — Tab / Shift+Tab over a multi-line selection indent
  every touched line and are exact inverses.
- **Tab-stop backspace** — Backspace in leading whitespace deletes a full indent.
- **Auto-indent** — Enter after an opener indents; Python `:` indents; Enter
  inside a matched `{}` splits and re-aligns; a typed closing bracket dedents to
  its opener.
- **Auto-close pairs** — typing `(`/`"`/`` ` `` inserts the partner; type-over the
  close; Backspace deletes the pair; the pair surrounds an active selection.
- **Line-comment toggle** — toggles the comment token on the line / selection
  (needs a buffer with a comment token; the token is compiled-in per language —
  pick one whose LSP won't auto-spawn, or disable lsp via config in the fixture).
- **Move lines** — Alt+Up/Down moves the line / selected block, cursor follows.
- **Clipboard** — Ctrl+C/X/V through the in-process register fallback (no wl-copy
  in tests); empty-selection Ctrl+C/Ctrl+X copy/cut the whole line.
- **Motion** — word (Ctrl+←/→), paragraph (Ctrl+↑/↓), smart-home/end (Alt+←/→),
  buffer start/end (Alt+{/}); goal-column survives vertical moves over short lines.
- **Matching-bracket underline** — cursor on a bracket; assert the partner cell
  carries the underline attr bit.
- **Unicode** — type a multi-rune grapheme (emoji/ZWJ/combining); cursor advances
  by cluster width, Backspace deletes the whole cluster, render lands it at the
  right column.

### Files

- **Open + save round-trip** — open an LF and a CRLF file, edit, `Ctrl+S`, read the
  temp file back: bytes preserve the line ending and trailing-newline exactly.
- **Save creates a missing file**; **save preserves mode** (a `+x` seed stays
  executable). *(primitive covered in buffer_test — e2e drives it via `Ctrl+S`.)*
- **External change, clean buffer** — rewrite the file on disk, drive the disk
  poll, buffer auto-reloads with cursor clamped.
- **External change, dirty buffer** — edit, rewrite on disk, `Ctrl+S` opens the
  conflict dialog; Reload / Overwrite / Cancel each do the right thing.
- **Big file** — open ≥ 2 MB; `big` set, highlight/git/LSP skipped, editing still works.

### Navigation & UI

- **Soft wrap** — a line wider than the width wraps at a word boundary;
  Down/Up move by visual row; continuation rows get a blank gutter (needs the
  configurable-width extension).
- **Horizontal scroll** — wrap off, cursor past the right edge scrolls `scroll_col`.
- **Welcome screen** — no-arg start shows welcome; `Ctrl+O`/`Ctrl+P` work, plain
  typing is ignored.
- **Command palette** — `Ctrl+P`, fuzzy-type a command name, Enter runs it.
- **Fuzzy file-open + multiple buffers** — `Ctrl+O` opens a second file; switch
  buffers; **close buffer** returns to the other.
- **Buffer switcher** — `Ctrl+E`, digit instant-jump, side preview follows selection.
- **Find / replace** — *partly done* (`e2e_find_flow`): also all-match highlight
  count, next/prev with wrap, regex `.*` toggle, smart-case `Aa`, `Alt+a` replace-all.
- **Line jump** — `Ctrl+G` fuzzy (file order) and `:N` / `:N:C` exact jump.
- **Project search** — `rg`-backed (external dep); results pane populates, Enter
  jumps to the hit.
- **File tree** — `Alt+f`: expand a folder, open a file, scope tabs (All/Open/Git/
  Unsaved), dotfile/ignored toggles (needs a filesystem + git fixture).
- **Jump list** — a definition/search jump pushes; back/forward restore position.
- **Quit guard** — a modified buffer + `Ctrl+Q` opens the quit dialog instead of exiting.
- **Status / message line** — read the status row glyphs: path, `●` modified flag,
  `line/total`, and a transient message set by an action.

### Language intelligence

- **Highlight** — open a `.odin` buffer (tree-sitter is compiled in, no external);
  assert a keyword's cell carries the keyword color. Exercises parse → query →
  color → render.
- **Merge conflict** — content-driven, no git: open a buffer with conflict markers;
  assert the ours/theirs/base tints, then `Alt+m` resolve deletes the right rows
  as one undo group.
- **Formatting** — a language `formatter` pointed at a stub filter; Format Document
  / format-on-save applies it as one undo group; a missing tool leaves the buffer
  untouched.
- **Git gutter + diff view** — temp git repo fixture: add/modify lines, assert the
  gutter marks; `Alt+g` diff view shows ghost rows for removed/replaced lines.
- **LSP** *(needs the fake-stdio-LSP extension)* — diagnostics underline + gutter,
  hover popup, go-to-definition jump, cross-file rename as one undo transaction,
  completion dropdown accept with `additionalTextEdits`.

### AI assist *(needs the fake-subprocess extension)*

- **AI edit** — `Ctrl+K` with `chat_command` → a stub emitting a fenced block; the
  block is relocated and applied as one undo group with whitespace framing kept.
- **FIM inline completion** — stub endpoint; ghost text appears at the cursor,
  `Tab` accepts all / `Ctrl+Right` a word, an edit dismisses.

### Panes via mouse *(needs the mouse-events extension)*

- Wheel-scroll, click-select a row, double-click activate, drag-select in a prompt
  field, click-away dismiss — one representative test per pane, plus buffer
  click-position / drag-select / double-click-word.
- **Terminal pane** — `Alt+t` opens; type a command, read the grid; drag-select
  auto-copies; `Esc` closes at the prompt.

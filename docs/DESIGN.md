# qed — Architecture

Living reference for how the pieces fit. Terse by policy: only what the code
can't tell you (non-obvious invariants, external-quirk workarounds) lives here.
Read CLAUDE.md first for philosophy and conventions. Tasks are in
[TODO.md](TODO.md); subsystem deep-dives are in [notes/](notes/).

## Data model

```odin
Buffer :: struct {
    path:        string
    lines:       [dynamic]Line          // never empty
    cursor:      Cursor
    selection:   Maybe(Cursor)          // anchor; cursor is the moving end
    goal_col:    int                    // remembered x for vertical moves
    line_ending: LineEnding             // .LF | .CRLF, detected on open
    final_newline, modified, big: bool
    undo, redo:  [dynamic]EditGroup     // inverse-op log; `open` group coalesces
    hl: Highlight, git: GitGutter       // per-buffer highlight tree + git marks
    language: Language                  // detected at open; Set Language overrides
    // ... lsp/diag/rev bookkeeping
}
Line   :: struct { text: [dynamic]u8 }   // bytes, no line terminator stored
Cursor :: struct { row, col: int }       // col = BYTE offset into lines[row]
```

Invariants:
- `lines` is never empty; an empty buffer is one empty line.
- `Line.text` holds no `\n`/`\r\n`; line breaks are the array boundary.
- `cursor.row ∈ [0, len(lines))`; `cursor.col ∈ [0, len(text)]` (one past end = caret after last char).

## Text encoding

`col` is a byte offset (keeps `buffer_insert`/`buffer_delete` byte-slicing
trivial). Interpretation is Unicode-aware: horizontal + word motion and
backspace/delete step whole **extended grapheme clusters** (UAX #29, via
`core:unicode/utf8`); every screen↔buffer column mapping goes through display
width.

**External-quirk invariant:** `cluster_width` (`cursor.odin`) is a direct port of
termbox2's `tb_cluster_width`. termbox recomputes each cell's width in `present()`,
so qed *must* advance columns by the identical value or the terminal cursor drifts
and corrupts the row. Multi-rune clusters render via `tb_set_cell` +
`tb_extend_cell` (EGC mode, enabled in `build.sh`). Some ZWJ-flag/keycap emoji
still misalign because certain terminals contradict `tb_wcwidth`; unavoidable.

## Rendering

Full redraw per event; termbox flushes only changed cells. Each loop iteration:
poll → dispatch → redraw (text, status bar, overlays) → set hardware cursor →
`present()` → `free_all(context.temp_allocator)`.

Layout, top to bottom: text area (`height - 2` rows) with a left gutter, then a
1-row **status bar** (path + `[*]` modified flag + indent style / `big`), then a
1-row **message line** (transient errors / prompts / status). Gutter = mark column
(git diff) + line numbers, width = digit count + padding, folded into every
screen↔buffer column mapping (cursor placement, mouse).

Message line clears on the next input event (no timers); an active interactive
prompt owns the line + input until it resolves. All writes go through
`editor_set_message`, which copies into owned storage — a raw `tprintf` string
would dangle once the per-frame `temp_allocator` is freed. Truecolor output; gruber palette
and all colors live in `config.odin` (`COLOR_*`), overridable via config `theme`.

## Editing & undo

All mutation funnels through two primitives:
```odin
buffer_insert(b, at, text) -> Cursor          // text may contain '\n'
buffer_delete(b, from, to) -> string          // returns removed text
```
Everything (typing, Enter, Tab→spaces, backspace, paste, replace-selection) is
expressed in these. Each primitive records its inverse `Edit`; edits collect into
an open `EditGroup` (= one undo step). A boundary (cursor move, different action
kind, newline, save) seals the group. This gives atomic compound actions and
coalesced typing (undo removes a run, not one keystroke). Undo applies a group's
inverses in reverse, restores the cursor, pushes to `redo`; any fresh edit clears
`redo`. Primitives also emit the `ts.InputEdit` (highlight) and `LspChange`
(incremental `didChange`) records — see [notes/perf.md](notes/perf.md).

## Cursor, selection, viewport

- Movement: arrows, Home/End, PgUp/PgDn, Ctrl+Left/Right (word), Ctrl+Home/End,
  Ctrl+Up/Down (paragraph), Alt smart-home/end and buffer start/end. A remembered
  goal column survives vertical moves over short lines.
- Word classes: alphanumeric+`_`, punctuation, whitespace; a word move stops at
  every class boundary.
- Selection: Shift+movement sets/extends the anchor; non-shift movement clears it.
  Editing replaces the selection — except Tab/Shift+Tab, which block indent/dedent
  every touched line (exact inverses; trailing line ending at col 0 not counted).
  Selected cells render inverted.
- Viewport: `scroll_row`/`scroll_col` track the top-left cell; after a move,
  scroll the minimum to keep the cursor visible honoring `SCROLL_MARGIN`.
- Mouse: click positions, drag extends (auto-scrolls past the edge), wheel
  scrolls, double/triple-click selects word/line.

## Files

- **Open:** detect LF vs CRLF and final-newline, split into lines without storing
  terminators. Missing path → empty buffer, created on first save. Files ≥
  `BIG_FILE_BYTES` (2 MB) open with `big` set — highlight, git gutter and LSP are
  skipped (fast plain-text buffer).
- **Save (atomic):** write a temp file in the same dir, then `rename` over target;
  reconstruct bytes from `line_ending` + `final_newline`.
- **Startup arg:** file → open it; directory → set working root + welcome screen;
  absent → welcome screen. Working root is the future root for cross-file features.

## Clipboard

Copy/cut/paste shell out via `clipboard.odin`: `wl-copy`/`wl-paste` or `xclip`
(Linux), `pbcopy`/`pbpaste` (macOS); in-process register fallback if none exists.

## Input

Explicit `switch` on `(key, mod, ch)` → action procs; keys named in `config.odin`.
Rebindable commands live in the `commands` table (`palette.odin`); primitive
editing/movement and `Ctrl+P` (palette) are fixed. Two terminal workarounds, both
documented in `lib/tb2/PATCHES.md`:
- **ALT keys:** termbox stays in ESC input mode; after a bare `Esc`, qed
  `peek_event`s for `ALT_ESC_TIMEOUT_MS` and re-tags a buffered printable as
  `Mod.Alt` (so `Alt+f`/`Alt+F` are distinct, unlike `Ctrl+letter`).
- **Bracketed paste:** patched termbox surfaces `Paste_Begin`/`Paste_End`; qed
  accumulates the keys between them and inserts the whole paste as one undo group.

## Language detection

Each `Buffer` carries a `language: Language`, set once at open (`language_of`).
File→language is **not hardcoded**: `DEFAULT_LANGUAGES` (`language.odin`) is a
list of `pattern → Language` rules materialized into the config `languages`
section like every other knob, so any mapping (e.g. `*.py`) is user-overridable
and extra globs can be added. Patterns are `*`-globs matched against the basename,
most-specific-first (exact before glob, longer before shorter); built-in defaults
cover extensions plus common dotfiles (`.bashrc` → shell, …). Everything —
highlight, LSP, status bar, comment token — reads `b.language`. The *Set Language*
command (`langpick.odin`) overrides it for the session (re-parses, re-opens LSP).

## Multiple servers / grammars

- **Syntax** (`highlight.odin`, `language.odin`): per-language `[Language]Syntax`;
  adding one = vendor `parser.c` (+`scanner.c`) + `highlights.scm` under
  `lib/tree_sitter/<lang>/`, add the FFI decl + `build.sh` line, fill the
  `LANGUAGES` row (grammar/comment/LSP) + a `DEFAULT_LANGUAGES` glob. Query is
  structural-only (predicates stripped, see `lib/tree_sitter/PATCHES.md`). A
  grammar/query that fails to compile surfaces a one-shot status message. Parse is
  incremental + async on big files — [notes/perf.md](notes/perf.md).
- **Injection** (markdown only): a `LANGUAGES` row may carry an `injections` query.
  After the host paint, `highlight_inject` runs it over the viewport, and for each
  region freshly re-parses the embedded language (synchronous, viewport-scoped —
  cheap since paint only reruns on tree/viewport change) and paints its colors over
  the host at the region's row/col offset. The target language is encoded by
  capture name (`@inline` → the inline grammar; `@language`+`@content` → the fenced
  block's named language via `language_of_name`), since qed can't evaluate the
  upstream `#set!` predicates. `MarkdownInline` is an injection-only `Language`
  (grammar + query, no file extension).
- **LSP** (`lsp.odin`): JSON-RPC/stdio, multiple servers concurrent
  (`g_lsps` keyed by server command), one per language; UTF-16 columns converted
  to byte offsets. `didChange` is incremental when the server advertises it. Servers
  auto-start lazily; the *Restart LSP* command tears the current buffer's server
  down so the next `lsp_sync` respawns it (crash recovery).

## File layout

`main` (entry/loop) · `editor` (dispatch + render) · `buffer` · `edit` (primitives
+ undo) · `cursor` · `config` · `settings` (JSON load) · `clipboard` · `shell` ·
`confirm` · `pane` (floating overlay) · `palette` · `picker` · `bufswitch` · `langpick` · `fuzzy` ·
`linefind` · `projsearch` · `jump` · `highlight` · `language` · `lsp` · `git` ·
`perf_bench`.

## Shipped

Core editing: buffer open/save (atomic, LF/CRLF + final-newline preserving),
insert/delete primitives + grouped undo/redo, auto-indent, selection +
selection-aware editing, block indent/dedent, clipboard (external + fallback),
full Unicode (grapheme + display width), tab-char display + tabs/spaces detect,
line-comment toggle, move-lines, paragraph/word/smart-home motion.

Navigation & UI: line-number + git gutter, mouse (position/drag/wheel/multi-click,
drag auto-scroll), status + message line, welcome screen, quit guard across
modified buffers, floating pane primitive, command palette, fuzzy file-open +
multiple buffers, close buffer, buffer switcher (`Ctrl+E`: fuzzy over open buffers
in stable order + digit instant-jump on empty query), fuzzy line jump, project-wide
search (`rg`), jump list (back/forward), runtime config (`~/.config/qed/config.json`).

Language intelligence: config-driven language detection (glob rules + built-in
dotfiles, per-buffer, `Set Language` override); tree-sitter highlight (Odin, JSON,
Python, C, JS/JSX, TS/TSX, Shell, Lua, SQL, Markdown w/ inline + fenced-code
injection); LSP diagnostics (ols, pyright, clangd, typescript-language-server,
bash-language-server, lua-language-server) — live syntax + on-save semantic, range
underline, gutter severity, diagnostics pane, `Restart LSP`; git diff gutter (live vs `HEAD`).

Performance: incremental + async tree-sitter parse, viewport-scoped highlight
query, incremental LSP `didChange`, big-file cutoff. See
[notes/perf.md](notes/perf.md).

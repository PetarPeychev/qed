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
    modified, big: bool
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

**Soft wrap** (`wrap.odin`, per-buffer `Buffer.wrap`, config `line_wrap`, default
on; *Toggle Line Wrap* flips the current buffer): a logical line spills over
consecutive visual rows, breaking at word boundaries (a word wider than the width
hard-breaks), tab/grapheme-width aware. Continuation rows get a blank gutter.
`line_wrap` yields per-line segment start offsets; `vpos_*` walk/measure visual
rows (bounded by the viewport). The render loop iterates visual rows; the row
renderer draws a byte range `[col_start,col_end)` at an `x_origin`. Ghost-text
(FIM) on the cursor line renders inline through the same wrap layout
(`editor_render_ghost_line`) so ghost + relocated suffix wrap too.

Layout, top to bottom: text area (`height - 2` rows) with a left gutter, then a
1-row **status bar** (path + `[*]` modified flag + indent style / `big`), then a
1-row **message line** (transient errors / prompts / status). Gutter = mark column
(git diff) + line numbers, width = digit count + padding, folded into every
screen↔buffer column mapping (cursor placement, mouse).

Line backgrounds are **alpha-composited** tints (`editor_line_bg` + `color_over`),
stacked bottom→top: optional git-hunk row tint → AI-edit tint → current-line tint
(a semi-transparent white lift over whatever's beneath). Tint strengths are
`*_TINT` constants in `config.odin`; the tint colors are theme-overridable. Hunk
row tint is toggled by *Toggle Hunk Highlight* (config `git_hunk_highlight`, off by
default) and is separate from the always-on gutter mark.

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
(incremental `didChange`) records — see [notes/perf.md](notes/perf.md). Undo is
per-buffer, except a cross-file rename tags every touched buffer's group with a
shared transaction id (`EditGroup.tx`); `editor_undo`/`editor_redo` then revert the
whole rename in one step across all buffers (falling back to per-buffer if any
member group is no longer on top).

## Cursor, selection, viewport

- Movement: arrows, Ctrl+Left/Right (word), Ctrl+Up/Down (paragraph), Alt
  smart-home/end (Alt+Left/Right) and buffer start/end (Alt+{/}). No Home/End
  binding. A remembered goal column survives vertical moves over short lines.
  With soft wrap on, arrows + smart-home/end move by **visual** row (goal column
  is the x within the visual row). Holding a plain arrow **accelerates**
  (`editor_accel_step`): a fractional-velocity ramp grows the step the longer the
  key repeats and carries the remainder, so motion eases in (no cliff); reversing
  direction or a pause > `cursor_accel_interval_ms` resets it. Word/paragraph and
  shift-collapse moves are never accelerated. Knobs: `cursor_accel*` in config.
- Word classes: alphanumeric+`_`, punctuation, whitespace; a word move stops at
  every class boundary.
- Selection: Shift+movement sets/extends the anchor; non-shift movement clears it.
  Editing replaces the selection — except Tab/Shift+Tab, which block indent/dedent
  every touched line (exact inverses; trailing line ending at col 0 not counted).
  Selected cells render inverted.
- Viewport: `scroll_row`/`scroll_col` track the top-left cell. Each command owns
  its own reveal — a command that moves the cursor calls `editor_scroll`; opening
  a pane / a no-cursor command (save, toggles, wheel scroll) leaves the viewport
  put. `editor_scroll` scrolls the minimum to keep the cursor visible honoring
  `SCROLL_MARGIN`. With soft wrap, `scroll_col` is 0 and `scroll_sub` anchors the
  visual sub-row of `scroll_row` at the top (all visibility math in visual rows —
  see `wrap.odin`). When the caret is scrolled out of the viewport it is hidden,
  not clamped to an edge.
- Mouse: click positions, drag extends (auto-scrolls past the edge), wheel
  scrolls, double/triple-click selects word/line.

## Files

- **Open:** detect LF vs CRLF, split on `\n` into lines without storing
  terminators. A trailing newline is a **real empty last line** (VS Code model:
  visible + navigable), so "content\n" → `["content", ""]`; join with `\n`
  reconstructs the file exactly, no separate final-newline flag. Missing path →
  empty buffer, created on first save. Files ≥ `BIG_FILE_BYTES` (2 MB) open with
  `big` set — highlight, git gutter and LSP are skipped (fast plain-text buffer).
- **Save (atomic):** write a temp file in the same dir, then `rename` over target;
  reconstruct bytes by joining lines with `line_ending` (the trailing empty line,
  if any, becomes the trailing newline). No newline is forced — files save exactly
  as shown. The temp is created with the target's existing **mode** (from the disk
  fingerprint) + an explicit `fchmod`, so `rename` doesn't flatten permissions (a
  `+x` script stays executable). Ownership is not preserved (single-user editor).
- **External changes:** each buffer keeps a `DiskStamp` (`mtime`/`size`/`mode`),
  captured on open and refreshed after every save (so our own write never looks
  external). The main loop polls `os.stat` for every open buffer, throttled by
  `disk_poll_ms` (idle branch uses a timed `peek_event`, so it fires even with no
  input). A changed file that is **clean** auto-reloads (`buffer_reload`: re-read,
  clear undo/redo, drop the parse tree, re-sync LSP via `didClose`→lazy `didOpen`,
  clamp the cursor); a **dirty** one sets `disk_conflict` + warns, and a `Ctrl+S`
  onto it opens the conflict dialog (Cancel / Overwrite / Reload) instead of
  clobbering. Reload skips a buffer while its highlight parse thread is busy
  (retries next poll). Deletion on disk is ignored (buffer stays; save recreates).
- **Startup arg:** file → open it; directory → set working root + welcome screen;
  absent → welcome screen. Working root is the future root for cross-file features.

## Clipboard

Copy/cut/paste shell out via `clipboard.odin`: `wl-copy`/`wl-paste` or `xclip`
(Linux), `pbcopy`/`pbpaste` (macOS); in-process register fallback if none exists.

## Input

Explicit `switch` on `(key, mod, ch)` → action procs; keys named in `config.odin`.
Rebindable commands live in the `commands` table (`palette.odin`); primitive
editing/movement and `Ctrl+P` (palette) are fixed.

Every editable text box (palette/picker/switcher/lang/indent/line-find/project-search
queries, rename, AI-edit, file-tree name prompts) is one shared single-line widget,
`TextField` (`textfield.odin`): `{text, caret, anchor}` with buffer-parity binds —
grapheme + word (`Ctrl+←/→`) motion, smart home/end (`Alt+←/→`), shift-select,
`Ctrl+A`, `Ctrl+X/C/V` (paste flattens newlines), delete-selection. `textfield_key`
returns whether the text changed (fuzzy callers re-filter); `textfield_render` draws it
scrolled to the caret with the selection inverted (`COLOR_PANE_BG`/`FG`). Word/home
motion is the same `word_left_col`/`word_right_col`/`home_smart_col` the buffer cursor
uses. `FuzzyList` (`overlay.odin`) embeds one; its `> ` prompt draws via `overlay_prompt_render`.
Every pane is mouse-driven through an optional `Overlay.mouse` handler (`editor_dispatch`
routes `.Mouse` to it): wheel scrolls, single-click selects a row, double-click activates,
a click in the query/prompt field places the caret and a button-held drag selects, and a
click outside the box dismisses (all drag/dismiss gated on the `Motion` flag). Shared row/
field/scroll helpers live in `overlay.odin` (`overlay_list_mouse`, `fuzzy_list_center_mouse`,
`overlay_prompt_mouse`, `dialog_mouse`; `textfield_mouse` maps a click to a caret).
Most panes reset their query on open; **line-find and project-search persist it** —
reopened with the text fully selected (`textfield_select_all`) so a keystroke replaces it,
else edit/arrow to refine. Project-search also restores its selected match; the file tree
persists its expanded set + selection.

Two terminal workarounds, both
documented in `lib/tb2/PATCHES.md`:
- **ALT keys:** termbox stays in ESC input mode; after a bare `Esc`, qed
  `peek_event`s for `ALT_ESC_TIMEOUT_MS` and re-tags a buffered printable as
  `Mod.Alt` (so `Alt+f`/`Alt+F` are distinct, unlike `Ctrl+letter`).
- **Bracketed paste:** patched termbox surfaces `Paste_Begin`/`Paste_End`; qed
  accumulates the keys between them and inserts the whole paste as one undo group.

## Language detection

Each `Buffer` carries a `language: Language`, set once at open (`language_of`).
File→language is **not hardcoded**: the config `languages` section is keyed by
language name, each entry an object with `patterns` (glob list), `lsp` (server
command) and `formatter` (external filter) — all user-overridable, per-key merged
back like every other knob. `LANGUAGE_DEFAULTS` (`language.odin`) is the compiled-in
source; `LANGUAGES` is the working copy config load resets then overlays (`lsp`/
`formatter` overrides). `DEFAULT_LANGUAGES` supplies each language's default globs.
Patterns are `*`-globs matched against the basename, most-specific-first (exact
before glob, longer before shorter); built-in defaults cover extensions plus common
dotfiles (`.bashrc` → shell, …). `lsp_id` and the comment token stay compiled-in.
Everything — highlight, LSP, status bar, comment token — reads `b.language`. The
*Set Language* command (`langpick.odin`) overrides it for the session (re-parses,
re-opens LSP).

## Multiple servers / grammars

- **Syntax** (`highlight.odin`, `language.odin`): per-language `[Language]Syntax`;
  adding one = vendor `parser.c` (+`scanner.c`) + `highlights.scm` under
  `lib/tree_sitter/<lang>/`, add the FFI decl + `build.sh` line, fill the
  `LANGUAGES` row (grammar/comment/LSP/formatter) + a `DEFAULT_LANGUAGES` glob. Query is
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
  down so the next `lsp_sync` respawns it (crash recovery). Client-initiated
  requests (definition/hover/formatting/rename/completion) are capability-gated off the
  `initialize` result and tracked in a per-server `pending` map keyed by request id;
  the async response is dispatched back by request kind. *Completion* (`completion.odin`)
  auto-triggers while typing: a word char (≥ `COMPLETION_MIN_CHARS`) or a server trigger char
  queues a debounced `textDocument/completion`; the popup then filters client-side against the
  typed prefix (dismissing on an invalid edit) and re-requests when the result was `isIncomplete`.
  `snippetSupport:false` is advertised so items arrive as plain text; a stray snippet is truncated
  at its first placeholder. `Tab` accepts — replacing the whole current word and applying any
  `additionalTextEdits` (auto-import) in the same undo group; `Esc`/movement/non-word input dismisses.
  Formatting carries the
  buffer `rev` so a stale result (doc changed mid-request) is dropped, and
  format-on-save chains the save onto the response. *Rename* (`rename.odin`, `Alt+r`)
  prompts in a small caret-editable box, then applies the server's WorkspaceEdit
  (`changes`/`documentChanges`) across every file — loading unopened ones as modified
  buffers (`editor_load_buffer`) — as one cross-buffer undo transaction. `initialize`
  advertises `workspaceFolders` + `workspace.configuration` (both needed for
  servers to do workspace-wide rename/refs); `didSave` **must** carry the document
  `text` (ols re-indexes from it — omitting it drops the file's symbols). pyright's
  open-files-only default is flipped via `LSP_DIAGNOSTIC_MODE` answered on the config
  pull + pushed on `didChangeConfiguration`.
- **Formatting** (`format.odin`): *Format Document* / format-on-save prefer a
  language's external `formatter` (a `LANGUAGES` field, e.g. Python → `ruff format -`)
  over the LSP path. The buffer is piped through the tool as a stdin→stdout filter
  (`shell_filter`: temp-file input so writing can't deadlock the output, stderr
  discarded so it can't corrupt the TUI), and the result is applied as one undo
  group (whole-buffer replace, cursor clamped). A missing tool / non-zero exit
  reports a message and leaves the buffer untouched (on save, it saves unformatted).
  `format_on_save` is a config knob seeding `editor.format_on_save` at startup.

## AI edit

*Selection + prompt* (`Ctrl+K`, `aiedit.odin` → `llm.odin`): a caret prompt takes an
instruction; qed sends the whole buffer — with the selection wrapped in
`<<<SELECT…SELECT>>>` — plus the instruction to a configurable chat command
(`llm.chat_command`, default `claude -p`; `llm.edit_prompt` is the template). The
command runs through the shared **async subprocess** runner (`subprocess.odin`:
spawn-with-stdin-body + non-blocking stdout drain + cancel, pumped next to `lsp_pump`);
multiple run concurrently and are cancellable (*Cancel AI Edits* / shutdown kill
them). Each request stores the target buffer **path** (survives `[]Buffer` realloc)
and the original selected **text**. On completion: the reply's **last fenced code
block** is extracted (the model may reason first), the block is **relocated** by
content search nearest the original range — so unrelated edits elsewhere don't
invalidate it; editing the block itself cancels the request immediately
(`llm_prune_edited`, kills the subprocess so it stops burning tokens) — the selection's
leading/trailing **whitespace framing is reattached**, and the range is replaced
as **one undo group** with the cursor/selection translated in place (no jump to the
edit). While a request is in flight its rows carry a faint highlight
(`COLOR_AI_EDIT_BG`, lighter `COLOR_AI_EDIT_CURRENT_BG` on the cursor line),
relocated live each render by the same content search so it tracks edits above/below.
`QED_LLM_DEBUG` dumps the prompt/response to `/tmp` for debugging. The
selection-replace contract can't touch code outside the region (e.g. add an
import); that's a TODO. See [notes/ai.md](notes/ai.md).

## Inline completion

*Ghost-text FIM* (`fim.odin`): with `fim.enabled` (config `llm.completion_enabled`,
seeded at startup, *Toggle Inline Completion* flips it), typing arms a debounced
(`completion_debounce_ms`) request. `prefix`/`suffix` are the buffer around the cursor
clamped to `completion_context_lines`, sent to a FIM endpoint (default Codestral
`/v1/fim/completions`) as an async `curl` subprocess through the shared
`subprocess.odin` runner (like the AI edit), pumped in the main loop; any edit
cancels the in-flight request and re-arms.
The reply's `choices[0].message.content` is stored as dimmed virtual text
(`COLOR_GHOST_FG`) drawn at the cursor, **not** backed by the buffer; multi-line
suggestions reserve blank rows via `fim_ghost_gap` (the buffer render offsets rows below
the cursor down) so continuation lines don't paint over real text. Ghost is valid only
while the cursor sits at `ghost_at`. `Tab` accepts all, `Ctrl+Right` a word (both one
`buffer_insert_text` undo group); other keys / mouse / cursor move dismiss. The LSP
completion popup takes precedence — ghost is suppressed while it is open. The API key is
read from `$CODESTRAL_API_KEY` (config `completion_api_key_env`) by the curl child, never
held by qed. **External quirk:** the POST body is fed on **stdin** (`--data-binary @-`),
not `@file` — the async spawn unlinks the temp immediately and curl opens a `@file`
lazily, so a `@file` races to an empty body. `QED_FIM_DEBUG` logs to `/tmp/qed-fim.log`.

## Terminal pane

*Floating embedded terminal* (`terminal.odin`, `Alt+t`): a persistent interactive
shell in an overlay sized by `overlay_layout` (like project-search). The shell +
PTY + emulator outlive pane open/close — toggling only shows/hides; the session
survives. The emulator is **vendored libvterm** (`lib:vterm`), fed PTY bytes; the
PTY itself is a `forkpty` shim (`lib:pty`, `-lutil`) — the one OS-specific piece.
`term_pump` (main loop, next to `lsp_pump`) does a non-blocking `read(pty_fd)` →
`vterm_input_write`; the loop's fast-poll gate carries `term_alive` so a hidden-but-
running shell still drains (child never blocks on a full pipe). `term_render` walks
the libvterm grid cell-by-cell to `tb2.set_cell` (full redraw, like everywhere);
the hardware cursor sits at the emulator cursor when focused. `term_dispatch`
forwards keys via `vterm_keyboard_*` and intercepts exactly one escape-hatch —
`Alt+t` — to defocus. Alt-screen is enabled (full-TUI capable: vim/htop/less).
Colours come from qed's own palette, not the host terminal (qed is a guest; the
host palette is invisible): `COLOR_TERM_FG/BG` + a 16-entry `COLOR_TERM_ANSI`
(config `terminal_foreground`/`terminal_background`/`terminal_ansi_0..15`) set on the
vterm state; default bg matches the pane. **External quirk:** this terminal's
termbox tags the control-byte keys (Enter/Tab/Backspace/Esc) with a spurious Ctrl
modifier, so `term_send_key` strips Ctrl for those before encoding. Mouse events forward
to the guest via `vterm_mouse_*` (libvterm only emits bytes when the program enabled mouse
reporting, so a plain shell ignores them); the wheel scrolls a libvterm scrollback ring
(`sb_pushline`/`sb_popline` callbacks, `TERM_SCROLLBACK` lines) at the shell prompt but
forwards to the program on the alt-screen (tracked via a `settermprop` callback); a click
outside the pane defocuses. `term_render` draws through a `sb_view` scroll offset; a
keystroke snaps back to the live bottom. Text copy-out/paste are not wired yet.
Deep-dive: [notes/terminal.md](notes/terminal.md).

## File layout

`main` (entry/loop) · `editor` (dispatch + render) · `buffer` · `edit` (primitives
+ undo) · `cursor` · `config` · `settings` (JSON load) · `clipboard` · `shell` ·
`confirm` · `pane` (box drawing) · `subprocess` (shared async one-shot subprocess: spawn-with-stdin-body / non-blocking drain / cancel) · `wrap` (soft-wrap layout) · `textfield` (shared single-line editable field) · `overlay` (shared fuzzy-list widget state) · `palette` · `picker` · `bufswitch` · `langpick` · `filetree` · `fuzzy` ·
`linefind` · `projsearch` · `jump` · `highlight` · `language` · `lsp` · `completion` · `rename` ·
`format` · `git` · `llm` · `aiedit` · `fim` · `terminal` · `perf_bench`.
Vendored C under `lib/`: `tb2` (termbox2), `tree_sitter`, `vterm` (libvterm), `pty` (forkpty shim).

## Shipped

Core editing: buffer open/save (atomic, permission-preserving, LF/CRLF +
final-newline preserving; external-change auto-reload + dirty-buffer save clobber guard),
insert/delete primitives + grouped undo/redo, bracket/colon-aware auto-indent
(Enter indents after an opener / Python `:`, splits a matched `{}` pair, closing
bracket re-aligns to its opener), selection +
selection-aware editing, block indent/dedent, tab-stop backspace (deletes a full
indent in leading whitespace), clipboard (external + fallback),
full Unicode (grapheme + display width), tab-char display + per-buffer
tabs/spaces + indent-width detect (`Change Indentation` command: Auto-detect /
Tabs / Spaces:1–4; literal-tab display width stays the global `tab_width`),
line-comment toggle, move-lines, paragraph/word/smart-home motion, held-arrow
cursor acceleration (smooth fractional-velocity ramp, `cursor_accel*` knobs), auto-close
pairs (brackets/quotes/backtick: surround selection, type-over, backspace-deletes-pair;
`auto_close_pairs` knob), matching-bracket underline.

Navigation & UI: per-buffer soft wrap (word-boundary, config `line_wrap` default on,
*Toggle Line Wrap*; visual-row cursor motion + sub-row scroll; wraps ghost-text too),
line-number + git gutter, mouse (position/drag/wheel/multi-click,
drag auto-scroll), status + message line, welcome screen, quit guard across
modified buffers, floating pane primitive, command palette, fuzzy file-open +
multiple buffers, close buffer, buffer switcher (`Ctrl+E`: `overlay_layout` two-pane — fuzzy over open
buffers in stable order + digit instant-jump on empty query, side preview of the
selected buffer's in-memory content centered on its cursor), fuzzy line jump (`Ctrl+F`,
matches in file order), project-wide search (`rg --sort path` for deterministic
order), file-tree browser (`Alt+f`: modal, lazy per-dir expand,
right-side preview, new/rename/delete with recursive-delete confirm; rename follows
open buffers), floating terminal pane (`Alt+t`: persistent embedded shell via
vendored libvterm + PTY, full-TUI capable, qed-palette colors, mouse forwarded to the
guest + wheel scrollback), jump list
(back/forward), runtime config (`~/.config/qed/config.json`). Every floating pane is
mouse-driven (wheel scroll, click-select, double-click activate, caret/drag-select in
prompt fields, click-away dismiss).
Preview panes (file-open, file-tree, project-search, buffer switcher) are syntax-highlighted
via a one-shot synchronous tree-sitter pass (`highlight_lines`); project-search parses
from line 1 to the window end (size-gated at `HIGHLIGHT_ASYNC_BYTES`) so constructs
opening above the window color correctly.

Language intelligence: config-driven language detection (glob rules + built-in
dotfiles, per-buffer, `Set Language` override); tree-sitter highlight (Odin, JSON,
Python, C, JS/JSX, TS/TSX, Shell, Lua, SQL, Markdown w/ inline + fenced-code
injection); LSP diagnostics (ols, pyright, clangd, typescript-language-server,
bash-language-server, lua-language-server) — live syntax + on-save semantic, range
underline, gutter severity, diagnostics pane, next/prev-diagnostic navigation
(`Alt+<`/`Alt+>`), go-to-definition (`Alt+d`, jump-list aware), hover popup (`Alt+s`),
workspace-wide rename (`Alt+r`, cross-file as modified buffers, single cross-buffer undo),
auto-triggered completion dropdown (as-you-type + trigger chars, debounced, client-side
incremental filter, `Tab` accept, `additionalTextEdits` auto-import),
document formatting (external formatter e.g. `ruff format -`, else LSP) + format-on-save
(config `format_on_save`, toggleable), `Restart LSP`; git diff gutter (live vs `HEAD`)
+ optional hunk row highlight (`Toggle Hunk Highlight`, config `git_hunk_highlight`).

AI assist: selection + prompt (`Ctrl+K`) via a configurable chat command
(`llm.chat_command`, default `claude -p`) — whole-file context, concurrent
cancellable async subprocesses, fenced-block extraction, content-relocated apply
as one undo group with whitespace framing preserved. Inline FIM completion
(ghost-text): auto-triggered debounced suggestions from a FIM endpoint (default
Codestral `/v1/fim/completions` via `curl`), dimmed virtual text with multi-line
push-down, `Tab` accepts all / `Ctrl+Right` a word, `Esc`/edit/move/mouse dismiss,
LSP popup takes precedence; `llm.completion_enabled` + *Toggle Inline Completion*.

Performance: incremental + async tree-sitter parse, viewport-scoped highlight
query, incremental LSP `didChange`, big-file cutoff. See
[notes/perf.md](notes/perf.md).

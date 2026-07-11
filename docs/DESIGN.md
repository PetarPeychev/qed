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
1-row **status bar** (pane chrome colors; icon-prefixed segments, `ICON_STATUS_*` in config: working-root-relative
path + `●` modified flag + `line/total` + git branch with `↑ahead↓behind` — polled async every
`git_stat_poll_ms` via `GitStat`; right side: language + LSP + indent style / `big`), then a
1-row **message line** (transient errors / prompts / status). Gutter = mark column
(git diff) + line numbers, width = digit count + padding, folded into every
screen↔buffer column mapping (cursor placement, mouse).

Line backgrounds are **alpha-composited** tints (`editor_line_bg` + `color_over`),
stacked bottom→top: optional git-hunk row tint → AI-edit tint → current-line tint
(a semi-transparent white lift over whatever's beneath). Tint strengths
(`*_TINT`) and tint colors are both theme-overridable. The
row tint is part of **diff view** (*Git: Toggle Diff View*, `Alt+g`, config
`git_diff_view`, off by default), separate from the always-on gutter mark — see
Git diff view below.

**Git diff view** (`git.odin`, global `g_diff_view`): with diff view on, a hunk's
removed/base lines render inline as dim-red **ghost rows** (`editor_render_hunk_ghosts`)
— above a modification, below a pure deletion — with the changed span word-highlighted
on both the ghost and the live line (`git_word_span`, prefix/suffix trim). The gutter
keeps the HEAD blob + per-line text (`base_text`) so old text is available; `git_diff`
emits `GitHunk`s + per-row `above`/`below` ghost counts. Ghost rows are virtual (one
clipped row each, never wrapped) and shift everything below, so the counts fold into
the screen-mapping walkers (`vpos_up`/`down`/`dist` via `line_rows` + `git_above`/`below`);
cursor *motion* is unaffected (it walks real rows via `cursor_visual_*`). All ghost math
no-ops when `g_diff_view` is off, so the viewport behaves exactly as before.

**Merge conflicts** (`conflict.odin`): content-driven, always on, no git dependency —
`merge_scan` finds `<<<<<<<`/`|||||||`/`=======`/`>>>>>>>` blocks by line prefix. Render
tints ours green, theirs blue, diff3 base gray, marker lines stronger + fg-colored (all
via the existing `editor_line_bg`/`diff_bg` render path). Ours↔theirs word emphasis reuses
`git_myers` (line pairing) + `git_word_span` (per-char span), shown on both sides.
*Git: Resolve Conflict* (`Alt+m`): cursor in a block opens a 3-way `Keep Ours/Theirs/Both`
dialog (`MergeDialog`, the shared `dialog_*` primitive); cursor outside jumps to the next
block. Resolve deletes the marker/side rows bottom-up as one undo group (`merge_resolve`).

Message line clears on the next input event (no timers); an active interactive
prompt owns the line + input until it resolves. All user-facing messages go through
`editor_log(editor, level, source, msg, show)` (`log.odin`): it appends a `LogEntry`
to a capped in-memory ring (`LOG_MAX`), appends a plain-text line to the disk log,
and (when `show`) sets the message line — copied into owned storage, since a raw
`tprintf` string would dangle once the per-frame `temp_allocator` is freed. `source`
is a short subsystem tag ("LSP", "Format", …; `""` renders bare); the message line
draws `Source: text` and colours by level — `.Info` → `COLOR_FG`, `.Warn` →
`COLOR_WARN_FG`, `.Error` → `COLOR_ERROR_FG`. `.Debug` entries are always log-only
(never touch the line). `editor_clear_message` (or an empty `msg`) blanks the line and
is never logged. The disk log lives at `$XDG_STATE_HOME/qed/qed.log` (append, flushed
per write, rotated to `qed.log.old` past 1 MB, session-start marker with version);
disk logging is skipped when `headless`. *Debug: Message Log* (`Alt+l`) opens a
floating pane over the ring — timestamped rows coloured by level (selection tints
bg only, keeping the level colour), sticks to the newest, arrow/wheel scroll +
select, `Shift+↑↓` extends a contiguous selection, `Ctrl+C` copies the selection
(newline-joined), and a file-tree-style footer whose `d`/`i`/`w`/`e` keys toggle
per-level visibility (Debug off by default, persisted for the session).
Timestamps render local wall-clock (`core:time/timezone`, lazy tzdb region, silent
UTC fallback). At startup the ring seeds from the disk-log tail (parsed back,
local→UTC via `datetime_to_utc`, never re-written), so the pane shows previous
sessions behind `=== qed … ===` marker rows. The pane opens on the welcome screen
too, where a status-bar variant (working root + git branch left, `qed VERSION`
right) and the message line render under the art, so startup errors are visible. Truecolor output; colors
(`COLOR_*`), UI glyphs (`ICON_*`), tint strengths (`*_TINT`) and the syntax
`captures` mapping come from the active theme — a JSON file with
`colors`/`captures`/`icons`/`tints` sections, hot-reloaded like config.json.
Theme resolution is a sparse overlay chain: embedded `default.json` (the complete
reference — full palette + capture table) → bundled same-name theme (a diff; nine
bundled, two light: solarized-light, catppuccin-latte; `colors` kept complete by
policy, icons/tints diffed) → user `~/.config/qed/themes/<name>.json` per-key.
qed never writes theme files; a missing non-bundled name errors to defaults.
`captures` maps tree-sitter capture names → theme color keys (plus
`bold`/`italic`/`underline`/`reverse`), longest-prefix fallback
(`comment.documentation` → `comment`), per-language overrides
(`"markdown": {"punctuation.special": …}`) beating global at each fallback step;
resolution is baked to capture-id → color arrays at query-build/recolor time, so
the paint path stays an array index. *Debug: Inspect Tokens* (a **passive**
floating pane, `inspect.odin` — takes no focus, Esc or the command closes it)
shows the node ancestry, capture stack, winning resolution chain and predicate
near-misses under the cursor, live. A theme change — via the *Set Theme* picker or the disk
poll — funnels through `editor_retheme`: theme colors are baked into two caches
(each language's `Syntax.colors` palette and every buffer's per-char `hl.colors`),
so it rebuilds the palettes (`syntax_recolor`) and invalidates the buffers
(`hl.top = -1`) or on-screen text keeps the old colors until the next edit.

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
- **Save (atomic):** write a temp file in the same dir (missing parent dirs
  created first), then `rename` over target;
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

Explicit `switch` on `(key, mod, ch)` → action procs. Rebindable commands live in
the `commands` table (`palette.odin`), their default binds in the embedded config's
`keybinds` section; primitive editing/movement and `Ctrl+P` (palette) are fixed.
Every pane closes/defocuses on its own command's chord via `command_matches`
(`palette.odin` — resolves the event against the *configured* keybind, so rebinds
keep the toggle; the fixed `Ctrl+P` and terminal's extra `Alt+T` tolerance stay
hardcoded); the welcome-screen key whitelist resolves the same way.

Every editable text box (palette/picker/switcher/lang/indent/line-find/project-search
queries, find/replace, rename, AI-edit, file-tree name prompts) is one shared single-line widget,
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
  accumulates the keys between them and routes the whole paste to whatever has
  focus — the buffer (one undo group), the terminal pane, or the active overlay's
  text field via `Overlay.paste` (flattened to one line, so a pasted newline
  can't fire Enter mid-paste); dialogs ignore it.

## Language detection

Each `Buffer` carries a `language: Language`, set once at open (`language_of`).
File→language is **not hardcoded**: the config `languages` section is keyed by
language name, each entry an object with `patterns` (glob list), `lsp` (server
command) and `formatter` (external filter) — all user-overridable, per-key merged
back like every other knob. `LANGUAGE_DEFAULTS` (`language.odin`) is compiled-in
wiring only (comment token, lsp id, grammar); default patterns/`lsp`/`formatter`
come from the embedded config's `languages` section. `LANGUAGES` is the working
copy each load resets then overlays. Patterns are `*`-globs matched against the basename, most-specific-first (exact
before glob, longer before shorter); built-in defaults cover extensions plus common
dotfiles (`.bashrc` → shell, …). `lsp_id` and the comment token stay compiled-in.
Everything — highlight, LSP, status bar, comment token — reads `b.language`. The
*Set Language* command (`langpick.odin`) overrides it for the session (re-parses,
re-opens LSP).

## Multiple servers / grammars

- **Syntax** (`highlight.odin`, `language.odin`): per-language `[Language]Syntax`;
  adding one = vendor `parser.c` (+`scanner.c`) + `highlights.scm` under
  `lib/tree_sitter/<lang>/`, add the FFI decl + `build.sh` line, fill the
  `LANGUAGE_DEFAULTS` row (grammar/comment/lsp id) + patterns/lsp/formatter in
  `config/config.json`. Queries are vendored **upstream-verbatim**: a predicate
  evaluator (`predicate.odin`) enforces `#eq?`/`#match?`/`#lua-match?`/`#any-of?`/
  ancestry predicates per match (parsed + regex-compiled once at query build,
  cached per pattern; unknown predicates are skipped, never reject a pattern —
  deviations in `lib/tree_sitter/PATCHES.md`). A
  grammar/query that fails to compile surfaces a one-shot status message. Parse is
  incremental + async on big files — [notes/perf.md](notes/perf.md).
- **Injection** (markdown + HTML): a `LANGUAGES` row may carry an `injections` query.
  After the host paint, `highlight_inject` runs it over the viewport, and for each
  region freshly re-parses the embedded language (synchronous, viewport-scoped —
  cheap since paint only reruns on tree/viewport change) and paints its colors over
  the host at the region's row/col offset. The target language follows the standard
  convention — `@injection.content` + `@injection.language` / `#set!
  injection.language` — resolved via `language_of_name`; markdown injects inline +
  fenced code blocks, HTML injects `<script>`/`<style>` bodies as JS/CSS.
  `MarkdownInline` is an injection-only `Language`
  (grammar + query, no file extension).
- **LSP** (`lsp.odin`): JSON-RPC/stdio, multiple servers concurrent
  (`g_lsps` keyed by server command), one per language; UTF-16 columns converted
  to byte offsets. `didChange` is incremental when the server advertises it. Servers
  auto-start lazily; the *LSP: Restart* command tears the current buffer's server
  down so the next `lsp_sync` respawns it (crash recovery). `LspState` is
  `Starting`→`Ready`→`Failed` (a server absent from `g_lsps` also reads as starting);
  the status segment shows the name colored by state — dim + `…` while starting,
  plain when ready, red + `✗` when failed. Server **stderr** is piped and drained
  non-blocking in `lsp_pump` (partial lines buffered to their newline, drained again
  on exit); each line logs as `.Debug` source "LSP" prefixed with the server name,
  capped at `LSP_STDERR_MAX_LINE` bytes and flood-limited at `LSP_STDERR_MAX_LINES`
  per server. Spawn + initialize (with capabilities) also log at `.Debug`. Client-initiated
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
multiple run concurrently and are cancellable (*AI: Cancel Edits* / shutdown kill
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
seeded at startup, *AI: Toggle Inline Completion* flips it), typing arms a debounced
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
keystroke snaps back to the live bottom. **Copy:** a left drag over the grid+scrollback
selects (rendered inverted) and auto-copies the trimmed text to the clipboard on release
(`term_copy_selection`); the drag is robust to tmux/WT dropping the press or slipping in a
stray release (a bare motion (re)anchors). A drag only selects when the guest isn't grabbing
the mouse — on a mouse-mode program (tracked via `PROP_MOUSE` settermprop) it forwards, and
`Shift`+drag forces a local selection. **Paste** (host bracketed-paste only): while the pane is
focused, `editor_dispatch` routes `Paste_Begin`/keys/`Paste_End` into `term_paste`, wrapping the
body in libvterm's `keyboard_{start,end}_paste` (bracketed only if the guest enabled DECSET 2004)
with `\n`→`\r`. **Escape** defocuses at a plain shell prompt but is forwarded on the alt-screen so
full-TUI programs keep it (config `terminal_escape_closes`, default on).
Deep-dive: [notes/terminal.md](notes/terminal.md).

## File layout

`main` (entry/loop) · `editor` (dispatch + render) · `buffer` · `edit` (primitives
+ undo) · `cursor` · `settings` (user-config globals; embedded `config/` JSON
defaults seeded before main, load + write-back) · `clipboard` · `shell` ·
`confirm` · `pane` (box drawing) · `log` (message ring + disk log + *Debug: Message Log* pane) · `subprocess` (shared async one-shot subprocess: spawn-with-stdin-body / non-blocking drain / cancel) · `wrap` (soft-wrap layout) · `textfield` (shared single-line editable field) · `overlay` (shared fuzzy-list widget state) · `preview` (shared scrollable highlighted preview / diff) · `palette` · `picker` · `bufswitch` · `langpick` · `filetree` · `fuzzy` ·
`linefind` · `find` (in-buffer find/replace) · `projsearch` · `jump` · `highlight` · `predicate` (query predicate evaluator) · `inspect` (*Debug: Inspect Tokens* pane) · `language` · `lsp` · `completion` · `rename` ·
`format` · `git` · `conflict` (merge-marker highlight + resolve) · `llm` · `aiedit` · `fim` · `terminal` · `perf_bench`.
Vendored C under `lib/`: `tb2` (termbox2), `tree_sitter`, `vterm` (libvterm), `pty` (forkpty shim).
Default config + bundled themes are JSON under `config/` at the repo root, embedded via `#load`.

## Testing

`core:testing` unit tests live in `src/*_test.odin`. On top of them, an **e2e
harness** (`e2e_test.odin`) drives the real `Editor` headless: termbox comes up
once per process on an 80×24 PTS via `tb2.init_fd` (no controlling tty,
`pty.open` supplies the pair, a background thread drains the master), synthetic
`tb2.Event`s feed `editor_step` (the factored main-loop body, so the ALT-Esc
retag and bracketed-paste accumulation are covered too), `editor_render` draws
into termbox's back buffer, and the grid reads back through `e2e_cell*` (glyph,
truecolor fg/bg, attr bits). `editor_init(headless)` skips terminal bring-up and
the process-global teardowns (termbox/syntax/clipboard/`g_language_rules`) so
many sessions reuse them; a mutex serializes sessions (the termbox singleton
doesn't survive re-init). Harness capabilities: `e2e_mouse` / `e2e_paste` /
`e2e_resize` (TIOCSWINSZ + SIGWINCH, size restored on stop), a temp-git-repo
fixture (`e2e_git_start`), a stub-subprocess fixture (`e2e_stub_script`: fake
formatter / chat command / FIM endpoint), and a fake stdio LSP server (canned
JSON-RPC, in `e2e_lsp_test.odin`). Coverage is one file per area:
`e2e_edit/files/nav/lang/ai/mouse/lsp_test.odin`; scope + assertion surfaces:
[notes/e2e.md](notes/e2e.md).

## Shipped

Core editing: buffer open/save (atomic, permission-preserving, LF/CRLF +
final-newline preserving; external-change auto-reload + dirty-buffer save clobber guard;
optional save fixups — `trim_trailing_whitespace_on_save` / `ensure_final_newline_on_save`
knobs + runtime *Toggle …* commands, markdown two-space hard breaks survive trimming,
one undo group, run before format-on-save; quit/close/conflict saves run the same
full fixups+format pipeline, quit deferring until an in-flight LSP format lands),
insert/delete primitives + grouped undo/redo, bracket/colon-aware auto-indent
(Enter indents after an opener / Python `:`, splits a matched `{}` pair, closing
bracket re-aligns to its opener), selection +
selection-aware editing, block indent/dedent, tab-stop backspace (deletes a full
indent in leading whitespace), clipboard (external + fallback; empty-selection `Ctrl+C`/`Ctrl+X` copy/cut the whole line),
full Unicode (grapheme + display width), tab-char display + per-buffer
tabs/spaces + indent-width detect (`Change Indentation` command: Auto-detect /
Tabs / Spaces:1–4; literal-tab display width stays the global `tab_width`),
line-comment toggle, move-lines, paragraph/word/smart-home motion, buffer-edge
arrow clamps (Down on the last line → line end, Up on the first → col 0;
wrap-aware, shift/accel included), held-arrow
cursor acceleration (smooth fractional-velocity ramp, `cursor_accel*` knobs), auto-close
pairs (brackets/quotes/backtick: surround selection, type-over, backspace-deletes-pair;
`auto_close_pairs` knob), matching-bracket underline.

Navigation & UI: per-buffer soft wrap (word-boundary, config `line_wrap` default on,
*Toggle Line Wrap*; visual-row cursor motion + sub-row scroll; wraps ghost-text too),
line-number + git gutter, mouse (position/drag/wheel/multi-click,
drag auto-scroll), status + message line (relative path, git branch + ahead/behind, segment icons),
structured message log (level/source-tagged ring + disk log at `~/.local/state/qed/qed.log`,
level-coloured line, local-time stamps, *Debug: Message Log* pane `Alt+l` — per-level
filters, multi-select copy, cross-session history seeded from the disk log, works on
welcome), welcome-screen status bar (root + branch + version + message line),
rebind-aware pane self-close chords (`command_matches`), Debug-level internals
instrumentation (subprocess/AI/FIM/save/config/clipboard/terminal trails), welcome screen, quit guard across
modified buffers, floating pane primitive, command palette, fuzzy file-open +
multiple buffers, close buffer, buffer switcher (`Ctrl+E`: `overlay_layout` two-pane — fuzzy over open
buffers in stable order + digit instant-jump on empty query, side preview of the
selected buffer's in-memory content centered on its cursor), find/replace in buffer (`Ctrl+F` find, `Ctrl+H` replace — floating top-right bar,
literal or regex `.*` toggle, smart-case `Aa` toggle, all matches highlighted +
current shown as selection, `Enter`/arrows next/prev with wrap, `Alt+a` replace-all,
single-line/per-line), fuzzy line jump (`Ctrl+G`,
matches in file order; a `:N`/`:N:C` query is an exact line/column jump instead), project-wide search (`rg --sort path` for deterministic
order), file-tree browser (`Alt+f`: modal, `Enter` expands a folder / opens a file,
lazy per-dir expand, right-side preview, new/rename/delete with recursive-delete confirm;
rename follows open buffers; footer toggles — `e` expand/collapse-all (skips
gitignored + hidden dotdirs), `.`/`i` show dotfiles / gitignored (both hidden by
default, config `filetree_show_dotfiles`/`filetree_show_ignored`), highlighted when on;
header scope tab bar (`All`/`Open`/`Git`/`Unsaved`, `←`/`→` or click) restricting the
tree to a pruned, auto-expanded view of matching files + ancestors; git-status bars —
`git status --porcelain --ignored --untracked-files=all` (single `sh -c` with `rev-parse`) scanned **async**
via the shared subprocess runner: the first open of a session blocks on it, every
reopen renders instantly from the cached status/ignored then refreshes in the
background (`filetree_scan_pump`); a green/yellow `▌` per
added/modified file propagated up its ancestor folders, ignored files dimmed; unsaved
open buffers marked with a trailing `●`, propagated to folders),
floating terminal pane (`Alt+t`: persistent embedded shell via
vendored libvterm + PTY, full-TUI capable, qed-palette colors, mouse forwarded to the
guest + wheel scrollback, drag-select auto-copy + host bracketed-paste, `Esc` closes at
the shell prompt), jump list
(back/forward), runtime config (**sparse overlays**: embedded `config/config.json`
is every default, none in Odin source, completeness test-enforced; user
`~/.config/qed/config.json` is a per-key diff qed never writes — no
materialization, unknown keys get a one-shot warning, malformed JSON falls back
to defaults without crashing; UI persistence like the theme picker's Enter writes
only its own key; both config + active theme hot-reload via the disk poll —
colors/keybinds/knobs apply live, runtime toggles
survive, terminal palette re-pushed; existing buffers keep their language, running LSPs
their command), JSON themes (sparse overlay chain over the embedded `default.json`
base — see Rendering; *Set Theme* fuzzy picker with instant preview,
Enter persists / Esc reverts), selection pre-fill (a single-line selection
pre-populates Find / Replace / Project Search / Line Jump, fully selected so
typing replaces; multi-line/whitespace selections keep each pane's persisted
query). Every floating pane is
mouse-driven (wheel scroll, click-select, double-click activate, caret/drag-select in
prompt fields, click-away dismiss).
Preview panes (file-open, file-tree, project-search, buffer switcher, line jump) share one
scrollable, syntax-highlighted `Preview` component (`preview.odin`): wheel-scrollable while
the pointer is over the right pane, soft-wrapping long lines (word-boundary via `line_wrap`,
blank continuation gutter, tab-aware — always on, no horizontal scroll; the scroll clamp
`preview_max_scroll` is wrap-aware so a wrapped tail stays reachable), highlighting line
1→viewport+lookahead (`preview_parse_ahead`)
and re-highlighting from the top as it scrolls, size-gated at `HIGHLIGHT_ASYNC_BYTES`
(window-only above it), capped at `preview_max_lines`. File source loads lazily via `head`;
buffer source (switcher/line jump) previews in-memory content. The file-tree **Git** tab
previews a diff instead — changed hunks + `preview_diff_context` lines of context in the
inline-diff-view style (dim-red ghost rows, added/modified tint, word-level highlight),
built by `git_diff_file` (HEAD-vs-worktree for a non-open file, reusing the gutter's line-hash diff).

Language intelligence: config-driven language detection (glob rules + built-in
dotfiles, per-buffer, `Set Language` override); tree-sitter highlight with full
predicate evaluation (Odin, JSON,
Python, C, C++, Go, Rust, JS/JSX, TS/TSX, HTML w/ script/style injection, CSS,
Shell, Lua, SQL, TOML, YAML, Dockerfile, Markdown w/ inline + fenced-code
injection, bold headings/strong + italic emphasis); theme-driven capture→color
mapping (per-language overrides, prefix fallback) + *Debug: Inspect Tokens*
live inspector; LSP diagnostics (ols, pyright, clangd C/C++, gopls, rust-analyzer,
typescript-language-server, vscode-html/css-language-server, taplo,
yaml-language-server, docker-langserver,
bash-language-server, lua-language-server) — live syntax + on-save semantic, range
underline, gutter severity, diagnostics pane, next/prev-diagnostic navigation
(`Alt+<`/`Alt+>`), go-to-definition (`Alt+d`, jump-list aware), hover popup (`Alt+s`),
workspace-wide rename (`Alt+r`, cross-file as modified buffers, single cross-buffer undo),
auto-triggered completion dropdown (as-you-type + trigger chars, debounced, client-side
incremental filter, `Tab` accept, `additionalTextEdits` auto-import),
document formatting (external formatter e.g. `ruff format -`, else LSP) + format-on-save
(config `format_on_save`, toggleable), `LSP: Restart`, state-colored status segment
(dim `…` starting / plain ready / red `✗` failed) + server stderr piped into the
`.Debug` message log; git diff gutter (live vs `HEAD`)
+ optional inline diff view (`Git: Toggle Diff View`, `Alt+g`, config `git_diff_view`): row
tint plus dim-red ghost rows for removed/replaced lines with word-level change highlight;
merge-conflict highlighting (ours green / theirs blue / diff3 base gray, marker lines
emphasized, ours↔theirs word-level diff on both sides) + resolve (`Alt+m`: keep ours /
theirs / both, or jump to next conflict).

AI assist: selection + prompt (`Ctrl+K`) via a configurable chat command
(`llm.chat_command`, default `claude -p`) — whole-file context, concurrent
cancellable async subprocesses, fenced-block extraction, content-relocated apply
as one undo group with whitespace framing preserved. Inline FIM completion
(ghost-text): auto-triggered debounced suggestions from a FIM endpoint (default
Codestral `/v1/fim/completions` via `curl`), dimmed virtual text with multi-line
push-down, `Tab` accepts all / `Ctrl+Right` a word, `Esc`/edit/move/mouse dismiss,
LSP popup takes precedence; `llm.completion_enabled` + *AI: Toggle Inline Completion*.

Performance: incremental + async tree-sitter parse, viewport-scoped highlight
query, incremental LSP `didChange`, big-file cutoff. See
[notes/perf.md](notes/perf.md).

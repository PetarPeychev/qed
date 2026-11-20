# qed — Architecture

Living reference for how the pieces fit. Terse by policy: only what the code
can't tell you (non-obvious invariants, external-quirk workarounds) lives here.
Read CLAUDE.md first for philosophy and conventions. Tasks are in
[TODO.md](TODO.md); subsystem deep-dives are in [notes/](notes/).

## Data model

```odin
Buffer :: struct {
    id:          u64                    // stable handle (plugins); never reused
    path:        string
    lines:       [dynamic]Line          // never empty
    cursor:      Cursor
    selection:   Maybe(Cursor)          // anchor; cursor is the moving end
    goal_col:    int                    // remembered x for vertical moves
    line_ending: LineEnding             // .LF | .CRLF, detected on open
    modified, big: bool
    undo, redo:  [dynamic]EditGroup     // inverse-op log; `open` group coalesces
    hl: Highlight, base: DiffBase       // highlight tree + diff base (git or plugin) marks
    deco: DecoStore                     // plugin decorations, row-anchored
    language: Language                  // detected at open; Settings: Language overrides
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
renderer draws a byte range `[col_start,col_end)` at an `x_origin`. The inline
ghost (`qed.deco.inline`) on the cursor line renders through the same wrap layout
(`editor_render_ghost_line`) so ghost + relocated suffix wrap too.

Layout, top to bottom: text area (`height - 2` rows) with a left gutter, then a
1-row **status bar** (pane chrome colors; icon-prefixed segments, `ICON_STATUS_*` in config: working-root-relative
path + `●` modified flag + `line/total` + `early` plugin segments (the `git` plugin's branch, `↑ahead↓behind`, `±label`
diff base and diff size) + `±label` of another plugin's base on the current buffer (its `set_base` label) + `[n/m]` + other
plugin segments; right side: language + LSP + indent style / `big`). Both sides are
`StatusSeg` lists fitted by `status_fit` (pure, unit-tested) to keep a 1-col gap (plugin right segments sit before the builtins): shorten the path from
the left (`…/dir/name`, down to the bare name), then drop segments by `drop` rank (indent, LSP, `big`,
language, then diff size, ahead/behind, diff base, branch, `[n/m]`), then clip the filename; then a
1-row **message line** (transient errors / prompts / status). Gutter = mark column
(git diff) + line numbers, width = digit count + padding, folded into every
screen↔buffer column mapping (cursor placement, mouse).

Line backgrounds are **alpha-composited** tints (`editor_line_bg` + `color_over`),
stacked bottom→top: optional git-hunk row tint → plugin decoration tints (push order;
the `conflict` and `ai` plugins' included) → current-line tint (a semi-transparent white lift over whatever's beneath). Tint strengths
(`*_TINT`) and tint colors are both theme-overridable. The
row tint is part of **diff view** (*Diff: Toggle Diff View*, config
`diff_view`, off by default), separate from the always-on gutter mark — see
Diff view below.

**Diff engine** (`diffbase.odin`, `Buffer.base`): the line-hash Myers engine behind the gutter marks,
ghost rows, word spans, change navigation and revert. Its text only comes from plugins
(`qed.buf.set_base`; the bundled `git` plugin pushes the base blob). Each plugin owns one slot per
buffer (`DiffBase.slots`, first-set order); the newest owner's non-cleared slot is active, an owner
updating its slot keeps its place, clearing marks it `none` (keeping its place, so git's transient
`nil` never reorders it above another plugin) and unloading removes it; either reveals the slot
beneath, so git takes over again when another plugin's base goes.

**Diff view** (global `g_diff_view`): with diff view on, a hunk's
removed/base lines render inline as dim-red **ghost rows** (`editor_render_hunk_ghosts`)
— above a modification, below a pure deletion — with the changed span word-highlighted
on both the ghost and the live line (`diff_word_span`, prefix/suffix trim). The gutter
keeps the base blob + per-line text (`base_text`) so old text is available; `diff_lines`
emits `DiffHunk`s + per-row `above`/`below` ghost counts. Ghost rows are virtual (one
clipped row each, never wrapped) and shift everything below, so the counts fold into
the screen-mapping walkers (`vpos_up`/`down`/`dist` via `line_rows` + `ghost_above`/`below`, which
add plugin decoration ghosts to the diff ones).
`diff_lines` also emits a flat `DiffChange` list (`{new_lo,new_hi,old_lo,old_hi}`, current
rows ↔ base rows) as the **revert unit** — independent of `g_diff_view`, consumed by
*Diff: Revert Hunk*;
cursor *motion* is unaffected (it walks real rows via `cursor_visual_*`). All ghost math
no-ops when `g_diff_view` is off, so the viewport behaves exactly as before.

**Git diff base** (`plugins/git`, session-only): the "old" side of every git surface, picked by
*Git: Set Diff Base* (`qed.pick`: HEAD, merge base with the default branch, local + remote refs,
last 50 commits). Branch and merge-base picks are live refs, re-resolved per fetch (falls back to
HEAD in a repo where the ref doesn't resolve); commit picks are a fixed sha. The base lives only in
the plugin, which also feeds the file tree's Git tab (see Git tab): with a base,
each repo's `diff --name-status <base>` replaces its tracked `status` lines. A working-root change
resets the base. The plugin's 2 s stat poll also resolves the base sha; when it changes (a moved
branch, or HEAD under the default base) it refetches every buffer's base and rescans the tree.

**Merge conflicts** (`plugins/conflict`): content-driven, no git dependency. `buf_open`, `buf_reload`,
`buf_save` and `startup` scan the buffer (`qed.buf.find_lines` with the marker list and `word`, one core
pass returning sorted rows and kinds) for `<<<<<<<`/`|||||||`/`=======`/`>>>>>>>` blocks and push
decorations: ours/theirs/diff3-base tints (`conflict` tint, markers `conflict_marker`) with marker lines
fg-colored, and ours↔theirs word spans (`qed.text.diff_rows` with `words`, the core Myers pairing and
`diff_word_span`, no text copied into Lua) blended at `conflict_word`. Tint strengths are theme tint keys
resolved per frame. A buffer whose last open/reload/save scan found blocks is **armed** (a save or reload
with none disarms it); only while some buffer is armed does the plugin hold `buf_changed`, so a plain
session runs no Lua per keystroke (a conflict typed or pasted into an unarmed buffer highlights on save or reload). On `buf_changed` it rescans the markers and
redecorates only blocks touching the dirty rows `lo..hi` or whose structure changed; blocks elsewhere keep
their (core-shifted) decorations. *Conflict: Resolve* (`Alt+m`): cursor in a block asks
`Keep Ours/Theirs/Both` (`qed.confirm`); cursor outside jumps to the next block (wraps). Resolve deletes
the marker/side rows bottom-up as one undo group; its `buf_changed` fires in the same flush.

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
per write, rotated to `qed.log.old` past `LOG_ROTATE_BYTES` (4 MB) at session start and again mid-session,
session-start marker with version);
disk logging is skipped when `headless`. *Debug: Message Log* (`Alt+l`) opens a
full core pane (`log`, scope `log`, see Panes) over the ring through the `.Log` source:
timestamped rows coloured by level (`sel_bg`), `follow` (sticks to the newest),
arrow/wheel scroll + select, `Shift+↑↓` extends a contiguous selection, *Copy* copies it
(newline-joined), and footer chips for the scoped *Message Log: Toggle Debug/Info/Warn/Error*
(`d`/`i`/`w`/`e`) and *Toggle History* (`h`) (Debug and history off by
default, persisted for the session in `Editor.logview`; seeded entries carry `LogEntry.seeded`).
Timestamps render local wall-clock (`core:time/timezone`, lazy tzdb region, silent
UTC fallback). At startup the ring seeds from the disk-log tail (parsed back,
local→UTC via `datetime_to_utc`, never re-written), so the pane can show
previous sessions behind `=== qed … ===` marker rows. The pane opens on the welcome screen
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
near-misses under the cursor, live. A theme change, via `qed.theme.set` (the *Settings: Theme* picker) or the disk
poll, funnels through `editor_retheme`: theme colors are baked into two caches
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
  scrolls, double/triple-click selects word/line. `editor_step` coalesces a
  burst of queued same-direction wheel events (0 ms peek) into one dispatch run
  with a single render, for every consumer.

## Files

- **Open:** detect LF vs CRLF, split on `\n` into lines without storing
  terminators. A trailing newline is a **real empty last line** (VS Code model:
  visible + navigable), so "content\n" → `["content", ""]`; join with `\n`
  reconstructs the file exactly, no separate final-newline flag. Missing path →
  empty buffer, created on first save. Files ≥ `BIG_FILE_BYTES` (2 MB) open with
  `big` set — highlight, git gutter and LSP are skipped (fast plain-text buffer).
- **Save (atomic):** write a temp file in the same dir (missing parent dirs
  created first), then `rename` over target; a symlink is resolved to its final
  target first (`path_symlink_target`), so the link survives;
  reconstruct bytes by joining lines with `line_ending` (the trailing empty line,
  if any, becomes the trailing newline). No newline is forced — files save exactly
  as shown. The temp is created with the target's existing **mode** (from the disk
  fingerprint) + an explicit `fchmod`, so `rename` doesn't flatten permissions (a
  `+x` script stays executable). Ownership is not preserved (single-user editor).
- **External changes:** each buffer keeps a `DiskStamp` (`mtime`/`size`/`mode`),
  captured on open and refreshed after every save (so our own write never looks
  external). The main loop polls `os.stat` for every open buffer, throttled by
  `DISK_POLL_MS` (idle branch uses a timed `peek_event`, so it fires even with no
  input). A changed file that is **clean** auto-reloads (`buffer_reload`: re-read,
  apply the changed hunks through the primitives like `buffer_set_text` so decorations and marks on
  untouched lines stay (`text_hunks_apply`: bottom-up with precomputed byte offsets, `modified` computed
  once; past a Myers work budget of ~(n+m)·d = 1e8 it is one replace hunk), clear undo/redo, drop the parse tree, re-sync LSP via `didClose`→lazy `didOpen`,
  map the cursor through the hunks); a **dirty** one sets `disk_conflict` + warns, and a `Ctrl+S`
  onto it opens the conflict dialog (Cancel / Overwrite / Reload) instead of
  clobbering. Reload skips a buffer while its highlight parse thread is busy
  (retries next poll). Deletion on disk is ignored (buffer stays; save recreates).
- **Startup arg:** file → open it; directory → set working root + welcome screen;
  absent → welcome screen.
- **Working root change**: the bundled `workspace` plugin's *Workspace: Open Directory* (`Ctrl+o`) is a
  `path` field over `qed.fs.dirs` prefilled with the root (see Panes). In the file tree the same chord
  (*Workspace: Open Selected Directory*) takes the selected dir (a file → its parent). `qed.set_root`
  refuses with `nil, "unsaved", info` while an unsaved buffer outside the target is not in its `discard`
  ids, so nothing unsaved closes unapproved (a buffer edited during the confirm is refused again). The
  plugin closes the picker before switching (restarting servers can outlast the command slice) and on
  `"unsaved"` reopens it by `id` (text and selection restored) under the child `qed.confirm`.
  `editor_change_root` closes buffers outside the new root, restarts every LSP server and queues
  `root_changed` (the file tree plugin reopens an open tree on the new root). The process cwd never changes; subprocesses get the root explicitly.

## Clipboard

Copy/cut/paste shell out via `clipboard.odin`: `wl-copy`/`wl-paste` or `xclip`
(Linux), `pbcopy`/`pbpaste` (macOS); in-process register fallback if none exists.

## Input

Explicit `switch` on `(key, mod, ch)` → action procs. Rebindable commands live in
two tables (`palette.odin`): the global `commands` and `pane_commands`, each row with the
`scope` of the pane it runs in (`log`, `plugins`). A pane command that mirrors a global operation borrows its
bind via `Command.bind_from` (the global command's name) — no config key of its own,
key/alt/shortcut resolved live from the referenced global command
(`command_effective_bind`), so one config entry drives both dispatch paths (log *Copy* follows
global *Copy*); the others keep their own `Message Log: …`/`Plugins: …` config key (`config_name`
vs the short display `name`). Plugin commands bind under `plugins.<id>.keybinds` (see Plugins). Every
core command's default bind is a `keybinds` entry in the embedded config — including *Command
Palette* (default `Ctrl+P`), whose single bind opens whichever palette is contextual (editor or a
scoped pane's). Only primitive editing/movement stays fixed. Dispatch resolves through the
configured bind (`command_for_key`/`command_for_alt`, or `pane_command_for_event(scope)`
over the pane table; `command_bind_matches` is the one matcher, where a bare key (`Command.ch`, refused in
the editor and tree scopes) fires only in a pane without fields), and every keybind hint renders the live configured
shortcut string verbatim via `command_shortcut(name)` — so a rebind updates the
welcome screen and every pane footer. Config keybind strings are kept consistently
cased (lowercase Ctrl letters) so hints read uniformly. Every pane closes/defocuses on its own command's chord via
`command_matches` (`palette.odin` — resolves the event against the *configured*
keybind, so rebinds keep the toggle; the terminal's extra `Alt+T` tolerance stays
hardcoded); the welcome-screen key whitelist resolves the same way.

Every editable text box (palette/picker/line-find
queries, find/replace, rename, footer inputs) is one shared single-line widget,
`TextField` (`textfield.odin`): `{text, caret, anchor}` with buffer-parity binds —
grapheme + word (`Ctrl+←/→`) motion, smart home/end (`Alt+←/→`), shift-select,
`Ctrl+A`, `Ctrl+X/C/V` (paste flattens newlines), delete-selection. `textfield_key`
returns whether the text changed (fuzzy callers re-filter); `textfield_render` draws it
scrolled to the caret with the selection inverted (`COLOR_PANE_BG`/`FG`). Word/home
motion is the same `word_left_col`/`word_right_col`/`home_smart_col` the buffer cursor
uses. A `> ` prompt draws via `overlay_prompt_render`.
Every pane is mouse-driven through `pane_mouse` or an optional `Overlay.mouse` handler (`editor_dispatch`
routes `.Mouse` to it): wheel scrolls, single-click selects a row, double-click activates,
a click in the query/prompt field places the caret and a button-held drag selects, and a
click outside the box dismisses (all drag/dismiss gated on the `Motion` flag). Shared row/
field/scroll helpers live in `overlay.odin` (`overlay_list_mouse`, `fuzzy_list_center_mouse`,
`overlay_prompt_mouse`; `textfield_mouse` maps a click to a caret).
List | preview panes (`split` panes: `split:tree` for the file tree, `split:code` for line jump and search) split
via `overlay_split` with per-list min/max (`filetree_list_*_width`, `code_list_*_width`) and a global
`preview_min_width`/`preview_max_width`. Inner width W (minus the divider) >= both maxes: both at max
and the box is centered (extra width becomes margin). Below that, the deficit is taken equally from
each side down to its min, the other side absorbing the rest. W under both mins hides the preview
(`lay.preview` false: list takes the full inner width, no divider, preview neither loaded nor hit-tested; a resize reloads it when it reappears,
`editor_previews_sync`). The `PICKER_MARGIN_X` side margin is fixed at every width.
Most panes reset their query on open. Plugin panes opened with an `id` (`search`, `goto`) restore
their field text fully selected (`textfield_select_all`) so a keystroke replaces it, and the selected
item (not for a line list); a tree list also restores its expanded set. A field given an empty `text`
(the file tree's filter) starts empty and keeps the restore.

Two terminal workarounds, both
documented in `lib/tb2/PATCHES.md`:
- **ALT keys:** termbox stays in ESC input mode; after a bare `Esc`, qed
  `peek_event`s for `ALT_ESC_TIMEOUT_MS` and re-tags a buffered printable as
  `Mod.Alt` (so `Alt+f`/`Alt+F` are distinct, unlike `Ctrl+letter`).
- **Bracketed paste:** patched termbox surfaces `Paste_Begin`/`Paste_End`; qed
  accumulates the keys between them and routes the whole paste to whatever has
  focus: the buffer (one undo group), the terminal pane, or the focused pane's
  or active overlay's text field via `pane_paste` / `Overlay.paste` (flattened to one line,
  so a pasted newline can't fire Enter mid-paste); dialogs ignore it.

## Panes

`Pane` (`pane.odin`) is the one UI model of [notes/panes.md](notes/panes.md), built so far to
M4: placement `center`/`full`/`split` (`pane_geom` computes every rect), size class, title, fields
(`input`/`filter`/`query`/`path` modes), a styled text body or a `Preview` body (`body_preview`), a list
(items with label/detail/path/row/col/buf/key/color/cells, matches under a filter field, multi range,
`max` with `N+`, empty hint, `sel_bg`, `follow`, an optional core source with columns), an auto file or
buffer preview, footer hints and chips or a footer input, tabs, per-key marks, a tree list, a `scope`, a closing chord (`toggle` plugin command id or `chord`
core command name), and Odin `on.activate`/`on.close`/`on.footer` handlers. `Editor.panes` is the stack:
- The topmost non-passive pane takes keys, mouse and paste (`pane_stack_dispatch`). Passive panes
  never do and draw under everything focused.
- Kinds: Exclusive (default; opening one closes the open non-safety exclusive pane, or returns
  nil while a `modal` pane is live), Child (`parent` handle), Passive. Safety dialogs
  (`safety`: quit, close, conflict; one each) stay on top: other root panes are inserted below them.
- Invariant: a pane's descendants follow it contiguously (a child goes right after its parent's
  subtree). `pane_end(handle, activate)` takes that run off the stack, then runs the children's
  `on.close` and the pane's `on.activate` or `on.close`, so a handler that opens another pane
  never sees the old one. A pane is live only if its parent chain is.
- `Pane.id` names core panes (`quit`, `close`, `conflict`) and plugin panes (`qed.ui.open{id}`);
  `handle` is unique per open; `ctx.buf` is the buffer a core dialog acts on, resolved in its handler.
- Plugin unload only marks its panes `dead`; `pane_stack_sync` closes them later, so no Lua runs
  inside an unload. `pane_stack_sync` (end of `editor_step` and `plugin_pump`) also syncs auto previews.
- A `query` field arms `query_due`/`query_at` (`PANE_QUERY_DEBOUNCE_MS`); Enter while a query is due
  or running sets `accept` instead. Plugin panes (`ctx.lua`) and `keep` core panes stay open on activate;
  a core pane ignores Enter on an empty list or without `on.activate`.
- **List sources** (`listsrc.odin`, D2): `PaneList.source` (`ListSource{kind, scope, path, buf}`) is read
  through accessors, never copied into `list.items`: `list_count`, `list_text(i)` (what a filter matches,
  borrowed) and `list_item(i)` (built on demand with temp or borrowed strings; only drawn, activated and
  changed items are built; tests count them behind `when ODIN_TEST`). An empty filter leaves the list unfiltered
  (`filtered` false, no index array), so a 1M-line source opens without an O(n) pass. `pane_list_load`
  (at open and on every `path` field change) refills the small caches. `.Commands` is the palette's
  table for one `scope` (`when`/welcome/big gating at open into names + plugin ids; a row resolves its
  command at activate and draw (`list_command`), so a removed command's row goes dead). `.Dirs` lists
  `path`'s subdirs, or under a `path` field the dir its text names, prefix-matched smart-case on the last
  segment (base dir's entries cached until its segment changes). `.Lines` is live over a buffer: matches
  stay in buffer order, `:N[:M]` (`lines_goto`) selects one row, the view opens on the match nearest the
  cursor, items carry `buf` so the auto preview shows the buffer. `.Log` holds entry seqs passing the
  filters, recomputed when `Editor.log_seq` or a filter changes. `.Plugins` reads `Plugins.list`.
  `.Walk` is a walk handle (see Walk service), self-filtering with a debounced refill.
  `list_columns` gives a source columns (Lines, Plugins, Lua `list.columns`). A reload resets the selection and `notified`,
  so `change` fires. A new source is an enum value plus accessor cases. Each source has a `list_stamp`
  (buffer `rev`, `log_seq` + filters, plugin count; 0 = gone or static); `pane_list_fit` (each render and
  before input) refilters keeping the selected item when it changes, and the accessors read a stale index
  as empty. Log eviction shifts positions so the selection and range stay on their entries.
- Any plugin's command run while a pane with a list has focus gets `ctx.items` (the selection) and
  `ctx.files` (their paths); `ctx.view` stays owner-only.
- **Scoped commands** (D4): a pane with `scope` runs core (`pane_commands`) and plugin commands of that
  scope on their chord, before field input, and the Command Palette chord opens the palette over just
  them as a child. A core pane's `chord` closes it from any of its children. Footer `chips` (core) are
  right-aligned `key label`, lit when `on`; a click runs the command (`pane_run_command`).
- `follow` lists stick to the end (`stick`): moving off the last row or a wheel up unsticks, reaching the
  end re-sticks; `pane_list_fit` (each render and before input) clamps selection, anchor and scroll for
  live sources that shrink.
- A `path` field drills on Tab, `/` at the end (with matches) and double-click, drops a segment on
  Backspace after `/` (`path_back`), and reports its text resolved (`~`, root-relative, cleaned:
  `pane_field_value`).
- The **command palette** (`palette_open`, D1: core-built so qed works with Lua broken) is a center
  `palette` pane: filter field over the `.Commands` source, `chord = "Command Palette"`, `modal` (a
  background plugin's exclusive open is `"busy"`, not a replacement), activate runs the command after the
  pane is gone. Over a scoped pane it is that pane's child with its scope. On the welcome screen the
  welcome gate applies to the editor palette only, so a scoped pane's palette lists all its commands.
- **Tabs** (`Pane.tabs`) fill the title row: Left/Right, a click, or a tab's `cmd` chord switch (the active
  tab's chord closes), then `on.tab`. **Marks** (`Pane.marks`, by item key) draw a `▌` bar, an fg, a suffix,
  a right-aligned `+N -N` (padded over the visible rows, dropped when the label would go under 8 columns)
  and `dim` (a tree inherits it downward). A **footer input** takes every key until Enter/Esc (`on.submit`).
- A **tree list** (`list.tree`, walk sources) draws indent and expand icons from `PaneList.expanded`
  (saved by `id`); Enter or double-click on one dir toggles it before `activate` (under a filter it clears
  the filter and reveals the dir), firing `on.expand`. Open buffers get the accent fg, unsaved ones `●`.
- The **Message Log** (`log.odin`), the **Plugins pane** (`plugin.odin`, `keep`, `on.footer` shows the
  selected plugin's last error, selection saved by name; Enter on a bundled plugin opens a `plugin_source`
  child with a `body_preview`; `l` opens the log as its child) and the **LSP rename** prompt (`rename.odin`,
  a center `input` pane, `modal`) are core panes (D1). The log and Plugins pane take
  `message_log_backdrop` / `plugins_pane_backdrop`.

**Plugin views** (`plugin_ui.odin`): `qed.ui.open` builds a Pane plus a `UiView` in `Plugins.views`
(registry refs: the view table, the item values, the `on` handlers; change/query task ids), keyed by
handle. Views and Lua never hold a `^Pane` (the stack reallocates). The UiView outlives its Pane until
the close event is flushed. Events (D8), no Lua during dispatch:
- `activate`/`close`: the pane's Odin handler queues a `UiViewEvent` (item indices, first field
  text); `plugin_views_flush` (start of `plugin_flush`) resumes `view:wait` waiters through
  `Plugins.answer`, then starts the handler task; close also kills the change/query tasks and
  releases the view. Closing saves field texts and the selected key under `id` (`Editor.pane_saved`).
- `change`: the same flush compares the selected item with `notified`, so moves between flushes
  coalesce; the previous change task is killed.
- `query`: `plugin_views_pump` (in `plugin_pump`, joined to `plugin_busy` and the poll timeout)
  starts it once due, killing the previous task and the foreground `qed.spawn` it waits on
  (`spawn_bg` processes stay with the plugin); it also lands a pending `accept`. Enter defers
  only while the query is due, or running with nothing `set`/`append`ed since it started (`landed`).
- `list.sort`: items stay ordered by key; `append` binary-inserts (shifting the Lua item array too) and
  keeps the selection and scroll on their item once the user moved (`PaneList.moved`).
- List handles: `qed.fs.dirs` records a `PluginList{id, owner, src}` in `Plugins.lists` and returns a
  `{id}` table with the one shared, locked metatable (registry `qed.List`, recognized by identity; its
  `__gc` frees the record by the table's `id`; unload frees the owner's). `list.items = h` copies `src`
  into the pane, so the view outlives the handle; `v:set(items)` unbinds it, `append`/`update` raise. A source list's
  `items_ref` stays empty: activate events clone the selected `PaneItem`s (`UiViewEvent.items`), change
  passes the highlighted one (`PluginStart.pitems`), and the task or `wait` continuation pushes them as
  `{label, path?, detail?}` (`api_pane_item_push`) inside the resume.
`qed.pick/prompt/confirm/pane` are Lua sugar in `src/prelude.lua`, installed into every plugin's
`qed` table by `plugin_qed_push`: `ui.open` + `view:wait()` + `view:close()`; pick/prompt/confirm
open with `kind = "child"` and `modal` (a child of the focused pane or the active overlay, else
exclusive). A child from a task not started by the user (`PluginTask.user`: commands) may only stack
on the caller's own pane, or from a view's `activate` task (`PluginTask.view`) on that view and its children, else
`"busy"`, so a timer cannot steal
focus; an open from such a task also leaves the message line alone. `ctx.view` is only handed to the view's
own plugin. `pane_unload` saves state before marking dead.

A `markdown` body (`qed.ui.open{markdown}`, full only) is rendered by core at the text width into
`Pane.md_lines`, a per-pane `virtual.Arena` swapped in as `context.temp_allocator` for `md_render`;
the cache is keyed on width and dropped by `v:markdown` and `editor_retheme`. `max_width` caps a
center/full box. A text body's scroll is saved by `id` with the field texts. A left click on a
markdown body hit-tests `MdSpan.link`: `#anchor` scrolls to the line whose `MdLine.slug` matches
(GitHub slugs, repeats `-1`, `-2`) unless the view has a `link` handler; anything else goes to `on.link` (queued like the other view
events), so the plugin owns open-file vs `qed.open_url` (`url_opener` in `shell.odin`, detached via a
backgrounded shell; headless only logs). `backdrop` (`dim`/`blank`) is applied in `pane_render`
before the box, to every cell drawn so far except the status rows, so panes below fade too.

Ported: the quit/close/conflict dialogs, the merge-conflict resolve dialog (`conflict` plugin), the command palette, the Message Log, the Plugins pane, the LSP
rename prompt, the working-root picker (`workspace` plugin), line find (`goto` plugin), the file tree (`filetree`
plugin), the AI edit prompt (`ai` plugin) and every plugin pane. Still legacy overlays: terminal, find bar.
**Migration coexistence** (shrinks each M step, gone after the last port): unported panes stay
`Overlay` vtable entries (`editor_overlays`). The stack sits above them: an overlay gets input only
when no pane has focus, and render draws the active overlay, then the stack. A child opened over
a bare overlay records its `active` flag in `Pane.over`; `pane_stack_sync` closes a child whose
overlay closed, and focus and render skip it until then. An exclusive pane does not close an open
overlay.

## Modules

The module system is gone. `ai` and `git` are bundled plugins (`plugins.ai`, `plugins.git`), LSP is the
top-level `lsp` section gated on `LSP_ENABLED` (`LSP:` commands carry `Command.lsp`, `lsp_enabled_sync`
tears servers down after a reload turns it off). Old `modules.ai.*`, `modules.git.*` and `modules.lsp.*`
keys warn "moved to"; any other `modules.*` key warns unknown.

## Plugins

Lua 5.4, vendored in `lib/lua` and built static. Design, API and phases:
[notes/plugins.md](notes/plugins.md). `plugin.odin` owns one `lua_State` per editor,
started at the end of `editor_init`. Invariants the code can't show:
- **No Lua API call outside a pcall.** Any stack building (env, config merge, `ctx`)
  runs in a C trampoline under `plugin_call`; `lua_atpanic` restores the terminal as
  a last resort.
- **The `^Editor` is never stored in Lua.** `plugin_enter` puts it (plus the Odin
  `context`) in the main thread's extraspace for the duration of a call; outside a
  call (`__gc` during unload/close) the `qed` API raises.
- **Ownership:** every registration records its plugin; `plugin_unload` releases the
  refs so the plugin's env is collectable.
- `#load_directory` doesn't recurse: a bundled dir plugin needs its own embed.
- User config is read through `editor_config_user` only (never cached); plugin
  `plugins.<name>` changes refresh `qed.config()` and fire `config_changed` on hot reload.
- A plugin declares its config keys and defaults with `qed.options` in `setup`; core
  knows only `enabled` before that, so unknown-key warnings cover loaded plugins only.
- Bindings live in `plugin_api.odin`. Lua sees 1-based rows and byte cols,
  half-open ranges; only `api_pos`/`api_pos_push` convert. Positions are validated
  (range, UTF-8 boundary) before any primitive runs, and a binding raises only
  before heap allocations (`lua_error` longjmps past Odin frames).
- Buffers are addressed by `Buffer.id`, looked up per call; none are visible on the
  welcome screen. Plugin edits shift the cursor and selection anchor like marks.
- Each plugin edit is its own `.Atomic` undo group. `qed.edit` records `len(b.undo)`,
  cursor and selection before `fn`; afterwards it merges every group added since
  (saves, builtin commands, nested edits included) into one, or on error inverts
  them all and restores cursor + selection, then re-raises. `plugin_msgh` leaves an
  already-tracebacked message alone, so the re-raise logs one traceback.
- Type stubs: `plugins/meta/qed.lua` (embedded, written to
  `$XDG_DATA_HOME/qed/lua/qed.lua` when changed). `lsp_config_lua` answers the `Lua`
  section (Lua 5.4, `workspace.library` = that dir) and joins the post-`initialized` push
  only when the working root is the config dir or below; elsewhere it is `null`. The repo
  root has a `.luarc.json` pointing at `plugins/meta`.
  Unit tests check stub and API against each other.
- **Scheduler** (`plugin_sched.odin`): every command, event handler, timer tick and
  `on_line` call runs on a pooled coroutine (`PluginTask`); `setup` and `when` run
  on the main thread and cannot wait. A waiting binding stores a `PluginWait` on its
  task and ends with `lua_yieldk`; the continuation builds the result inside the
  coroutine, so Odin never pushes onto a suspended thread. A continuation re-yields
  unless `Plugins.current` is its thread, so a Lua `coroutine.resume` of a waiting
  task is a no-op; pooled threads are reused only by the same plugin. Waits refuse
  inside `qed.edit` and in non-task threads. Tasks are found by id after every resume (a
  nested entry can reallocate `tasks`); unload frees suspended tasks and marks
  running ones `doomed`, freed when their resume returns.
- `plugin_pump` (main loop, fast-poll branch and idle timeout) runs due timers and
  sleeps, drains processes, finishes `buf_pre_save` waits, then `plugin_flush`.
  `plugin_busy` (startup due, live processes, pending saves, queued events) joins
  the fast-poll gate; the `peek_event` timeout is clamped to the next deadline.
- Events never run Lua inside core code: call sites `plugin_queue` (a no-op without
  subscribers) and `plugin_flush` drains after `editor_step` (skipped mid-paste) and
  in the pump. `buf_changed`/`cursor_moved` come from comparing `Buffer.plugin_rev`/
  `plugin_cursor` at the top of every flush round (`plugin_buffers_check`, after `plugin_views_flush`), so
  an edit made by a handler or after an awaited dialog fires in the same flush. `buf_changed`'s `lo..hi`
  is the union of rows the primitives touched since the last delivery (`Buffer.plugin_lo/hi`, shifted by
  later edits: rows above are untouched, rows below only shifted); its `typed` is `Buffer.typed_rev == rev`, which
  `editor_dispatch_key` sets when a character, Enter, Backspace or Delete without Ctrl/Alt changed the buffer. Exceptions: `buf_pre_save` runs inside
  `editor_save_full`; a handler that waits parks the save in `Plugins.saves` until
  its tasks end or `plugin_hook_timeout_ms` passes (`editor_save_id` finishes it).
  `quit` runs after the main loop, pumping until done or the same timeout.
- Plugin communication ([notes/panes.md](notes/panes.md) §6): `qed.export` (setup only, once) stores a table of
  functions on `Plugin.exports`; `qed.plugin(id)` (raises during setup) builds a fresh proxy of C closures holding
  owner, load generation (`Plugin.gen`), caller and name, so a call after the owner unloads or reloads raises and
  the proxy keeps nothing alive. A call runs in the caller's task through `lua_pcallk` (yields allowed), with a
  `PluginCall{co, owner, caller}` pushed for `qed.caller()` and popped by the continuation or `plugin_task_free`;
  calls from a plugin's own coroutines are refused, and a message handler keeps the callee's frames in the traceback.
  Unloading the owner kills every task inside one of its calls. Each plugin's qed closures carry `"<id>\0<gen>"` as
  their first upvalue, so `plugin_owner` rejects code from an older load.
  `qed.emit("<own id>:<event>", data)` queues a `.Custom` event (data held as a registry ref) for hooks of that
  name; `plugin_loaded`/`plugin_unloaded` are queued by `plugin_load`/`plugin_unload` after startup and skip their
  subject. Hooks of every kind go with their owner.
- Budgets: one count hook (100k instructions) on the main state, inherited by every
  thread, checks the slice in `Plugins.slice` against `plugin_budget(kind)` (`plugin_command_max_ms` for
  commands, `plugin_slice_max_ms` for events and timers). Past the
  hard limit it yields from the hook when it can (pcall cannot catch that), else
  raises and drops the hook count to 1 until the slice ends; the task is stopped with a warning and the plugin
  stays loaded. A task's own Lua error (or out-of-memory) is logged at Error and the plugin stays loaded too;
  only load and setup errors mark it errored. `plugin_error` rate-limits per plugin (`PluginErrors`): at most
  `PLUGIN_ERRORS_PER_SECOND` entries per window, the rest summarized by the pump as `(N more errors suppressed)`;
  a known message shows `(N times)` and only its first occurrence logs the traceback. The soft limit
  (`PLUGIN_SOFT_MS`, 50) is a Debug line measured after the resume. A nested entry's time is credited back to
  the outer slice. `__close` handlers run by `closethread` get the event budget.
- `qed.lsp.format` sends a core LSP format request tagged with a token and waits
  (`.Lsp`, bounded by `plugin_hook_timeout_ms` → `"timeout"`); `plugin_lsp_done`
  queues the outcome, `plugin_pump` resumes the task. A response nobody waits for
  any more is not applied.
- When a `buf_pre_save` deadline passes, the late handler tasks are killed with
  the `qed.spawn` they wait on (`plugin_task_kill`), so nothing edits after the save.
- Bundled dir plugin files are listed one by one in `bundled_plugin_dir_files`
  (`plugin.odin`) so `test.lua` stays out of the binary; a test fails when a
  `plugins/<dir>/*.lua` is missing from it. The `test.lua` runner reads from disk.
- **UI**: `qed.ui.open` views, events and the prelude sugar are in Panes. A pane records the
  command whose task opened it (`Pane.toggle` from `PluginTask.command`); that command's chord
  closes it like Esc. `ctx.view` is the focused plugin view's table. `qed.ui.open` raises in `setup`.
  Unloading the owner releases its views and their queued events, then marks its panes dead; another
  plugin's child of them resolves `nil` at the next sync and flush (the owner's own waiters are freed).
- `qed.parse_locations` (pure, `plugin_api.odin`) turns `file:row[:col][: msg]`
  lines into pick items with `path`/`pos`. `qed.jump` takes a buffer id or a path,
  takes the jump origin before opening (an origin in the just-opened file would let
  a near-top target overwrite the previous jump-list entry in place), clamps `pos`
  and snaps a col inside a UTF-8 sequence back.
- `qed.theme.set` without `persist` only changes what is shown (`Editor.theme_shown`;
  setting the configured theme clears it). A config reload keeps the shown theme
  while a plugin pane is open, else drops it. Unloading the plugin that set it
  restores the configured theme. `persist` writes the `theme` key, fires
  `theme_changed`, and fails with `nil, err` when the write fails. Headless sessions
  persist to `Plugins.persist_path` (tests).
- Config hot reload (`plugins_config_apply`) runs `plugins_rebind` only after `config_changed` handlers ran (see plugins.md §4 for the full order).
- Hot reload (`plugins_poll` → `plugins_sync`, before the config reload) is keyed on `Plugin.stamp`; details in plugins.md §4.
- Plugin names are interned in `Plugins.names` (freed at shutdown): owners in tasks, pooled threads and queued events point at them.
- A plugin's id (`Plugin.name`) is its file/dir name: config key, keybind namespace and
  owner everywhere in code. `Plugin.display` (id title-cased, or `qed.meta`) labels its
  messages, log lines and Plugins pane row; `plugin_label(owner)` maps an owner to it.
  It survives unload and resets when the next load starts. A plugin `Command` keeps `bare` (the registered name), `name` =
  `<display>: <bare>` (palette, `qed.run`) and `config_name` (the `plugins.<id>.keybinds`
  key: `keybind` or `bare`). `qed.meta` must precede `qed.command`.
- Plugin command visible names are unique per scope (a tree and an editor command may share
  one). `qed.command` returns a handle whose `remove()` unregisters it; removing or
  unloading commands closes the palette, whose rows index `Plugins.commands`.
- Plugin binds come only from `key=` and `plugins.<id>.keybinds`. A keyed command rebinds
  its key-less siblings sharing `config_name` (they may have registered first);
  `plugins_rebind` clears every plugin shortcut, then binds in order. Unknown keybind names
  are checked by `plugins_keybinds_check` at the end of a flush for plugins with `keys_due`
  (set on load and config apply), so `startup` handlers can register first.
- `ctx.selection_text`, `file` and `files` (the focused list's selection)
  are computed on first read through `__index` and cached on the ctx, so `when` stays
  cheap.
- `qed.term` wraps the core sessions (see Terminal pane); a session records its
  creating plugin as owner and unload closes it (after the plugin's tasks are freed)
  unless `detach`. `state.busy` is `tcgetpgrp` of the PTY differing from the session's pid.
  `qed.jump` closes every pane opened with `jump_closes` (the file tree).
- **Decorations** (`deco.odin`): `Buffer.deco` holds plain `Deco` records (ghosts in their own list, with
  per-row above/below counts rebuilt lazily after a ghost or line change, so the walkers stay O(1) per row). `buffer_insert`/`buffer_delete` shift row anchors and drop spans on
  edited rows (rules in plugins.md §3), so a keystroke runs no Lua. Marks (`DecoStore.marks`, `qed.deco.mark`)
  shift by byte position and are removed when an edit overlaps their inside. The inline ghost
  (`DecoStore.inline`, one per buffer) is cleared by any edit (a reload is hunk edits); core renders it while the cursor
  sits on it (`inline_gap` reserves the rows below for its continuation lines) and handles its keys in
  `editor_dispatch_key` before anything else: `Tab` inserts it, `Ctrl+Right` one word (`inline_word_len`),
  any other key or a click drops it, all synchronously. Colors are interned theme keys
  (`Plugins.colors`), resolved into a per-frame palette; a tint or span alpha may be a theme tint key
  (`Deco.tint`, an index into `config_tints`), also resolved per frame. `deco_rows` buckets the visible
  rows once per frame; a blended span (`blend`) paints `color_over(line bg, bg, alpha)`. Namespaces (`Plugins.deco_ns`), status segments (`Plugins.status`) and plugin diff bases
  record their plugin; unload clears them.
- `qed.spawn` runs on `subprocess_spawn` (stderr captured, reaped with a
  non-blocking `process_wait`). The child leads its own process group
  (`subprocess_start_group`, a fork/exec like `os.process_start`) and every kill signals
  the group, so a cancelled shell takes its descendants. Argv and env strings over
  128 KiB raise before forking (Linux `MAX_ARG_STRLEN`). With `on_line`, delivered lines are cut from `out`
  and reads are capped per pump, so a streaming process stays bounded. A
  `spawn_bg` record is freed when its result is handed out by `wait()`, or once
  done after its handle's `__gc` (which only marks it; the pump frees).
  `Plugins.fakes` (`e2e_spawn_fake`) answers a matching command without forking.

## Language detection

Each `Buffer` carries a `language: Language`, set once at open (`language_of`).
File→language is **not hardcoded**: the config `languages` section is keyed by
language name, each entry an object with `patterns` (glob list) and `lsp` (server
command), both user-overridable, per-key merged back like every other knob (formatter
commands live in `plugins.format.commands`). `LANGUAGE_DEFAULTS` (`language.odin`) is compiled-in
wiring only (comment token, lsp id, grammar); default patterns/`lsp`
come from the embedded config's `languages` section. `LANGUAGES` is the working
copy each load resets then overlays. Patterns are `*`-globs matched against the basename, most-specific-first (exact
before glob, longer before shorter); built-in defaults cover extensions plus common
dotfiles (`.bashrc` → shell, …). `lsp_id` and the comment token stay compiled-in.
Everything — highlight, LSP, status bar, comment token — reads `b.language`. The
*Settings: Language* command (bundled `settings` plugin) overrides it for the session (re-parses,
re-opens LSP).

## Multiple servers / grammars

- **Syntax** (`highlight.odin`, `language.odin`): per-language `[Language]Syntax`;
  adding one = vendor `parser.c` (+`scanner.c`) + `highlights.scm` under
  `lib/tree_sitter/<lang>/`, add the FFI decl + `build.sh` line, fill the
  `LANGUAGE_DEFAULTS` row (grammar/comment/lsp id) + patterns/lsp in
  `config/config.json` (+ an optional formatter in `plugins/format`'s `qed.options`). Queries are vendored **upstream-verbatim**: a predicate
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
  at its first placeholder. `Enter` accepts — replacing the whole current word and applying any
  `additionalTextEdits` (auto-import) in the same undo group (`Tab` is reserved for the inline ghost,
  which coexists with the popup); `Esc`/movement/non-word input dismisses.
  Formatting (`qed.lsp.format`) carries the buffer `rev` so a stale result (doc
  changed mid-request) is dropped; the response, a server error or a server stop
  resumes the waiting plugin task through `plugin_lsp_done`. *Rename* (`rename.odin`, `Alt+r`)
  prompts in a center input pane, then applies the server's WorkspaceEdit
  (`changes`/`documentChanges`) across every file — loading unopened ones as modified
  buffers (`editor_load_buffer`) — as one cross-buffer undo transaction. `initialize`
  advertises `workspaceFolders` + `workspace.configuration` (both needed for
  servers to do workspace-wide rename/refs); `didSave` **must** carry the document
  `text` (ols re-indexes from it — omitting it drops the file's symbols). pyright's
  open-files-only default is flipped via `LSP_DIAGNOSTIC_MODE` answered on the config
  pull + pushed on `didChangeConfiguration`.
- **Formatting** is the bundled `format` plugin (`plugins/format/`). Its `buf_pre_save`
  handler runs the save fixups (trim trailing whitespace, markdown hard breaks kept;
  final newline; one `qed.edit` step) and then, with format-on-save on, formats.
  *Format: Document* / format-on-save prefer `plugins.format.commands.<language>`
  (e.g. Python → `ruff format …`) over `qed.lsp.format`. The command is a
  stdin→stdout filter via `qed.spawn` (`sh -c`, stderr captured, never shown), cwd =
  the file's dir (path-less → root), `{file}` → the shell-quoted absolute path
  (path-less → `<root>/untitled`). The result lands through `qed.buf.set_text`
  with the pre-spawn rev: a minimal line diff (`buffer_set_text`, `diff_myers` over
  line hashes) as one undo step, cursor and selection mapped onto their lines. A
  missing tool (exit 127) / non-zero exit / empty output messages and leaves the
  buffer untouched; on save it saves unformatted. A format-on-save that waits parks
  the save, bounded by `plugin_hook_timeout_ms`. The `format_on_save` /
  `trim_trailing_whitespace_on_save` / `ensure_final_newline_on_save` knobs seed
  the plugin's toggles; on `config_changed` only knobs whose config value changed
  are re-applied, so runtime toggles survive unrelated edits.

## Markdown rendering

`md_render(src, width, lang) -> []MdLine` (`mdrender.odin`) backs LSP hover and the `markdown`
pane body. Hand-rolled, not tree-sitter: the grammar splits block and inline trees, and inline
content inside quotes and lists is discontiguous (included-range reparses per paragraph), while a
line-based container parser handles nesting directly. `md_parse` builds blocks (paragraph with
soft/hard breaks, ATX/setext heading, fenced/indented code, rule, quote, list with loose/task
items, GFM table, HTML block, link reference definitions), recursing into quote and item bodies
with their prefix stripped. `md_blocks` emits through a prefix stack (quote bar, bullet or number
then hanging indent), so text wraps at the remaining width. Every marker is hidden. Colors come
from the markdown `captures` (`text.title`, `text.literal`, `text.reference`,
`punctuation.special`), so the preview matches the editor; strong/emphasis/strike are attributes
on the run color (`text.strong` is `foreground bold`, so bold never reads as a heading). H1 gets a
`━` rule in the heading color, H2 a `─` rule. Code (blocks and inline) sits on a band: tint
`markdown_code` of the pane selection color over the pane background, filled to the right edge
via `MdLine.fill`; blocks are highlighted by `highlight_lines` and char-wrapped. Links show their
text underlined plus `[n]` (both carry the target), each URL listed once as a footnote at the end (anchors and autolinks
get none). Images and `<img>` show `[image: alt]`; other HTML tags drop (`br` and block closers
break lines; only real tag names count, so `Vec<T>` stays text). Plaintext hovers go through
`md_escape_plain` (punctuation escaped, hard breaks, indent as no-break spaces); a MarkedString
`{language, value}` becomes a fenced block. Front matter renders as a yaml code block. Containers
nest at most `MD_MAX_NEST` deep (deeper markers are text), inline scans stop after `MD_SCAN_MAX`
bytes, prefixes beyond half the width are hidden and every line is cut to the width, so hostile
input stays linear and in bounds. Inline code falls back to the pane foreground when the theme's
code color has under 3:1 contrast on the band. Tables fit columns to content, keep whole words when every column's longest word
fits, share the rest evenly and wrap cells; below 3 columns per cell, rows become `header: value`
lines.

## AI plugin

`plugins/ai` (`plugins.ai`). *AI: Edit Selection* (`Ctrl+k`): with a selection, `qed.prompt` takes an
instruction; the whole buffer, the selection wrapped in `<<<SELECT…SELECT>>>`, goes through the
`edit_prompt` template to `chat_command` (default `claude -p`) on stdin via `qed.spawn_bg`. Requests run
concurrently, each tracked by a `qed.deco.mark` over its range and tinted (`ai_edit_background`, theme tint
`ai_edit`) while in flight, with an `AI:N` status segment. The mark is set before the prompt and re-read
after it, so a buffer change elsewhere under the prompt (another edit landing) keeps the request. An edit
inside the range cancels the request (`buf_changed`, kills the process), as does a reload that touches it
(`file reloaded`) or closing the buffer; edits elsewhere move the mark. A non-zero exit is discarded
(`Command failed (exit N)`). The reply's last fenced block replaces
the marked range as one `qed.edit` step with the selection's whitespace framing reattached and the cursor
and selection kept on the new text. *AI: Cancel Edits* kills them all. Prompt and response are logged at
Debug.

Inline completion (`completion_enabled`, *AI: Toggle Inline Completion*): a `buf_changed` with `typed`
arms a `qed.defer(completion_debounce_ms)` timer (each typed change kills the pending timer and request);
it is dropped when the cursor or rev moved by the time it fires (a click during the debounce), and never
armed on a big buffer (`qed.buf.big`). The request is `curl` through `qed.spawn_bg` to a FIM endpoint
(default Codestral), prefix and suffix clamped to `completion_context_lines` and 64 KB each; the
`Authorization` header reaches curl as `-H @/dev/fd/3` from a here-doc expanding
`$completion_api_key_env` (validated as a variable name), never through argv.
**External quirk:** the body goes on curl's stdin (`--data-binary @-`); the spawn unlinks its temp at once,
so a lazily opened `@file` would race to an empty body. A
reply for the same buffer, rev and cursor becomes `qed.deco.inline` text; Lua never sees the keys that
accept or dismiss it. The plugin subscribes to `buf_changed` only while a request runs or completion is on.
The ghost and the LSP completion popup coexist: `Tab` takes the ghost (and closes the popup), `Enter` the
menu, and a multi-line ghost floats the popup above the caret (`completion_render`). See
[notes/ai.md](notes/ai.md).

## Terminal pane

*Floating embedded terminal* (`terminal.odin`, `Alt+t`): named sessions
(`Terminals.list` of heap `^Terminal`, stable for the vterm callbacks' `user`
pointer), one of them `shown` in an overlay sized by `overlay_layout` (like
project-search). `Alt+t` toggles the default `"shell"` session (an interactive
`$SHELL -i`), starting or restarting it when needed; plugins add background
sessions (`/bin/sh -c cmd`, own cwd/env) through `qed.term`. A session's shell + PTY + emulator outlive pane open/close; a non-default
session shows its name (and exit code) in the top border. The emulator is
**vendored libvterm** (`lib:vterm`), fed PTY bytes; the PTY itself is a `forkpty`
shim (`lib:pty`, `-lutil`, argv + an envp built in the parent with
`TERM=xterm-256color`), the one OS-specific piece; the master fd is non-blocking and
close-on-exec. The child is a session leader, so its pid is its process group:
`term_stop` (the single kill path for kill/restart/close/unload/shutdown) SIGKILLs the
PTY's foreground job group, then the session group, and reaps for up to 200 ms; a
child still unreaped is parked in `Terminals.zombies` for `term_pump`. Writes to the
PTY never spin: what the program does not read waits in `Terminal.pending` (flushed
by `term_pump`, capped at 1 MiB, overflow dropped with a warning).
`term_pump` (main loop, next to `lsp_pump`) drains every live session's PTY
(non-blocking `read` → `vterm_input_write`) whether shown or not, then reaps with
`waitpid(WNOHANG)`; a reaped child marks the session exited (code, 128 + signal when
killed) and queues `term_exit` (`term_open`/`term_close` on spawn and close). The loop's fast-poll gate carries `term_alive` (any
live session) so a hidden session never blocks on a full PTY. Only the shown
session renders and takes keys, mouse and paste. Hidden sessions keep their size
until shown (created at the overlay size, 80x24 headless). `term_render` walks
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
`confirm` (quit/close/conflict dialogs, `dialog_pane`) · `pane` (Pane model + stack, box drawing) · `log` (message ring + disk log + *Debug: Message Log* pane) · `subprocess` (shared async one-shot subprocess: spawn-with-stdin-body / non-blocking drain / cancel) · `wrap` (soft-wrap layout) · `textfield` (shared single-line editable field) · `overlay` (shared fuzzy-list widget state) · `preview` (shared scrollable highlighted preview / diff) · `palette` · `walk` (walk service, tree lists, `qed.fs` writes) · `treeshim` (temporary provider shim, M6 removes it) · `fuzzy` ·
`listsrc` (pane list sources, `path` field) · `find` (in-buffer find/replace) · `jump` · `highlight` · `predicate` (query predicate evaluator) · `inspect` (*Debug: Inspect Tokens* pane) · `language` · `lsp` · `mdrender` (markdown → styled terminal lines, hover popup) · `completion` · `rename` ·
`diffbase` (diff engine, ghost rows, revert) · `deco` (plugin decorations, marks, the inline ghost) · `terminal` · `plugin` (Lua state, loader, hot reload, *Debug: Plugins* pane) · `plugin_api` (`qed` bindings, type stub) · `plugin_sched` (coroutines, events, timers, processes, budgets) · `plugin_ui` (`qed.ui.open` views and events, `qed.theme`, `qed.status`) · `prelude.lua` (`qed.pick`/`prompt`/`confirm`/`pane` sugar) · `perf_bench`.
Vendored C under `lib/`: `tb2` (termbox2), `tree_sitter`, `vterm` (libvterm), `pty` (forkpty shim), `lua` (Lua 5.4).
Bundled Lua plugins live in `plugins/` at the repo root (`ai/`: *Edit Selection*, *Cancel Edits*, inline completion; `filetree/`: the file tree; `format/`: save fixups + formatting; `settings/`: *Settings: Theme*, *Language*, *Indentation*; `search/`: *Find in Files* in the editor and the tree; `workspace/`: *Open Directory* and the tree's *Open Selected Directory*; `goto/`: *Line*; `git/`: diff base fetch, stat poll, file tree status provider, *Git: Set Diff Base*, *Git: Restore File*; `markdown/`: *Markdown: Preview* with scoped *Back*/*Forward*; `conflict/`: merge-conflict highlight, *Conflict: Resolve*).
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
formatter / chat command / FIM endpoint), a fake stdio LSP server (canned
JSON-RPC, in `e2e_lsp_test.odin`), and `e2e_plugin(name, src)` / `e2e_spawn_fake` /
`e2e_plugin_config` (injects a user plugin / fakes a `qed.spawn` / overrides a
plugin's config and reloads it). Each bundled `plugins/<name>/test.lua` returns a
table of test functions (`src/term_test.lua` does the same for `qed.term`); `e2e_plugins_test.odin` runs each in a fresh session with a
`t` API (`key`, `type`, `step`, `wait`, `expect_line`, `expect_cell`, `eq`, `ok`,
`fake_spawn`, `config`, `open`, `stub`, `message`, `log_has`, `editor`,
`poll_disk`, `pump`, `hook_timeout`, `lsp`, `bg` (rendered cell background), `ui` (focused plugin view: kind pick/prompt/confirm/pane, query, matches, labels, selected, hint), `config_path` (where `persist` writes)), with the root at the session's temp dir; the session theme and the clipboard register are restored afterwards; a Lua error or a plugin error fails the test with its traceback. Plugin bindings are unit-tested on a headless state in
`plugin_test.odin` (loader) and `plugin_api_test.odin` (bindings). Coverage is one file per area:
`e2e_edit/files/nav/lang/ai/mouse/lsp/narrow/pane/plugin_ui/ui_open/list/scope/workspace/walk_test.odin` (`ai`: the inline ghost and the LSP popup together); scope + assertion surfaces:
[notes/e2e.md](notes/e2e.md).
The headless e2e suite stays the main net. To smoke-test a visible change on the real binary,
`tools/tmux-qed.sh` (`start` / `keys` / `capture [--color]` / `stop`) runs `./qed` in a detached
tmux session with an isolated HOME; run `tools/tmux-qed.sh` bare for usage.

## Shipped

Core editing: buffer open/save (atomic, permission-preserving, LF/CRLF +
final-newline preserving; external-change auto-reload + dirty-buffer save clobber guard;
optional save fixups in the `format` plugin — `plugins.format.trim_trailing_whitespace_on_save` /
`ensure_final_newline_on_save` knobs + runtime *Toggle …* commands, markdown two-space hard breaks survive trimming,
one undo group, run before format-on-save; quit/close/conflict saves run the same
full fixups+format pipeline, quit deferring until a parked save lands),
insert/delete primitives + grouped undo/redo, bracket/colon-aware auto-indent
(Enter indents after an opener / Python `:`, splits a matched `{}` pair, closing
bracket re-aligns to its opener), selection +
selection-aware editing, block indent/dedent, tab-stop backspace (deletes a full
indent in leading whitespace), clipboard (external + fallback; empty-selection `Ctrl+C`/`Ctrl+X` copy/cut the whole line),
full Unicode (grapheme + display width), tab-char display + per-buffer
tabs/spaces + indent-width detect (`Settings: Indentation`, `settings` plugin: Auto-detect /
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
drag auto-scroll), status + message line (relative path, git branch + ahead/behind + diff size, segment icons;
narrow-width fitting), narrow-width panes (preview hides below the list/preview minimums),
structured message log (level/source-tagged ring + disk log at `~/.local/state/qed/qed.log`,
level-coloured line, local-time stamps, *Debug: Message Log* pane `Alt+l` — per-level
filters, multi-select copy, cross-session history seeded from the disk log behind
an `h` chip (off by default); toggles are rebindable scoped commands with clickable chips, works on welcome), welcome-screen status bar (root + branch + version + message line),
rebind-aware pane self-close chords (`command_matches`), Debug-level internals
instrumentation (startup context, subprocess/AI/FIM/save/config/clipboard/terminal trails,
LSP request/response/diagnostics, completion counts, git branch + scan, disk reload/conflict —
full AI prompt/response bodies logged at Debug, no env-var dumps), welcome screen, quit guard across
modified buffers, pane model + stack (`qed.ui.open` plugin panes: center/full/split, filter/query/input/path fields, streaming lists, accessor-backed core list handles (`qed.fs.dirs`, `qed.buf.line_list`), pane-scoped commands with a scoped Ctrl+P, footer chips, queued events, exclusive panes persisted by `id`; pick/prompt/confirm stack over open panes, safety dialogs on top; tabs, marks, footer input and tree lists over `qed.fs.walk` handles; `qed.fs.copy/rename/remove/mkdir`), command palette (a core pane over the commands source; context-filtered via
`command_available`: welcome lists only the working whitelist, big-file buffers
hide the LSP/inspect commands),
multiple buffers, close buffer (buffer switching folded into the file-tree **Open** tab —
`Alt+o`, fuzzy + `Enter` switches, in-memory preview centered on the cursor, `Ctrl+W`
batch-closes the selection, silent for clean buffers and behind a `Close N buffers? (M unsaved)`
confirm when any are unsaved; standalone switcher removed), find/replace in buffer (`Ctrl+F` find, `Ctrl+H` replace — floating top-right bar,
literal or regex `.*` toggle, smart-case `Aa` toggle, all matches highlighted +
current shown as selection, `Enter`/arrows next/prev with wrap, `Alt+a` replace-all,
single-line/per-line), fuzzy line jump (`goto` plugin, *Go To: Line* `Ctrl+G`, filter over the list column,
matches in file order; a `:N`/`:N:C` query is an exact line/column jump instead), project-wide search (`search` plugin: a `qed.ui.open` query pane, **debounced** parallel `rg --line-buffered` streamed into a key-sorted list as lines arrive, query and selection persisted by `id`, `plugins.search.min_query`;
whole-project via `Alt+F`, or scoped to a file-tree selection via the tree's `Alt+F`; file-tree-style
layout: left-half search box, full-height preview, match count (`N`, or `500+` when capped) by the divider),
file tree (`filetree` plugin, see File tree: `Alt+f`/`Alt+o`/`Alt+u` open it on the All/Open/Unsaved tab and
the `git` plugin's `Alt+g` on its Git tab, also on welcome; Enter opens a file or toggles a dir; type-to-filter over the walk (debounced
`WALK_FILTER_DEBOUNCE_MS`, ranked, capped at `WALK_FILTER_MAX_RESULTS` with `N+`, narrowing the previous hits);
New/Rename/Delete/Copy/Cut/Paste/Close Buffers/Select All over a `Shift+↑↓` range (a dir stands for its selected
rows; `(copy N)` names; dangling symlinks count as taken; failures name the reason), batch open, scoped `Ctrl+P`,
`Alt+F` search in the selection as a child; chips for ignored/dotfiles (All) and diff (previewing tabs), `Alt+e`
expand/collapse all; git bars propagated to dirs, ignored rows dimmed, deleted files listed virtually with
Enter restoring them, renames as `new  ← old`, `+N -N` on Git; open buffers accented,
unsaved `●`),
floating terminal pane (`Alt+t`: persistent embedded shell via
vendored libvterm + PTY, full-TUI capable, qed-palette colors, mouse forwarded to the
guest + wheel scrollback, drag-select auto-copy + host bracketed-paste, `Esc` closes at
the shell prompt), runtime working-root change (`workspace` plugin: `Ctrl+o` path picker + file-tree
`Ctrl+o` on a dir), jump list
(back/forward), runtime config (**sparse overlays**: embedded `config/config.json`
is every default, none in Odin source, completeness test-enforced; user
`~/.config/qed/config.json` is a per-key diff qed never writes — no
materialization, unknown keys get a one-shot warning, malformed JSON falls back
to defaults without crashing; UI persistence like the theme picker's Enter writes
only its own key; both config + active theme hot-reload via the disk poll —
colors/keybinds/knobs apply live, runtime toggles
survive, terminal palette re-pushed; existing buffers keep their language, running LSPs
their command), `lsp.enabled` (live toggle-off tears servers down; git is
`plugins.git`, auto-off when the binary is absent; AI is `plugins.ai`), JSON themes (sparse overlay chain over the embedded `default.json`
base, see Rendering; *Settings: Theme* fuzzy picker with instant preview,
Enter persists / Esc reverts), selection pre-fill (a single-line selection
pre-populates Find / Replace / Project Search / Line Jump, fully selected so
typing replaces; multi-line/whitespace selections keep each pane's persisted
query). Every floating pane is
mouse-driven (wheel scroll, click-select, double-click activate, caret/drag-select in
prompt fields, click-away dismiss) and draws a scrollbar thumb
(`pane_draw_scrollbar`, on the divider or right border) when its list overflows.
Preview panes (file-tree, project-search, line jump) share one
scrollable, syntax-highlighted `Preview` component (`preview.odin`): the cursor/focus line
carries the gray selection background band (`COLOR_PANE_SEL_BG`) with its syntax colors kept;
wheel-scrollable while
the pointer is over the right pane, soft-wrapping long lines (word-boundary via `line_wrap`,
blank continuation gutter, tab-aware — always on, no horizontal scroll; the scroll clamp
`preview_max_scroll` is wrap-aware so a wrapped tail stays reachable, cached on
width/height/total). Rows are built once on load, capped at `PREVIEW_MAX_LINES` and the file read at `PREVIEW_MAX_BYTES` (4MB); under
`HIGHLIGHT_ASYNC_BYTES` the whole source is highlighted once, above it only the visible window
± `PREVIEW_PARSE_AHEAD`, re-highlighted when scrolling leaves the colored range. File source is
read in-process up to the line cap; buffer source (file-tree open buffers / line jump) previews in-memory content. A file with a NUL
byte in its head renders as a hexdump-style view (offset + hex + ASCII, unwrapped
rows); an empty file/buffer renders a dim `PREVIEW_EMPTY_TEXT` placeholder —
both in every consumer. (`os.read` quirk: EOF arrives as `io.Error.EOF`, not a
nil error with 0 bytes.) A file-tree tab with a `preview` callback (the Git tab)
previews a diff instead: changed hunks + `preview_diff_context` lines of context in the
inline-diff-view style (dim-red ghost rows, added/modified tint, word-level highlight),
built by `preview_diff_file` (the callback's base text vs the file on disk, reusing the gutter's
line-hash diff; a deleted file previews entirely as ghost rows; a `nil` base previews the file plainly).
*File Tree: Toggle Diff* (`Alt+d`, a session flag of the `filetree` plugin seeded from config
`filetree_diff_only`, default on) switches between this collapsed view and the
whole file with the same diff annotations (`preview_set_diff`'s `diff_only`: off → every row visible,
gap-collapsing never fires).
Preview loading is **debounced** (`WALK_PREVIEW_DEBOUNCE_MS`) for walk lists: a selection change arms
`Pane.preview_due` and `pane_stack_pump` loads once it settles, so a held arrow can't back up the input queue
or flood the tab's plugin with base requests.

**Walk service** (`walk.odin`): `Walk{root, dotfiles, ignored}` records in `Editor.walks`, shared by equal
options and refcounted by list sources (`walk_gc` frees unreferenced ones once their prewarm landed); the candidate
set comes from the parallel `readdir` walk (`walk_run`) or a background prewarm (ignore-set snapshot, adopted only
if `Walk.gen` did not move meanwhile). Each root has one ignore set (`walk_ignore_set`, fed by `h:ignore`; `false`
marks it not known yet, which holds the prewarm and `v:expand(true)` back; only a changed set restales). A `qed.fs`
write (`fs_*`, `qed.fs.write`) restales only the walks whose root can contain the path (`walk_invalidate`); a
`qed.fs.walk` call restales just that walk. A stale walk keeps serving its old candidates while the prewarm reruns
it; only a first walk with nothing to serve runs on the main thread. Restaling and adopting bump `Walk.gen`, the list
stamp, so open walk lists refill keeping the selected and anchor paths. `within(paths)`/`union(paths)` narrow
through a refcounted `WalkScope` (listed paths keep their descendants and skip the dotfiles/ignored rules; virtual
paths and their missing parents are injected when absent). A scope copies its paths into one buffer and keys its
listed and ancestor sets by slices of it; `union` points at its base scope instead of copying it. A narrowed tree's
dir rows (`posix` readdir, sorted, filtered) are cached on the scope until the walk restales, so a refill is a
copy; entry paths and pane mark keys live in arenas. `h:release()` frees a handle before collection. `list_walk_fill` builds the rows: lazy per-dir `readdir`
for the browsable tree, or under a filter a ranked, capped (`list.max`, 500) path list that narrows the previous
hits as the query grows. `qed.fs.copy/rename/remove/mkdir` (`fs_*`) refuse an existing target, a target inside the
source (`into itself`), special files (fifos, sockets, devices; skipped inside a copied dir) and removing the root or
an ancestor; they never follow symlinks (copied as links), stream file data through a fixed buffer, fall back to
copy + remove only on `EXDEV` (keeping mtimes; a failed remove drops the copy and fails) and repath buffers.

**File tree** (`plugins/filetree`, D1: not in the works-without-Lua set): a `split:tree` view (`id = "filetree"`,
scope `filetree`, `toggle = false`, `jump_closes`) over a `qed.fs.walk` handle made at each open and toggle. Tabs are
`within` handles (Open, Unsaved: buffer paths; an added tab: its `paths` plus `union` of its `virtual` ones); each
tab's `cmd` is an editor command (*File Tree: All/Open/Unsaved*, *Git: Changes*), so a chord switches tabs and the
active tab's closes. Other plugins reach the tree only through its exports (`qed.plugin("filetree")`): `set_tab{label,
paths, virtual?, cmd?, detail?, preview?, missing?}` adds or replaces the caller's tab (between Open and Unsaved; the
same `paths`/`virtual` tables keep the cached narrowed handle), `remove_tab(label)`, `set_marks(marks)` (shown on every
tab; several callers merge, later id wins per path), `set_ignored(paths|false)` (fed to the walks' ignore set; `false`
holds the prewarm) and `open(label)` (the whole open, narrowed fill included, runs in the caller's task). All of it is keyed by `qed.caller()` and dropped on `plugin_unloaded`; an export
stores and defers one `sync` (`qed.defer(0)`), which updates the tab row in place (`v:tab(i, tabs)`), source, marks
and preview. Marks go out with `v:marks` (suffix and sizes only on a `detail` tab), chips with `v:footer`, New:/Rename:
as the footer input, delete and close confirms as `qed.confirm` children with their targets taken before the
dialog; a tab with `preview` turns the auto preview off and calls it (pcall, in the tree's task) per item after an
80 ms sleep in `change` (a newer change kills it, so a held arrow asks once; `change` is set only on that tab). Enter
on a listed path missing on disk calls the tab's `missing`. File operations emit `filetree:refresh`. Tree
commands take the binds of the core *Copy*/*Cut*/*Paste*/*Close Buffer*/*Select All* through `bind_from`
(`plugin_command_bind` reads the core command at every rebind). A status push is compared with the last one and
marks are pushed in chunks with `qed.sleep(0)` between, narrowed handles are cached per tab and released when
replaced, and a tab switch only flips `v:marks{detail}`. A root change reopens the view, back to each tab's default
expansion.

**Git tab** (`plugins/git`): at `startup` and on `plugin_loaded("filetree")` git takes the tree's exports and
publishes its last scan: `set_tab{label = "Git", cmd = "Git: Changes", paths, virtual = deleted, detail, preview =
blob at the base, missing = restore}`, `set_marks` (bars propagated up the dirs with a deleted file shown as modified
above it, deleted fg, rename suffix, sizes, dim ignored) and `set_ignored` (`false` until the first scan). A scan
runs on `filetree:refresh`, a root change, a base move, *Set Diff Base* and a restore; it is compared with the last
one and a scan that only moved sizes or marks keeps the path tables, so the tree keeps its narrowed handle.
*Git: Changes* (`Alt+g`) opens the tree on the tab and hides without the tree. Without `filetree` git still does
gutters, status segments and *Set Diff Base*; without git the tree has no Git tab and no ignore set.
The `git` plugin's scan (`tree.lua`) sleeps every 2000 parsed lines (`repo.each`) so no slice nears the
budget, parses and drops each command's output before the next, caps the list at `tree.MAX` (50000) paths with a
warning, and a new request kills the running scan's spawn and reruns once.

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
rendered-markdown hover (`mdrender.odin`, see Markdown rendering; popup wheel-scrolls while
hovered, `contentFormat` advertises markdown first), markdown preview (`markdown` plugin,
*Markdown: Preview* `Alt+p` in markdown buffers: a `full` pane capped at
`plugins.markdown.max_width`, live on `buf_changed`, scroll kept and restored per buffer, *Markdown: Back*/*Forward* over anchor and file-link history),
workspace-wide rename (`Alt+r`, cross-file as modified buffers, single cross-buffer undo),
auto-triggered completion dropdown (as-you-type + trigger chars, debounced, client-side
incremental filter, `Tab` accept, `additionalTextEdits` auto-import),
document formatting (`format` plugin: external command e.g. `ruff format -`, else LSP) + format-on-save
(config `plugins.format.format_on_save`, toggleable), `LSP: Restart`, state-colored status segment
(dim `…` starting / plain ready / red `✗` failed) + server stderr piped into the
`.Debug` message log; diff gutter against any diff base (the `git` plugin's: live vs `HEAD` or a session diff base, *Git: Set Diff Base*: merge base / branch / commit, `±label` status segment)
+ optional inline diff view (`Diff: Toggle Diff View`, config `diff_view`): row
tint plus dim-red ghost rows for removed/replaced lines with word-level change highlight;
hunk navigation (`Diff: Next/Previous Change`, `Alt+'`/`Alt+;`, `diffbase_goto`): jumps the cursor,
centered, to the first line of the next/previous changed block off the gutter marks, no wrap;
hunk revert (`Diff: Revert Hunk`, `Alt+z`, `diffbase_revert`): restores the base lines for the
hunk(s) the cursor/selection touches (whole-hunk atomic, buffer-vs-base) as one undo group;
merge-conflict highlighting (`conflict` plugin: ours green / theirs blue / diff3 base gray, marker lines
emphasized, ours↔theirs word-level diff on both sides) + resolve (*Conflict: Resolve*, `Alt+m`: keep ours /
theirs / both, or jump to next conflict).

AI assist (`ai` plugin, `plugins.ai`): selection + prompt (`Ctrl+k`) via a configurable chat command
(default `claude -p`): whole-file context, concurrent cancellable requests tracked by range marks and
tinted while in flight, fenced-block extraction, one undo step with whitespace framing preserved. Inline FIM
completion: debounced suggestions on typing from a FIM endpoint (default Codestral via `curl`), shown as the
core inline ghost (multi-line push-down, `Tab` all / `Ctrl+Right` a word, any other key/edit/click
dismisses), coexisting with the LSP popup; `completion_enabled` + *AI: Toggle Inline Completion*.

User commands are `qed.command` calls in a user plugin; `qed.parse_locations` turns
compiler/grep output into `qed.pick` items for a list + preview picker.

Lua plugins (bundled + `~/.config/qed/plugins/`): decorations (`qed.deco` gutter marks, tints, ghost
rows, spans, end-of-line text, range marks, the inline ghost), status segments (`qed.status`, multi-color chunks), diff base (`qed.buf.set_base`), plugin exports (`qed.export`/`qed.plugin`/`qed.caller`), namespaced custom events (`qed.emit`) and `plugin_loaded`/`plugin_unloaded` (the `git` plugin adds the file tree's Git tab through them); hot reload on file add/remove/edit
and `enabled` flips; *Debug: Plugins* pane with enable/disable (persisted), reload,
per-plugin log, and source view (bundled read-only); `qed.meta` display names prefixing
commands and labeling messages; per-plugin keybinds (`plugins.<id>.keybinds`); Lua
completion settings when the root is under the config dir.

Performance: incremental + async tree-sitter parse, viewport-scoped highlight
query, incremental LSP `didChange`, big-file cutoff, in-process fuzzy ranking,
async + debounced project search, parallel `readdir` file-tree walk (`d_type`, no
per-entry stat) prewarmed on a background thread. See [notes/perf.md](notes/perf.md).

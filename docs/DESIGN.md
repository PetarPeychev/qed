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

**External-quirk invariant:** `cluster_width` (`cursor.odin`) calls termbox2's
`tb_cluster_width` (made public by a local patch), the value `present()` advances
by, so qed's columns and termbox's cells agree by construction. A non-emoji
cluster is the sum of its codepoint widths, as tmux draws Devanagari vowel signs
and conjuncts; emoji sequences are 2. Multi-rune clusters render via
`tb_set_cell` + `tb_extend_cell` (EGC mode, enabled in `build.sh`). Where a
terminal still disagrees (tmux draws a ZWJ family 4 wide) the glyph may clip, but
the patched `present()` never leaves stale cells (`lib/tb2/PATCHES.md`).

## Rendering

Full redraw per event; termbox flushes only changed cells. Each loop iteration:
poll → dispatch → redraw (text, status bar, overlays) → set hardware cursor →
`present()` → `free_all(context.temp_allocator)`.
While termbox is up, fd 2 points at `$XDG_STATE_HOME/qed/crash.log` (so Odin panic, assert and bounds messages,
and stray child stderr, don't vanish with the alt screen), and `crash_restore` (SIGSEGV/BUS/FPE/ILL/TRAP/ABRT,
async-signal-safe) restores the saved termios and modes, writes one line naming that file to the original fd 2,
then re-raises; shutdown and the Lua panic handler put fd 2 back first.

**Soft wrap** (`wrap.odin`, session-global `g_line_wrap` seeded and hot-reloaded from config `line_wrap`, default
on; *Toggle Line Wrap* flips it for every view, never written to config; each editor view resolves its own wrap:
the node's `wrap`, else off for a one-row field, else the global): a logical line spills over
consecutive visual rows, breaking at word boundaries (a word wider than the width
hard-breaks), tab/grapheme-width aware. Continuation rows get a blank gutter.
`line_wrap` yields per-line segment start offsets (buffer lines go through
`buffer_line_wrap`, which memoizes the last few lines ≥ 4 KB keyed on buffer id, rev,
row, width and tab width); `vpos_*` walk/measure visual
rows (bounded by the viewport). The render loop iterates visual rows; the row
renderer draws a byte range `[col_start,col_end)` at an `x_origin`. The inline
ghost (`qed.deco.inline`) on the cursor line renders through the same wrap layout
(`editor_render_ghost_line`) so ghost + relocated suffix wrap too.

Layout (the `layout` plugin's `base` mount), top to bottom: a row of the main `editor` node with a left gutter and the
`editor_side` outlet (empty, it takes no space; a side mount gets a `pane_border` rule), then a
1-row **status bar**, the core `status` node (`ui.status{}`, `status_render`): one mechanism for core segments and
every plugin's `qed.status.set` segment (pane chrome colors; icon-prefixed segments, `ICON_STATUS_*` in config: working-root-relative
path + `●` modified flag + `line/total` + `early` plugin segments (the `git` plugin's branch, `↑ahead↓behind`, `±label`
diff base and diff size) + `±label` of another plugin's base on the current buffer (its `set_base` label) + `[n/m]` + other
plugin segments; right side: language + LSP + indent style / `big`). Both sides are
`StatusSeg` lists fitted by `status_fit` (pure, unit-tested) to keep a 1-col gap (plugin right segments sit before the builtins): shorten the path from
the left (`…/dir/name`, down to the bare name), then drop segments by `drop` rank (indent, LSP, `big`,
language, then diff size, ahead/behind, diff base, branch, `[n/m]`), then clip the filename; then a
1-row **message line** (the layout's text node, fed by the `message` event). Gutter = mark column
(git diff) + line numbers, width = digit count + padding, folded into every
screen↔buffer column mapping (cursor placement, mouse).

Line backgrounds are **alpha-composited** tints (`editor_line_bg` + `color_over`),
stacked bottom→top: optional git-hunk row tint → plugin decoration tints (push order;
the `conflict` and `ai` plugins' included) → current-line tint (a semi-transparent white lift over whatever's beneath). Tint strengths
(`*_TINT`) and tint colors are both theme-overridable. The
row tint is part of **diff view** (*Git: Toggle Diff View*, config
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
*Git: Restore Hunk*;
cursor *motion* is unaffected (it walks real rows via `cursor_visual_*`). All ghost math
no-ops when `g_diff_view` is off, so the viewport behaves exactly as before.

**Git diff base** (`plugins/git`, session-only): the "old" side of every git surface, picked by
*Git: Set Diff Base* (`qed.pick`: HEAD, merge base with the default branch, local + remote refs,
last 50 commits, the session's checkpoint). Branch and merge-base picks are live refs, re-resolved per fetch (falls back to
HEAD in a repo where the ref doesn't resolve); commit picks are a fixed sha. The base lives only in
the plugin, which also feeds the file tree's Git tab (see Git tab): with a base,
each repo's `diff --name-status <base>` replaces its tracked `status` lines. A working-root change
resets the base and drops the checkpoint. The plugin's 2 s stat poll also resolves the base sha; when it changes (a moved
branch, or HEAD under the default base) it refetches every buffer's base and rescans the tree.
*Git: Checkpoint* (unbound) snapshots the root's repo, tracked and untracked minus ignored, into a tree object
through a copy of the index in `$TMPDIR` (`add -A`, `write-tree`; HEAD and the real index untouched) and makes it
the base. That temp index is kept as the checkpoint's index: the scan and diff size run with `GIT_INDEX_FILE` on it,
so a file untracked now but in the checkpoint diffs as tracked and a file new since it shows as `??`. *Accept File*
(Git tab) writes a new tree from a copy of that index with the path re-added (`add -A -- path`, deletions too); *Accept All*
takes a fresh checkpoint. Each snapshot gets a new index file (a running scan's `git status` may still rewrite the
old one); the old one is removed, as is the last on quit. *Restore File* (Git tab, also Enter on a deleted row,
confirmed, refused while the file has unsaved edits) puts the file back as in any base: `restore --source --worktree`
(plus `--staged` against HEAD, so it drops off the list), a file absent in the base is deleted and its buffers closed.
A failed git step writes no file and changes no base.

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
disk logging is skipped when `headless`. *Message Log: Open* (`Alt+l`) is the `log` plugin: a `qed.ui` box over
`qed.messages` (a live core list of the ring): Time/Source/Message under a header, rows coloured by level, a `follow`
scroll (sticks to the newest; parked while the selection is off the last row, until the user returns to the end or
that row is evicted), the `list` and `list_range` scopes' keys, `Shift+↑↓` or a drag extends a range (`extend_from`), *Copy* copies it (newline-joined), `Enter` shows the entry in full, wrapped, and clickable chips for
the scoped *Message Log: Toggle Debug/Info/Warn/Error* (`d`/`i`/`w`/`e`) and *Toggle History* (`h`) (Debug and history
off by default, kept for the session; seeded entries carry `LogEntry.seeded`).
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
- Viewport: each editor node's state (`scroll_row`/`scroll_sub`/`scroll_col`, per node and buffer) is the view.
  `ui_editor_reveal` scrolls when the cursor moved since the node last saw it: the minimum to keep `scroll_margin`
  rows, or centred after a jump (the view state's `center`, set by `editor_goto` on the view showing the buffer); a no-cursor command (save, toggles,
  wheel scroll) leaves the view put. With soft wrap, `scroll_col` is 0 and `scroll_sub` anchors the visual sub-row
  of `scroll_row` at the top (all visibility math in visual rows, see `wrap.odin`). `buffer:screen_row`, `top_row`
  (row plus the scrolled fraction of its wrapped rows), `set_screen_row` (a fractional row picks the sub-row, so
  `set_screen_row(top_row())` is exact) and `focus` (an id'd view only) act on the view showing the buffer (`ui_buffer_view`). When the caret is scrolled out of
  the view it is hidden, not clamped to an edge.
- Mouse: click positions, drag extends (auto-scrolls past the edge), wheel
  scrolls; with wrap off Alt+wheel or the sideways wheel moves `scroll_col` by `wheel_scroll_columns`, up to the
  buffer's widest line (`buffer_width_max`, cached per `rev`); double/triple-click selects word/line. `editor_step` coalesces a
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
  once; past a Myers work budget of ~(n+m)·d = 1e8 it is one replace hunk) as one undo step (Ctrl+Z brings the
  pre-reload text back, modified against disk; only the latest reload stays undoable, so a new one drops the log
  up to the previous one; when the old file, the buffer or the new file reaches `big_file_bytes`, undo/redo are cleared instead), drop the parse tree, re-sync LSP via `didClose`→lazy `didOpen`,
  map the cursor through the hunks); a **dirty** one sets `disk_conflict` + warns, and a `Ctrl+S`
  onto it opens the conflict dialog (Cancel / Overwrite / Reload) instead of
  clobbering; Reload is the same undoable step, so the discarded edits come back with Ctrl+Z. The poll skips a buffer while its highlight parse thread is busy
  (retries next poll); `highlight_jobs_pump` (main loop) adopts every buffer's finished parse, not only the shown one's, and
  `buffer_reload` joins and discards an in-flight parse (the conflict dialog's Reload). Deletion on disk is ignored (buffer stays; save recreates).
- **Startup arg:** file → open it; directory → set working root + welcome screen;
  absent → welcome screen.
- **Working root change**: the bundled `workspace` plugin's *Workspace: Open Directory* (`Ctrl+o`) is a
  path picker (a `qed.ui` tree over `qed.fs.list`) prefilled with the root. In the file tree the same chord
  (*Workspace: Open Selected Directory*) takes the selected dir (a file → its parent). `qed.set_root`
  refuses with `nil, "unsaved", info` while an unsaved buffer outside the target is not in its `discard`
  ids, so nothing unsaved closes unapproved (a buffer edited during the confirm is refused again). The
  plugin closes the picker before switching (restarting servers can outlast the command slice) and on
  `"unsaved"` reopens it on the typed path under the child `qed.confirm`.
  `editor_change_root` closes buffers outside the new root, restarts every LSP server and queues
  `root_changed` (the file tree plugin reopens an open tree on the new root). The process cwd never changes; subprocesses get the root explicitly.

## Clipboard

Copy/cut/paste shell out via `clipboard.odin`: `wl-copy`/`wl-paste` or `xclip`
(Linux), `pbcopy`/`pbpaste` (macOS); in-process register fallback if none exists.

## Input

Explicit `switch` on `(key, mod, ch)` → action procs. Rebindable commands live in
two tables (`palette.odin`): the global `commands` and `pane_commands`, each row with the
`scope` of the pane it runs in (`log`, `plugins`). A pane command that mirrors a global operation borrows its
bind via `Command.bind_from` (the global command's id; code refers to core commands by id, `command_shortcut`/`command_matches` included) — no config key of its own,
key/alt/shortcut resolved live from the referenced global command
(`command_effective_bind`), so one config entry drives both dispatch paths (log *Copy* follows
global *Copy*); every other command has an explicit snake_case `Command.id` (scoped core ones prefixed:
`editor_word_left`, `list_next`). User binds live in `keybinds.json` (embedded `config/keybinds.json` holds the core
defaults, `~/.config/qed/keybinds.json` the sparse user diff, loaded and hot-reloaded with config.json by
`keybinds_load`), nested by group: `{"core": {id: chord}, "<plugin id>": {id: chord}}`. Every
core command's default bind is an entry under `core` there, including *Command
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

Every editable text box (palette, pickers, line jump, find, rename, plugin queries) is a `qed.ui` editor node
over an internal buffer, so it edits like the buffer (the `editor` scope's core commands). Mouse input on
`qed.ui` nodes goes through their `on` handlers and the engine's native handling (scroll wheel, editor click and
drag, terminal). Split layouts (a list beside a preview) are plugin trees: a 40% column clamped to
`split_tree_*_width` or `split_code_*_width`, the preview growing into the rest.

Terminal workarounds, documented in `lib/tb2/PATCHES.md`:
- **ALT keys:** termbox stays in ESC input mode; after a bare `Esc`, qed
  `peek_event`s for `ALT_ESC_TIMEOUT_MS` and re-tags the next key (a printable,
  Backspace, Enter, arrows; not Esc or an already-Alt key) as `Mod.Alt` (so
  `Alt+f`/`Alt+F` are distinct, unlike `Ctrl+letter`).
- **Unknown sequences:** patched termbox decodes `CSI 27;m;k~` / `CSI k;m u`
  (foot, kitty) and `SS3 M` to keys and swallows any other complete CSI/SS3;
  key caps missing from terminfo fall back to the builtin xterm ones.
- **Unknown TERM:** if `tb2.init` fails, `editor_terminal_init` retries as
  `xterm-256color` (logged, `TERM` restored for children), else exits with the error.
- **Bracketed paste:** patched termbox surfaces `Paste_Begin`/`Paste_End`; qed
  accumulates the keys between them and routes the whole paste to whatever has
  focus: the buffer (one undo group), a focused `terminal` node, or a focused `qed.ui` editor node (single-line
  fields flatten newlines in their plugin, so a pasted newline can't fire Enter mid-paste); safety dialogs ignore it.

## Panes

All UI beyond the editor view is the `qed.ui` node tree ([notes/ui.md](notes/ui.md)): six layer outlets
(`background`, `base`, `popup`, `pane`, `notification`, `alert`), mounts owned by plugins or core, one focused node.
Core owns the engine and the heavy leaves (editor, terminal, image, the `qed.markdown.parse` node, virtual columns
over core lists: `qed.list`, `qed.fuzzy.list`, `walk:tree()`, `buffer:line_list()`, `qed.messages`). Bundled
plugins build every pane: palette, file tree, goto, search, workspace, dialogs (`qed.pick/prompt/confirm`), log,
plugin manager, settings, terminal, markdown preview, welcome screen (`layout`).

Core-built nodes (no Lua, so they work with plugins broken or off): the safety dialogs (quit with unsaved
buffers, close unsaved, disk conflict; `confirm.odin`), the LSP rename prompt (`rename.odin`), the caret popups
(`caret_popup.odin`) and the status leaf. A core-built node handles keys and clicks with `UiNode.core_event`, at
the point a plugin's `on.key`/`on.click` runs. A safety dialog is a full-screen catcher mounted last in `alert`
with focus: it keeps every key that bubbles to it and every click, and paste is ignored while it shows; a later
plugin mount into `alert` goes below it and a plugin focus request waits for it to close.

## Modules

The module system is gone. `ai` and `git` are bundled plugins (`plugins.ai`, `plugins.git`), LSP is the
top-level `lsp` section gated on `LSP_ENABLED` (`LSP:` commands carry `Command.lsp`, `lsp_enabled_sync`
tears servers down after a reload turns it off). Old `modules.ai.*`, `modules.git.*` and `modules.lsp.*`
keys warn "moved to"; any other `modules.*` key warns unknown.

**Moved keys:** one `CONFIG_MOVED` table (`settings.odin`) of `{old, new}` slash paths serves every
unknown-key warning (top level, `lsp/`, `languages/`, `modules/`, `plugins/<id>/`, plugin names, core and plugin
keybinds): `"old" moved to "new"`. The longest entry naming the path or a parent wins, `*` is one segment,
and entries point at final names, so a rename re-points older entries instead of chaining.

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
- A plugin declares its options with one `qed.options` call in `setup` (see Config), kept as
  `Plugin.schema` and the normalized table `Plugin.options` until it unloads. A disabled or errored plugin has none, so
  the menu shows only its `enabled` and its config keys are not checked.
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
  `plugin_cursor` at the top of every flush round (`plugin_buffers_check`, after `plugin_views_flush`), `view_scrolled`
  from the current buffer's view top line (`ui_view_top`, with the wrapped fraction) against `plugin_scroll` (only with
  subscribers). A wheel or a reveal forced by `screen_row`/`top_row` shows in that flush; one done by layout (a reveal,
  a re-wrap on resize) makes `plugin_busy` true, so the loop flushes right after the frame; `set_screen_row` moves the
  baseline, so a plugin's own scroll fires nothing. So
  an edit made by a handler or after an awaited dialog fires in the same flush. `buf_changed`'s `lo..hi`
  is the union of rows the primitives touched since the last delivery (`Buffer.plugin_lo/hi`, shifted by
  later edits: rows above are untouched, rows below only shifted); its `typed` is `Buffer.typed_rev == rev`, which
  the editor node's typing and its Enter/Backspace/Delete commands set. Exceptions: `buf_pre_save` runs inside
  `editor_save_full`; a handler that waits parks the save in `Plugins.saves` until
  its tasks end or `plugin_hook_timeout_ms` passes (`editor_save_id` finishes it).
  `quit` runs after the main loop, pumping until done or the same timeout.
- Plugin communication ([notes/plugins.md](notes/plugins.md)): `qed.export` (setup only, once) stores a table of
  functions on `Plugin.exports`; `qed.plugin(id)` (raises during setup) builds a fresh proxy of C closures holding
  owner, load generation (`Plugin.gen`), caller and name, so a call after the owner unloads or reloads raises and
  the proxy keeps nothing alive. A call runs in the caller's task through `lua_pcallk` (yields allowed), with a
  `PluginCall{co, owner, caller}` pushed for `qed.caller()` and popped by the continuation or `plugin_task_free`;
  calls from a plugin's own coroutines are refused, and a message handler keeps the callee's frames in the traceback.
  Unloading the owner kills every task inside one of its calls. Each plugin's qed closures carry `"<id>\0<gen>"` as
  their first upvalue, so `plugin_owner` rejects code from an older load.
  `qed:emit("<own id>:<event>", data)` queues a `.Custom` event (data held as a registry ref) for hooks of that
  name; `plugin_loaded`/`plugin_unloaded` are queued by `plugin_load`/`plugin_unload` after startup and skip their
  subject. Hooks of every kind go with their owner.
- Budgets: one count hook (100k instructions) on the main state, inherited by every
  thread, checks the slice in `Plugins.slice` against `plugin_budget(kind)` (`plugin_command_max_ms` for
  commands, `plugin_slice_max_ms` for events and timers). Past the
  hard limit it yields from the hook when it can (pcall cannot catch that), else
  raises and drops the hook count to 1 until the slice ends; the task is stopped with a warning (through
  `plugin_error`'s rate limiter) and the plugin stays loaded. A repeating timer or hook stopped
  `PLUGIN_KILLS_MAX` (3) times in a row (`PluginTask.source`, reset by a clean run) is removed with an error. A task's own Lua error is logged at Error and the plugin stays loaded too; out of memory runs a full
  collection, then stops that task with one Error giving the cap and usage (the cap is shared, so the plugin is never blamed);
  only load and setup errors mark it errored. `plugin_error` rate-limits per plugin (`PluginErrors`): at most
  `PLUGIN_ERRORS_PER_SECOND` entries per window, the rest summarized by the pump as `(N more errors suppressed)`;
  a known message shows `(N times)` and only its first occurrence logs the traceback. The soft limit
  (`PLUGIN_SOFT_MS`, 50) is a Debug line measured after the resume. A nested entry (e.g. `buf_pre_save` handlers under
  `qed.save`) has its own budget and its time also counts toward the outer slice; when it returns with the outer slice
  past its limit, the outer thread's count hook drops to 1, so a loop of nested calls stops at its next instruction. `__close` handlers run by `closethread` get the event budget.
- GC: the Lua collector never runs inside a slice (one big allocation could owe it a whole mark of a 40 MB heap).
  `plugins_open` stops it; `plugin_gc_step`, after `plugin_pump` and after `editor_step`'s flush, starts a cycle once
  the heap doubles since the last one (or reaches halfway from there to the cap) and steps it for `PLUGIN_GC_STEP_MS`
  (2 ms), then keeps paying the bytes allocated since the last call (`gc_debt`, 512 B per step) for at most
  `PLUGIN_GC_DEBT_MS` (8 ms) or `PLUGIN_GC_DEBT_STEPS` (64) steps, 4x both past half the cap; unpaid debt carries
  over, so garbage made with no idle time does not outrun the collector to the cap. A cycle starts at least
  `PLUGIN_GC_HEADROOM` (1 MB) above the last one's heap. `plugin_gc_due` keeps the main loop stepping back to back while
  idle. One `lua_gc` step is bounded: step size 512 B (`PLUGIN_GC_STEP_SIZE_LOG2`), a patched `entersweep`
  (`lib/lua/PATCHES.md`), and glibc fastbins off at startup (`malloc.odin`). Every full collection
  (unload, out of memory, a plugin's own, an emergency) rebases the pacer. `collectgarbage` allows only
  `collect`/`count`/`step`, so no plugin can switch the mode or restart the collector inside slices.
- `qed.lsp.format` sends a core LSP format request tagged with a token and waits
  (`.Lsp`, bounded by `plugin_hook_timeout_ms` → `"timeout"`); `plugin_lsp_done`
  queues the outcome, `plugin_pump` resumes the task. A response nobody waits for
  any more is not applied.
- When a `buf_pre_save` deadline passes, the late handler tasks are killed with
  the `qed.spawn` they wait on (`plugin_task_kill`), so nothing edits after the save.
- Bundled dir plugin files are listed one by one in `bundled_plugin_dir_files`
  (`plugin.odin`) so `test.lua` stays out of the binary; a test fails when a
  `plugins/<dir>/*.lua` is missing from it. The `test.lua` runner reads from disk.
- **UI**: the `qed.ui` node tree (see Panes and [notes/ui.md](notes/ui.md)); unloading a plugin unmounts its
  trees and closes its internal buffers and lists.
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
  It survives unload and resets when the next load starts. A plugin `Command` keeps `bare` (the registered `name`), `name` =
  `<display>: <bare>` (palette, `qed.run`; built, never parsed back) and `id` (its snake_case key under the plugin's
  group in keybinds.json, unique per plugin and scope). `qed.meta` must precede `qed.command`.
- Plugin command visible names are unique per scope (a tree and an editor command may share
  one). `qed.command` returns a handle whose `remove()` unregisters it; removing or
  unloading commands closes the palette, whose rows index `Plugins.commands`.
- Plugin binds come only from `key=` and keybinds.json. A keyed command rebinds
  its key-less siblings sharing `id` (they may have registered first);
  `plugins_rebind` clears every plugin shortcut, then binds in order. An unknown core id warns at load
  (`keybinds_load`); unknown groups and unknown ids of loaded plugins wait for `keybinds_plugin_warn` at the end of a
  flush after a load or config apply (`keys_due`, `keybinds_due`), so `startup` handlers can register first, and it
  warns only when the file or the plugin set changed (`keybinds_sig`); a disabled or errored plugin's group is skipped.
  A bind left in config.json (`keybinds`, `plugins.<id>.keybinds`) is not applied; it warns where it would go
  (`keybind_legacy_dest`: a CONFIG_MOVED rename, else the snake_cased name in its group).
- `ctx.selection_text`, `file` and `files` (the focused list's selection)
  are computed on first read through `__index` and cached on the ctx, so `when` stays
  cheap. A command's snapshot ctx keeps `selection_text` lazy too (buffer id, rev and range at invocation; nil
  once the rev moved), so a huge selection costs nothing unless read.
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
  `ui_dispatch_key` before anything else: `Tab` inserts it, `Ctrl+Right` one word (`inline_word_len`),
  any other key or a click drops it, all synchronously. Colors are interned theme keys
  (`Plugins.colors`), resolved into a per-frame palette; a tint or span alpha may be a theme tint key
  (`Deco.tint`, an index into `config_tints`), also resolved per frame. `deco_rows` buckets the visible
  rows once per frame; a blended span (`blend`) paints `color_over(line bg, bg, alpha)`. Namespaces (`Plugins.deco_ns`), status segments (`Plugins.status`) and plugin diff bases
  record their plugin; unload clears them.
- `qed.spawn` runs on `subprocess_spawn` (stderr captured, reaped with a
  non-blocking `process_wait`). The child leads its own process group
  (`subprocess_start_group`, a fork/exec like `os.process_start`) and every kill signals
  the group, so a cancelled shell takes its descendants. Argv and env strings over
  128 KiB raise before forking (Linux `MAX_ARG_STRLEN`). Reads are capped per pump (1 MiB per stream, stdout 64 KiB
  with `on_line`); with `on_line`, delivered lines are cut from `out`. Past `PLUGIN_SPAWN_OUTPUT_MAX` (32 MiB) stored
  stdout + stderr the group is killed and the result is `nil, "output too large"`. **External quirk:** Odin's heap
  allocator frees the old block when a resize fails, leaving the dynamic array dangling, so an uncapped
  buffer that hits an allocation failure segfaults on the next append instead of failing cleanly. A
  `spawn_bg` record is freed when its result is handed out by `wait()`, or once
  done after its handle's `__gc` (which only marks it; the pump frees).
  `Plugins.fakes` (`e2e_spawn_fake`) answers a matching command without forking.

## Language detection

Each `Buffer` carries a `language: Language`, set once at open (`language_of`).
File→language is **not hardcoded**: the `languages` option is a map from a language
(`choices = qed.languages`) to a record of `patterns` (glob list) and `lsp` (server
command), merged per entry and field like every other option (formatter
commands live in `plugins.format.commands`). `LANGUAGE_DEFAULTS` (`language.odin`) is compiled-in
wiring only (comment token, lsp id, grammar); default patterns/`lsp`
come from its declaration in `config/options.lua`. `LANGUAGES` is the working
copy each load resets, then `languages_from_config` overlays the merged map (an unknown language name warns). Patterns are `*`-globs matched against the basename, most-specific-first (exact
before glob, longer before shorter); built-in defaults cover extensions plus common
dotfiles (`.bashrc` → shell, …). `lsp_id` and the comment token stay compiled-in.
Everything — highlight, LSP, status bar, comment token — reads `b.language`. The
*Settings: Language* command (bundled `settings` plugin) overrides it for the session (re-parses,
re-opens LSP).

## Multiple servers / grammars

- **Syntax** (`highlight.odin`, `language.odin`): per-language `[Language]Syntax`;
  adding one = vendor `parser.c` (+`scanner.c`) + `highlights.scm` under
  `lib/tree_sitter/<lang>/`, add the FFI decl + `build.sh` line, fill the
  `LANGUAGE_DEFAULTS` row (grammar/comment/lsp id) + a `languages` default entry in
  `config/options.lua` (+ an optional formatter in `plugins/format`'s `qed.options`). Queries are vendored **upstream-verbatim**: a predicate
  evaluator (`predicate.odin`) enforces `#eq?`/`#match?`/`#lua-match?`/`#any-of?`/
  ancestry predicates per match (parsed + regex-compiled once at query build,
  cached per pattern; unknown predicates are skipped, never reject a pattern —
  deviations in `lib/tree_sitter/PATCHES.md`). A
  grammar/query that fails to compile surfaces a one-shot status message. Parse is
  incremental + async on big files; the query covers only visible rows, and only the
  on-screen byte window of rows ≥ `HIGHLIGHT_CLIP_BYTES` (`editor_highlight_clips`) — [notes/perf.md](notes/perf.md).
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
  the save, bounded by `plugin_hook_timeout_ms`. The `on_save` /
  `trim_whitespace_on_save` / `final_newline_on_save` knobs seed
  the plugin's toggles; on `config_changed` only knobs whose config value changed
  are re-applied, so runtime toggles survive unrelated edits.

## Markdown rendering

`markdown.odin` backs the `markdown` node (the preview) and the LSP hover: cmark-gfm turns the source into HTML
(GFM tables, strikethrough, autolinks, task lists, footnotes, raw HTML, `data-sourcepos`), and litehtml lays it out on
the cell grid through a `document_container` whose pixels are cells (1 col = 8 px, 1 row = 16 px, the font one row
tall), painting into `MdCell`s. Both are vendored C/C++ under `lib/` (`qmd.c`, `qlh.cpp` wrappers). Container,
stylesheet and HTML rewrites: [notes/markdown.md](notes/markdown.md).

The HTML is rewritten before layout: GitHub heading ids (`md_slug`, `-1` dedupe when stacked), alerts (`> [!NOTE]` etc. become a
titled, colored quote), task boxes, `<details>` open state (the node's toggles), images resolved or turned into
`[image: alt]` (also drawn for a file that sized but failed to decode). Code blocks are highlighted by the language's tree-sitter query (`highlight_query_clone`: its own
parser and cursor, a copied palette) and emitted as colored spans, one per source line. The stylesheet comes from
theme keys (markdown `captures`, pane colors, `markdown_code` tint); a retheme re-renders.

A render reads only an `MdInput` gathered on the main thread (`md_input_make`: source, stylesheet, fence languages
and their queries, image settings), so the preview renders on a thread per node (`ui_markdown.odin`): the last render
stays up until the new one is adopted; a newer edit or width cancels a stale render; a first open waits once up to
`md_wait_ms` (60), then the pane stays empty until the first piece lands. litehtml grows faster than linearly, so the
HTML is cut into pieces at top-level block boundaries qmd.c marks (only after a block whose bottom margin is one row,
which the stacking puts back); a cut goes after one block in 8 whose source hashes to it, so an edit moves no cut
but its own. Source rows, `<details>` indices and heading ids inside a piece are relative (made absolute when the
pieces are stacked), so a piece whose HTML, width and stylesheet match one on screen is reused even when lines were
added above it; highlighted code is cached by content. A first render shows its pieces as they finish; closing a
preview cancels its render at the next piece. The hover renders once, synchronously (about 2 ms), at the measuring
width, and keeps that render at the box's width (rules don't count). A piece is capped at 20k rows (a hostile
`height`). cmark-gfm's extension characters are a process-wide table; a patch sets them once
(`lib/cmark_gfm/PATCHES.md`) so parses on two threads don't race.

Each row carries the source row of the last block starting at or above it (`data-sourcepos`; code rows are exact),
which drives scroll sync both ways (`ui_markdown_line_of_source`/`source_of_line` interpolate inside a block). Links
are walked boxes (`MdCell.link`), anchors every element `id` (headings, footnotes), `<summary>` boxes toggle their
`<details>` on click (`UiMarkdown.open`, re-rendered keeping the scroll). Known differences from GitHub: litehtml may
break a line between an inline code span and adjacent punctuation; table images use `width: 100%` (litehtml ignores
`max-width` in cells), so small screenshots in tables upscale to their column.

## Images

`image.odin`: kitty graphics with Unicode placeholders, so termbox's diff owns every cell and images scroll,
clip and hide under overlays like text. A `markdown` body with a dir shows local PNG/JPEG images where litehtml boxes
them (inline, in table cells, `width` honoured; anything else stays `[image: alt]`); the file preview shows image files. Size comes from the file header at render time, so layout
reserves the rows at once; until the terminal has the image they draw a dim box with the alt text. Only drawn rows
load; one background thread (`image_pump`) prepares the transmit bytes (a PNG within the largest box it can show at as its own
file, else decoded, scaled down to fit that box and deflated), so the render path only writes them. qed links the
system libz (`vendor:zlib`) for that compression. Only images drawn recently keep a payload or a terminal copy
(`IMAGE_CACHE_MAX`, LRU outside the current frame). Detection (config
`image_protocol`) and the protocol details are in [notes/images.md](notes/images.md).

## AI plugin

`plugins/ai` (`plugins.ai`). *AI: Edit Selection* (`Ctrl+k`): with a selection, `qed.prompt` takes an
instruction; the whole buffer, the selection wrapped in `<<<SELECT…SELECT>>>`, goes through the
`edit_prompt` template to `edit_command` (default `claude -p`) on stdin via `qed.spawn_bg`. Requests run
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
menu, and a multi-line ghost floats the popup above the caret (`caret_popup`). See
[notes/ai.md](notes/ai.md).

## Config

Every option is one typed declaration: core's in `config/options.lua` (embedded like the prelude), each plugin's in a
`qed.options{name = decl}` call in `setup`. A decl is `{type, default?, description?}` plus `min`/`max` (int), `choices`
(choice: a static list, or a function, e.g. `qed.theme.list`, `qed.languages`), `of` (list), `key` (map: string or
choice) and `value` (map), `fields` (record); compounds nest and a bare type name is `{type = name}`. `string` is one
line, `text` any string. A missing default is the type's zero (a record's comes from its fields); a function choice
outside a map key needs a default. `options.odin` parses a decl table into an `Option` tree (`options_declare`,
arena-owned per plugin) and pushes a normalized Lua copy (types expanded, defaults filled; choice functions kept), which
`qed.config_schema()` (core) and `qed.plugins()[i].options` hand to the menu. Core's tree is parsed before main in a
throwaway Lua state (`options_core_declare`) and gives `g_config_defaults`, which seeds the typed globals of
`settings.odin`; the plugin state parses the same file again for the live table.

Validation is one function, `option_merge`: user JSON over the defaults, a record per field, a map per entry (`null`
drops an entry), a list or scalar replaced. An undeclared key, a wrong type, a newline in a `string`, a choice outside
its list or an int out of bounds is reported (`"path" (expected ...)` or `unknown "path"`, through `config_unknown_msg`,
so CONFIG_MOVED applies) and the default kept; a bad map entry is skipped, a list with a bad item keeps the default.
Function choices are resolved into heap-owned lists on the `Option` (`option_resolve`): core's sources (themes,
languages) in Odin before each core merge (`option_choices_native`, matched by C function, so the throwaway state's
stand-ins and a plugin's `qed.languages` agree; options.lua may use no other function); a plugin's own function from its
registry ref when the plugin declares and on each config refresh, in that plugin's context and budget, with a warning
when it fails or returns no list (its values then go unchecked). `qed.config_values` reuses the lists. Core runs the merge in `config_merge`, plugins in
`plugin_config_resolve` (enabled ones), and `qed.config_values()` hands the menu the merged values plus every slash path
the file names. `qed.config_set` shapes an empty table by the declared type at its path (`option_shape`) and writes
`qed.json.null` as `null`.

## Settings menu

`plugins/settings/menu.lua`: one centered `qed.ui` box (`pane_max_width`) with Options (Key | Value) and Keybinds
(Command | Chord) tabs (Tab/Shift+Tab) over a filter field and a `virtual_column` of rows. *Settings: Open Config UI*
opens it on Options and *Open Keybinds UI* on Keybinds (the same command again closes it, the other switches tab);
*Open Config JSON* and *Open Keybinds JSON* open the user files (created as `{}`). Options walks core's declarations,
then per plugin an implicit `<id>.enabled` and its declarations (a disabled or errored plugin has none), by dotted
name (`lsp.enabled`, `languages.go.lsp`, `format.commands.python`; scalars before compounds). A scalar is one row; a
list is a header (`N items`), one row per item (`name[i]`) and a `+ add item` row; a map a header (`N entries`), one row
per entry, a `(removed)` row per default entry the file drops with `null`, and a `+ add entry` row; a record's fields are
rows of their own, under a header only when the record is an item or entry. Values come from `qed.config_values()` (no
second validator); a row whose path the file names (or whose list it does) gets a `git_modified` bar. The info strip
shows the description and the default (a compound's as a count, a long one clipped); on Keybinds the command name,
default chord and scope.

Enter edits by type: a bool toggles, a choice opens a `qed.pick` over its choices, an int or string edits in an input
row (whole number, `min`/`max`, one line; bad input writes nothing), a text in a box of editor rows (wrapped; Enter is a
newline, *Settings: Save Text* `Ctrl+s` writes, Esc cancels). A list header or add row asks for a new item with the item
type's widget; a map header or add row asks for the key (a picker of the free choices for a choice key, an input for a
string key), then the value (a compound value starts from its default). Every write is one key with `qed.config_set`,
or `config_unset` when it equals the default at that path; an item, or anything inside one, is written as its whole
list. *Settings: Reset* (`Ctrl+d`, scoped) removes a list item or a user-added map entry, resets an overridden default
entry, drops an untouched default entry (`qed.json.null`), restores a dropped one, and resets anything else (a header
the whole list or map). Keybinds lists every command with an id (`qed.commands`: `owner` is its group, `id` its key),
one row per name; Enter captures a chord (an input row), a single key is refused in the editor and tree scopes, and a
chord another command holds in the same scope asks Cancel / Replace (Replace writes `""` for the other, or unsets it
when its default is empty); writes go through `qed.keybind_set`/`keybind_unset`. The view refreshes after each write and
on `config_changed`, `theme_changed`, `plugin_loaded` and `plugin_unloaded`, updating changed rows in place (`list:set`)
so the selection and scroll stay, or rebuilding when rows come or go (an added item or entry is selected).
`qed.config_set` and `qed.keybind_set` mark the write as the editor's own and zero the disk-poll clock, so the hot
reload applies it on the next loop without a "reloaded" message.

## Terminal pane

*Floating embedded terminal* (`terminal.odin`, `Alt+t`): named sessions
(`Terminals.list` of heap `^Terminal`, stable for the vterm callbacks' `user`
pointer), one of them shown through the `terminal` plugin's `qed.ui.terminal` node. `Alt+t` toggles the default `"shell"` session (an interactive
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
(non-blocking `read` → `vterm_input_write`, at most `TERM_DRAIN_MAX` (256 KiB) or `TERM_DRAIN_MS` (8 ms) per session per pump, since libvterm moves the whole grid per scrolled line; a session left with more sets `Terminals.more`, which drops the next peek timeout to 0 so a flood keeps draining between input events) whether shown or not, then reaps with
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
full-TUI programs keep it (`plugins.terminal.escape_closes`, default on).
Deep-dive: [notes/terminal.md](notes/terminal.md).

## File layout

`main` (entry/loop) · `editor` (dispatch + render) · `buffer` · `edit` (primitives
+ undo) · `cursor` · `settings` (user-config globals seeded before main from the declarations, load + write-back) · `options` (typed option
declarations: parse, merge/validate, core's declaration pass) · `clipboard` · `shell` ·
`confirm` (quit/close/conflict safety dialogs as core-built `qed.ui` nodes in the alert layer) · `rename` (the LSP rename prompt, core-built) · `draw` (box, text and cell drawing helpers, `Rect`) · `log` (message ring + disk log) · `subprocess` (shared async one-shot subprocess: spawn-with-stdin-body / non-blocking drain / cancel) · `wrap` (soft-wrap layout) · `preview` (preview read limits, binary check, hexdump rows) · `palette` · `walk` (walk service, `qed.fs` writes) · `walk_tree` (`walk:tree()` list kind) · `fuzzy` ·
`find` (in-buffer find/replace) · `jump` · `highlight` · `predicate` (query predicate evaluator) · `inspect` (*Debug: Inspect Tokens* pane) · `language` · `lsp` · `markdown` (cmark-gfm + litehtml on the cell grid: preview and hover) · `image` (kitty graphics: detection, decode, placeholders) · `completion` · `caret_popup` (completion menu, hover and the caret diagnostic as core-built `qed.ui` floats at `anchor = "cursor"` under the focused editor: a core mount in the `caret` outlet, rebuilt only when its content changes) · `rename` ·
`diffbase` (diff engine, ghost rows, revert) · `deco` (plugin decorations, marks, the inline ghost) · `terminal` · `plugin` (Lua state, loader, hot reload) · `plugin_api` (`qed` bindings, type stub) · `plugin_sched` (coroutines, events, timers, processes, budgets) · `plugin_ui` (walk handles, `qed.theme`, `qed.status`) · `ui`/`ui_api`/`ui_input`/`ui_list`/`ui_lines`/`ui_markdown` (the `qed.ui` engine, lists, line lists, the markdown node) · `prelude.lua` (node constructors, `qed.markdown.parse`, `qed.ui.dismissable`, the pane helpers `qed.ui.pane`/`split`/`footer`, `qed.pick`/`prompt`/`confirm` forwarding to the `dialog` plugin) · `perf_bench`.
Vendored C under `lib/`: `tb2` (termbox2), `tree_sitter`, `vterm` (libvterm), `pty` (forkpty shim), `lua` (Lua 5.4), `cmark_gfm` (markdown to HTML), `litehtml` (C++ HTML/CSS layout, gumbo inside; libstdc++ linked statically where the toolchain has it); plus `asciinema-player` (JS, the e2e demo pages' shared `player.js`).
Bundled Lua plugins live in `plugins/` at the repo root (`layout/`: the default UI (main editor, status row, message
line, welcome); `palette/`: the command palette; `dialog/`: `qed.pick`/`prompt`/`confirm`; `find/`: in-buffer
find/replace bar; `log/`: the message log; `manager/`: the Plugins pane; `terminal/`: the terminal pane; `ai/`: *Edit Selection*, *Cancel Edits*, inline completion; `filetree/`: the file tree; `format/`: save fixups + formatting; `settings/`: *Settings: Open Config UI* / *Open Keybinds UI* (the settings menu, `menu.lua`), *Open Config JSON*, *Open Keybinds JSON*, *Theme*, *Language*, *Indentation*; `search/`: *In Files* in the editor and the tree; `workspace/`: *Open Directory* and the tree's *Open Selected Directory*; `goto/`: *Line*; `git/`: diff base fetch, stat poll, file tree status provider, *Git: Set Diff Base*, *Git: Restore File*; `markdown/`: *Markdown: Preview* and *Toggle Split* with scoped *Back*/*Forward*; `conflict/`: merge-conflict highlight, *Conflict: Resolve*).
Core option declarations (`config/options.lua`), core keybinds (`config/keybinds.json`) and bundled themes live under
`config/` at the repo root, embedded via `#load`.

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
fixture (`e2e_git_start`), a stub-subprocess fixture (plugin tests' `t.stub`: fake
formatter / chat command / FIM endpoint), a fake stdio LSP server (canned
JSON-RPC, in `e2e_lsp_test.odin`), and `e2e_plugin(name, src)` / `e2e_spawn_fake` /
`e2e_plugin_config` (injects a user plugin / fakes a `qed.spawn` / overrides a
plugin's config and reloads it), and `input_feed` (`e2e_input_test.odin`: writes raw
bytes to the PTY master and collects termbox's parsed events; the fixture table holds
bytes recorded from real emulators). Each bundled `plugins/<name>/test.lua` returns a
table of test functions (`src/term_test.lua` does the same for `qed.term`); `e2e_plugins_test.odin` runs each in a fresh session with a
`t` API (`key`, `type`, `step`, `wait`, `expect_line`, `expect_cell`, `eq`, `ok`,
`fake_spawn`, `config`, `open`, `stub`, `message`, `log_has`, `editor`,
`poll_disk`, `pump`, `click` (text or `x, y`), `wheel`, `resize`, `tick` (fire the plugin's repeating timers now), `hook_timeout`, `lsp`, `bg` (rendered cell background), `ui` (focused plugin view: kind pick/prompt/confirm/pane, query, matches, labels, selected and its cells and mark bar, hint, footer input, tab), `config_path` (where `persist` writes)), with the root at the session's temp dir; the session theme and the clipboard register are restored afterwards; a Lua error or a plugin error fails the test with its traceback. Plugin bindings are unit-tested on a headless state in
`plugin_test.odin` (loader) and `plugin_api_test.odin` (bindings). Coverage is one file per area:
`e2e_edit/files/nav/lang/ai/mouse/lsp/narrow/pane/plugin_ui/ui_open/list/scope/workspace/walk_test.odin` (`ai`: the inline ghost and the LSP popup together); scope + assertion surfaces:
[notes/e2e.md](notes/e2e.md).
`tools/test.sh` builds the test binary once and runs the suite across `QED_TEST_SHARDS` processes (default
cores/2, at most 8), each with its own termbox backend and `e2e_lock`: same tests as `odin test`, ~3x faster.
The headless e2e suite stays the main net. To smoke-test a visible change on the real binary,
`tools/tmux-qed.sh` (`start` / `keys` / `capture [--color]` / `stop`) runs `./qed` in a detached
tmux session with an isolated HOME; run `tools/tmux-qed.sh` bare for usage.
**Golden screen tests** on the real binary: `tools/e2e.sh verify|update|demo|matrix` (driver
`tools/e2e/main.odin`, our libvterm as the terminal) replays `tools/e2e/scenarios/*.e2e` in a per-run
sandbox and diffs text + per-cell style against `tools/e2e/golden`; DSL in [notes/e2e.md](notes/e2e.md).
Performance budgets are gated headlessly by `bench_gate` (`perf_gate_test.odin`) over a generated
stress corpus: `tools/perf-gate.sh`, standard and corpus in [notes/perf.md](notes/perf.md).

## Shipped

Core editing: buffer open/save (atomic, permission-preserving, LF/CRLF +
final-newline preserving; external-change auto-reload + dirty-buffer save clobber guard;
optional save fixups in the `format` plugin — `plugins.format.trim_whitespace_on_save` /
`final_newline_on_save` knobs + runtime *Toggle …* commands, markdown two-space hard breaks survive trimming,
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
line-number + git gutter, mouse (position/drag/wheel/Alt+wheel horizontal/multi-click,
drag auto-scroll), status + message line (relative path, git branch + ahead/behind + diff size, segment icons;
narrow-width fitting), narrow-width panes (preview hides below the list/preview minimums),
structured message log (level/source-tagged ring + disk log at `~/.local/state/qed/qed.log`,
level-coloured line, local-time stamps, *Message Log: Open* pane `Alt+l` — per-level
filters, multi-select copy, cross-session history seeded from the disk log behind
an `h` chip (off by default); toggles are rebindable scoped commands with clickable chips, works on welcome), welcome-screen status bar (root + branch + version + message line),
rebind-aware pane self-close chords (`command_matches`), Debug-level internals
instrumentation (startup context, subprocess/AI/FIM/save/config/clipboard/terminal trails,
LSP request/response/diagnostics, completion counts, git branch + scan, disk reload/conflict —
full AI prompt/response bodies logged at Debug, no env-var dumps), welcome screen, quit guard across
modified buffers, the `qed.ui` node tree (layers, core leaves, scoped commands with a scoped Ctrl+P, the `list` scope's core navigation, live core lists: `qed.list`, `qed.fuzzy.list`, `buffer:line_list()`, `walk:tree()`, `qed.messages`); pick/prompt/confirm (the `dialog` plugin) in the `alert` layer, safety dialogs core-built; `qed.fs.copy/rename/remove/mkdir`), command palette (the `palette` plugin over `qed.commands()`; context-filtered via
`command_available`: welcome lists only the working whitelist, big-file buffers
hide the LSP/inspect commands),
multiple buffers, close buffer (buffer switching folded into the file-tree **Open** tab —
`Alt+o`, fuzzy + `Enter` switches, in-memory preview centered on the cursor, `Ctrl+W`
batch-closes the selection, silent for clean buffers and behind a `Close N buffers? (M unsaved)`
confirm when any are unsaved; standalone switcher removed), find/replace in buffer (`Ctrl+F` find, `Ctrl+H` replace — floating top-right bar,
literal or regex `.*` toggle, smart-case `Aa` toggle, all matches highlighted +
current shown as selection, `Enter`/arrows next/prev with wrap, `Alt+a` replace-all,
single-line/per-line), fuzzy line jump (`goto` plugin, *Go to: Line* `Ctrl+G`, filter over the list column,
matches in file order, a query extending the last one rescans only its hits; a `:N`/`:N:C` query is an exact line/column jump instead), project-wide search (`search` plugin: a `qed.ui` query pane, **debounced** parallel `rg --line-buffered` streamed into a key-sorted list as lines arrive, `plugins.search.min_query`;
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
(back/forward), runtime config (**typed sparse overlays**: every option is a typed declaration, core's in `config/options.lua`, a
plugin's in its `qed.options`, none in Odin source, completeness test-enforced; user
`~/.config/qed/config.json` is a per-key diff, never materialized, validated closed against the declarations, binds in
`keybinds.json` by group and command id; only the theme
picker's Enter (`theme`), the Plugins pane's `e` (`plugins.<id>.enabled`,
removed when it returns to the default) and `qed.config_set`/`config_unset` (the settings menu; `qed.keybind_set`/`keybind_unset` for keybinds.json) write it, one key each; unknown keys get a
one-shot warning, malformed JSON falls back to defaults without crashing; both config + active theme hot-reload via the disk poll —
colors/keybinds/knobs apply live, runtime toggles
survive, terminal palette re-pushed; existing buffers keep their language, running LSPs
their command), `lsp.enabled` (live toggle-off tears servers down; git is
`plugins.git`, auto-off when the binary is absent; AI is `plugins.ai`), JSON themes (sparse overlay chain over the embedded `default.json`
base, see Rendering; *Settings: Theme* fuzzy picker with instant preview,
Enter persists / Esc reverts), settings menu (*Settings: Open Config UI* / *Open Keybinds UI*: every core and loaded plugin option
with its description and every keybind, edited in place by per-type widgets (list items, map entries through a key
picker, records as nested rows), chord capture with a conflict
confirm, overrides marked, `Ctrl+d` resets; see Settings menu), selection pre-fill (a single-line selection
pre-populates Find / Replace / Project Search / Line Jump, fully selected so
typing replaces; multi-line/whitespace selections do not pre-fill). Every floating pane is
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
previews a diff instead: the file with the callback's text as its base, in an editor node with `diff = "changes"`
(hunks + `preview_diff_context` rows, a `diff_gap` row between runs, real line numbers) or `diff = true` (whole file),
both forcing the inline diff view (ghost rows, tints, word spans) whatever the global toggle; a deleted file previews
its base tinted as removed. *File Tree: Toggle Diff* (`Alt+d`, a session flag of the `filetree` plugin seeded from
`plugins.filetree.diff_only`, default on) switches between the two.
Preview loading is **debounced** (`WALK_PREVIEW_DEBOUNCE_MS`) for walk lists: a selection change arms
`Pane.preview_due` and `pane_stack_pump` loads once it settles, so a held arrow can't back up the input queue
or flood the tab's plugin with base requests.

**Walk service** (`walk.odin`): `Walk{root, dotfiles, ignored}` records in `Editor.walks`, shared by equal
options and refcounted by list sources (`walk_gc` frees unreferenced ones once their prewarm landed); the candidate
set comes from the parallel `readdir` walk (`walk_run`) or a background prewarm (ignore-set snapshot, adopted only
if `Walk.gen` did not move meanwhile). Each root has one ignore set (`walk_ignore_set`, fed by `h:ignore`; `false`
marks it not known yet, which holds the prewarm and Expand All back; only a changed set restales). A `qed.fs`
write (`fs_*`, `qed.fs.write`) restales only the walks whose root can contain the path (`walk_invalidate`); a
`qed.fs.walk` call restales just that walk. A stale walk keeps serving its old candidates while the prewarm reruns
it; only a first walk with nothing to serve runs on the main thread. Restaling and adopting bump `Walk.gen`, the list
stamp, so open walk lists refill keeping the selected and anchor paths. `within(paths)`/`union(paths)` narrow
through a refcounted `WalkScope` (listed paths keep their descendants and skip the dotfiles/ignored rules; virtual
paths and their missing parents are injected when absent). A scope copies its paths into one buffer and keys its
listed and ancestor sets by slices of it; `union` points at its base scope instead of copying it. A narrowed tree's
dir rows are cached on the scope until the walk restales, so a refill is a copy. A dir no listed path covers takes
its rows from the scope chain's own paths (grouped by parent; a listed path's parent index is kept from creation),
guarded by one `stat`: the dir's link count must equal 2 + the scope's subdirs there, else (a listed or symlinked
dir, a missing one, or a filesystem without dir link counts) it reads the disk (`posix` readdir, sorted, filtered).
A listed file missing from disk in such a dir still shows (the disk read hid it unless virtual); entry paths and pane mark keys live in arenas. `h:release()` frees a handle before collection. `list_walk_fill` builds the rows: lazy per-dir `readdir`
for the browsable tree, or under a filter a ranked, capped (`list.max`, 500) path list that narrows the previous
hits as the query grows. A browsable fill caches each dir's rows on the source until its walk restales (reopening
a dir rereads it) and reads uncached dirs for at most `walk_fill_slice_ms` (6); dirs left unread stay `pending`
(drawn `…`) and the next pump splices them in after their rows (`list_walk_resume`), keeping the selected path
and its screen offset. Expand All marks dirs open as the fill meets them (`expanding`, stopped at
`WALK_EXPAND_MAX_ROWS`, 200k, with a warning), so it streams; Esc mid-stream closes just the pending dirs, Alt+e collapses everything.
Symlinked dirs are leaves, so a cycle ends. `qed.fs.copy/rename/remove/mkdir` (`fs_*`) refuse an existing target, a target inside the
source (`into itself`), special files (fifos, sockets, devices; skipped inside a copied dir) and removing the root or
an ancestor; they never follow symlinks (copied as links), stream file data through a fixed buffer, fall back to
copy + remove only on `EXDEV` (keeping mtimes; a failed remove drops the copy and fails) and repath buffers.

**File tree** (`plugins/filetree`, D1: not in the works-without-Lua set): a full-screen `qed.ui` box (`id = "filetree"`,
scopes `filetree` and `list`): tab row, query field, a `virtual_column` over `walk:tree()` and a preview split
(`split_tree_*`), over a `qed.fs.walk` handle made at each open and toggle; a jump closes it. Tabs are
`within` handles (Open, Unsaved: buffer paths; an added tab: its `paths` plus `union` of its `virtual` ones); each
tab's `cmd` is an editor command (*File Tree: All/Open/Unsaved*, *Git: Changes*), so a chord switches tabs (Tab/Shift+Tab cycle them) and the
active tab's closes. A shown tab (open or switch) expands to and highlights the current file if it lists it, retrying
while dirs load or the tab's paths arrive, else its last row, else its first. Other plugins reach the tree only through its exports (`qed.plugin("filetree")`): `set_tab{label,
paths, virtual?, cmd?, detail?, preview?, missing?}` adds or replaces the caller's tab (between Open and Unsaved; the
same `paths`/`virtual` tables keep the cached narrowed handle), `remove_tab(label)`, `set_marks(marks)` (shown on every
tab; several callers merge, later id wins per path), `set_ignored(paths|false)` (fed to the walks' ignore set; `false`
holds the prewarm), `open(label)` (the whole open, narrowed fill included, runs in the caller's task) and `dotfiles()` (the live dotfiles state the workspace picker follows). All of it is keyed by `qed.caller()` and dropped on `plugin_unloaded`; an export
stores and defers one `sync` (`qed.defer(0)`), which rebuilds the tab row, source, marks and preview. Marks draw in
the rows (suffix and sizes only on a `detail` tab), chips in a row under the list, New:/Rename: as an input row,
delete and close confirms as `qed.confirm` children with their targets taken before the
dialog; a tab with `preview` turns the auto preview off and calls it (pcall, in the tree's task) per item after an
80 ms debounce on the list's `on.state` (a held arrow asks once). Enter
on a listed path missing on disk calls the tab's `missing`. File operations emit `filetree:refresh`. Tree
commands take the binds of the core *Copy*/*Cut*/*Paste*/*Close Buffer*/*Select All* through `bind_from`
(`plugin_command_bind` reads the core command at every rebind). A status push is compared with the last one and
narrowed handles are cached per tab and released when replaced. A root change reopens the view, back to each tab's default
expansion.

**Git tab** (`plugins/git`): at `startup` and on `plugin_loaded("filetree")` git takes the tree's exports and
publishes its last scan: `set_tab{label = "Git", cmd = "Git: Changes", paths, virtual = deleted, detail, preview =
blob at the base, missing = restore, empty = loading / not a repo / no changes / status failed}`, `set_marks` (bars
propagated up the dirs with a deleted file shown as modified above it, deleted fg, rename suffix, sizes, dim ignored)
and `set_ignored` (`false` until the first scan inside a repo; outside one `{}` at once, so the walk never waits on
the nested repo search). A scan
runs on `filetree:refresh`, a root change, a base move, *Set Diff Base* and a restore; it is compared with the last
one and a scan that only moved sizes or marks keeps the path tables, so the tree keeps its narrowed handle.
*Git: Changes* (`Alt+g`) opens the tree on the tab and hides without the tree. Without `filetree` git still does
gutters, status segments and *Set Diff Base*; without git the tree has no Git tab and no ignore set.
The `git` plugin's scan (`tree.lua`) sleeps every 2000 parsed lines (`repo.each`) so no slice nears the
budget, parses and drops each command's output before the next, caps the list at `tree.MAX` (50000) paths with a
warning, and a new request kills the running scan's spawn and reruns once.

Language intelligence: config-driven language detection (glob rules + built-in
dotfiles, per-buffer, *Settings: Language* override); tree-sitter highlight with full
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
rendered-markdown hover (`markdown.odin`, see Markdown rendering; popup wheel-scrolls while
hovered, `contentFormat` advertises markdown first), markdown preview (`markdown` plugin, laid out like GitHub by cmark-gfm + litehtml off the main thread: tables with row
rules, alerts, clickable `<details>`, footnotes, heading ids;
*Markdown: Preview* `Alt+p` in markdown buffers: a `full` pane capped at
`pane_max_width`, live on `buf_changed`, scroll kept, synced with the editor cursor on open and (after scrolling) on close, keys from the `list` scope (held arrows accelerate), *Markdown: Back*/*Forward* over anchor and file-link history;
*Markdown: Toggle Split* (unbound; launch state `plugins.markdown.split`, the toggle is session-only and a reload
applies `split` only when it changed): a sticky side-by-side preview in the layout's `editor_side` outlet, its own
nodes and history, `split_width` percent of the row, shown only while a markdown buffer is current, scroll-locked both ways on the top
line (VS Code style: the editor's `top_row` goes to the body's interpolated `source`, the preview's `source` back
through `set_screen_row`; `view_scrolled` and scrolling cursor moves one way, the scroll's `on.state{offset}` the
other; a re-render keeps the preview's own top line; heading jumps wait on the body's `settled()`; the cursor never moves), focus stays in the editor until the preview is clicked (*Markdown: Focus Editor*, Esc,
returns it), history also records editor switches to markdown buffers; Alt+p opens the overlay over it, dimmed, and
closing the overlay syncs the editor, which the split follows),
workspace-wide rename (`Alt+r`, cross-file as modified buffers, single cross-buffer undo),
auto-triggered completion dropdown (as-you-type + trigger chars, debounced, client-side
incremental filter, `Tab` accept, `additionalTextEdits` auto-import),
document formatting (`format` plugin: external command e.g. `ruff format -`, else LSP) + format-on-save
(config `plugins.format.on_save`, toggleable), `LSP: Restart`, state-colored status segment
(dim `…` starting / plain ready / red `✗` failed) + server stderr piped into the
`.Debug` message log; diff gutter against any diff base (the `git` plugin's: live vs `HEAD` or a session diff base, *Git: Set Diff Base*: merge base / branch / commit / checkpoint, `±label` status segment; *Git: Checkpoint* with *Accept File* / *Accept All*, *Restore File* against any base)
+ optional inline diff view (`Git: Toggle Diff View`, config `diff_view`): row
tint plus dim-red ghost rows for removed/replaced lines with word-level change highlight;
hunk navigation (`Git: Next/Previous Change`, `Alt+'`/`Alt+;`, `diffbase_goto`): jumps the cursor,
centered, to the first line of the next/previous changed block off the gutter marks, no wrap;
hunk restore (`Git: Restore Hunk`, `Alt+z`, `diffbase_restore`): restores the base lines for the
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
rows, spans, end-of-line text, range marks, the inline ghost), status segments (`qed.status`, multi-color chunks), diff base (`qed.buf.set_base`), plugin exports (`qed.export`/`qed.plugin`/`qed.caller`), namespaced custom events (`qed:emit`) and `plugin_loaded`/`plugin_unloaded` (the `git` plugin adds the file tree's Git tab through them); hot reload on file add/remove/edit
and `enabled` flips; *Plugin Manager: Open* (the `manager` plugin) with enable/disable (persisted), reload,
per-plugin log, and source view (bundled read-only); `qed.meta` display names prefixing
commands and labeling messages; plugin keybinds in keybinds.json by plugin id and command id; Lua
completion settings when the root is under the config dir.

Performance: incremental + async tree-sitter parse, viewport-scoped highlight
query, incremental LSP `didChange`, big-file cutoff, in-process fuzzy ranking,
async + debounced project search, parallel `readdir` file-tree walk (`d_type`, no
per-entry stat) prewarmed on a background thread. See [notes/perf.md](notes/perf.md).

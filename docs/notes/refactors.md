# Note — audit backlog: performance + structural refactors

Detail behind the Performance / Refactors items in [TODO.md](../TODO.md), from
the 2026-07-08 full-codebase audit. Each section is one TODO item; delete the
section when its item ships.

## Performance

### Cap `bracket_match` scan range

`bracket_scan_forward`/`backward` (`pairs.odin`) walk until they find the
partner — for an unmatched bracket that means to EOF/BOF, **every frame**,
since `editor_render_buffer` calls `bracket_match` per render. Gated on
`!b.big`, so a just-under-2 MB file still scans ~2 MB per frame to draw an
underline. Fix: cap the scan at a few thousand lines from the cursor and
return not-found past it; an unmatched-bracket underline loses nothing.

### Cache `llm_locate` per (path, rev)

While an AI edit is in flight, every render calls `llm_active_rows` →
`llm_locate` (`llm.odin`), which concatenates the **entire buffer** into a
temp string and substring-searches it — per request, per frame.
`llm_prune_edited` repeats the same work after every edit. Fix: cache the
located `(from, to)` on the request keyed by `b.rev`; recompute only when the
rev changed. Same shape as the git gutter's `computed`/`rev` guard.

### Cache `merge_scan` / `merge_word_map` per rev

Both run per render (`editor_render_buffer`, also `fim_render`): O(n) marker
prefix checks plus a Myers diff + word spans when conflicts exist. Cache the
conflict list + span map on the buffer keyed by `b.rev` (the git-gutter
pattern again). Only matters for large files, but the fix is mechanical.

### Modified flag via save watermark

`buffer_recompute_modified` compares the whole buffer against `saved` on
**every primitive edit** (a replace = two full scans). Fix: drop the string
compare; record the undo state at save time (undo-stack depth + whether the
open group was committed, plus an epoch that bumps when history is cut by
`redo_clear`) and define `modified` = current state ≠ watermark. O(1), and
undo-back-to-saved still correctly clears the flag. `saved` then only exists
for... nothing — it can be deleted along with the snapshot at save/open.
Covers the `buffer_recompute_modified` half of the existing perf TODO line.

### Debounce the git gutter recompute

`git_recompute` (line hash of every row + Myers) runs on the first render
after every rev bump — effectively per keystroke. Marks that lag ~100 ms are
imperceptible: debounce the recompute (recompute only when `rev` stable for
N ms, or on the idle branch of the main loop). Covers the "sub-cutoff git
gutter" half of the same TODO line.

### Migrate interactive-path blocking spawns to the async runner

Two subprocess mechanisms coexist: blocking `popen` (`shell.odin`) and the
async `subprocess.odin` runner (used by LLM/FIM/file-tree scan). Blocking
spawns still sit on latency-sensitive paths:

- `projsearch_run`: `rg` per keystroke,
- `format_external`: freezes the UI for the formatter's full runtime,
- `fuzzy_rank_fzf`: `fzf` per keystroke in every picker,
- `preview_file_reload`: `head` per preview load/scroll,
- `git_base_fetch`: `git show HEAD` on a buffer's first render (also in the
  cold-open perf TODO).

Migration order by feel: format_external (worst stall), projsearch, git base
fetch. The file-tree scan shows the pattern: render the cached result
immediately, kick the subprocess, apply on `*_pump`. Keep sync `popen` for
cheap one-shots (`command_exists`, clipboard).

### Per-frame `line_wrap` memo (measure first)

Wrap layout (`line_wrap`: full grapheme iteration + two temp arrays) is
recomputed several times per line per frame via `wrap_rows`/`wrap_subrow`/
`wrap_segment`/the vpos walkers. A one-frame memo keyed by (line, width)
would cut it 3–4×, but the work is viewport-bounded — **do not build this
without a profile showing wrap cost**.

## Refactors

### Collapse the four dialogs into one primitive

Quit / close / conflict (`confirm.odin`) / merge (`conflict.odin`) are four
identical `{active, selected}` structs, each with open/close/execute/
dispatch_key/dispatch_mouse/render boilerplate (~200 lines total) around the
already-shared `dialog_key`/`dialog_mouse`/`dialog_render`. Fix: one `Dialog`
struct holding `question: proc(^Editor) -> string`, `actions: []string`,
`execute: proc(^Editor, int)`; per-use code shrinks to an open call + one
execute proc. Keeps explicit dispatch — the Overlay entry points at the
shared procs with the editor's single `Dialog` slot (only one dialog is ever
open at a time; nested conflict-after-close still works since execute opens
the next dialog).

### Collapse the centered pickers + shared two-pane key dispatch

`palette`, `langpick`, `indentpick` have byte-identical dispatch_key /
render / paste shapes differing only in item source and execute. Extract
`centerpick_key(l, ev, execute, close)` + `centerpick_render(l, labels)` (the
mouse half, `fuzzy_list_center_mouse`, is already shared). Then the same for
the two-pane pickers (`picker`, `bufswitch`, `linefind`, `projsearch`):
their dispatch_key bodies are the same Esc/Enter/arrows/refilter/preview
ritual around per-picker callbacks. Payoff is future panes — TODO already
lists find-references and symbol-search pickers; after this each costs ~30
lines instead of ~150.

### Unify virtual rows (git ghosts, FIM ghost, inline diagnostics)

Three mechanisms exist for "screen content not backed by buffer rows":

1. git diff ghost rows — `git_above`/`git_below` counts folded into the vpos
   walkers + `editor_render_hunk_ghosts`,
2. FIM ghost — `fim_ghost_gap` row reservation + `editor_render_ghost_line`
   (wrapped) + the cursor-line-suffix hack in `fim_render` (unwrapped),
3. (planned) inline diagnostic virtual text — the AI-section TODO's "shared
   inline virtual-text primitive".

Generalize the walkers' git-specific hooks into one per-buffer provider —
"N extra rows above/below row R, rendered by X" — and one ghost-row renderer.
Then FIM stops special-casing wrap vs no-wrap, and inline diagnostics /
sticky scroll drop in without adding a fourth interleaved concern to
`editor_render_buffer` (already a ~150-line loop juggling seven). **Do this
before starting the inline-diagnostics TODO.**

### Per-buffer viewport state

`scroll_row`/`scroll_sub`/`scroll_col` live on `Editor`, which is why every
buffer switch resets the scroll (`editor_switch_to` zeroes them). Move the
three fields into `Buffer` (or a small `View` struct on it); the existing
"per-buffer viewport memory" TODO then becomes a deletion — switch stops
zeroing — and jump/goto code stops guessing whose scroll it is touching.

### One buffer-intel reset choke point

`editor_set_language`, `filetree_repath_buffers`, and `buffer_reload` each
hand-roll slightly different subsets of "lsp_did_close + highlight_destroy +
`b.hl = {}` + git_invalidate". Extract `buffer_intel_reset(editor, b)` so the
next per-buffer cache (sticky-scroll data, conflict cache above) has exactly
one place to be forgotten in.

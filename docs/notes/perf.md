# Note — large-file performance

Deep-dive on the editing/open performance work. Read only when touching
highlight, LSP sync, git gutter, or `buffer_open` on large files. The summary
lives in [../DESIGN.md](../DESIGN.md); this is the *why* behind it.

## Where the time went

Profiled on generated `parser.c` (118k lines) and the 515k-line / 14 MB Odin
grammar `parser.c`, plus the sqlite3 amalgamation (~260k lines, 9 MB) as a
real-code case. Findings:

- Per-keystroke was dominated (~98%) by `highlight_update`: a full tree-sitter
  reparse + a whole-tree highlight query + a whole-buffer color-grid rebuild.
- The viewport-scoped query is a non-issue once added (~0.1 ms, size-independent).
- The incremental parse is the remaining highlight wall (~110–168 ms mid-file on
  huge files; roughly O(log n) with a large constant).
- On a C file with clangd attached the real per-keystroke killer was the LSP
  full-text `didChange` (~307 ms of snapshot + JSON-escape + format before a
  blocking 14 MB pipe write).
- `git_gutter_update` (whole-buffer line hash + Myers) and
  `buffer_recompute_modified` are secondary.

## Fixes shipped

**Incremental parse.** Each buffer retains its `^ts.Tree`.
`buffer_insert`/`buffer_delete` record a precise `ts.InputEdit` (byte + row/col
deltas, via `buffer_byte_offset`) fed to `ts_tree_edit` before reparsing with the
old tree.

**Viewport-scoped query + grid.** The query cursor is range-limited
(`ts_query_cursor_set_point_range`) to visible rows; only those rows' color grid
is rebuilt, recomputed on scroll via a visible-range cache key. Result on the
118k file: highlight per edit 585 ms → ~7.8 ms; combined per-keystroke ~600 → ~21 ms.

**Async cold parse.** Opening a large file blocked ~700 ms on a blank screen (cold
`highlight_update` ran before the first `present()`). Files ≥
`HIGHLIGHT_ASYNC_BYTES` (256 KB) now snapshot their text and spawn
`highlight_job_run` on a background worker with its **own private parser** (shares
no tree-sitter state with the main thread); the buffer renders as plain text but
stays interactive. Edits during the parse accumulate as `pending` `InputEdit`s; on
completion `highlight_job_adopt` takes the tree and `highlight_reparse` catches up.
Smaller files parse inline (no thread overhead, no uncolored flash).

**Async incremental parse.** The per-edit reparse also runs on the worker (same
`HighlightJob`) via a cheap `ts_tree_copy` + replayed `pending` edits;
`highlight_update` dispatches and returns, keeping the last painted colors
(stale-but-colored) until the parse lands, then adopts + repaints, chaining
another job if edits arrived meanwhile (converges on typing pause). Thread-safety
rests on `ts_tree_copy` making the worker's edit/parse copy-on-write against the
retained tree, and the main thread doing no refcount-affecting op on a shared tree
while the worker runs (returns early during a job; `thread.destroy` joins before
any delete). `highlight_destroy` joins a running job before freeing.

**Incremental LSP `didChange`.** Every primitive edit records an `LspChange`
(UTF-16 range + text) at the `buffer_insert`/`buffer_delete` choke points;
`didChange` sends only the batched diff (~100 bytes for a keystroke) instead of the
whole file, gated on the server advertising Incremental `textDocumentSync` (parsed
from the initialize response), else full-text fallback.

**Big-file cutoff.** Files ≥ `BIG_FILE_BYTES` (2 MB, config knob) open with
`buffer.big`: `editor_render` skips highlight + git gutter, `lsp_sync` skips the
attach. A monster file is a fast plain-text buffer (status bar shows `big`).

The main loop swaps `poll_event` for the `LSP_POLL_MS` (30 ms) `peek_event` loop
while `highlight_busy`, re-rendering when `highlight_ready` fires.

Net per-keystroke on the 515k file: ~291 → ~82 ms with fixes on, ~0 (plain) in
big-file mode.

## Regression coverage (`src/perf_bench.odin`, `src/lsp_test.odin`)

- `test_highlight_incremental`: incremental + viewport path paints byte-identical
  colors to a full parse; asserts a per-edit budget on the 118k file.
- Large cold parse goes async and paints real colors after adoption; async edit
  path dispatches without blocking and repaints after settling.
- LSP change reconstruction: replaying the recorded `LspChange`s is byte-identical
  to the buffer, including astral/surrogate and cross-line-break cases.
- A `QED_BENCH`-gated bench prints the full per-stage breakdown.

## Still open (see TODO.md)

- Cold `git_gutter_update` (~45–56 ms `git show HEAD` subprocess) still runs
  synchronously before first paint.
- `buffer_open` floor (~224 ms on the 118k file: read + `strings.split` + ~118k
  per-line allocs + a redundant `saved` snapshot). Candidate: an arena for line
  storage / lighter dirty-tracking, but it touches the core `Buffer` — measure
  hard first.
- `buffer_recompute_modified` scans row 0 → first change every edit; candidate for
  O(1) incremental dirty tracking.
- The git-gutter algorithm is only gated off *above* the cutoff, not made cheaper
  for large-but-sub-cutoff files.

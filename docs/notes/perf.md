# Note — large-file performance

Deep-dive on the editing/open performance work. Read only when touching
highlight, LSP sync, git gutter, or `buffer_open` on large files. The summary
lives in [../DESIGN.md](../DESIGN.md); this is the *why* behind it.

## The standard

Large and odd files and repos must not break the editor. Budgets:

| What | Budget |
|------|--------|
| Keystroke-to-frame, one scroll step (≤100k lines or ≤10 MB) | 16 ms |
| Open to first frame | 300 ms |
| 5 MB one-line minified JS, a 1 MB line in a file: type, move, scroll, select, search (highlighting may degrade) | 50 ms per action |
| 100k-file repo / 1M-line buffer: pane opens (file tree, Find in Files, Go to: Line, palette) | 300 ms |
| Same: one filter keystroke | 50 ms |
| One plugin slice in normal use (conflict, git, filetree, markdown, format) | 50 ms |

**Gate.** `tools/perf-gate.sh [CORPUS_DIR] [default]` generates the corpus if
missing and runs `bench_gate` (`src/perf_gate_test.odin`) on an `-o:speed`
build (`default`: the optimization `./build.sh` uses). It opens each corpus file
through `editor_init`, drives keys through `editor_step` and renders with
`editor_render`, plugins loaded, at 160×48, on the heap allocator. Each row is
checked against a limit of 3× the budget under 50 ms, 2× otherwise; `info` rows
are not gated. Without `rg` the Find in Files rows skip.
`QED_GATE_ONLY=files,long,longoff,longon,panes,plugins` and
`QED_GATE_FILES=a.c,b.md` narrow a run. Always under `ulimit -v` and `timeout`
(the script sets 6 GB / 30 min).

**Corpus.** `tools/gen-corpus.py DIR` (deterministic, ~860 MB, ~50 s; never in
the repo): 100k-line C/Python/JS/Odin, 10 MB mixed C, 5 MB one-line minified JS,
JSON with a 1 MB line, `odd.txt` (wide, emoji, combining, RTL, zero-width,
control and invalid bytes, CRLF, tabs, 200 KB emoji/combining lines), 100k-line
markdown, 2000 Lua conflict blocks, a 1M-line file, and `repo/`: a git repo of
100k files with 50k modified.

**Profiling.** No `perf` on WSL; sample a debug `-o:speed` test binary under gdb
(`odin test … -debug -keep-executable -out:X`, then interrupt it periodically
and `bt` the `bench_gate` thread). `ptrace_scope=1` means gdb must start it.

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

## Long lines and the gate (fixes shipped)

- Row render walked the whole line per wrap segment and past the right edge;
  it now starts at the segment, stops at the edge, skips styling off-screen
  clusters, and advances `x_origin` per segment (`visual_col_from`).
- Find matches were scanned per grapheme (5000 spans × 5M clusters, ~30 s/frame);
  a moving index makes it linear. `find_scan` checks the first byte before `find_eq`.
- `cluster_end`: an ASCII byte followed by ASCII (not CR) is its own cluster, so
  cluster walks skip the UAX #29 iterator; `grapheme_next/prev` resync at the
  nearest ASCII pair instead of walking from column 0.
- Lua scanner bails out of error recovery (2000 conflict blocks: 29 s → ~190 ms
  per reparse; see `lib/tree_sitter/PATCHES.md`), and a buffer whose inline parse
  exceeds 16 ms reparses off-thread from then on (`Highlight.slow`).
- `buffer_set_content` walks newlines in place into a reserved array; the
  snapshot builder is presized (1M lines: 467 → ~300 ms).

## Still open (see TODO.md)

Measured with the gate (`-o:speed` unless noted); file:line is where the time goes.

- **Repeated `line_wrap` of the cursor line** (wrap on, 5 MB line: type 200 ms,
  search keystroke 136 ms; 1.4 s/key on the default build). Each keystroke wraps
  the whole line 6–8 times: `wrap_subrow` (`editor_scroll_vert`, editor.odin),
  `wrap_seg_start` (`cursor_goal_sync`, cursor.odin), `line_rows` (`vpos_up`,
  wrap.odin) and the render loop, each O(line). Fix: a per-frame (or per buffer
  rev + width) memo of the last `line_wrap` result keyed on the line, which is the
  existing "per-frame line_wrap memo" TODO, now justified.
- **Default build is `-o:minimal`.** The same paths run 3–25× slower than
  `-o:speed` (Go to: Line filter on 1M lines: 40 ms vs 1.1 s; minified type with
  wrap: 200 ms vs 1.4 s). `build.sh` passing `-o:speed` is the cheapest win.
- **Markdown preview renders the whole document** in one slice (100k lines:
  1.7 s, `md_render` → `md_blocks` → `md_emit_wrapped`/`md_cells`, append churn in
  mdrender.odin). Fix: render per block lazily for the visible range and cache
  rendered blocks by source range, or at least yield between blocks.
- **Git tab `view:set`** on a 50k-path scope takes one ~250 ms core call:
  `walk_scope_rows` (walk.odin) readdirs every expanded dir and checks each entry
  with `walk_scope_has`. Fix: build a narrowed scope's rows from its own sorted
  path list (closure map already holds the ancestors), no readdir.
- **git plugin parse chunks** (startup / refresh, 50k changes: 60–100 ms slices):
  `repo.each` yields every 2000 lines but each line costs ~50 µs in Lua (pattern
  parse, path concat, GC). Smaller chunks cut the slice but multiply wall time;
  better a core `git status --porcelain` parser or fewer per-line allocations.
- **format `buf_pre_save`** (100k lines: 83–105 ms): `fixups` materializes
  `qed.buf.lines` and pattern-matches every line in Lua. Fix: a core helper that
  returns only rows with trailing whitespace (like `qed.buf.find_lines`).
- **1M-line open** (~300–380 ms; 590 ms default build): one `clone_to_dynamic`
  per line plus the `saved` snapshot. Fix candidates: line storage in one block
  (data-structure change, needs a decision) or a lighter saved-state watermark.
- **Typing at EOF of a 1M-line file** (5.5 ms speed, 17 ms default):
  `buffer_recompute_modified` scans from row 0.
- The diff-base algorithm (line hash + Myers) is only gated off above the big
  cutoff, not made cheaper for large-but-sub-cutoff files.

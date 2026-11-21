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
build, as `./build.sh` ships (`default`: `odin test`'s `-o:minimal`). It opens each corpus file
through `editor_init`, drives keys through `editor_step` and renders with
`editor_render`, plugins loaded, at 160×48, on the heap allocator. Rows report
mean/p95/max; p95 is checked against a limit of 3× the budget under 50 ms, 2×
otherwise. `.Info` rows and `.Open` rows (known over budget, in TODO.md; flip the
row's mode to `.Gate` once fixed) are not enforced. Keystroke rows count dispatch +
render only: a reparse running off-thread is not in them. The gate refuses to run
when the load average exceeds the core count (`QED_GATE_ANY_LOAD=1` overrides).
Without `rg` the Find in Files rows skip.
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
- `build.sh` builds `-o:speed` (`-o:minimal` was 3–25× slower on these paths;
  costs ~25 s of build time). CI and release build through it.
- `buffer_line_wrap` memoizes the last 4 wraps of lines ≥ 4 KB, keyed on buffer
  id, rev, row, width and tab width; the wrap helpers take its segments. A
  keystroke used to wrap the cursor line 6–8 times. `line_wrap` also skips
  `cluster_end` for printable ASCII (5 MB line: ~36 → ~11 ms per wrap). 5 MB
  line, wrap on: type 272 → ~30 ms, search keystroke 164 → ~1 ms.
- `highlight_query_paint` queried and painted whole visible rows, so the frame
  adopting a reparse on a 1 MB JSON line ran the query over the full row. Rows ≥
  `HIGHLIGHT_CLIP_BYTES` (4 KB) now get their own point range over the bytes that
  can be on screen (`editor_highlight_clips`: wrap segments from `scroll_sub` plus
  a screen's worth, or `scroll_col`..+width unwrapped; a ghost line from 0); runs of
  short rows share one range. Each range paints only inside itself, so a node
  spanning two ranges cannot repaint over the other's nested captures; colors
  outside a window are left stale, and the clips join the repaint cache key.
  `col_at_visual` gained the printable-ASCII fast path (the two window scans still add
  1-3 ms to an unwrapped long-line keystroke). Adopt frame: wrap off
  204 -> 10-12 ms, wrap on 195 -> 7-13 ms.
- `buffer_recompute_modified` resumes from a clean-row watermark
  (`clean_rows`/`clean_pos`, lowered to the edited row by each insert/delete)
  instead of row 0. 1M-line keystroke: ~6 → ~1.2 ms (default build 34 → 10 ms).

## Plugin paths (fixes shipped)

- Markdown preview (100k lines): one 1.75 s slice. `md_render` is now an `MdJob` stepped by whole
  top-level blocks, 10 ms per step (first step inline, then `pane_stack_pump`); the pane keeps the last
  finished render and the layout-reading `v:` calls wait for it. Constant factor: 16-byte cells indexing
  their spans, one wrap buffer, runs sliced from their span, no grapheme iterator for
  simple runes, inline text copied in runs (render 1.75 s -> ~0.6 s total, arena 715 -> 276 MB).
  Gate: open 1753 -> 48 ms, slice 1750 -> 35 ms, content after ~0.75 s.
- Git tab, 50k changed: `walk_scope_rows` read every expanded dir. An uncovered dir now takes its rows
  from the scope's paths (parent indices kept from `walk_scope_new`), guarded by a dir link-count `stat`;
  scope maps reserve past the load factor; `api_path_clean` is one pass (50k paths: 28 -> 5 ms).
  Slices 247 -> 45 ms (`within`) and 39 ms (`view:set`); open 103 -> 45 ms; populated 365 -> 85 ms.
- Format on save: `qed.buf.find_trailing` returns only the rows to trim. Slice 93 -> 0.5 ms, save 112 -> 20 ms.
- git plugin parse: byte compares, untouched paths skip `clean`'s gsubs, sizes look up by the short
  relative path. Standalone parse 283 -> 170 ms per 50k; gate slices startup 43 -> 26 ms, tree open
  119 -> 41-52 ms. The chunk itself is now 1-7 ms; the rest of a long slice is a Lua GC step.
- File tree open with 50k marks: the first 4000-mark push no longer shares the open's slice
  (open call 25-50 -> 12-35 ms).
- tmux smoke (default build): Git tab first arrow ~830 -> 6 ms; Alt+g to tab 238 ms; markdown
  preview frame 72 ms, content after ~1.2 s.

## Still open (see TODO.md)

Measured with the gate (`-o:speed` unless noted); file:line is where the time goes.

- **Typing on a 5 MB wrapped line** (within budget: mean 26, p95 42 ms): one
  rewrap per edit (rev changes) plus ~5 `visual_col` prefix scans of the cursor
  line (`cursor_goal_sync`, cursor placement in `editor_render`, ~3 ms each).
  Next step if needed: store each segment's start visual column in the wrap memo.
- **Markdown preview time to content** (100k lines: ~0.9 s of blank pane, in
  10 ms steps; open 49 ms, slices ≤36 ms): the remaining cost is spread (tree-sitter per code block ~20%,
  tables, lists, parse ~15%). A single huge top-level block (a 100k-line list or
  fence) is still one step. Options: highlight code blocks lazily at draw time, a
  "rendering" hint.
- **Lua GC steps** add 20–50 ms to whatever slice triggers them once the plugin
  heap holds 50k-entry tables (git, filetree); the git parse chunk itself is
  1–7 ms. Fewer allocations per item, or GC tuning, would cut them.
- **Git tab / tree open at 50k** sit near the budget: `within` (scope build ~20 ms
  plus the Lua path list) ~45 ms, `view:set` ~39 ms; on tree open the filetree
  and git slices land at 41–61 ms depending on GC (last gate: filetree 55 ms on
  tree open, 51 ms on the Git tab, both over budget but under the limit).
- **1M-line open** (~370 ms; 560 ms on `-o:minimal`): one `clone_to_dynamic`
  per line plus the `saved` snapshot. Fix candidates: line storage in one block
  (data-structure change, needs a decision) or a lighter saved-state watermark.
- **Edits deep in a 1M-line file** still pay `buffer_byte_offset` (buffer.odin),
  which sums line lengths from row 0 for the tree-sitter edit (keystroke now
  1.2 ms, ~4 ms on `-o:minimal`; unprofiled).
- The diff-base algorithm (line hash + Myers) is only gated off above the big
  cutoff, not made cheaper for large-but-sub-cutoff files.

# Note — end-to-end tests

## What e2e tests are for

The harness (`src/e2e_test.odin`) drives the **real** `Editor` headless: termbox
comes up once on an 80×24 PTS (no tty), synthetic `tb2.Event`s go through
`editor_step` (the real loop body), `editor_render` draws into termbox's back
buffer, and the grid is read back cell-by-cell. A session opens a real temp file
(`e2e_start(content)`), exactly the `qed FILE` entry path.

E2E covers the **wiring** the unit tests can't: keybind → action → buffer
mutation → render, and what actually lands on screen. It is *not* a place to
re-test primitives already covered in the unit tests — assert the user-visible
outcome of a real keystroke sequence, not the primitive.

Assertion surfaces: buffer state (`b.lines`, `b.cursor`, `b.selection`,
`modified`), overlay/pane state (`ed.find.active`, palette/picker rows), and the
rendered grid (`e2e_cell` glyph; `e2e_cell_fg`/`_bg` truecolor; attr bits under
`ATTR_W=64`, so color-of-a-cell and underline are assertable).

Harness capabilities: `e2e_key` / `e2e_type` / `e2e_step`, `e2e_mouse` (click /
drag / wheel / multi-click), `e2e_paste` (bracketed), `e2e_resize` (TIOCSWINSZ +
SIGWINCH, size restored on stop), `e2e_git_start` (temp git repo fixture),
`e2e_spawn_fake` (fake `qed.spawn`), and a fake stdio LSP server (canned JSON-RPC over Content-Length
framing, embedded in `e2e_lsp_test.odin`). Coverage is one file per area:
`e2e_edit/files/nav/lang/ai/mouse/lsp_test.odin`.

Sessions share one process with the multithreaded test runner: serialize through
`e2e_lock`, restore any global you mutate before `e2e_stop`, bound every
pump-until-condition wait with a wall-clock deadline.

## Golden screen tests (out of process)

`tools/e2e.sh` builds `tools/e2e/qed-e2e` and runs `./qed` in a PTY whose other end is the vendored
libvterm, so input goes through termbox's real parser and the screen is libvterm's grid. Modes:
`verify` (diff against `tools/e2e/golden/<scenario>/<snap>.txt`; on failure the actuals stay in the sandbox's `out/`),
`update`, `demo --out DIR` (asciinema v2 `.cast` on a virtual clock, `.gif` when `agg` is on PATH),
`matrix` (sizes x TERM values; every TERM is diffed against the first), `show FILE` (color preview).

Determinism: a per-run sandbox `/tmp/qed-e2e-XXXXXX` (root, HOME, XDG dirs, reset per scenario) whose
random suffix is masked back to `XXXXXX` in snapshots, so concurrent runs don't collide; an `env -i`-style
environment (`TZ=UTC`, `LANG=C.UTF-8`, `PS1`, `PATH` limited to the sandbox bin plus system dirs), fake
`wl-copy`/`wl-paste`, git config pinned, `lsp.enabled` false unless a scenario's `config` turns it on.
`update` writes a golden only after two identical consecutive snapshots. `e2e.sh` rebuilds `./qed` when
anything under `src`/`plugins`/`config`/`lib` is newer.

Scenario lines (`#` comments): `size WxH`, `requires TOOL`, `timeout MS`, `file PATH` / `config` /
`expect-file PATH` (body up to a line `end`, each line newline-terminated), `run [ARGS]`, `wait TEXT`,
`key K...` (`ctrl+s alt+F shift+right down*3 esc enter tab pgdn`), `type TEXT`, `click X Y`,
`dclick X Y`, `drag X1 Y1 X2 Y2`, `wheel X Y up|down [COUNT]`, `snap NAME`. Coordinates are 0-based cells.

Snapshot file: header (size, cursor), `-- text` rows (right-trimmed), `-- style` rows (one symbol
per cell, wide-char continuations skipped), `-- legend` (symbol to `fg= bg=` + attrs). Letters are
assigned in order of appearance, so a diff compares decoded styles, not letters.
Demos render at `--size COLSxROWS` (default 160x45, agg `--font-size 16`) unless a scenario sets `size`; verify/update default to 80x24; no scenario sets a size today.

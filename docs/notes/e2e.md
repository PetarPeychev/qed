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
`e2e_stub_script` (fake external subprocess: formatter / chat command / FIM
endpoint), and a fake stdio LSP server (canned JSON-RPC over Content-Length
framing, embedded in `e2e_lsp_test.odin`). Coverage is one file per area:
`e2e_edit/files/nav/lang/ai/mouse/lsp_test.odin`.

Sessions share one process with the multithreaded test runner: serialize through
`e2e_lock`, restore any global you mutate before `e2e_stop`, bound every
pump-until-condition wait with a wall-clock deadline.

## Remaining gap

- FIM ghost × LSP completion-popup precedence — ghost must stay suppressed while
  the completion popup is open; needs the FIM stub and the fake LSP wired into
  one session.

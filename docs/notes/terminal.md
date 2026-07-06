# Terminal pane

**Shipped.** This note is the design record; the terse reference lives in
[../DESIGN.md](../DESIGN.md) ("Terminal pane"). Below is the original plan, still
accurate to the implementation, followed by the resolved decisions.


A floating **terminal pane** — same overlay geometry as project-search
(`overlay_layout`) — hosting one persistent interactive shell. Goal is *cohesion*:
manage the editor's environment (git, builds, scripts, full-screen TUIs) without
quitting qed. Persistent: the shell + PTY + emulator outlive pane open/close (like
line-find persisting its query); toggling the pane only shows/hides it.

Scope decision (locked with Petar): **persistent session + full TUIs** — a real
embedded terminal emulator, not a one-shot output pane. This is the largest single
subsystem in qed, LSP-sized or larger. It stays **one** terminal pane (an auxiliary
floating window over the buffer), never split/tiled editing — that stays out of scope.

## Don't hand-roll the emulator: vendor libvterm

qed is a *guest* in the host terminal; there is nothing of the host emulator to
reuse for an embedded terminal. A correct xterm emulator (SGR/CSI/OSC, DEC modes,
scroll regions, **alt-screen** for htop/less/vim, scrollback, mouse encodings) is
weeks of work + a permanent bug tail. Vendor **libvterm** (the lib behind neovim
`:terminal`) instead:

- Pure C99 **state machine, zero I/O, no platform deps** — feed it PTY bytes, it
  maintains the cell grid and hands back damage rects. MIT-licensed.
- Same dependency shape as vendored termbox2 / tree-sitter: drop under
  `lib/vterm/`, build a static lib in `build.sh`, FFI decls from Odin.
- Portable to the Linux+macOS lock: the only OS-specific piece is the PTY
  (`forkpty` — Linux `<pty.h>` `-lutil`; macOS `<util.h>`, libSystem), isolated in
  a `pty_*` shim like the other platform bits.

## Data model

```odin
Terminal :: struct {
    active:   bool            // pane visible + focused (Overlay.active slot)
    alive:    bool            // child shell still running
    pty_fd:   int             // master fd, non-blocking
    pid:      int             // child $SHELL
    vt:       rawptr          // VTerm* (opaque, from libvterm)
    screen:   rawptr          // VTermScreen*
    cols, rows: int           // emulator grid = pane inner size
    // scrollback + dirty flag as libvterm callbacks require
}
```

Lives on `Editor` next to the other overlays; created lazily on first open,
destroyed at shutdown (kill child, `pclose`-equivalent, `vterm_free`).

## Main-loop pump (the one thing overlays don't do today)

PTY output is asynchronous, so — exactly like `lsp_pump`/`fim_pump` in `main.odin`
— add `term_pump`: non-blocking `read(pty_fd)` → `vterm_input_write` → mark dirty →
request redraw. Extend the loop's fast-poll gate
(`lsp_running() || llm_running() || fim_active() || highlight_busy()`) with
`term_alive(&editor)` so the shell stays responsive while focused. On child exit
(`read` EOF / `waitpid`) set `alive=false` and show a "[process exited]" line.

## Rendering

Register in `editor_overlays()` as `{&editor.terminal.active, term_dispatch, term_render}`.
`term_render` draws the box via `pane_draw_box(overlay_layout(...).box)`, then walks
the libvterm screen cells and emits `tb2.set_cell` per cell with its fg/bg/attrs —
same shape as the syntax-highlighted preview in `projsearch_render`, but colors come
from `vterm_screen_get_cell` instead of tree-sitter. Hardware cursor placed at the
emulator cursor when the pane is focused. Full redraw per event as everywhere else.

## Focus & input

The overlay dispatch already `return`s after handling a key while `active^` — so a
focused terminal naturally captures **all** input. `term_dispatch` forwards keys to
the child by encoding them with `vterm_keyboard_*` (unicode/key/modifier) and
writing to `pty_fd`; it intercepts exactly one **escape-hatch key** (e.g. the
toggle bind) that qed keeps for itself to defocus/hide the pane — otherwise Ctrl+Q
etc. would go to the shell, not qed. Mouse: forward via `vterm_mouse_*` only when
the child enabled a mouse mode; otherwise ignore.

## Resize

Floating-pane size is fixed by `overlay_layout`, so resize only fires on qed-window
change: recompute inner `cols,rows` → `vterm_set_size` + `ioctl(TIOCSWINSZ)` +
`SIGWINCH` to the child. Handle in the overlay `.Resize` branch.

## Nesting & keybinds (real risk)

qed runs inside **tmux inside Windows Terminal**; a full-screen app in the pane is
~4 terminal layers. It works (neovim does it), but keybind collisions compound
across layers — including WT eating Ctrl+V. The escape-hatch key must be one qed
*always* intercepts before forwarding, and it should avoid tmux's prefix and WT's
reserved chords. Pick it deliberately in `config.odin`.

## Resolved decisions

- **Escape-hatch / focus-toggle:** `Alt+t` (also the open toggle). Keeps every Ctrl
  key free for the shell; `term_dispatch` always intercepts it before forwarding.
- **Control-key quirk:** the dev terminal (tmux-in-WT) tags Enter/Tab/Backspace/Esc
  with a spurious Ctrl modifier; `term_send_key` strips Ctrl for those keys so they
  encode as plain Enter/Backspace rather than Ctrl-variants the shell ignores.
- **Colours:** qed can't read the host palette (it's a guest), so the emulator runs
  on qed's own — `COLOR_TERM_FG/BG` + `COLOR_TERM_ANSI[16]`, all config-overridable
  (`terminal_*` theme keys). Default bg = pane bg; ANSI = kitty's palette lifted
  +0x20/channel for legibility on the light pane.
- **Scrollback:** left to the child (less/tmux) for now — no in-pane scroll key.
- **Shell/cwd:** `$SHELL` (`/bin/sh` fallback), started in `working_root`, env inherited.

## Not yet wired

- Mouse forwarding to the child (only when it enables a mouse mode).
- Copy out of the pane (selection → clipboard).

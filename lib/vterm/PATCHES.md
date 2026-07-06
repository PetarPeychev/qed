# libvterm (vendored)

Terminal-emulator state machine behind the floating terminal pane (`src/terminal.odin`).

- **Upstream:** https://github.com/neovim/libvterm
- **Version:** 0.3.3 (rev `934bc2fbf21800ac3458a499df8820ca5fb45fd3`)
- **License:** MIT (`LICENSE`)

Vendored verbatim: `include/` + `src/` copied unchanged, all generated `.inc`
tables already checked in upstream. `build.sh` compiles `src/*.c` into
`libvterm.a`; `vterm.odin` holds the FFI subset qed uses (screen cells, keyboard,
input/output, size). No patches.

## Updating

Re-copy `include/` and `src/` from the upstream tag, then re-check the FFI struct
layouts in `vterm.odin` against `include/vterm.h` — `ScreenCell`/`Color`/`Pos` are
mirrored by hand and must stay byte-compatible (size 40 / 4 / 8; cell `attrs` at
offset 28, `fg`/`bg` at 32/36).

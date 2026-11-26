# Images

Reference for `src/image.odin`; DESIGN.md has the summary.

## Rendering

- A placeholder cell is `U+10EEEE` + a row and a column diacritic (kitty's `rowcolumn-diacritics.txt`,
  `IMAGE_DIACRITICS`), fg = the image id as truecolor (24-bit, never 0). termbox measures it as width 1.
- `md_inline` tags image spans (`![](x)`, `<img src>`, inside links too) with their dest; in a paragraph or HTML
  block with a resolvable one, `md_emit_images` emits in source order: image rows, and the text between images
  wrapped with its empty rows dropped (a `<td>` grid becomes one column). Remote URLs, missing files, a render
  without a dir (hover) or no protocol: the `[image: alt]` span stays in the text.
- `image_cells`: cols from pixel width / cell width, never upscaled, capped by the available width and
  `image_max_rows`; rows keep the aspect. Cell pixels come from `TIOCGWINSZ` on termbox's tty (8x16 when 0).

## Data

- `image_get` reads only the head (`IMAGE_HEAD_BYTES`): PNG IHDR or JPEG SOF gives the size, so layout never
  waits for a decode. Files over `IMAGE_MAX_FILE_BYTES` or `IMAGE_MAX_PIXELS` fail before decoding.
- An entry starts `Probed` (size only). Only drawn rows load: `image_show` (per drawn row) asks for the
  payload (`Loading`); `image_pump` (main loop, fast-poll branch while `image_busy`) runs one thread at a
  time, the most recently used first. The thread builds the whole transmit payload (`image_payload`): a PNG
  within the largest box it can show in (terminal width x max(`image_max_rows`, height) cells) goes as its
  own file (`a=t,f=100`, the terminal decodes it; `q=2` hides its errors, so the chunks must reach `IEND` within
  the file or it fails here); anything else is decoded with `core:image` (16-bit samples are
  native-endian), scaled down to fit that box when larger (`image_fit`, area average), and deflated (`f=32,o=z`, `vendor:zlib`, system libz).
  Base64, 4096-byte chunks and the tmux wrap are done there too. A failed load re-renders markdown panes so the
  alt text shows.
- `image_show` writes the payload once (`tb2.send`, out with that frame's `present`), frees it, then a virtual
  placement `a=p,U=1,i,p=1,c,r` per size. The fixed `p=1` makes a new size replace the old placement (kitty:
  same image and placement id replaces); without it kitty keeps several virtual placements and picks any.
- Until `image_show` has sent the image, its reserved rows draw `image_box_row`: a dim `┌─┐│└─┘` box (3+ rows,
  else plain rows) with `⋯ alt` centered on the middle row, cut with `…`. Markdown bakes it per line
  (`MdLine.loading`, `pane_shortcut_foreground` like its `[image: alt]`); the image node uses `pane_dim_foreground` and the file name.
  A drawn markdown line whose id is gone (dropped past `IMAGE_ENTRIES_MAX`) or reprobed to `Failed` re-renders the
  pane, which re-resolves the path (a new entry, or the alt text).
- Entries are keyed by path and keep their id, so lines already rendered never point at a dead id; a changed
  disk stamp reprobes under a new id. Only entries holding a payload or a terminal copy count against
  `IMAGE_CACHE_MAX`: past it the least recently used one not drawn in the last frame (`image_frame_begin`)
  goes back to `Probed` and is deleted on the terminal (`a=d,d=I`), reloading if drawn again. A doc with more
  images than the cap only holds the visible ones. Metadata entries are capped at `IMAGE_ENTRIES_MAX`.
  Quit deletes all.

## Detection

- `image_protocol`: `auto` (default), `kitty` (force), `none`. Hot reload to `auto` starts detection once.
- Startup sends a kitty query (`a=q`, id 31), XTVERSION and DA1 with the first frame. Replies arrive as
  `Event_Kind.Reply` (termbox patch, `lib/tb2/PATCHES.md`), always swallowed, also when late.
- Kitty = `OK` + an XTVERSION starting with `kitty` or `ghostty`: WezTerm (20240203) answers `OK` but draws
  placeholders as text and ignores `U=1`.
- Inside tmux (`$TMUX`) every sequence goes out DCS-wrapped (`ESC P tmux; ... ESC \`, ESC doubled); needs
  `allow-passthrough on`, and tmux must keep truecolor fg (`Tc`/`RGB`). tmux answers a bare DA1 itself at
  once, while the outer terminal's replies (graphics, XTVERSION, wrapped DA1) come later in that order, so
  detection ends on the second DA1. With passthrough off nothing more arrives: detection ends on the first
  key or mouse event.

## Limits

- A `dim` backdrop recolors placeholder fg, so the image disappears under it.
- The same image at two sizes at once (preview + markdown) re-places every frame.
- No remote fetch, no SVG/GIF, `<img width>` ignored, images are not resent if the terminal drops them.

## Terminals

- Windows Terminal: sixel only (no kitty graphics). tmux 3.4 forwards sixel to it only with
  `set -as terminal-features ',xterm-256color:sixel'` (WT's DA1 level 61 is not parsed by 3.4), and deletes a
  whole sixel image when any cell over it is written.
- Test rig (kitty / xterm / WezTerm on Xvfb with screenshots): `/home/petar/qed-overnight/tools/images-rig/`.

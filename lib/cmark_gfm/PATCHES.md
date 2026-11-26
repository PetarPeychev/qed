# cmark-gfm

Vendored from https://github.com/github/cmark-gfm at 7fe8904ee31fa24b772ae565c4908b1394850de6 (0.29.0.gfm.14,
BSD-2-Clause, COPYING): src/*.c minus main.c, extensions/*.c, plus config.h, cmark-gfm_export.h and
cmark-gfm_version.h generated once by its CMake.

- `blocks.c` `process_inlines`: no longer adds and then removes the extensions' trigger characters (`~`, `:`, `w`,
  ...) in the process-wide `SPECIAL_CHARS`/`SKIP_CHARS` tables around each parse. A parse finishing on one thread
  cleared them under a parse on another (lost strikethrough and autolinks, a data race). Every qed parser attaches
  the same extensions, so `qmd_init` sets them once.

`qmd.c` is qed's wrapper: `qmd_init` registers the GFM extensions and sets their trigger characters once (call it on one thread before any parse),
`qmd_to_html` parses with the table, strikethrough, autolink, tagfilter and tasklist extensions and footnotes, adds
`data-sourcepos` to the first tag of raw HTML blocks and replaces each code block with the HTML its callback returns
(given the info string, the code and the first content line). `cmark_gfm.odin` binds it.

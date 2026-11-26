# Markdown rendering

Reference for `src/markdown.odin` and `src/ui_markdown.odin`; DESIGN.md has the summary.

## Pipeline

1. `md_input_make` (main thread): copies the source, builds the stylesheet from the theme (and its hash), resolves
   every fence word to a `Language` (`language_of_name` reads config) and clones its highlight query
   (`highlight_query_clone`: fresh parser and cursor, copied palette and fallback color), snapshots the image settings.
   Calls `cm.init()`, which registers the GFM extensions and sets their trigger characters once.
2. `md_html` (any thread): front matter becomes a ```` ```yaml ```` block (same line count); `qmd_to_html` runs
   cmark-gfm with `UNSAFE | GITHUB_PRE_LANG | FOOTNOTES | SOURCEPOS` and the table, strikethrough, autolink, tagfilter
   and tasklist extensions, adds `data-sourcepos` to the first tag of raw HTML blocks, inserts a
   `<!--qed-piece LINE-->` marker before every top-level block whose predecessor is a paragraph, heading, list,
   quote, code block, rule or table (never before footnote definitions, which render inside one section), and
   replaces each code block with the HTML `md_code_html` returns (one `data-sourcepos` span per line; the colored
   line HTML is cached by language and content across renders). One scan over the tags then rewrites:
   - every `data-sourcepos` relative to the current piece's first line;
   - `<hN>` gets `id` = GitHub slug of its text (lowercase, letters/digits/`-`/`_`, spaces to `-`); repeats get `-1`..
     when the pieces are stacked;
   - `<blockquote>` whose first paragraph starts `[!NOTE]` / `TIP` / `IMPORTANT` / `WARNING` / `CAUTION` (the marker
     alone on its line) gets `class="alert alert-x"` and a `<p class="alert-title">icon Title</p>`;
   - `<details>` gets `open` per the source XOR the node's toggles (`UiMarkdown.open`, by document order), its
     `<summary>` `id="qed-details-N"` with N relative to the piece;
   - task `<input type=checkbox>` becomes `<span class="task">☐</span>` / `task done ☑`;
   - `<img>` keeps its tag when `md_image_info` sizes the file, else becomes `<span class="image-alt">[image: alt]`;
   - at a marker, a cut when the source of the block before it hashes to 0 mod 8 (or the piece passed 16 KB) and no
     raw HTML element is open (a stack of open tag names; a closer matching nothing open is ignored). An element
     left open forces a cut after 128 KB. The marker carries the next piece's first line.
   Checks `cancel` every 256 tags.
3. `md_layout`: each piece goes through `md_chunk_layout` unless the previous render (or a cancelled one) has a
   piece with the same HTML, width and stylesheet hash. Pieces publish as they finish (`MdJob.ready`, atomic);
   `cancel` stops between pieces. A piece is capped at 20k rows.
4. `md_doc_assemble` (main thread): rows stacked with one blank row between pieces (every cut is after a block whose
   bottom margin is 1em, and the first child of a piece loses its top margin), source rows and details made
   absolute, heading ids deduplicated, per-row link base, images with their cache ids.

## Container (`lib/litehtml/qlh.cpp`)

- Units: 1 column = 8 px, 1 row = 16 px. `get_default_font_size` is 16 and every font reports height 16 and
  `ch` 8, so `em` is a row and `ch` a column. `pt_to_px` scales by 16/12.
- `create_font` packs bold (weight ≥ 600), italic, mono, underline and line-through into flag bits; the font is
  that flag set. `text_width` is cells × 8 (`md_text_width`: ASCII bytes, else `cluster_width` per grapheme, the
  value termbox draws).
- `draw_text` places clusters from `round(x / 8)` on the row holding the box's vertical middle; a wide cluster marks
  the next cell `tail`. Colors keep the CSS RGB; font flags become termbox attributes.
- `draw_solid_fill` fills cell backgrounds (alpha under 128 skipped, the root skipped so the pane background shows).
- `draw_borders`: a visible side (style above `hidden`) is one cell thick, drawn as line bits per cell; bits from
  crossing borders join into box-drawing glyphs (`md_line_glyph`: light, heavy for groove/ridge, double). Borders
  must be a full cell in CSS (`1em` / `1ch`), or they round away.
- `draw_list_marker`: disc/circle/square become `•` `◦` `▪` in the bullet color; ordered markers come through
  `draw_text` as `N.` in the item's color.
- `get_image_size` returns the size `md_image_info` computed (`image_cells` × 8 / 16); `draw_image` records the
  cell box (`round` start, whole cells of width so a box ending mid-cell leaves the padding cell).
- `qlh_walk` visits every element with `href`, `data-sourcepos`, `src` or `id` and reports its rendering boxes:
  `a href` marks cells with a link id, `data-sourcepos` gives `(row, source line)` pairs (zero-width boxes skipped:
  an empty inline sits at the end of the row above), ids become anchors, `qed-details-N` ids become summary boxes.

## Stylesheet

`MD_MASTER_CSS` replaces litehtml's master sheet (parsing that cost more than a small document): display types and
the few defaults markdown HTML needs. `md_css` adds the theme. Choices that are not obvious:

- headings `font-size: 1em`, h1 `border-bottom: 1em groove` (heavy `━`, heading color), h2 `1em solid` (border color);
  `sup, sub, small, code ...` stay `1em` and on the baseline so rows never go fractional;
- `body > *:first-child` / `:last-child` drop their margin (pieces rely on it);
- `li:first-child > p:first-child { margin-top: 0 }` keeps loose lists from opening with a blank row;
- `li:has(> .task)` hides the bullet of a task item;
- `pre { white-space: pre-wrap }`: long code lines wrap instead of clipping; code rows get a padding column;
- tables `border-collapse` with full-cell borders on every side: GitHub's row rules; `td img { width: 100% }`
  because litehtml ignores `max-width` inside table cells (small table images upscale to their column);
- blockquote `border-left: 1ch` plus `padding-left: 1ch`, text in the dim color; alerts keep normal text and color
  the bar and title (NOTE info, TIP git added, IMPORTANT keyword, WARNING warning, CAUTION error);
- `sup.footnote-ref` shows `[n]`; the footnote section gets a top rule.

## Threads

The worker reads only its `MdInput`, the previous render's pieces and code cache (immutable until the job is adopted)
and the immutable query state behind each cloned `HighlightQuery`; it never touches the image cache, the language
table, theme globals or termbox state. cmark-gfm keeps its extension trigger characters in a process-wide table it
used to set and clear around every parse; `lib/cmark_gfm/PATCHES.md` sets them once. litehtml is shared between the
worker and the hover on the main thread: its global string-id table is mutex-guarded, and `lib/litehtml/PATCHES.md`
makes its storage a deque so a returned reference survives another thread adding ids. A stale job is cancelled when a
newer edit or width is wanted; its finished pieces become spares for the next job.

## Numbers (8 cores, -o:speed)

- Hover-sized doc: 1-2 ms, rendered once.
- README.md at 100 columns: about 12 ms; DESIGN.md (1000 lines): about 85 ms from scratch.
- Enter in DESIGN.md with the split open (200x50): main-loop frame median 4.7 ms; the preview is current again after
  26 ms median (74 ms when every piece after the edit was laid out again).
- Typing in DESIGN.md with the split open: median frame 3.8 ms, p90 6.8 ms (the old sliced renderer: 11.4 / 15.7 ms).

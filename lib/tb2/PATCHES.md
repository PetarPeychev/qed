# Local patches to vendored termbox2

`termbox2.h` here is **not** pristine upstream — it carries qed-specific
modifications. If you ever re-vendor a newer termbox2, re-apply these. Every
patch site is marked with a `qed patch:` comment so they are greppable:

```sh
grep -n "qed patch" lib/tb2/termbox2.h
```

## Bracketed paste

qed needs to treat a terminal paste as one atomic action (one undo group)
instead of a stream of individual keystrokes. termbox2 upstream has no
bracketed-paste support, so we added it:

1. **Enable/disable the mode.** `TB_HARDCAP_ENTER_BRACKETED_PASTE`
   (`ESC[?2004h`) is emitted in `send_init_escape_codes`, and
   `TB_HARDCAP_EXIT_BRACKETED_PASTE` (`ESC[?2004l`) in `tb_deinit`.

2. **Parse the markers.** `extract_esc_paste` (called from `extract_esc`, before
   the terminfo-cap parser) recognizes the two 6-byte sequences the terminal
   wraps a paste in:
   - `ESC[200~` → event type `TB_EVENT_PASTE_BEGIN` (4)
   - `ESC[201~` → event type `TB_EVENT_PASTE_END` (5)

   The pasted bytes *between* the markers are left in the input buffer and
   parsed as ordinary key events. So the editor sees:
   `PASTE_BEGIN`, then the content as normal keys, then `PASTE_END`, and
   accumulates the content into a single insert. This keeps the C change tiny —
   no new fields on `struct tb_event`, no buffering of paste text in C.

The matching Odin side is `Event_Kind.Paste_Begin` / `Paste_End` in
`lib/tb2/tb2.odin`; the editor-side handling is `editor_paste_accumulate` /
`editor_paste_commit` in `src/editor.odin`.

## Build-time options

`build.sh` compiles the impl with `-DTB_OPT_EGC`. This turns on termbox2's
extended-grapheme-cluster cells (`tb_extend_cell`, the `ech`/`nech` cell fields,
and `tb_cluster_width` in `present`), which qed's renderer relies on to draw a
multi-rune grapheme (combining marks, ZWJ emoji, regional-indicator flags) as a
single cell. Without it those clusters would render as their base rune only.
This is a compile flag, not a source edit, so re-vendoring keeps it — but the
renderer in `src/editor.odin` assumes it is on.

## Split escape sequence completion

A single `read()` (64-byte buffer) under rapid input — notably mouse-wheel
scrolling, which streams SGR sequences `ESC[<Cb;Cx;Cy(M|m)` back to back — can
end exactly on the `ESC` that starts the next sequence. That leaves a lone `ESC`
in the input buffer. In `TB_INPUT_ESC` mode `extract_event` treats a lone `ESC`
as the Esc key, so it emitted a bogus Esc and the sequence's tail
(`<Cb;Cx;Cy…`) parsed as individual literal keystrokes — leaking into whatever
had focus (e.g. the file-tree filter box).

`esc_pull_pending` (called from `extract_event` before the lone-ESC path) does a
non-blocking `select`+`read` of any bytes already queued on the fd and appends
them to the input buffer, so the sequence completes and termbox's own parser
handles it as a real mouse/CSI/SS3 event. If nothing is queued (a genuine Esc
press), the buffer stays a lone `ESC` and the Esc key is emitted as before, with
no added latency.

## Cluster width and stale-cell-proof present

termbox only re-sends cells whose content changed. When the terminal draws a
cluster at a different width than termbox's model, the following text lands in
the wrong columns and, once the content changes (buffer switch, overlay close),
cells termbox believes unchanged keep stale glyphs. Upstream measured a cluster
as the widest of its codepoints, so a Devanagari vowel sign or conjunct
(`ना`, `क्षे`) counted 1 while tmux, which does not cluster, draws one column per
spacing codepoint.

1. **`tb_cluster_width` is public and sums.** A non-emoji cluster spans the sum
   of its codepoint widths (non-printables count 1, since they go out as
   U+FFFD); VS15 makes it 1; VS16, a regional-indicator pair, or any wide
   codepoint (emoji + modifier/ZWJ) makes it 2. qed's `cluster_width` calls
   this exact function, so qed's columns and termbox's cells agree by
   construction.

2. **`tb_present` tolerates a terminal that still disagrees** (e.g. tmux draws a
   ZWJ family 4 wide). For each changed cell, with `cell_width` giving the model
   width and the width a codepoint-summing terminal would draw:
   - the cells a wide cluster covers are first written as spaces, so a
     terminal drawing it narrower leaves no old glyph there;
   - a zero-width cluster (lone ZWSP, BOM, combining mark) is sent after a
     space so it fills the one cell counted for it (just the space in the last
     column: libvterm wraps a zero-width char in the pending-wrap state);
   - a cluster a summing terminal would push past the right edge is sent as
     spaces, like upstream does for a wide char without room;
   - when the old or new content has a model or summed width other than 1,
     the cells the terminal could have covered (up to the larger of both widths,
     plus one) are invalidated in the front buffer so they are resent in the
     same pass, and the next send repositions the cursor explicitly.

   The extra output is limited to changed cells holding non-trivial clusters.

Autowrap (DECAWM) is deliberately left on: tmux 3.4 drops a combining mark that
follows a VS16 wide char (`1️⃣`) when autowrap is off.

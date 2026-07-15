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

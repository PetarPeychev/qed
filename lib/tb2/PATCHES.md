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

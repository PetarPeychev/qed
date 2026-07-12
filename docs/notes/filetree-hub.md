# File tree as the file/buffer hub

Direction (1.0-gated): the file tree (`Alt+f`) becomes the single place for
finding and managing files and buffers. The standalone fuzzy file-open (`Ctrl+O`)
and buffer switcher (`Ctrl+E`) panes are **folded into it and removed** — their
chords reopen the tree in the right mode instead. One hub, fewer overlays.

Decisions locked with Petar:

- **Replace, don't duplicate.** When a capability lands in the tree, the
  standalone pane goes away; `Ctrl+O`/`Ctrl+E` become entry points into the tree.
  No parallel panes left for muscle memory.
- **1.0 gate.** Part of the daily-driver baseline; blocks `v1.0.0`.
- **Scope for 1.0:** two capabilities move in — (1) **fuzzy filter in-tree** (the
  `Ctrl+O` file-open behavior: type to fuzzy-match the tree), and (2) **buffer
  switching in the `Open` tab** (the `Ctrl+E` behavior: the Open scope tab acts as
  the switcher — recency order, digit instant-jump on empty query, batch close via
  the existing multi-select). Project search and line/symbol jump are **out** of
  this theme (stay their own panes for now).

Already in place to build on: the `Open`/`Git`/`Unsaved`/`All` scope tabs, the
right-side preview, keyboard multi-select (Shift+Arrow) with batch delete/open,
and copy/cut/paste. The switcher's current features to preserve when folding in:
stable open-buffer order, digit instant-jump, side preview of in-memory content
centered on the buffer's cursor.

Open questions (resolve when building):
- How the fuzzy filter and the tree's expand/collapse coexist (filter flattens to
  matches vs. prunes the tree like the scope tabs do).
- Whether `Ctrl+E` lands on the `Open` tab with the query focused, and whether
  batch-close reuses the delete dialog's confirm shape.

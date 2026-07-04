# qed — TODO

The working task list — open items only. **Hard rule: one line per item.** State
the task, not how to do it; if it needs more than a line, the detail goes in a
`notes/*` file and the item links to it — never expand it here. Workflow and
close-out are in [../CLAUDE.md](../CLAUDE.md); architecture in [DESIGN.md](DESIGN.md).
A finished task is **deleted** (not ticked), its capability landing in DESIGN.md's
Shipped list. Groups are priority buckets, not a build order.

## Bugs

_(none open)_

## Features

- [ ] In-buffer find, then find & replace (`Ctrl+F`; `Alt+n`/`Alt+m` prev/next; incremental, wrap, highlight).
- [ ] Configurable indent width + auto-detect from the file (like tabs-vs-spaces).
- [ ] Central language detection: one extension → `Language` table driving comment token, grammar, LSP.
- [ ] Open-buffer switcher: fuzzy picker over currently-open buffers (binding TBD, e.g. `Alt+b`).
- [ ] File-tree pane over the working root.

## Syntax highlighting (tree-sitter)

- [ ] Query predicate evaluator (`#match?`/`#eq?`/…) so upstream `.scm` work unstripped.
- [ ] Dynamic grammar loading via `dlopen` (exploration — tension with vendored/no-plugins).

## LSP capabilities

- [ ] Inline diagnostic virtual text (dimmed end-of-line message).
- [ ] Go-to-definition.
- [ ] Find references (floating pane / picker).
- [ ] Rename symbol (workspace-wide, from the prompt).
- [ ] Hover (type/docs popup on a key).
- [ ] Completion dropdown (floating pane, incremental).
- [ ] Symbol search (fuzzy document/workspace symbols).
- [ ] Signature help (later).
- [ ] Inlay hints (later).
- [ ] LSP restart command (a crashed server currently stays down for the session).

## Git diff gutter

- [ ] Hunk navigation (next/prev change).
- [ ] Hunk preview + revert.
- [ ] Stage / unstage hunks (later).
- [ ] Idea: reuse the gutter to mark lines changed since last save (buffer vs disk).

## Polish

- [ ] Context-filter the command list (hide commands that don't apply, e.g. on welcome screen).
- [ ] Picker mouse support (click row, wheel scroll).
- [ ] Colored file preview (parse `bat --color=always` ANSI into pane cells).
- [ ] Per-buffer viewport memory across buffer switches.
- [ ] Permission/ownership-preserving saves.
- [ ] Coalesce feedback-only work off the per-keystroke path (`buffer_recompute_modified`, sub-cutoff git gutter) — see [notes/perf.md](notes/perf.md).
- [ ] Cheaper cold `git_gutter_update` + `buffer_open` per-line-allocation floor before first paint — see [notes/perf.md](notes/perf.md).

# qed — TODO

The working task list — open items only. **Hard rule: one line per item.** State
the task, not how to do it; if it needs more than a line, the detail goes in a
`notes/*` file and the item links to it — never expand it here. Workflow and
close-out are in [../CLAUDE.md](../CLAUDE.md); architecture in [DESIGN.md](DESIGN.md).
A finished task is **deleted** (not ticked), its capability landing in DESIGN.md's
Shipped list. Groups are priority buckets, not a build order.

## Bugs

## Features

- [ ] Status bar: show git branch + ahead/behind (watch the one-line budget — may need abbreviating).
- [ ] Go-to-line-number (`:42`-style exact jump, distinct from `Ctrl+F` content search).
- [ ] Save all modified buffers in one command.
- [ ] Whole-line copy/cut on empty selection: `Ctrl+C` copies the line, `Ctrl+X` cuts it (= delete line).
- [ ] Sticky scroll: pin the enclosing scope header (function/block) at the top while scrolled — tree-sitter tree.
- [ ] Command palette: order entries by recency of use, persisted cross-session (needs a small state file).
- [ ] Cross-session state (provisional — design TBD): a persisted state file (`~/.local/state/qed/`?) that could back restore-last-session buffers/viewport, palette MRU, etc. Figure out scope + format before building.
- [ ] File browser: show more detail per entry (size, line count, other `ls -l`-style bits).

## AI / LLM assist

See [notes/ai.md](notes/ai.md) for the two-backend architecture and config schema.

- [ ] Context + prompt: floating prompt pane, cursor-context aware, insert/replace.
- [ ] Let an AI edit touch code outside the selection (add a missing import etc.) — whole-file rewrite or agentic mode; `Ctrl+K` today is selection-replace only.
- [ ] `llm` config section: independent `completion` (FIM) and `chat` providers, each a shell command or named HTTP provider (provider-neutral).
- [ ] Shared inline virtual-text primitive (ghost-text + inline diagnostics).

## Syntax highlighting (tree-sitter)

- [ ] Markdown: better visual distinction between headers and bold text.
- [ ] Query predicate evaluator (`#match?`/`#eq?`/…) so upstream `.scm` work unstripped.
- [ ] Dynamic grammar loading via `dlopen` (exploration — tension with vendored/no-plugins).

## LSP capabilities

- [ ] Inline diagnostic virtual text (dimmed end-of-line message).
- [ ] Code actions / quick-fix (`textDocument/codeAction`) — esp. auto-import for TS/React.
- [ ] Find references (floating pane / picker).
- [ ] Completion: interactive snippet placeholder navigation (Tab through `$1`/`$2`) + `completionItem/resolve` for lazy detail/edits.
- [ ] Symbol search (fuzzy document/workspace symbols).
- [ ] Signature help (later).
- [ ] Inlay hints (later).

## Git diff gutter

- [ ] Hunk navigation (next/prev change).
- [ ] Hunk preview + revert.
- [ ] Stage / unstage hunks (later).
- [ ] Idea: reuse the gutter to mark lines changed since last save (buffer vs disk).

## Polish

- [ ] Unsaved/modified indicators in panes with file lists where missing (buffer switcher, file tree, …).
- [ ] Color file names in list panes with git status colors.
- [ ] File tree: mark the active buffer's entry (like the buffer switcher marks `current`).
- [ ] Unify preview panes (file-open, file-tree, project-search): consistent empty/binary placeholder.
- [ ] List panes: scroll affordance (count / thumb) when scrolled past the visible rows.
- [ ] Context-filter the command list (hide commands that don't apply, e.g. on welcome screen).
- [ ] Terminal copy/paste: drag-select + copy-out (auto-copy on drag-release; Ctrl+C stays SIGINT) + paste into the PTY (Ctrl+V / host bracketed paste).
- [ ] Per-buffer viewport memory across buffer switches.
- [ ] Permission/ownership-preserving saves.
- [ ] Coalesce feedback-only work off the per-keystroke path (`buffer_recompute_modified`, sub-cutoff git gutter) — see [notes/perf.md](notes/perf.md).
- [ ] Cheaper cold `git_gutter_update` + `buffer_open` per-line-allocation floor before first paint — see [notes/perf.md](notes/perf.md).

# qed — TODO

The working task list — open items only. **Hard rule: one line per item.** State
the task, not how to do it; if it needs more than a line, the detail goes in a
`notes/*` file and the item links to it — never expand it here. Workflow and
close-out are in [../CLAUDE.md](../CLAUDE.md); architecture in [DESIGN.md](DESIGN.md).
A finished task is **deleted** (not ticked), its capability landing in DESIGN.md's
Shipped list. Groups are priority buckets, not a build order.

## Bugs

## Features

- [ ] Auto-close pairs: `()[]{}`/quotes/backtick, surround selection, auto-close + rename JSX tags.
- [ ] Bracket/colon-aware auto-indent on Enter; dedent on closing `}`.
- [ ] Highlight the bracket matching the one at the cursor.
- [ ] Configurable indent width + auto-detect from the file (like tabs-vs-spaces).

## AI / LLM assist

See [notes/ai.md](notes/ai.md) for the two-backend architecture and config schema.

- [ ] Inline FIM completion: async debounced ghost-text, Tab/word accept, `Esc` dismiss (default backend Codestral).
- [ ] Selection + prompt (`Ctrl+K`): replace selection via chat backend, one undo group.
- [ ] Context + prompt: floating prompt pane, cursor-context aware, insert/replace.
- [ ] `llm` config section: independent `completion` (FIM) and `chat` providers, each a shell command or named HTTP provider (provider-neutral).
- [ ] Async subprocess runner with cancellation (generalize `lsp.odin` machinery; `curl` subprocess for HTTP providers).
- [ ] Shared inline virtual-text primitive (ghost-text + inline diagnostics).

## Syntax highlighting (tree-sitter)

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

- [ ] Context-filter the command list (hide commands that don't apply, e.g. on welcome screen).
- [ ] Picker mouse support (click row, wheel scroll).
- [ ] Per-buffer viewport memory across buffer switches.
- [ ] Permission/ownership-preserving saves.
- [ ] Coalesce feedback-only work off the per-keystroke path (`buffer_recompute_modified`, sub-cutoff git gutter) — see [notes/perf.md](notes/perf.md).
- [ ] Cheaper cold `git_gutter_update` + `buffer_open` per-line-allocation floor before first paint — see [notes/perf.md](notes/perf.md).

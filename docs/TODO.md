# qed — TODO

The working task list — open items only. **Hard rule: one line per item.** State
the task, not how to do it; if it needs more than a line, the detail goes in a
`notes/*` file and the item links to it — never expand it here. Workflow and
close-out are in [../CLAUDE.md](../CLAUDE.md); architecture in [DESIGN.md](DESIGN.md).
A finished task is **deleted** (not ticked), its capability landing in DESIGN.md's
Shipped list.

Organized around the road to **v1.0**. The top section is the release gate —
everything there blocks 1.0; when it all clears, tag `v1.0.0`. Below it is
deferred and standing work. Within a section, order is priority, not build order.

## Road to 1.0

**v1.0 = a stranger downloads the binary, configures it for their workflow, and
daily-drives it for programming.** Every item here blocks that.

### Language coverage

- [ ] Documented add-a-language path: config-driven LSP/formatter for any language + how highlight is wired (bundled-grammar mechanism). Full runtime grammars are post-1.0.

### LSP

- [ ] Inline diagnostic virtual text (dimmed end-of-line message).
- [ ] Code actions / quick-fix (`textDocument/codeAction`) — esp. auto-import for TS/React.
- [ ] Find references (floating pane / picker).
- [ ] Completion: interactive snippet placeholder navigation (Tab through `$1`/`$2`) + `completionItem/resolve` for lazy detail/edits.
- [ ] Symbol search (fuzzy document/workspace symbols).
- [ ] Signature help.
- [ ] Inlay hints.

### Robustness — won't eat my work

- [ ] Crash safety: a panic restores the terminal and never loses unsaved buffers (recovery/backup on abnormal exit).
- [ ] Autosave: automatic saving of modified buffers (idle/periodic; knob).

### Environment

- [ ] Wider terminal support / environment-agnostic hardening: keybinds must survive macOS terminals, tmux vs non-tmux, and other emulator quirks.

### File/buffer hub — fold panes into the file tree

Direction + locked decisions: [notes/filetree-hub.md](notes/filetree-hub.md). Sequenced phases (each ships + is verified on its own):

- [ ] Phase 4 — search in selection: path-scope `projsearch`, `/` command runs it over the selection (`Ctrl+A` first for a whole tab); standalone `Alt+F` stays whole-project.
- [ ] File-tree filter perf: `filetree_apply_filter`/`filetree_collect` re-walk the whole working tree from disk (`read_directory_by_path`) on every keystroke — cache the candidate list per filter session (invalidate on scope/toggle/refresh) and re-rank only.

### Docs & onboarding

- [ ] README: solid hook + feature list, sexy screenshots, install + 60-second quickstart.
- [ ] Config reference: every knob documented in one place.
- [ ] Dependencies guide in the install docs: per-language LSP/formatter (ols, pyright, clangd, …) plus the other external tools (rg, clipboard, git, …). (In-editor keybind discovery is already done — the palette lists every command with its shortcut.)
- [ ] In-editor help: discoverable help screen/pane beyond the palette's keybind listing.

## 1.0 polish — clear the known rough edges

- [ ] File tree: bulk rename over a multi-selection (pattern / sequential, applied as one batch).
- [ ] File tree: bulk close — close every selected buffer's row (ties into the `Open`-tab buffer-switcher fold-in, [notes/filetree-hub.md](notes/filetree-hub.md)).
- [ ] Color file names in list panes with git status colors.
- [ ] Terminal→editor cwd back-channel: handle OSC 7 from the PTY (shell reports cwd) so `Alt+t` can retarget qed's working root — VSCode's shell-integration model; env vars stay uncrossable.
- [ ] Per-buffer viewport memory across buffer switches — move scroll state into `Buffer`, see [notes/refactors.md](notes/refactors.md).
- [ ] Permission/ownership-preserving saves.
- [ ] Coalesce feedback-only work off the per-keystroke path (`buffer_recompute_modified` → save watermark, git gutter → debounce) — see [notes/refactors.md](notes/refactors.md) + [notes/perf.md](notes/perf.md).
- [ ] Cheaper cold `git_gutter_update` + `buffer_open` per-line-allocation floor before first paint — see [notes/perf.md](notes/perf.md).
- [ ] `subprocess_output` can block the main loop up to 1s in `process_wait` after stdout EOF — reap non-blocking.

## Post-1.0 — deferred

Enhancements beyond the daily-driver baseline; none blocks 1.0.

### Features

- [ ] Multi-line find (regex `\n` spanning rows) — current find is single-line, matching the per-line data model; needs whole-buffer scan + cross-row match/highlight.
- [ ] Save all modified buffers in one command.
- [ ] Sticky scroll: pin the enclosing scope header (function/block) at the top while scrolled — tree-sitter tree.
- [ ] Command palette: order entries by recency of use, persisted cross-session (needs a small state file).
- [ ] Cross-session state (provisional — design TBD): a persisted state file (`~/.local/state/qed/`?) that could back restore-last-session buffers/viewport, persisted undo history, palette MRU, etc. Figure out scope + format before building.
- [ ] Hex view/edit for binary files.
- [ ] Markdown viewer (rendered preview).
- [ ] File browser: show more detail per entry (size, line count, other `ls -l`-style bits).
- [ ] Pane swap (NOT FINALISED — design unsure): opening a nav pane's chord while another nav pane is open closes the current + opens the target (1 fewer key, no Esc first); intercept at the `editor_dispatch` choke point, sources = nav panes only (exclude terminal/rename/aiedit/dialogs). Open question: is bisecting behaviour this way (some panes swap, some don't) actually good design?

### AI / LLM assist

See [notes/ai.md](notes/ai.md) for the two-backend architecture and config schema.

- [ ] Context + prompt: floating prompt pane, cursor-context aware, insert/replace.
- [ ] Let an AI edit touch code outside the selection (add a missing import etc.) — whole-file rewrite or agentic mode; `Ctrl+K` today is selection-replace only.
- [ ] `llm` config section: independent `completion` (FIM) and `chat` providers, each a shell command or named HTTP provider (provider-neutral).
- [ ] Shared inline virtual-text primitive (ghost-text + inline diagnostics) — unify with git ghost rows first, see [notes/refactors.md](notes/refactors.md).

### Syntax highlighting (tree-sitter)

- [ ] Markdown: better visual distinction between headers and bold text.

### Language architecture endgame

Decided direction + sequence: [notes/languages.md](notes/languages.md). The
runtime-grammar arc that lets a stranger add *any* language with zero rebuild —
1.0 ships the bundled set instead. In order:

- [ ] Language registry: replace the `Language` enum with a runtime table; hardcoded per-language behaviors (Python colon-indent, injection wiring, fenced-block aliases) become table fields.
- [ ] Runtime dir for queries + language metadata as files, compiled-in fallback for the core set.
- [ ] Grammar lock-file build fetch — vendored parser.c out of the repo, build pulls by pinned commit + sha.
- [ ] Runtime grammar loading via `dlopen` for user-added tail languages (core set stays compiled in).

### Git diff gutter

- [ ] Git diff viewer (design TBD): a pane showing the full diff, beyond the gutter marks.
- [ ] Hunk navigation (next/prev change).
- [ ] Hunk preview + revert.
- [ ] Stage / unstage hunks (later).
- [ ] Idea: reuse the gutter to mark lines changed since last save (buffer vs disk).

## Standing work — not 1.0-gated

Internal health; land opportunistically. Details: [notes/refactors.md](notes/refactors.md), [notes/perf.md](notes/perf.md).

### Performance

- [ ] Cap `bracket_match` scan range — an unmatched bracket scans to EOF/BOF every frame.
- [ ] Cache `llm_locate` per (path, rev) — an in-flight AI edit rebuilds + searches the whole buffer every render.
- [ ] Cache `merge_scan`/`merge_word_map` per buffer rev — currently re-run every render.
- [ ] Migrate interactive-path blocking spawns (`format_external`, projsearch `rg`, picker `fzf`, preview `head`, `git show`) to the async subprocess runner.
- [ ] Per-frame `line_wrap` memo — measure first, only if profiling shows wrap cost.

### Refactors

- [ ] Keybind-name consistency pass: every shortcut hint/label is config-driven and uses the exact configured key string — casing matters (`Ctrl+F` ≠ `Ctrl+f`); audit for hardcoded/mis-cased bind text across the editor.
- [ ] Collapse the four dialogs (quit/close/conflict/merge) into one `Dialog` primitive.
- [ ] Collapse the centered pickers (palette/langpick/indentpick) + shared two-pane picker key dispatch.
- [ ] Unify the file-tree and Message Log (`Alt+l`) panes under one generic selectable-list model — fuzzy filter/search, scoped `Ctrl+P` command palette, shared multi-select + filter toggles (the file-tree hub model applied to the log pane).
- [ ] `buffer_intel_reset` choke point for the language-change / repath / reload teardown dance.

### E2E test coverage

- [ ] FIM ghost × LSP completion-popup precedence — needs the FIM stub and the fake LSP wired into one session.

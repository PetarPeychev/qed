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

### Docs & onboarding

- [ ] In-editor help: discoverable help screen/pane beyond the palette's keybind listing.

## 1.0 polish — clear the known rough edges

- [ ] File tree: bulk rename over a multi-selection (pattern / sequential, applied as one batch).
- [ ] Color file names in list panes with git status colors.
- [ ] Terminal→editor cwd back-channel: handle OSC 7 from the PTY (shell reports cwd) so `Alt+t` can retarget qed's working root — VSCode's shell-integration model; env vars stay uncrossable.
- [ ] Per-buffer viewport memory across buffer switches — move scroll state into `Buffer`, see [notes/refactors.md](notes/refactors.md).
- [ ] Permission/ownership-preserving saves.
- [ ] Coalesce feedback-only work off the per-keystroke path (`buffer_recompute_modified` → save watermark, git gutter → debounce) — see [notes/refactors.md](notes/refactors.md) + [notes/perf.md](notes/perf.md).
- [ ] Cheaper cold `git_gutter_update` + `buffer_open` per-line-allocation floor before first paint — see [notes/perf.md](notes/perf.md).
- [ ] `subprocess_output` can block the main loop up to 1s in `process_wait` after stdout EOF — reap non-blocking.
- [ ] config.json writer that preserves comments and key order (UI persistence strips them today).

## Plugin system

Lua 5.4 plugins, built in phases. Scope of each phase: [notes/plugins.md](notes/plugins.md) §8.

- [ ] Phase 0: vendored Lua, plugin loader, `qed.log/message/command/run`, dynamic commands, minimal Plugins pane.
- [ ] Phase 1: `Buffer.id`, `qed.buf.*`, `qed.edit`, `qed.goto`, fs/json/path/config/opt, type stub + lua-ls settings.
- [ ] Phase 2: coroutine scheduler, `spawn`/`spawn_bg`, timers, `plugin_pump`, budgets, events with hook timeouts, `test.lua` runner.
- [ ] Phase 3: port `format` to a bundled plugin, delete the Odin formatter path.
- [ ] Phase 4: `pick`/`prompt`/`confirm`/`pane`, port the pickers.
- [ ] Phase 5: `commands` plugin (dropped in phase 10), file-tree `ctx.file/files`.
- [ ] Phase 6: hot reload, live enable/disable, full Plugins pane.
- [ ] Phase 7: N terminal sessions, `qed.term`, `tasks` plugin.
- [ ] Phase 8: decoration store, `status.set`, diff-base primitive.
- [ ] Phase 9: port `git`, `modules.git` becomes `plugins.git`.
- [ ] Phase 10: drop the `commands` plugin, add `qed.parse_locations`.
- [ ] Phase 11: file tree status provider (`qed.filetree`), Git tab moves to the `git` plugin, `.Git` module gone.
- [ ] Phase 12: query-driven `qed.pick` (`query`, `on_query`, `picker:set`), project search moves to the `search` plugin.
- [ ] Phase 13: `qed.meta` display names, automatic command prefix, `plugins.<id>.keybinds`, message attribution, Lua settings scoped to the config dir, `modules.lsp` becomes `lsp`, `pickers` becomes `settings`, `tasks` dropped.
- [ ] Pane model M0: Odin `Pane` + stack + kinds; quit/close/conflict/merge dialogs and `qed.confirm`/`qed.prompt` on it ([notes/panes.md](notes/panes.md) §7).
- [ ] Pane model M1: `qed.ui.open` (center/full/split, filter/query/input fields, set/append/update), queued events, exclusive panes persisted by `id`, `qed.pick/prompt/confirm/pane` as prelude sugar, `search` streams into a query pane ([notes/panes.md](notes/panes.md) §7).
- [ ] Pane model M2: palette core-built on a commands list source, core list handles (`qed.fs.dirs`), `path` field, `qed.set_root`, the working-root picker becomes the `workspace` plugin ([notes/panes.md](notes/panes.md) §7).
- [ ] Low priority: review every bundled plugin's config keys for naming and sense.

## Post-1.0 — deferred

Enhancements beyond the daily-driver baseline; none blocks 1.0.

### Features

- [ ] Discontinuous file-tree selection (pick non-adjacent files for a command) — deferred: mouse Ctrl/Shift-click is blocked (vendored termbox2 drops mouse modifier bits — patchable — and Windows Terminal itself eats Ctrl/Shift-click), so it needs a keyboard mark key (e.g. Insert toggles the current row) and/or the termbox mouse-mod patch; sound data model is a path-keyed selection set + prune-to-visible on rebuild.
- [ ] Multi-line find (regex `\n` spanning rows) — current find is single-line, matching the per-line data model; needs whole-buffer scan + cross-row match/highlight.
- [ ] Save all modified buffers in one command.
- [ ] Settings-menu plugin: every option with its current value, editable in place (needs per-option description/type in `qed.options`).
- [ ] Sticky scroll: pin the enclosing scope header (function/block) at the top while scrolled — tree-sitter tree.
- [ ] Command palette: order entries by recency of use, persisted cross-session (needs a small state file).
- [ ] Cross-session state (provisional — design TBD): a persisted state file (`~/.local/state/qed/`?) that could back restore-last-session buffers/viewport, persisted undo history, palette MRU, etc. Figure out scope + format before building.
- [ ] Hex view/edit for binary files.
- [ ] File browser: show more detail per entry (size, line count, other `ls -l`-style bits).

### AI / LLM assist

See [notes/ai.md](notes/ai.md) for the two-backend architecture and config schema.

- [ ] Context + prompt: floating prompt pane, cursor-context aware, insert/replace.
- [ ] Let an AI edit touch code outside the selection (add a missing import etc.) — whole-file rewrite or agentic mode; `Ctrl+K` today is selection-replace only.
- [ ] `modules.ai` config: independent `completion` (FIM) and `chat` providers, each a shell command or named HTTP provider (provider-neutral).
- [ ] Shared inline virtual-text primitive (ghost-text + inline diagnostics) — unify with git ghost rows first, see [notes/refactors.md](notes/refactors.md).

### Syntax highlighting (tree-sitter)


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
- [ ] Stage / unstage hunks (later).
- [ ] Idea: reuse the gutter to mark lines changed since last save (buffer vs disk).

## Standing work — not 1.0-gated

Internal health; land opportunistically. Details: [notes/refactors.md](notes/refactors.md), [notes/perf.md](notes/perf.md).

### Performance

- [ ] Cap `bracket_match` scan range — an unmatched bracket scans to EOF/BOF every frame.
- [ ] Cache `llm_locate` per (path, rev) — an in-flight AI edit rebuilds + searches the whole buffer every render.
- [ ] Cache `merge_scan`/`merge_word_map` per buffer rev — currently re-run every render.
- [ ] Migrate remaining interactive-path blocking spawns (`format_external`, `git show`) to the async subprocess runner.
- [ ] Per-frame `line_wrap` memo — measure first, only if profiling shows wrap cost.

### Refactors

- [ ] Unify the file-tree and Message Log (`Alt+l`) panes under one generic selectable-list model — fuzzy filter/search, scoped `Ctrl+P` command palette, shared multi-select + filter toggles (the file-tree hub model applied to the log pane).
- [ ] `buffer_intel_reset` choke point for the language-change / repath / reload teardown dance.

### E2E test coverage

- [ ] FIM ghost × LSP completion-popup coexistence e2e — needs the FIM stub and the fake LSP wired into one session (assert both render, `Tab` accepts ghost, `Enter` the menu).

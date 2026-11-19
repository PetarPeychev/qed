# Note: plugin system (Lua 5.4)

Design for a plugin system. Status: decided. Build phases are tracked in TODO.md.

## 1. Goals / non-goals

Goals
- Make core pieces solid by moving glue builtins (spawn a tool, pick from a list, call a core setter) into bundled Lua.
- Ship custom user commands and long-running tasks as plugins, not core features.
- Async without threads: Lua coroutines on the main loop, so `qed.pick`, `qed.spawn` and `qed.sleep` read as straight-line code.
- A failing plugin never crashes or freezes qed, and it is visible in the Plugins pane.
- Completion when editing plugins in qed, for bundled and user plugins alike.

Non-goals
- Project-local plugins, sandboxing, trust prompts. Plugins are global and written by Petar.
- Lua on any render path or on the raw per-keystroke path.
- A package manager, a versioned API, backwards compatibility.
- Moving LSP, tree-sitter, the file tree, PTY/vterm into Lua.
- Threads in Lua, or more than one Lua state.

## 2. Core vs plugin boundary

These stay in Odin:
- The text model, edit primitives and undo, all per keystroke.
- Rendering (full redraw on every event). Lua is never called from it.
- Input decoding (Alt-Esc retag, bracketed paste).
- Tree-sitter (incremental parse on a thread).
- LSP (`didChange` on every edit, UTF-16 conversion).
- Anything that owns threads or file descriptors (parallel file-tree walk, PTY, vterm).

Plugins **push** state (status text, decorations, diff-base text) and core caches
it for rendering.

In the KS column, KS means the code runs per keystroke or per render today.

| Subsystem (file) | KS | Verdict | API it needs / reason |
|---|---|---|---|
| buffer/edit/undo/cursor/wrap/pairs | KS | core | Exposed as `qed.buf` and `qed.edit`. |
| rendering, status layout, gutter | KS | core | Plugins push segments and decorations. |
| highlight/predicate/inspect | KS | core | Threads, FFI, per-edit reparse. |
| textfield/overlay/fuzzy/pane/preview/confirm widgets | KS | core | Exposed as `qed.pick`, `prompt`, `confirm`, `pane`. |
| palette + keybind dispatch | KS | core | Gains a dynamic plugin-command list. |
| find/replace, linefind, jump, cwdpick | | core | Interactive per keystroke. Porting gains nothing. |
| quit/close/disk-conflict dialogs | | core | Safety of unsaved work. |
| log | | core | `qed.log`, `qed.message`. |
| clipboard | | core | `qed.clipboard`. |
| terminal | KS (pump) | core, generalized | One `Terminal` becomes N named sessions behind `qed.term`. Alt+t is the default session. |
| lsp/completion/rename/hover/mdrender | KS | core | `qed.lsp.format(b)` (awaitable) for the formatter fallback. |
| `format.odin` external formatter + save fixups | | **plugin** (port 1) | `spawn`, `buf_pre_save`, `buf.set_text` with rev guard, plugin config. |
| langpick / themepick / indentpick | | **plugin** (port 2) | `pick{on_change}`, `buf.set_language`, `theme.set`, `buf.set_indent`. Closes the "collapse centered pickers" TODO. |
| basepick | | **plugin** (with git) | `pick`, `spawn`. |
| git: base blob fetch, stat poll (branch, ahead/behind, diff size), base picker, restore file | (poll) | **plugin** (port 3) | `spawn`, `every`, `status.set`, `buf.set_base`, events. |
| git: line-hash + Myers gutter diff, ghost rows, word spans, next/prev change, revert hunk | KS (`git_recompute` per rev) | core, renamed **diff base** | The plugin sets base text, and core diffs and renders. "Changed since save" becomes a few lines of Lua. |
| file tree Git tab + status bars | | later | Needs a `qed.filetree.set_status(map)` provider. Until then it stays core, gated on `plugins.git.enabled`. |
| conflict.odin | KS (per render) | later | Needs tints, spans, `confirm`. |
| projsearch | | later | Needs a streaming list+preview picker. |
| llm / aiedit | KS (relocate per render) | later | `prompt`, `spawn`, range-anchored tints. |
| fim | KS (debounce) | later, last | Inline ghost decoration + `buf_changed`. |
| module.odin | | replaced | `modules.git` becomes `plugins.git`. `modules.lsp` and `modules.ai` stay until ported. |
| **custom commands** | | **new plugin** | `command{when}`, `spawn`, `term`, location `pick`, `pane`. |
| **tasks** | | **new plugin** | `qed.term`, `pick`, `status.set`, `term_exit`. |
| **Plugins pane** | | core | Must work when the plugin system itself is broken. |

The API forces these core changes:
- `Buffer.id: u64`, so handles survive reallocation of `[]Buffer`.
- `commands` becomes a fixed builtin array plus a `[dynamic]Command`.
  - `Command` gains `ref` (a Lua registry ref) and `owner`.
  - Dispatch calls `command_run(editor, cmd)`.
- `Terminal` becomes `[dynamic]Terminal` with a name, cmd, cwd, env and exit state. `term_pump` drains them all.
- A per-buffer decoration store, namespaced. Row anchors shift on line insert/delete inside the primitives.
- `subprocess.odin` captures stderr, reaps without blocking (existing TODO) and gets handle ids.
- `buf.set_text` applies a minimal line diff (reusing `git_myers`).

## 3. API

The API is one global, `qed`.
- Buffer arguments: `b` is a buffer id. `nil` or `0` means the current buffer.
- ⏳ marks a call that yields. Every entry point runs in a coroutine, so yielding is always legal.

### Indexing
- Rows and columns are **1-based**, and columns are **byte** offsets, so `line:find("x")` plugs straight in.
- `col = #line + 1` is the caret at the end of the line.
- Ranges are half-open: `{from, to}`, with `to` after the last byte, so `line:sub(from.col, to.col - 1)` is the text.
- Positions are `{row, col}` (`qed.Pos` in the stub).
- `qed.text.width(s)` gives display width.
- The binding is the only place that converts to core's 0-based coordinates.

### Buffers, cursor, edits
| Function | Notes |
|---|---|
| `qed.buf.current() -> b`, `qed.buf.list() -> b[]` | |
| `qed.buf.valid(b) -> bool` | Any other call on a closed buffer raises `buffer closed`. |
| `qed.buf.path(b)`, `.language(b)`, `.modified(b)`, `.rev(b)`, `.line_count(b)` | `rev` is the version used for await safety. |
| `qed.buf.lines(b, from?, to?) -> string[]`, `.line(b, row)`, `.text(b)` | Bulk copies. No per-line FFI loops. |
| `qed.buf.insert(b, pos, text) -> pos`, `.delete(b, from, to) -> string`, `.replace(b, from, to, text)` | Wrappers over the primitives. |
| `qed.buf.set_text(b, text, {rev?}) -> bool` | Minimal-diff whole replace. Returns false if `rev` is stale. |
| `qed.edit(b, fn, {rev?}) -> bool` | Everything inside `fn` is one undo group. `fn` must not yield. |
| `qed.buf.cursor(b) -> pos`, `.set_cursor(b, pos)` | |
| `qed.buf.selection(b) -> from, to \| nil`, `.set_selection(b, anchor, cursor)` | |
| `qed.buf.set_language(b, name) -> changed`, `.set_indent(b, "tabs"\|"spaces"\|"auto", width?)`, `.indent(b) -> style, width`, `qed.languages()` | Existing core setters. |
| `qed.buf.set_base(b, text \| nil, {label?})` | Diff base: gutter, ghost rows, change navigation, revert hunk. |
| `qed.open(path) -> b`, `qed.save(b)`, `qed.close(b)` | `save` runs the full pipeline, including `buf_pre_save`. |
| `qed.jump(b, pos)` | Switch, reveal, record in the jump list. (`goto` is a Lua keyword.) |

### Commands and keybinds
| Function | Notes |
|---|---|
| `qed.command{name, run, when?, key?, welcome?, scope?} -> handle` | `handle:remove()` unregisters. A name is unique per scope: the same name may be one editor and one file-tree command; `qed.run` picks the editor one, and `keybinds[name]` binds both. `run(ctx)` runs in a coroutine and `when(ctx)` gates the palette and the chord. `key` is the default, and config `keybinds[name]` overrides it. `scope = "filetree"` puts the command in the tree palette. `welcome = true` also offers it on the welcome screen. |
| `qed.run(name)` | Run any builtin or plugin command. |
| `qed.commands() -> {name, shortcut, owner}[]` | |
| `ctx` | `{buf, path, language, root, selection_text, base}`, plus for `scope = "filetree"`: `file` (entry under the cursor) and `files` (all selected paths, in tree order). |

### Events
`qed.on(event, fn) -> handle`, removed with `handle:off()`.
- Handlers run as coroutines, in plugin load order.
- A coalesced event fires at most once per main-loop iteration, after dispatch.

| Event | Args | Core waits |
|---|---|---|
| `startup` | | |
| `buf_open`, `buf_close`, `buf_enter` | `b` | |
| `buf_pre_save` | `b` | **yes**, bounded by `plugin_hook_timeout_ms`. On timeout the save proceeds, logging `.Warn` with the slow plugin's name. |
| `buf_save`, `buf_reload` | `b` | |
| `buf_changed` | `b`, `rev` | coalesced |
| `cursor_moved` | `b` | coalesced |
| `language_changed` | `b` | |
| `root_changed` | `old`, `new` | |
| `config_changed`, `theme_changed` | | |
| `term_exit` | `name`, `code` | |
| `quit` | | yes, bounded by `plugin_hook_timeout_ms` |

There is deliberately no `key` event.

### UI
| Function | Notes |
|---|---|
| `qed.message(text, level? \| {level?, source?})`, `qed.log(level, text)` | `source` defaults to the plugin name; `""` is bare. |
| ⏳ `qed.pick{items, prompt?, initial?, multi?, on_change?} -> item \| items[] \| nil` | Items are strings or `{label, detail?, value?, path?, pos?}`. Items with `path` get the core list+preview layout. `multi = true` uses Shift+↑↓ range select (log-pane model) and returns `items[]`. `on_change` is for live preview. `initial` is an item index or label. Esc returns `nil`. |
| ⏳ `qed.prompt{prompt, text?} -> string \| nil` | Shared `TextField`. |
| ⏳ `qed.confirm(question, choices?) -> index \| nil` | Shared `dialog_*`. |
| `qed.pane{title, lines, footer?} -> pane` | Read-only floating pane. `pane:set(lines)` and `pane:close()`. Lines are strings or `{text, color}`. |
| `qed.status.set(id, {text, color?, side?, drop?})`, `qed.status.clear(id)` | Pushed segment, fitted by `status_fit`. |
| `qed.clipboard.get()`, `.set(text)` | |
| `qed.terminal.run(cmd, {cwd?})` | Clears the prompt line, types `cmd` into the terminal pane's shell and shows it; `nil, "terminal busy"` while a program runs there. Superseded by `qed.term` in phase 7. |
| `qed.theme.set(name, {persist?})`, `.list()`, `.current()` | |

- Only one modal wait at a time. If another overlay is open, the call returns `nil, "busy"`.
- Panes that handle keys (custom key handling, actions) come later. The first consumer would be a tasks or locations pane richer than `pick`.

### Terminals (`qed.term`)
Core owns PTY and vterm. Each session has a name.

| Function | Notes |
|---|---|
| `qed.term.create{name, cmd?, cwd?, env?, restart?} -> name` | Starts in the background without showing. `cmd` nil means an interactive shell. Fails if the name is live. |
| `qed.term.show(name)`, `.hide()` | Shows the session in the terminal pane overlay. Alt+t shows `"shell"`, the default session. |
| `qed.term.kill(name)`, `.restart(name)`, `.send(name, text)` | `restart` kills and respawns with the same spec. |
| `qed.term.state(name) -> {running, code?, pid?}`, `qed.term.list()` | |
| `qed.term.close(name)` | Kills the session and frees its scrollback. |

A `term_exit` event fires when a session's process exits. Sessions created by a
plugin die when it unloads, unless they were created with `{detach = true}`.

### Decorations
- Push only, namespaced per plugin: `ns = qed.deco.ns(name)`.
- Colors are theme keys, never hex.
- Row anchors shift with edits, and spans on edited rows drop.

| Function | Notes |
|---|---|
| `qed.deco.gutter(b, ns, row, glyph, color)` | Mark column. |
| `qed.deco.tint(b, ns, from_row, to_row, color, alpha?)` | Goes through the `editor_line_bg` stack. |
| `qed.deco.ghost(b, ns, row, lines, {above?, color?})` | Virtual rows. |
| `qed.deco.span(b, ns, from, to, style)` | `{fg?, bg?, bold?, underline?}` |
| `qed.deco.eol(b, ns, row, text, color)` | Inline virtual text. |
| `qed.deco.clear(b, ns, from_row?, to_row?)` | |

### Processes, timers
| Function | Notes |
|---|---|
| ⏳ `qed.spawn{cmd \| argv, stdin?, cwd?, env?, on_line?} -> {code, stdout, stderr}` | Async on `subprocess.odin`. `cwd` defaults to the root. |
| `qed.spawn_bg{...} -> proc` | `proc:kill()`, ⏳ `proc:wait()`. Killed on unload and on quit. |
| ⏳ `qed.sleep(ms)` | |
| `qed.defer(ms, fn)`, `qed.every(ms, fn) -> timer` | Stop with `timer:stop()`. |

### Files, JSON, paths, config
| Function | Notes |
|---|---|
| `qed.fs.read`, `.write` (atomic), `.exists`, `.stat`, `.list` | Synchronous. |
| `qed.json.decode`, `.encode` | `core:encoding/json` |
| `qed.path.join/dir/base/rel/abs`, `qed.shell_quote` | |
| `qed.root()`, `qed.version` | |
| `qed.config() -> table` | This plugin's merged subtree. Read-only. |
| `qed.opt(key)` | Read-only core knob. |
| ⏳ `qed.lsp.format(b) -> bool` | Core LSP formatting. |

### Type stubs
- `plugins/meta/qed.lua` (`---@meta`) is maintained by hand next to `src/plugin_api.odin`. A unit test fails if a registered `qed.*` function is missing from it.
- The stub is embedded and written to `$XDG_DATA_HOME/qed/lua/qed.lua` whenever its content changes.
- **Completion without `.luarc.json`.** lua-language-server pulls `Lua` settings through `workspace/configuration`, and qed already answers that in `lsp_config_for_section` (it only handles python sections today). Two changes:
  - Add a `"Lua"` case returning `{"runtime":{"version":"Lua 5.4"},"workspace":{"library":["<stub dir>"]},"diagnostics":{"globals":["qed"]}}`.
  - Add the same `"Lua"` object to the post-`initialized` `didChangeConfiguration` push, which is hardcoded to python today.

  Both are keyed on the section name, not the server, so other servers ignore it.
- The library applies to every Lua file, including `~/.config/qed/plugins/` opened from any working root.
- Verify against lua-language-server in isolation before relying on it.

## 4. Lifecycle

| Aspect | Rule |
|---|---|
| Sources | Bundled plugins are in repo `plugins/`, embedded via `#load_directory`. User plugins are in `~/.config/qed/plugins/`. |
| Shape | `name.lua` or `name/init.lua`. `require` resolves only inside the plugin's dir. |
| Spec | Returns `{defaults = {...}, setup = function(cfg) end}`. All registration happens in `setup`. |
| Order | Bundled first, then user, alphabetical within each. A user plugin with a bundled name replaces the bundled one. `startup` fires after all plugins are loaded. |
| Enable | `plugins.<name>.enabled`, default true. Bundled defaults live in the embedded config.json. |
| Config | `plugins.<name>` is a sparse diff over `defaults`. Unknown keys warn once. |
| Ownership | Every registration (command, hook, timer, process, term session, decoration ns, status segment, modal) records its owner. Unloading tears all of it down. |
| Hot reload | Triggers: the disk poll sees a user plugin file added, removed or changed (any file inside a dir plugin), `enabled` flips, or `r` in the Plugins pane. Only that plugin unloads and reloads; a same-name user plugin appearing or disappearing swaps it with the bundled one. Load order stays bundled-then-user, alphabetical. A plugin loaded after startup gets its own `startup` event. |
| Config changes | A changed `plugins.<name>` subtree (other than `enabled`) reaches a plugin that subscribes to `config_changed` through that handler, so its runtime state (e.g. `format`'s toggles) survives. A plugin without a `config_changed` handler, or an errored one, is reloaded instead. |
| Isolation | One `lua_State` with a per-plugin `_ENV`. |
| Errors | Every Odin→Lua entry goes through resume/pcall with a traceback. Load, hook and timer errors disable the plugin; command errors only log. All errors are logged as `.Error` with the plugin as source and the traceback at `.Debug`. Each plugin's last error is kept for the Plugins pane. A memory cap turns OOM into a catchable `LUA_ERRMEM`. |
| Modules | `modules.git` becomes `plugins.git`. `module_enabled(.Git)` becomes "the git plugin is loaded" for the core pieces still gated on it. `.Lsp` and `.Ai` stay as modules. |

Hot reload mechanics:
- `plugins_poll` runs in the disk poll, before the config reload. It rescans bundled plugins plus `Plugins.user_dir` (headless sessions have none and never poll).
- `Plugin.stamp` hashes mtime and size of a single-file plugin, or of every `*.lua` file under a dir plugin. Dot entries are skipped, and symlinks below the top-level entry are not followed. Cost is ~13 us per file (`bench_plugin_poll`).
- On any difference `plugins_sync` unloads removed, changed or shadow-swapped plugins while they are still in the list, rebuilds the list in load order, then loads. The Plugins pane keeps its selection by name.
- Unload frees the plugin's tasks first (their `__close` runs), then hooks, timers, processes (whole process group) and pooled threads.
- A load after startup queues `startup` for that plugin only (`PluginQueued.only`).
- Config hot reload (`plugins_config_apply`): re-merge each loaded plugin's config, apply `enabled` flips and config-driven reloads (`Plugin.cfg_sig`; subscribers adopt the new signature), flush `config_changed`, then `plugins_rebind` and the unknown-plugin warning. A config that fails to parse leaves plugin state alone.
- Commands registered after the first full bind (`Plugins.bound`) report their own key problems, except inside that window (`binds_deferred`).

### Plugins pane (core)
A floating list modeled on *Debug: Message Log*. It is opened by *Debug: Plugins*
(palette, no default bind). It is core so that it still works when Lua fails to
load.

| Column / action | Behavior |
|---|---|
| Rows | name, `bundled`/`user`, state (`enabled` / `disabled` / `errored`), load time in ms. The selected row's last error is shown in the footer. Click selects, double click is `Enter`. |
| `Enter` | Opens the plugin's main file. Bundled plugins open read-only from the embedded copy in a highlighted view inside the pane, with a hint to fork it to the user dir. |
| `e` | Toggles enabled. Writes only `plugins.<name>.enabled` (`config_persist_path_to`, atomic; refused when config.json doesn't parse) and loads or unloads the plugin. The config stamp is left alone, so the next poll runs the normal reload and finds the flip already applied. |
| `r` | Reloads the plugin. |
| `l` | Opens the Message Log filtered to this plugin's source. |

## 5. Runtime model

- **Scheduler.**
  - Each entry (command, event handler, timer tick) runs on a pooled coroutine.
  - A yield hands Odin a wait record (`pick`, `prompt`, `confirm`, `spawn`, `sleep`, `lsp_format`), which Odin stores in `pending[id]`.
  - Waiting bindings end with `return lua_yield(L, n)`, so nothing yields across an Odin frame.
- **Resume sources.**
  - UI waits resume from the plugin overlay's Enter/Esc in `editor_dispatch`.
  - spawn, sleep and LSP waits resume from `plugin_pump` in the fast-poll branch of the main loop.
  - `plugin_busy()` joins the fast-poll gate.
  - The `peek_event` timeout is clamped to the next timer deadline.
- **Await safety.**
  - Handles are ids, and positions are values.
  - An edit after an await follows the pattern: read `rev`, await, then edit with `{rev = r}`. If the rev is stale, the edit returns false and the plugin drops the result, the same pattern LSP formatting already uses.
  - Edits validate before the first primitive runs, so a group never half-applies.
- **Hook budgets.** A `lua_sethook` count hook runs every 100k instructions and checks the wall time of the current resume slice. Time spent waiting in a yield doesn't count.

  | Entry | Soft (Debug log) | Hard |
  |---|---|---|
  | `buf_changed`, `cursor_moved` | 1 ms | 20 ms: error, plugin disabled |
  | other events, timers | 5 ms | 200 ms: disabled |
  | `setup` | 2 ms | 1 s: disabled |
  | commands | n/a | 2 s: error logged |

- **Startup budget.**
  - perf.md has no cold-start target today. Its known pre-paint costs are cold `git_gutter_update` (~45-56 ms) and `buffer_open` on huge files.
  - Target: Lua state plus the whole bundled set in **≤ 5 ms** before first paint, measured in `perf_bench` and logged at `.Debug` (total and per-plugin `setup` time, also shown in the Plugins pane).
  - The rule that keeps it there: `setup` only registers (commands, hooks, status ids). Real work (spawns, file reads, polls) goes in a `startup` handler or `qed.defer(0, ...)`, which runs after first paint.
  - If the bundled set still misses the target, compile bundled plugins to bytecode at build time (`luac`-style dump embedded instead of source).
- **Per-keystroke guarantee.** A plain keystroke runs zero Lua unless a plugin subscribed to a coalesced event, and then it runs once per iteration.

## 6. Testing

| Layer | How |
|---|---|
| API bindings | Odin unit tests (`plugin_test.odin`) on a headless `lua_State`: index conversion, `qed.edit` grouping, rev guards, error isolation, budget aborts, stub completeness. |
| Plugins in e2e | `e2e_start` loads the embedded bundled plugins like a real start. `e2e_plugin(name, src)` injects an ad-hoc plugin. Assertions use the existing surfaces (buffer, overlays, grid). Waits on plugin coroutines use the existing deadline-bounded pump loop. |
| Deterministic spawn | `qed.spawn` routes through `subprocess_start`, so `e2e_stub_script` already covers fake formatters and git. Add `e2e_spawn_fake(pattern, {stdout, code, delay_ms})`, a table the spawn binding consults first under test (no fork), so ordering and timeouts are exact. |
| Plugin-owned tests | `plugins/<name>/test.lua` (bundled only). One Odin e2e test, `e2e_plugins_test.odin`, iterates over the embedded plugins with a `test.lua` and runs each in a fresh session. The test file gets `t.key`, `t.type`, `t.step`, `t.expect_line`, `t.expect_cell`, `t.fake_spawn`, `t.wait(cond)`, and a failure maps to `testing.fail` with the Lua traceback. Petar's user plugins can use the same runner through `qed --test-plugin PATH` (later). |

Every port phase ships its plugin's `test.lua` and moves or adapts the existing
e2e tests of the Odin feature it replaces.

## 7. Validation plan

| # | Port | Proves |
|---|---|---|
| 1 | `format` (external formatter, format-on-save toggle, save fixups, LSP fallback) | `spawn` + await, awaitable and bounded `buf_pre_save`, `set_text` + rev guard, edit groups, plugin config, default keys. |
| 2 | `pickers` (Set Theme, Set Language, Change Indentation) | `pick` await, `on_change` preview, Esc revert, core setters, `theme.set{persist}`. |
| 3 | `git` (base fetch, stat poll, Set Diff Base, Restore File) | Timers, status push, diff-base primitive, events, dir plugin with `require`, module→plugin. If the Lua reads worse than the Odin did, the API is wrong. |
| new | `commands`: `plugins.commands.list = [{name, run, output, stdin, save, cwd, env, when, key}]`, with `output = message \| log \| replace \| insert \| clipboard \| terminal \| task \| locations` (schema in CONFIG.md) | User commands end to end. `task` delegates to `tasks`, and `locations` parses `file:line:col` into a path `pick`. |
| new | `tasks`: `plugins.tasks.list = [{name, cmd, cwd?, env?}]` | `qed.term` sessions. Task picker shows each task's state, with run / restart / kill / show. A status segment shows the running count and turns red on a non-zero exit. Running an already-running task restarts it. |

## 8. Build phases

Each phase is one agent-sized step, ships green, and includes its tests.

| Phase | Scope | Tag |
|---|---|---|
| 0 | Vendor Lua 5.4 source in `lib/lua` (static via `build.sh`, bindings adapted from `vendor:lua/5.4`). `plugin.odin`: state, load bundled+user, `_ENV`, pcall/traceback, last-error capture, `qed.log/message/command`, dynamic command list, keybinds by name. **Minimal Plugins pane** (rows + state + last error, read-only). `plugin_test.odin` + `e2e_plugin`. Startup timing in `perf_bench`. CLAUDE.md lock update. | minor |
| 1 | `Buffer.id`, `qed.buf.*`, `qed.edit`, `qed.jump`, fs/json/path/config/opt. Stub + completeness test, stub write + lua-ls `Lua` settings. | minor |
| 2 | Coroutine scheduler, `spawn`/`spawn_bg`, timers, `plugin_pump`, budgets, events with save/quit timeouts. `e2e_spawn_fake`, the `test.lua` runner. | minor |
| 3 | Port 1 `format` (+ `set_text` minimal diff, `qed.lsp.format`). Delete the Odin path and the `formatter` key. | minor |
| 4 | `pick` (incl. `multi`), `prompt`, `confirm`, `pane`. Port 2 `pickers`. | minor |
| 5 | `commands` plugin (all outputs except `task`). Filetree `ctx.file/files`. | minor |
| 6 | Hot reload, live enable/disable, plugin file poll. **Full Plugins pane** (`e`/`r`/`l`/`Enter`). Poll cost: ~13 us per user plugin file (0.15 ms for 10, 2.6 ms for 200, `bench_plugin_poll`). | minor |
| 7 | `Terminal` → N sessions, `qed.term`, `term_exit`. `tasks` plugin + `output = "task"`. | minor |
| 8 | Decorations store, `status.set`, diff-base primitive. | patch |
| 9 | Port 3 `git`, `modules.git` → `plugins.git`. | minor |
| later | File tree status provider, interactive panes, conflicts, projsearch, aiedit, fim, `qed --test-plugin`. | |

## 9. Decisions

1. 1-based rows and byte columns, half-open ranges.
2. Vendor the Lua source in `lib/lua` and build it static, since `vendor:lua` uses the system library on macOS and Linux arm64.
3. Load, hook and timer errors disable the plugin; command errors only log.
4. Default keys are declared via `key=` in `qed.command`, overridable by `keybinds[name]`.
5. Git: diff engine core, plumbing in Lua, file tree Git tab core for now.
6. One `format` plugin orders save fixups before formatting. No hook priorities.
7. Formatter config lives in `plugins.format.commands.<lang>`.
8. The stub is auto-written to `$XDG_DATA_HOME/qed/lua/qed.lua` and fed to lua-ls via `Lua.workspace.library`.
9. `modules.ai` stays core until decorations exist; then aiedit moves first and fim last.
10. One Lua state with a per-plugin `_ENV`.
11. A user plugin with a bundled name replaces the bundled one.
12. Tasks are core `qed.term` sessions plus a bundled `tasks` plugin.
13. `Enter` on a bundled plugin in the Plugins pane opens its embedded source read-only. A separate explicit *Fork Plugin* command may come later.
14. One shared knob, `plugin_hook_timeout_ms`, bounds both `buf_pre_save` and `quit`.

# Note: plugin system (Lua 5.4)

Design for a plugin system. Status: decided. Build phases are tracked in TODO.md.

## 1. Goals / non-goals

Goals
- Make core pieces solid by moving glue builtins (spawn a tool, pick from a list, call a core setter) into bundled Lua.
- Ship long-running tasks as a plugin, not a core feature. User commands are plain `qed.command` calls in a user plugin.
- The API grows by porting built-in features to bundled plugins, which is how it gets tested. No new plugin or API function without a concrete built-in or a real user need behind it.
- Async without threads: Lua coroutines on the main loop, so `qed.pick`, `qed.spawn` and `qed.sleep` read as straight-line code.
- A failing plugin never crashes or freezes qed, and it is visible in the Plugins pane.
- Completion when editing plugins in qed, for bundled and user plugins alike.

Non-goals
- Project-local plugins, sandboxing, trust prompts. Plugins are global and written by Petar.
- Lua on any render path or on the raw per-keystroke path.
- A package manager, a versioned API, backwards compatibility.
- Moving LSP, tree-sitter, PTY/vterm into Lua. (The file tree moves to Lua in [panes.md](panes.md) M5, on core walk handles.)
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
| textfield/overlay/fuzzy/pane/preview/confirm widgets | KS | core | Exposed as `qed.ui.open`; `qed.pick`, `prompt`, `confirm`, `pane` are Lua sugar over it. |
| palette + keybind dispatch | KS | core | Gains a dynamic plugin-command list. |
| find/replace, linefind, jump, cwdpick | | core | Interactive per keystroke. Porting gains nothing. |
| quit/close/disk-conflict dialogs | | core | Safety of unsaved work. |
| log | | core | `qed.log`, `qed.message`. |
| clipboard | | core | `qed.clipboard`. |
| terminal | KS (pump) | core, generalized | One `Terminal` becomes N named sessions behind `qed.term`. Alt+t is the default session. |
| lsp/completion/rename/hover/mdrender | KS | core | `qed.lsp.format(b)` (awaitable) for the formatter fallback. |
| `format.odin` external formatter + save fixups | | **plugin** (port 1) | `spawn`, `buf_pre_save`, `buf.set_text` with rev guard, plugin config. |
| langpick / themepick / indentpick | | **plugin** (port 2) | `pick{on_change}`, `buf.set_language`, `theme.set`, `buf.set_indent`. Closes the "collapse centered pickers" TODO. |
| basepick | | **plugin** (with git, done) | `pick`, `spawn`. |
| git: base blob fetch, stat poll (branch, ahead/behind, diff size), base picker, restore file | (poll) | **plugin** (port 3, done: `plugins/git`) | `spawn`, `every`, `status.set` (chunks, `sep`), `buf.set_base`, events, `theme.icon`. |
| git: line-hash + Myers gutter diff, ghost rows, word spans, next/prev change, revert hunk | KS (`git_recompute` per rev) | core **diff base** (`diffbase.odin`, phase 8) | The plugin sets base text, and core diffs and renders. "Changed since save" becomes a few lines of Lua. |
| file tree Git tab + status bars: status scan, numstat sizes, renames, deleted files, ignored set, preview base, restore | | **plugin** (phase 11, done: `plugins/git/tree.lua`) | `filetree.provide{refresh, preview, open_deleted}`, `filetree.set_status`, `filetree.set_base`. Core keeps the tab, bars, sizes, ghost rows, preview diff and the walk (render and keystroke paths). |
| conflict.odin | KS (per render) | later | Needs tints, spans, `confirm`. |
| projsearch: rg invocation, parse, sort, 500 cap, min query, query and selection memory, tree scope | | **plugin** (phase 12, done: `plugins/search`; on `qed.ui.open` since M1) | `ui.open{id, query field}`, `view:set/append`, `spawn_bg{on_line}`, `jump`, `ctx.files`. Core keeps the split layout, the preview, the count and hint, the query debounce (keystroke path) and the query/selection memory (`id`). |
| llm / aiedit | KS (relocate per render) | later | `prompt`, `spawn`, range-anchored tints. |
| fim | KS (debounce) | later, last | Inline ghost decoration + `buf_changed`. |
| module.odin | | replaced | `modules.git` became `plugins.git`; `.Git` is gone (phase 11). `modules.lsp` became the top-level `lsp` section (phase 13). `modules.ai` stays until ported. |
| **custom commands** | | user plugins | `command{when}`, `spawn`, `parse_locations` + `pick`, `term`, `pane`. The config-driven `commands` plugin was dropped in phase 10. |
| **tasks** | | dropped (phase 13) | Was a bundled plugin over `qed.term`; the API stays, covered by `src/term_test.lua`. |
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
| `qed.buf.set_base(b, text \| nil, {label?}) -> active` | Diff base: gutter, ghost rows, change navigation, revert hunk. Each plugin owns one base per buffer. The plugin that set its first most recently wins; setting again keeps its place, `nil` clears it in place (a later set does not move it up), and `nil` or unload reveals the one beneath, so the `git` plugin's base comes back when another plugin's goes. Returns whether this plugin's base is the one shown. `text` is raw bytes (need not be UTF-8). `""` is an empty base (every line added). `label` shows as the `±label` status segment: `±base` when omitted, nothing when `""`. Big files have no diff base. |
| `qed.open(path) -> b`, `qed.save(b)`, `qed.close(b)` | `save` runs the full pipeline, including `buf_pre_save`. |
| `qed.jump(b \| path, pos)` | Switch (or open the path, like `qed.open`), reveal, record in the jump list from where you were. `pos` is clamped to the buffer and a col inside a UTF-8 sequence snaps back. `nil, err` when the path fails to open. (`goto` is a Lua keyword.) |

### Commands and keybinds
| Function | Notes |
|---|---|
| `qed.command{name, run, when?, key?, welcome?, scope?, keybind?} -> handle` | `name` is bare; the command is shown and run as `<display name>: <name>` (the visible name). `handle:remove()` unregisters. A visible name is unique per scope: the same name may be one editor and one file-tree command; `qed.run` picks the editor one, and the one keybind binds both. `run(ctx)` runs in a coroutine and `when(ctx)` gates the palette and the chord. `key` is the default, and `plugins.<id>.keybinds[name]` overrides it. `scope = "filetree"` puts the command in the tree palette. `keybind` is the key in `plugins.<id>.keybinds` when it differs from `name`; commands sharing a key share its bind, and one without `key` takes the first `key` among them. `welcome = true` also offers it on the welcome screen. |
| `qed.run(name)` | Run a builtin or plugin command by visible name. A bare name falls back to the caller's own editor command; bare names equal to a core command are refused at registration, so core names stay unambiguous. |
| `qed.commands() -> {name, shortcut, owner}[]` | |
| `ctx` | `{buf, path, language, root, selection_text}`, plus for `scope = "filetree"`: `file` (entry under the cursor) and `files` (all selected paths, in tree order; on a scoped tab a selected dir stands for its in-scope files). |

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
| `term_open`, `term_close` | `name` | |
| `term_exit` | `name`, `code` | |
| `quit` | | yes, bounded by `plugin_hook_timeout_ms` |

There is deliberately no `key` event.

### UI
| Function | Notes |
|---|---|
| `qed.message(text, level? \| {level?})`, `qed.log(level, text)` | Always attributed to the plugin's display name. Unknown options raise. |
| `qed.ui.open(spec) -> view \| nil, "busy"\|"closed"` | A pane on the core model ([panes.md](panes.md) §5, M1 as built): `id`, `place` (`center`/`full`/`split`), `size`, `kind` (`exclusive`/`child`), `parent`, `focus = false` (passive), `title`, `fields` (`{prompt?, text?, mode = filter\|query\|input, count?}`), `list` (`{items, multi?, max?, empty?, selected?, sort?}`), `modal`, `preview = "auto"`, `text` lines, `footer = {hints}`, `on = {activate, change, query, close}`. Items are strings or `{label, detail?, value?, path?, pos?, key?}`. Raises in `setup`. |
| `on.activate(v, items)`, `on.change(v, item)`, `on.query(v, text)`, `on.close(v)` | Queued during input dispatch, run as tasks in the flush before the next frame. `change` coalesces per flush and kills the previous run; `query` runs at open and `PANE_QUERY_DEBOUNCE_MS` (120) after typing stops, killing the previous run and the `qed.spawn` it waits on (not `spawn_bg`); close kills both. Activate leaves the pane open. |
| `v:set(items, {selected?, more?, hint?})`, `v:append(items)`, `v:update(key, fields)`, `v:text(lines)`, `v:close()` | `set`/`append`/`update`/`text` return false once closed. `max` caps the list and shows `N+`. |
| ⏳ `v:wait() -> items \| nil, index \| nil, text \| nil` | The next activate (items, the first one's index, the first field's text) or the close (`nil, nil, text`). |
| ⏳ `qed.pick{items, prompt?, initial?, multi?, on_change?, query?, on_query?} -> item \| items[] \| nil` | Sugar: a child `ui.open` + `wait` + `close`. Items with `path` get the split layout (count by the divider). `multi = true` returns `items[]`. `on_change` is for live preview. `initial` is an item index or label. `query` is the initial text, fully selected. Esc returns `nil`. |
| `on_query(query, picker)` | Sugar for a `query` field: items only from `picker:set(items, {selected?, more?, hint?}) -> live` (`view:set`). `pick` returns the final query as a third value (also on Esc), and Enter while a query is due or running accepts once it ends. |
| ⏳ `qed.prompt{prompt, text?} -> string \| nil` | Sugar: a child pane with one `input` field. |
| ⏳ `qed.confirm(question, choices?) -> index \| nil` | Sugar: a child `dialog` pane (question + action list). |
| `qed.pane{title, lines, footer?} -> pane` | Sugar: an exclusive `full` pane. `pane:set(lines)` (`view:text`) and `pane:close()`. Lines are strings or `{text, color}`. |
| `qed.status.set(id, {text, color?, side?, drop?, sep?})`, `qed.status.clear(id)` | Pushed segment, fitted by `status_fit`. `id` is per plugin; `set` replaces it in place. `text` is a string or a list of `{text, color?}` chunks, each painted in its color; `""` hides the segment but keeps its place. `sep` is the text before it (two spaces). A segment that still overflows once nothing is left to drop is clipped with `…`. `side` defaults to `left` (after the builtins and the `[n/m]` buffer counter); `early = true` puts a left segment before `[n/m]` and another plugin's base label (the git segments); `right` segments sit left of the builtins. `drop` defaults to 1 (among the first dropped); 0 is never dropped. Tabs and newlines become spaces. Cleared on unload. |
| `qed.clipboard.get()`, `.set(text)` | |
| `qed.theme.set(name, {persist?})`, `.list()`, `.current()`, `.icon(name)` | `icon` is a theme icon such as `status_branch`. |
| `qed.filetree.provide{refresh?, preview?, open_deleted?} \| nil -> true \| nil, err` | Removed in [panes.md](panes.md) M6 (the `git` plugin adds its tab through `filetree` exports). Claims the Changed tab: one provider, `nil, "taken by <plugin>"` while another holds it; unload or `nil` drops it, and the tab with it. Calling again replaces the callbacks and keeps the status and tab. Callbacks run as queued coroutines (event budget): `refresh()` when the tree wants status (opened, root changed, a tree file operation, or `provide` over an open tree; the `git` plugin also scans at startup, so the first open is instant), `preview(path)` when the Changed tab wants a base, `open_deleted(ctx)` as a tree command on `Enter` over a listed deleted file missing on disk. |
| `qed.filetree.set_status(files, ignored?)` | Replaces the tree status. `files[path] = {mark = "added"\|"modified"\|"deleted", from?, added?, removed?}`; `from` is a rename's old path, `added`/`removed` the `+N -N` sizes. Core propagates marks to ancestor dirs, lists deleted files virtually and hides `ignored` paths unless *Toggle Ignored*. Validated before anything changes. Raises unless the caller is the provider. |
| `qed.filetree.set_base(path, text \| nil)` | Answers `preview(path)`: the Changed tab previews `path` diffed against `text`, raw bytes (a NUL on either side shows a hexdump; `nil`: plain file). A stale path is ignored; every `set_status` drops the cached base, keeping the old rows up until the re-ask is answered. |

- `qed.pick`/`prompt`/`confirm` stack as a child over an open pane or overlay; they return `nil, "busy"` only while a core safety dialog (quit, close, conflict) shows. Outside a user's command they stack only on the plugin's own pane, else `"busy"`. An exclusive open (`qed.ui.open` default, `qed.pane`) is also `"busy"` while a `modal` pane (the sugar's) is open, and otherwise closes the open exclusive pane, whose waiters get `nil`.
- The chord of the command that opened a pane closes it like Esc (the core pane convention). A command of the view's own plugin run while it has focus gets it as `ctx.view`; reachable once panes get scoped commands (M3).

### Terminals (`qed.term`)
Core owns PTY and vterm. Each session has a name.

| Function | Notes |
|---|---|
| `qed.term.create{name, cmd?, cwd?, env?, restart?, detach?} -> name` | Starts in the background without showing. `cmd` (run by `/bin/sh -c`) nil means an interactive shell. `cwd` defaults to the root. Fails with `nil, "already running"` if the name is live, unless `restart = true`, which restarts it with the new spec. An exited session of that name is replaced. `"shell"` cannot be created, killed, restarted or closed by a plugin. |
| `qed.term.show(name)`, `.hide()` | Shows the session in the terminal pane overlay, its name in the pane title. Alt+t shows `"shell"`, the default session; `show("shell")` starts it like Alt+t. Raises during `setup`. |
| `qed.term.kill(name)`, `.restart(name)`, `.send(name, text)` | `kill` SIGKILLs the session's process group and keeps its output. `restart` kills and respawns with the same spec on a fresh screen. `send` writes raw bytes (`"\r"` is Enter); input the program does not read is buffered up to 1 MiB, the rest dropped with a warning. |
| `qed.term.state(name) -> {name, running, code?, pid?, busy?} \| nil`, `qed.term.list()` | `code` is the last exit code (128 + signal when killed). `busy`: a program other than the session's own process holds the foreground (the shell is running a command). `list` is in creation order. |
| `qed.term.close(name)` | Kills the session and frees its scrollback. |

A `term_exit` event fires when a session's process exits, including `kill`, but not
on `restart`, `close` or teardown. `term_open` fires whenever a session's process starts
(create, restart, Alt+t), `term_close` when a session is closed (also on plugin unload, not
at teardown). Sessions created by a plugin die when it unloads,
unless they were created with `{detach = true}`.

### Decorations
- Push only, namespaced per plugin: `ns = qed.deco.ns(name)` (same name, same id). A namespace is usable only by its plugin; unload clears all of them.
- Colors are theme keys, never hex; an unknown key raises. They resolve per frame, so a theme change recolors.
- Row anchors shift inside `buffer_insert`/`buffer_delete` (no Lua). An insert at col 0 pushes that row's decorations down with its text, unless the row was empty (a replaced hunk keeps them on its first row). A whole-line delete (col 0 to col 0) drops the deleted rows; a joining delete drops the rows joined into the first. Tints shrink instead of dropping. Spans on any edited row drop. Undo shifts anchors back but never restores dropped decorations. A reload drops spans and clamps the rest.

| Function | Notes |
|---|---|
| `qed.deco.gutter(b, ns, row, glyph, color)` | Mark column, one single-width glyph. A diff-base mark on the row wins; among decorations the last pushed wins. |
| `qed.deco.tint(b, ns, from_row, to_row, color, alpha?)` | Goes through the `editor_line_bg` stack: diff hunk, conflict, decoration tints (push order), AI edit, current line. `alpha` defaults to the theme tint `decoration`. |
| `qed.deco.ghost(b, ns, row, lines, {above?, color?})` | Virtual rows, one clipped row each, folded into the screen-mapping walkers like the diff ghosts. Order: decoration ghosts above, diff ghosts above, the row, decoration ghosts below, diff ghosts below. Like the diff ghosts, ghosts above the top screen row are hidden. `color` defaults to `ghost_foreground`. |
| `qed.deco.span(b, ns, from, to, style)` | `{fg?, bg?, bold?, underline?}`, over syntax and diff word colors, under find matches and the selection. |
| `qed.deco.eol(b, ns, row, text, color)` | Virtual text one cell after the line end (last wrapped row), clipped at the window edge (a wide char never splits). Several on a row join with a space. |
| `qed.deco.clear(b, ns, from_row?, to_row?)` | Decorations touching the rows; all when omitted. |

Cost (`bench_decorations`, debug build, 10k-line buffer): 10k decorations add ~40 us per keystroke (anchor shift) and ~0.17 ms per frame; 50k add ~160 us and ~1.2 ms.

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
| `qed.parse_locations(text, {cwd?}) -> {label, path, pos}[]` | Parses `file:row:col: msg`, `file:row:col`, `file:row: msg` and `file:row` lines (CRLF ok; the shortest file wins, so `a:b.txt:4: m` is `a:b.txt`) into `qed.pick` items. Relative files resolve against `cwd` (default the root); lines naming a missing file are skipped; labels are root-relative. `{}` when nothing parses. |
| `qed.root()`, `qed.version` | |
| `qed.options(defaults) -> table` | Declares this plugin's config keys and defaults, returns the merged config. Setup only, once per load; raises otherwise. `enabled` and `keybinds` are reserved and raise. |
| `qed.meta{display_name?}` | Plugin metadata. Setup only, once per load; unknown fields and a non-string or empty `display_name` raise. Must come before any `qed.command`. A display name another loaded plugin uses, or a core log label (`PLUGIN_RESERVED_LABELS`), raises. |
| `qed.config() -> table` | This plugin's merged subtree. Read-only. |
| `qed.opt(key)` | Read-only core knob. |
| ⏳ `qed.lsp.format(b) -> bool` | Core LSP formatting. |

### Type stubs
- `plugins/meta/qed.lua` (`---@meta`) is maintained by hand next to `src/plugin_api.odin`. A unit test fails if a registered `qed.*` function is missing from it.
- The stub is embedded and written to `$XDG_DATA_HOME/qed/lua/qed.lua` whenever its content changes.
- **Scoped to the config dir.** qed writes no Lua type file. It answers the `Lua` section of `workspace/configuration` (and adds it to the post-`initialized` push) with `runtime.version = "Lua 5.4"` and `workspace.library = ["<stub dir>"]` only when the working root is the config dir or below (`qed ~/.config/qed`, `qed ~/.config/qed/plugins`); elsewhere `Lua` is `null`.
- The repo has a checked-in `.luarc.json` at its root pointing at `plugins/meta` for the bundled plugins (lua-language-server reads it only at the workspace root).

## 4. Lifecycle

| Aspect | Rule |
|---|---|
| Sources | Bundled plugins are in repo `plugins/`, embedded via `#load_directory`. User plugins are in `~/.config/qed/plugins/`. |
| Shape | `name.lua` or `name/init.lua`. `require` resolves only inside the plugin's dir. |
| Spec | Returns `{setup = function() end}`. All registration happens in `setup`. |
| Order | Bundled first, then user, alphabetical within each. A user plugin with a bundled name replaces the bundled one. `startup` fires after all plugins are loaded. |
| Enable | `plugins.<name>.enabled`, default true. The embedded config.json lists each bundled plugin's `enabled` and nothing else. |
| Naming | The id is the file or dir name: config key, keybind namespace, owner in code. The display name is the id title-cased (`my_tools` is "My Tools") or `qed.meta{display_name}`; it prefixes commands (palette, keybind hints), labels messages and log lines, and names the plugin in the Plugins pane. It survives unload (a disabled plugin keeps its last name) and resets at the start of the next load; a plugin never loaded shows the title-cased id. |
| Keybinds | `plugins.<name>.keybinds[<bare name or keybind>]` over each command's `key`; the top-level `keybinds` holds core commands only (a plugin command there warns where it moved). Names no command of the loaded plugin has warn after the next event flush following a load (so `startup` handlers can register) or a config apply; a disabled or errored plugin's binds are not checked. A bare name equal to a core command is refused. A key taken by a core command or another plugin command in the same scope is ignored with a warning; the first bound wins. Disabling drops the binds with the commands. Old bundled names in the top-level `keybinds` warn where they moved. |
| Config | `setup` calls `qed.options(defaults)`, the one place a plugin's keys and defaults live. `plugins.<name>` is a sparse diff over them. Unknown keys warn once, after setup ran, and only for enabled plugins that loaded; a disabled or errored plugin's typo surfaces when it loads. |
| Ownership | Every registration (command, hook, timer, process, term session, decoration ns, status segment, diff base, modal) records its owner. Unloading tears all of it down. |
| Hot reload | Triggers: the disk poll sees a user plugin file added, removed or changed (any file inside a dir plugin), `enabled` flips, or `r` in the Plugins pane. Only that plugin unloads and reloads; a same-name user plugin appearing or disappearing swaps it with the bundled one. Load order stays bundled-then-user, alphabetical. A plugin loaded after startup gets its own `startup` event. |
| Config changes | A changed `plugins.<name>` subtree (other than `enabled`) reaches a plugin that subscribes to `config_changed` through that handler, so its runtime state (e.g. `format`'s toggles) survives. A plugin without a `config_changed` handler, or an errored one, is reloaded instead. |
| Isolation | One `lua_State` with a per-plugin `_ENV`. |
| Errors | Every Odin→Lua entry goes through resume/pcall with a traceback. Load, hook and timer errors disable the plugin; command errors only log. All errors are logged as `.Error` under the plugin's display name and the traceback at `.Debug`. Each plugin's last error is kept for the Plugins pane. A memory cap turns OOM into a catchable `LUA_ERRMEM`. |
| Modules | `modules.git` became `plugins.git`, and phase 11 removed `.Git`: the Git tab follows the file tree status provider, conflicts are ungated. Phase 13 made `modules.lsp` the top-level `lsp` section, gated on `LSP_ENABLED`. `.Ai` stays a module. |

Hot reload mechanics:
- `plugins_poll` runs in the disk poll, before the config reload. It rescans bundled plugins plus `Plugins.user_dir` (headless sessions have none and never poll).
- `Plugin.stamp` hashes mtime and size of a single-file plugin, or of every `*.lua` file under a dir plugin. Dot entries are skipped, and symlinks below the top-level entry are not followed. Cost is ~13 us per file (`bench_plugin_poll`).
- On any difference `plugins_sync` unloads removed, changed or shadow-swapped plugins while they are still in the list, rebuilds the list in load order, then loads. The Plugins pane keeps its selection by name.
- Unload frees the plugin's tasks first (their `__close` runs), then hooks, timers, processes (whole process group) and pooled threads.
- A load after startup queues `startup` for that plugin only (`PluginQueued.only`).
- Config hot reload (`plugins_config_apply`): re-merge each loaded plugin's config, apply `enabled` flips and config-driven reloads (`Plugin.cfg_sig`; subscribers adopt the new signature), flush `config_changed`, then `plugins_rebind`, each loaded plugin's unknown keys (`Plugin.unknown`, computed at merge) and the unknown-plugin warning. Outside a config apply, a load warns its own unknown keys. A config that fails to parse leaves plugin state alone.
- Commands registered after the first full bind (`Plugins.bound`) report their own key problems, except inside that window (`binds_deferred`).

### Plugins pane (core)
A floating list modeled on *Debug: Message Log*. It is opened by *Debug: Plugins*
(palette, no default bind). It is core so that it still works when Lua fails to
load.

| Column / action | Behavior |
|---|---|
| Rows | display name, `bundled`/`user`, state (`enabled` / `disabled` / `errored`), load time in ms. The selected row's last error is shown in the footer. Click selects, double click is `Enter`. |
| `Enter` | Opens the plugin's main file. Bundled plugins open read-only from the embedded copy in a highlighted view inside the pane, with a hint to fork it to the user dir. |
| `e` | Toggles enabled. Writes only `plugins.<name>.enabled` (`config_persist_path_to`, atomic; refused when config.json doesn't parse) and loads or unloads the plugin. The config stamp is left alone, so the next poll runs the normal reload and finds the flip already applied. |
| `r` | Reloads the plugin. |
| `l` | Opens the Message Log filtered to this plugin's display name. |

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
| Plugin-owned tests | `plugins/<name>/test.lua` (bundled only). One Odin e2e test, `e2e_plugins_test.odin`, iterates over the embedded plugins with a `test.lua` and runs each in a fresh session. The test file gets `t.key`, `t.type`, `t.step`, `t.expect_line`, `t.expect_cell`, `t.fake_spawn`, `t.wait(cond)`, `t.sh(cmd)` (in the session dir), `t.settle()` (plugin processes and tree scans done), `t.marks(b)` (diff marks per row), and a failure maps to `testing.fail` with the Lua traceback. Petar's user plugins can use the same runner through `qed --test-plugin PATH` (later). |

Every port phase ships its plugin's `test.lua` and moves or adapts the existing
e2e tests of the Odin feature it replaces.

## 7. Validation plan

| # | Port | Proves |
|---|---|---|
| 1 | `format` (external formatter, format-on-save toggle, save fixups, LSP fallback) | `spawn` + await, awaitable and bounded `buf_pre_save`, `set_text` + rev guard, edit groups, plugin config, default keys. |
| 2 | `pickers`, now `settings` (Theme, Language, Indentation) | `pick` await, `on_change` preview, Esc revert, core setters, `theme.set{persist}`. |
| 3 | `git` (base fetch, stat poll, Set Diff Base, Restore File) | Timers, status push, diff-base primitive, events, dir plugin with `require`, module→plugin. If the Lua reads worse than the Odin did, the API is wrong. |

## 8. Build phases

Each phase is one agent-sized step, ships green, and includes its tests.

| Phase | Scope | Tag |
|---|---|---|
| 0 | Vendor Lua 5.4 source in `lib/lua` (static via `build.sh`, bindings adapted from `vendor:lua/5.4`). `plugin.odin`: state, load bundled+user, `_ENV`, pcall/traceback, last-error capture, `qed.log/message/command`, dynamic command list, keybinds by name. **Minimal Plugins pane** (rows + state + last error, read-only). `plugin_test.odin` + `e2e_plugin`. Startup timing in `perf_bench`. CLAUDE.md lock update. | minor |
| 1 | `Buffer.id`, `qed.buf.*`, `qed.edit`, `qed.jump`, fs/json/path/config/opt. Stub + completeness test, stub write + lua-ls `Lua` settings. | minor |
| 2 | Coroutine scheduler, `spawn`/`spawn_bg`, timers, `plugin_pump`, budgets, events with save/quit timeouts. `e2e_spawn_fake`, the `test.lua` runner. | minor |
| 3 | Port 1 `format` (+ `set_text` minimal diff, `qed.lsp.format`). Delete the Odin path and the `formatter` key. | minor |
| 4 | `pick` (incl. `multi`), `prompt`, `confirm`, `pane`. Port 2 `pickers` (now `settings`). | minor |
| 5 | `commands` plugin (all outputs except `task`, dropped in phase 10). Filetree `ctx.file/files`. | minor |
| 6 | Hot reload, live enable/disable, plugin file poll. **Full Plugins pane** (`e`/`r`/`l`/`Enter`). Poll cost: ~13 us per user plugin file (0.15 ms for 10, 2.6 ms for 200, `bench_plugin_poll`). | minor |
| 7 | `Terminal` → N sessions, `qed.term`, `term_exit`. `tasks` plugin. | minor |
| 8 | Decorations store, `status.set`, diff-base primitive (`git.odin` fetches the blob and pushes it through `diffbase_set`). The `tasks` status segment. | patch |
| 9 | Port 3 `git`, `modules.git` → `plugins.git` (`diff_view`, `filetree_diff_only` moved to the top level). `Git: Next/Previous Change`, `Revert Hunk`, `Toggle Diff View` became `Diff: ...`, gated on a diff base. | minor |
| 10 | Drop the `commands` plugin (`plugins.commands`, `cmd:` sessions); user commands are `qed.command` in a user plugin. Add `qed.parse_locations`; `qed.jump` takes a path and clamps `pos`. | minor |
| 11 | File tree status provider (`qed.filetree.provide{refresh, preview, open_deleted}`, `set_status`, `set_base`); the Git tab's scan, sizes, renames, deleted files, ignored set and preview base move to `plugins/git/tree.lua`. `git.odin`, `qed.git.set_base`, `qed.filetree.refresh`, `ctx.base`, the `.Git` module and `g_git_loaded` are gone; *File Tree: Git* becomes *File Tree: Changed*. | minor |
| 12 | Query-driven `qed.pick` (`query`, `on_query`, `picker:set`), the opening command's chord closes a modal, `ctx.files` expands scoped-tab dirs. Project search moves to `plugins/search` (*Find in Files* and the tree's *Search*); `projsearch.odin` and `projsearch_min_query` (now `plugins.search.min_query`) are gone. | minor |
| 13 | `qed.meta{display_name}`, display names everywhere a plugin is named, automatic `<display name>: ` command prefix, `qed.message` without `source`, keybinds under `plugins.<id>.keybinds` (plugin binds leave the top-level `keybinds`), the `Lua` LSP settings go out only under the config dir, `modules.lsp` becomes `lsp` and `.Lsp` leaves the `Module` enum, `pickers` becomes `settings` (`plugins.settings`), the `tasks` plugin is dropped (`plugins.tasks`, its picker and `tasks N` segment; `qed.term` stays). | minor |
| M1 | `qed.ui.open` and views (set/append/update/text/close/wait), queued `activate`/`change`/`query`/`close`, exclusive panes persisted by `id`, `ctx.view`; `qed.pick/prompt/confirm/pane` become prelude sugar (`pick` over an open pane is a child, not `"busy"`); `search` streams parallel `rg --line-buffered` into a key-sorted query pane. | minor |
| later | Conflicts, aiedit, fim and the remaining panes: the pane model's M steps ([panes.md](panes.md) §7). `qed --test-plugin`. | |

## 9. Decisions

1. 1-based rows and byte columns, half-open ranges.
2. Vendor the Lua source in `lib/lua` and build it static, since `vendor:lua` uses the system library on macOS and Linux arm64.
3. Load, hook and timer errors disable the plugin; command errors only log.
4. Default keys are declared via `key=` in `qed.command`, overridable by `plugins.<id>.keybinds[name]`.
5. Git: diff engine and tree rendering core, plumbing (including the Git tab's data) in Lua.
6. One `format` plugin orders save fixups before formatting. No hook priorities.
7. Formatter config lives in `plugins.format.commands.<lang>`.
8. The stub is auto-written to `$XDG_DATA_HOME/qed/lua/qed.lua` and fed to lua-ls via `Lua.workspace.library`, sent only when the working root is under the config dir. No Lua type file is written.
9. `modules.ai` stays core until decorations exist; then aiedit moves first and fim last.
10. One Lua state with a per-plugin `_ENV`.
11. A user plugin with a bundled name replaces the bundled one.
12. Background sessions are core `qed.term`; the bundled `tasks` plugin was dropped in phase 13.
13. `Enter` on a bundled plugin in the Plugins pane opens its embedded source read-only. A separate explicit *Fork Plugin* command may come later.
14. One shared knob, `plugin_hook_timeout_ms`, bounds both `buf_pre_save` and `quit`.

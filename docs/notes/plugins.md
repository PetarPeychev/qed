# Note: plugin system (Lua 5.4)

Design for a plugin system. Status: shipped; §8 lists the build phases.

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
- Moving LSP, tree-sitter, PTY/vterm into Lua. (The file tree is a bundled plugin on core walk handles since [panes.md](panes.md) M5.)
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
| textfield/overlay/fuzzy/pane/preview/confirm widgets | KS | core | Exposed as `qed.ui.open`; `qed.pick`, `prompt`, `confirm` are Lua sugar over it. |
| palette + keybind dispatch | KS | core | Gains a dynamic plugin-command list. |
| find/replace, jump | | core | Interactive per keystroke. Porting gains nothing. |
| linefind | | **plugin** (M3, `plugins/goto`) | `ui.open` filter field over `qed.buf.line_list`, `qed.jump`. Core keeps filtering, the `:N[:M]` spec and the buffer preview. |
| cwdpick | | **plugin** (M2, `plugins/workspace`) | `ui.open` `path` field over `qed.fs.dirs`, `confirm`, `set_root`. Core keeps the field (drill, segment drop, resolve) and the dir listing. |
| quit/close/disk-conflict dialogs | | core | Safety of unsaved work. |
| log | | core | `qed.log`, `qed.message`. |
| clipboard | | core | `qed.clipboard`. |
| terminal | KS (pump) | core, generalized | One `Terminal` becomes N named sessions behind `qed.term`. Alt+t is the default session. |
| lsp/completion/rename/hover/mdrender | KS | core | `qed.lsp.format(b)` (awaitable) for the formatter fallback. `mdrender` also backs the `markdown` view body. |
| markdown preview | | **plugin** (`plugins/markdown`) | `ui.open{markdown, max_width, backdrop, scope, on.link}`, `v:markdown`, `v:anchor`, `v:scroll`, `v:source_line`/`v:source_scroll` + `qed.buf.screen_row`/`set_screen_row` (cursor sync), scoped Back/Forward over a `{path, buf, scroll}` history, `qed.open_url`, `buf_changed` subscribed only while open. |
| `format.odin` external formatter + save fixups | | **plugin** (port 1) | `spawn`, `buf_pre_save`, `buf.set_text` with rev guard, plugin config. |
| langpick / themepick / indentpick | | **plugin** (port 2) | `pick{selected, on = {change}}`, `buf.set_language`, `theme.set`, `buf.set_indent`. Closes the "collapse centered pickers" TODO. |
| basepick | | **plugin** (with git, done) | `pick`, `spawn`. |
| git: base blob fetch, stat poll (branch, ahead/behind, diff size), base picker, restore file | (poll) | **plugin** (port 3, done: `plugins/git`) | `spawn`, `every`, `status.set` (chunks, `sep`), `buf.set_base`, events, `theme.icon`. |
| git: line-hash + Myers gutter diff, ghost rows, word spans, next/prev change, revert hunk | KS (`git_recompute` per rev) | core **diff base** (`diffbase.odin`, phase 8) | The plugin sets base text, and core diffs and renders. "Changed since save" becomes a few lines of Lua. |
| file tree Git tab + status bars: status scan, numstat sizes, renames, deleted files, ignored set, preview base, restore | | **plugin** (phase 11, `plugins/git/tree.lua`) | Since M6 through the `filetree` plugin's exports (`set_tab`, `set_marks`, `set_ignored`, `open`), reached with `qed.plugin("filetree")` at `startup` and on `plugin_loaded`. |
| file tree | | **plugin** (M5, `plugins/filetree`) | `qed.fs.walk` handles, `ui.open` (tabs, tree list, marks, footer input, chips), `v:select`, `qed.fs.*` writes, `qed.confirm`. Core keeps the walk, tree rows, render, filter and preview. |
| conflict.odin | KS (per render) | **plugin** (M7, `plugins/conflict`) | `buf_open`/`buf_reload`/`buf_save`/`startup` scans, `buf_changed` (`lo`, `hi`) incremental rescans only while a buffer is armed, over `qed.buf.find_lines` (marker list, `word`), `qed.deco` tints and spans with theme tint keys, `qed.text.diff_rows` word spans, `qed.confirm`, `qed.edit`. Core keeps the render and the anchor shifts. |
| projsearch: rg invocation, parse, sort, 500 cap, min query, selection memory, tree scope | | **plugin** (phase 12, done: `plugins/search`; on `qed.ui.open` since M1) | `ui.open{id, query field}`, `view:set/append`, `spawn_bg{on_line}`, `jump`, `ctx.files`. Core keeps the split layout, the preview, the count and hint, the query debounce (keystroke path) and the selection memory (`id`; the query is not kept). |
| llm / aiedit | KS (relocate per render) | **plugin** (M7, `plugins/ai`) | `prompt`, `spawn_bg`, `deco.mark`/`range` (range anchors), tints by theme tint name, `edit`, `status.set`. |
| fim | KS (debounce) | **plugin** (M7, `plugins/ai`); core keeps the ghost | `buf_changed` `typed` + `defer` for the debounce, `spawn_bg` curl, `deco.inline`. Core renders the ghost and handles Tab / Ctrl+Right / dismiss on the keystroke path; Lua only supplies the text. |
| module.odin | | replaced | `modules.git` became `plugins.git`; `.Git` is gone (phase 11). `modules.lsp` became the top-level `lsp` section (phase 13). `modules.ai` became `plugins.ai`, `.Ai` is gone (M7); the empty scaffolding went in M8. |
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
- Buffers are objects (`qed.buf.current()`, `qed.buf.list()`, `ctx.buf`, event arguments); every per-buffer call is a method (`buffer:text()`), and the calling plugin is the owner. APIs taking a buffer (`qed.edit`, `qed.jump`, `qed.close`, `qed.save`, `qed.deco.*`) take an object; ids and `nil` are refused.
- ⏳ marks a call that yields. Every entry point runs in a coroutine, so yielding is always legal.
- Failures: an action that can fail returns `true` (or the value it makes, e.g. `qed.open`'s buffer id) on success and `nil, err` on an expected failure (stale rev, unsaved buffer, unknown name, a process that cannot start, a closed view). It raises only for programmer errors: a bad argument type or shape, or a closed buffer id. Actions that cannot fail return nothing; queries return their value, or `nil` when absent. Teardown calls (`handle:off()`, `handle:remove()`, `timer:stop()`, `proc:kill()`, `view:close()`) are no-ops when already done.

### Indexing
- Rows and columns are **1-based**, and columns are **byte** offsets, so `line:find("x")` plugs straight in.
- `col = #line + 1` is the caret at the end of the line.
- Ranges are half-open: `{from, to}`, with `to` after the last byte, so `line:sub(from.col, to.col - 1)` is the text.
- Positions are `{row, col}` (`qed.Pos` in the stub).
- `qed.text.width(s)` gives display width.
- `qed.text.diff(a, b) -> hunks | nil` diffs two string lists with the gutter's engine: `{a, a_count, b, b_count}` runs, `nil` past its edit-distance cap. Equal lines are checked by content (a hash collision counts as a change).
- `qed.text.diff_rows(b, a_lo, a_hi, b_lo, b_hi, {words?}) -> hunks | nil` does the same over two row ranges of a buffer, read in core; rows are buffer rows. `words` adds `spans`, per paired row `{a_from, a_to, b_from, b_to}` (`diff_word_span`).
- The binding is the only place that converts to core's 0-based coordinates.

### Buffers, cursor, edits
| Function | Notes |
|---|---|
| `qed.buf.current() -> buffer`, `qed.buf.list() -> buffer[]`, `qed.buf.create{internal = true}` | `create` makes an internal buffer the plugin owns; `buffer:close()` frees it. |
| `buffer:valid() -> bool`, `buffer:on("change", fn) -> {remove}`, `buffer:find(query, opts) -> search` | Any other call on a closed buffer raises `buffer closed`. A search handle (`update`, `result`, `step`, `replace`, `close`) is owned by the caller and closed on unload. |
| `buffer:path()`, `:language()`, `:modified()`, `:big()`, `:rev()`, `:line_count()` | `rev` is the version used for await safety. `big`: opened from a file over `BIG_FILE_BYTES`. |
| `buffer:lines(from?, to?) -> string[]`, `:line(row)`, `:text()` | Bulk copies. No per-line FFI loops. |
| `buffer:find_lines(prefix \| prefixes, {word?}) -> rows, kinds?` | Rows starting with `prefix` (plain bytes), in order. With a list, `kinds` holds each row's prefix index. `word`: the prefix is followed by the line end or a space. One core pass, no text copy: a `buf_changed` handler's cheap check. |
| `buffer:find_trailing() -> rows, from, to` | Rows ending in spaces or tabs, in order; `from` is the run's first column, `to` the line end. One core pass, no text copy (the format plugin's trim on save). |
| `buffer:insert(pos, text) -> pos`, `:delete(from, to) -> string`, `:replace(from, to, text)` | Wrappers over the primitives. |
| `buffer:set_text(text, {rev?}) -> true \| nil, "stale"` | Minimal-diff whole replace. |
| `qed.edit(b, fn, {rev?}) -> true \| nil, "stale"` | Everything inside `fn` is one undo group. `fn` must not yield. |
| `buffer:cursor() -> pos`, `:set_cursor(pos)` | |
| `buffer:screen_row(row?) -> n \| nil`, `:set_screen_row(row, screen_row) -> true \| nil, "not current"` | Terminal row (1-based) showing `row` (default the caret), nil off screen; put `row` on `screen_row`, clamped at the buffer ends. Current buffer only. |
| `buffer:selection() -> from, to \| nil`, `:set_selection(anchor, cursor)` | |
| `buffer:set_language(name) -> true \| nil, err` (unknown name), `:set_indent("tabs"\|"spaces"\|"auto", width?)`, `:indent() -> style, width`, `qed.languages()` | Existing core setters. |
| `buffer:set_base(text \| nil, {label?}) -> true`, `buffer:base() -> id \| nil` | Diff base: gutter, ghost rows, change navigation, revert hunk. Each plugin owns one base per buffer. The plugin that set its first most recently wins; setting again keeps its place, `nil` clears it in place (a later set does not move it up), and `nil` or unload reveals the one beneath, so the `git` plugin's base comes back when another plugin's goes. `base` is the id of the plugin whose base is shown. `text` is raw bytes (need not be UTF-8). `""` is an empty base (every line added). `label` shows as the `±label` status segment: `±base` when omitted, nothing when `""`. Big files have no diff base. |
| `qed.open(path) -> b \| nil, err`, `qed.save(b) -> true \| nil, err`, `qed.close(b, {discard?}) -> true \| nil, "unsaved"` | `save` runs the full pipeline, including `buf_pre_save`; `err` is `no file name`, `changed on disk` or `save in progress`. `close` refuses an unsaved buffer unless its id is in `discard`. |
| `qed.jump(b \| path, pos) -> true \| nil, err` | Switch (or open the path, like `qed.open`), reveal, record in the jump list from where you were. `pos` is clamped to the buffer and a col inside a UTF-8 sequence snaps back. `nil, err` when the path fails to open. (`goto` is a Lua keyword.) |

### Commands and keybinds
| Function | Notes |
|---|---|
| `qed.command{name, run, when?, key?, welcome?, scope?, keybind?} -> handle` | `name` is bare; the command is shown and run as `<display name>: <name>` (the visible name). `handle:remove()` unregisters. A visible name is unique per scope: the same name may be one editor and one file-tree command; `qed.run` picks the editor one, and the one keybind binds both. `run(ctx)` runs in a coroutine and `when(ctx)` gates the palette and the chord. `key` is the default, and `plugins.<id>.keybinds[name]` overrides it. `scope = "filetree"` puts the command in the tree palette; any other scope (a core pane's `"log"`/`"plugins"`, or a `qed.ui.open{scope}`) runs it on its chord while such a pane has focus and lists it in that pane's Ctrl+P. A bare `key` (`"x"`) is refused for the editor and tree scopes and fires only in a pane without fields. `keybind` is the key in `plugins.<id>.keybinds` when it differs from `name`; commands sharing a key share its bind, and one without `key` takes the first `key` among them. `bind_from` (without `key`) takes a core command's bind, re-read at every rebind. `welcome = true` also offers it on the welcome screen. |
| `qed.run(name) -> true \| nil, "unavailable"` | Run a builtin or plugin command by visible name (`unavailable`: a core command that does not apply now, or a plugin command whose `when` returns false; an unknown name raises). A bare name falls back to the caller's own editor command; bare names equal to a core command are refused at registration, so core names stay unambiguous. |
| `qed.commands() -> {name, shortcut, scope, owner?, keybind?, key?}[]` | Every core and plugin command. `scope` is `"global"`, `"editor"` (editor nodes) or a pane or node scope; `owner` the plugin id (nil for core); `keybind` the command's key in `keybinds` or `plugins.<owner>.keybinds` (nil for a core command borrowing another's bind) and `key` its default bind. |
| `ctx` | `{buf, path, language, root, selection_text}` (`path` is `""` for an unnamed buffer), plus `items` (the focused pane's selection, any plugin's command), `item` (the item under the cursor in any focused list, shaped like an entry of `items`), `files` (all selected paths, in list order; on a narrowed walk a selected dir stands for its in-scope files) and `view` (this plugin's focused view). A command's ctx is taken when it is invoked, so it stays put across awaits; `files` on a walk keeps the selected rows and expands them on first access, and `selection_text` is read on first access, nil once the buffer changed since the invocation. |

### Events
`qed:on(event, fn) -> handle`, removed with `handle:off()`.
- Handlers run as coroutines, in plugin load order.
- A coalesced event fires at most once per main-loop iteration, after dispatch, and again within the same flush for a change a handler (or a task resumed by a dialog) made.

| Event | Args | Core waits |
|---|---|---|
| `startup` | | |
| `buf_open`, `buf_enter` | `b` | |
| `buf_close` | `b`, `path` | |
| `buf_pre_save` | `b` | **yes**, bounded by `plugin_hook_timeout_ms`. On timeout the save proceeds, logging `.Warn` with the slow plugin's name. |
| `buf_save`, `buf_reload` | `b` | |
| `buf_changed` | `b`, `rev`, `typed`, `lo`, `hi` | coalesced. `lo..hi`: the rows touched since the last delivery to any subscriber (a coalesced union, current rows; the whole buffer for a rev change with no recorded edit); rows above `lo` are unchanged, rows below `hi` only shifted. `typed`: the latest change was the user typing a character, Enter, Backspace or Delete (no Ctrl/Alt), not a paste, undo, command or plugin edit. |
| `cursor_moved` | `b` | coalesced |
| `language_changed` | `b` | |
| `root_changed` | `old`, `new` | |
| `config_changed` | `changed`: set of this plugin's top-level keys whose merged value changed (`{}` when only core config did); apply just those to keep live toggles of the others | |
| `theme_changed` | | |
| `term_open`, `term_close` | `name` | |
| `term_exit` | `name`, `code` | |
| `quit` | | yes, bounded by `plugin_hook_timeout_ms` |
| `plugin_loaded`, `plugin_unloaded` | `id` | After startup only (hot reload, enable, disable, a setup error); the plugin itself does not get its own. A reload queues `plugin_unloaded`, then its `startup`, then `plugin_loaded`. |
| `"<plugin>:<event>"` | `data` | A custom event from that plugin's `qed:emit` (below). |

There is deliberately no `key` event.

### Plugin communication

Per [panes.md](panes.md) §6 (D10). Setup registers only; cross-plugin calls happen in `startup` and on `plugin_loaded`.

| Function | Notes |
|---|---|
| `qed.export(fns)` | Setup only, once per load; `fns` maps names to functions (anything else raises). They run in the caller's task (they may wait) against the owner's state; a call from a coroutine the plugin made itself raises. Unloading the owner stops every task inside one of its calls (the caller gets a warning), and code kept from an old load (closures, handles) raises once the plugin reloads. |
| `qed.plugin_enable(id, on)`, `qed.plugin_reload(id)`, `qed.plugin_source(id)` | Enable/disable (persisting `plugins.<id>.enabled`) or reload another plugin at the next flush; the bundled source of a plugin. `qed.plugins()` rows carry `error`, `load_ms`, `main`, `fork`. The bundled `manager` plugin (*Plugin Manager: Open*) is the Plugins pane over these. |
| `qed.plugin(id) -> table \| nil` | The owner's exports, or `nil` when it is not loaded (the installed check). Raises during setup. The proxy's `qed.caller()` is whoever called `qed.plugin`. Each call raises `plugin '<id>' was unloaded` once the owner unloads or reloads, so callers drop it on `plugin_unloaded` and fetch again on `plugin_loaded`. Tables passed either way are read-only by convention. |
| `qed.caller() -> id \| nil` | Inside an exported function, the calling plugin, so owners key per-caller state and drop it on `plugin_unloaded`; `nil` elsewhere. |
| `qed:emit(name, data?)` | `name` is `"<own id>:<event>"` (anything else raises). Queued like core events, one task per `qed:on(name)` handler, all given the same `data`; a no-op without subscribers. Handlers go with their plugin. |

Exports of the bundled `filetree` plugin (all per caller): `set_tab{label, paths, virtual?, cmd?, detail?, preview?,
missing?, empty?}` (adds or replaces the caller's tab; `preview(path)` returns a base string or nil and runs in the tree's
task; `missing(path)` runs on Enter over a listed path missing on disk; `empty` is the hint while the tab lists nothing), `remove_tab(label)`, `set_marks(marks)`,
`set_ignored(paths|false)`, `open(label)`, `dotfiles()` (the live show-dotfiles state, toggles included). It emits `filetree:refresh` when it opens and after its file operations.

### UI
| Function | Notes |
|---|---|
| `qed.message(text, level?)`, `qed.log(text, level?)` | Level last, default `"info"`. Always attributed to the plugin's display name. `qed.message("")` clears the message line. |
| `qed.ui.open(spec) -> view \| nil, "busy"\|"closed"` | A pane on the core model ([panes.md](panes.md) §5, M1 as built): `id`, `place` (`center`/`full`/`split`), `size`, `kind` (`exclusive`/`child`), `parent`, `focus = false` (passive), `title`, `fields` (`{prompt?, text?, mode = filter\|query\|input\|path, count?}`), `list` (`{items (a table or a `qed.List` handle), multi?, max?, empty?, selected?, sort?}`), `modal`, `preview = "auto"`, `text` lines, `markdown` (a `full` body rendered by core, see below), `max_width` (center/full box cap), `backdrop` (`none`/`dim`/`blank`: everything below the pane except the status rows), `toggle` (a command's visible name whose chord closes the pane; default the opening command; `false`: none), `jump_closes` (`qed.jump` closes it), `info` (full/split: a strip above the footer with this text wrapped, never truncated while 3 list rows remain; `v:info(text)` replaces it, `""` hides it), `footer = {hints, chips}` (chips `{label, cmd, on}`), `tabs` (`{label, cmd?}` or labels) + `tab`, field `hint`/`esc_clears`, `list.tree` (a walk handle as a tree) and `list.columns` (`{title?, width?, min?, max?, right?}`, items carry `cells`; `width` is a fixed `n`, `"fit"` (grows to the widest cell seen: the first 1000 items and every drawn row, never shrinking while open) or `"fill"` (default, shares the rest); a narrow pane shrinks fill columns, then fit columns to `min`, cells clip with `…`; `right` right-aligns cells, titles stay left; any `title` adds a header row and a rule under it that stay put while the list scrolls), `size = "split:tree"`, `on = {activate, change, query, close, link, tab, expand, submit}`. `v:set(h, {selected?})` swaps in a handle (selection kept by key, or `selected`), `v:reveal(path)` expands and selects in a tree, `v:footer{hints?, chips?, input?}` (`input = {prompt?, text?, mode?}`; `mode = "chord"` captures the next bindable key in core and submits its config string, Esc cancels), `v:tab(i?)`, `v:preview(false\|"auto"\|{path, base?, diff_only?})`, `v:expand(true\|false\|path, open?)` (no argument: collapse all when a shown dir is open, else expand all), `v:selection() -> item, row, anchor, count` (nothing once closed), `v:select(row, anchor?)`, `v:on(event, fn|false)`, `v:marks(map, {replace?, detail?, total?})` (`detail = false` hides suffixes and sizes). `link(v, target)` fires on a click on a markdown link; `#anchor` only when `link` is set (else core scrolls). `scope` makes the pane run that scope's commands. `v:scroll(row?)` gets or sets a body's top row (clamped to what can show). `v:source_line(row?) -> source, row` maps a terminal row (default the body top, clamped to the body) to the source line shown there (code and table rows exactly, reflowed blocks to their first line), `v:source_scroll(source, row?)` puts that source line's block on a terminal row (clamped to the body), so a pane's border and title rows do not shift it; a markdown view's `close` handler still reads its last `scroll` and `source_line`. Items are strings or `{label, detail?, value?, path?, pos?, buf?, key?}`; `buf` previews that open buffer live; any other field of a Lua item survives into `activate`, `change` and `ctx.items` (the same table). Raises in `setup`. |
| `on.activate(v, items)`, `on.change(v, item)`, `on.query(v, text)`, `on.close(v)` | Queued during input dispatch, run as tasks in the flush before the next frame. `change` coalesces per flush and kills the previous run; `query` runs at open and `PANE_QUERY_DEBOUNCE_MS` (120) after typing stops, killing the previous run and the `qed.spawn` it waits on (not `spawn_bg`); close kills both. Activate leaves the pane open. |
| `qed.open_url(url) -> true \| nil, err` | Platform opener (macOS `open`, WSL `wslview` else `explorer.exe`, Linux `xdg-open`), detached; headless sessions only log `Open URL:` at Debug. |
| `v:set(items, {selected?, more?, hint?, columns?})`, `v:append(items)`, `v:update(key, fields)`, `v:text(lines)`, `v:info(text)`, `v:markdown(text)`, `v:anchor(slug)`, `v:close()` View methods that change the view return `true`, or `nil, "closed"` once it is closed (`update`: also `"not found"`); value-returning ones (`tab`, `scroll`, `source_scroll`, `anchor`) return `nil, "closed"` instead of the value. `anchor` scrolls a markdown body to a heading slug and returns the heading's source line, or `nil, "not found"`. `reveal` fails with `"not listed"`, `expand` with `"loading"`. `max` caps the list and shows `N+`; `set`'s `columns` replaces `list.columns`. `markdown` keeps the scroll; core renders at the pane width, caches per width and theme, so a `buf_changed` handler only passes text. The scroll persists by `id`. |
| `v:tab(i?, tabs?) -> i \| nil, "closed"` | The active tab; `i` switches without `on.tab`; `tabs` replaces the tab row first (validated before anything changes). |
| ⏳ `v:wait() -> items \| nil, index \| nil, text \| nil` | The next activate (items, the first one's index, the first field's text) or the close (`nil, nil, text`). |
| ⏳ `qed.pick{items, prompt?, selected?, on?} -> item \| nil` | The bundled `dialog` plugin's export (a qed.ui mount in the `alert` layer). Items with `path` get a list + `preview` split. `selected` is an item index or label; `on = {change}` runs on every highlight move (live preview). Esc or an outside click returns `nil`. |
| ⏳ `qed.prompt{prompt, text?} -> string \| nil` | The `dialog` plugin: one input field. |
| ⏳ `qed.confirm{question, choices?} -> index \| nil` | The `dialog` plugin: the question and a choice list; `choices` defaults to `{"Yes", "No"}`. |
| `qed.status.set(id, {text, color?, side?, drop?, sep?})`, `qed.status.clear(id)` | Pushed segment, fitted by `status_fit`. `id` is per plugin; `set` replaces it in place. `text` is a string or a list of `{text, color?}` chunks, each painted in its color; `""` hides the segment but keeps its place. `sep` is the text before it (two spaces). A segment that still overflows once nothing is left to drop is clipped with `…`. `side` defaults to `left` (after the builtins and the `[n/m]` buffer counter); `early = true` puts a left segment before `[n/m]` and another plugin's base label (the git segments); `right` segments sit left of the builtins. `drop` defaults to 1 (among the first dropped); 0 is never dropped. Tabs and newlines become spaces. Cleared on unload. |
| `qed.clipboard.get()`, `.set(text)` | |
| `qed.theme.set(name, {persist?})`, `.list()`, `.current()`, `.icon(name)` | `icon` is a theme icon such as `status_branch`. |

- `qed.pick`/`prompt`/`confirm` draw above old panes and take keys first; one is open at a time (a second returns `nil, "busy"`), as while a core safety dialog (quit, close, conflict) shows. Unloading the asker closes it.
- The chord of the command that opened a pane closes it like Esc (the core pane convention). A command of the view's own plugin run while it has focus (a `scope` command's chord or the scoped Ctrl+P) gets it as `ctx.view`.

### Terminals (`qed.term`)
Core owns PTY and vterm. Each session has a name.

| Function | Notes |
|---|---|
| `qed.term.create{name, cmd?, cwd?, env?, restart?, detach?} -> true \| nil, err` | Starts in the background without showing. `cmd` (run by `/bin/sh -c`) nil means an interactive shell. `cwd` defaults to the root. Fails with `nil, "already running"` if the name is live, unless `restart = true`, which restarts it with the new spec. An exited session of that name is replaced. `"shell"` cannot be created, killed, restarted or closed by a plugin. |
| `qed.term.shell()` | Starts the default `"shell"` session if needed (`nil, "terminal unavailable"` when it cannot). Showing is the bundled `terminal` plugin's: `qed.plugin("terminal").show(name)` (a `qed.ui.terminal` node in its pane, the name as title; `"shell"` starts it) and `.hide()`; its *Terminal: Toggle* (Alt+t) shows `"shell"`. Raises during `setup`. |
| `qed.term.kill(name)`, `.restart(name)`, `.send(name, text)` | Each returns `true` or `nil, "no such session"` (`restart`: also `"cannot start"`, `send`: `"not running"`). `kill` SIGKILLs the session's process group and keeps its output. `restart` kills and respawns with the same spec on a fresh screen. `send` writes raw bytes (`"\r"` is Enter); input the program does not read is buffered up to 1 MiB, the rest dropped with a warning. |
| `qed.term.state(name) -> {name, running, code?, pid?, busy?} \| nil`, `qed.term.list()` | `code` is the last exit code (128 + signal when killed). `busy`: a program other than the session's own process holds the foreground (the shell is running a command). `list` is in creation order. |
| `qed.term.close(name)` | Kills the session and frees its scrollback. |

A `term_exit` event fires when a session's process exits, including `kill`, but not
on `restart`, `close` or teardown. `term_open` fires whenever a session's process starts
(create, restart, Alt+t), `term_close` when a session is closed (also on plugin unload, not
at teardown). Sessions created by a plugin die when it unloads,
unless they were created with `{detach = true}`.

### Decorations
- Push only, namespaced per plugin: `ns = qed.deco.ns(name)` (same name, same id). A namespace is usable only by its plugin; unload clears all of them.
- Styling goes in the last argument, an options table (`{color}`, `{color, alpha?}`, `{above?, color?}`; `span` takes `{fg?, bg?, ...}` since it colors both). Colors are theme keys, never hex; an unknown key raises. They resolve per frame, so a theme change recolors.
- Row anchors shift inside `buffer_insert`/`buffer_delete` (no Lua). An insert at col 0 pushes that row's decorations down with its text, unless the row was empty (a replaced hunk keeps them on its first row). A whole-line delete (col 0 to col 0) drops the deleted rows; a joining delete drops the rows joined into the first. Tints shrink instead of dropping. Spans on any edited row drop. Undo shifts anchors back but never restores dropped decorations. A reload applies its changed hunks through the same primitives, so decorations on untouched lines stay.

| Function | Notes |
|---|---|
| `qed.deco.gutter(b, ns, row, glyph, {color})` | Mark column, one single-width glyph. A diff-base mark on the row wins; among decorations the last pushed wins. |
| `qed.deco.tint(b, ns, from_row, to_row, {color, alpha?})` | Goes through the `editor_line_bg` stack: diff hunk, decoration tints (push order), current line. `alpha` is a number or a theme tint key (`"conflict"`, `"ai_edit"`, resolved per frame); default the theme tint `decoration`. |
| `qed.deco.ghost(b, ns, row, lines, {above?, color?})` | Virtual rows, one clipped row each, folded into the screen-mapping walkers like the diff ghosts. Order: decoration ghosts above, diff ghosts above, the row, decoration ghosts below, diff ghosts below. Like the diff ghosts, ghosts above the top screen row are hidden. `color` defaults to `ghost_foreground`. |
| `qed.deco.span(b, ns, from, to, style)` | `{fg?, bg?, alpha?, bold?, underline?}`, over syntax and diff word colors, under find matches and the selection. `alpha` (number or theme tint key, needs `bg`) blends `bg` over the line background. |
| `qed.deco.eol(b, ns, row, text, {color})` | Virtual text one cell after the line end (last wrapped row), clipped at the window edge (a wide char never splits). Several on a row join with a space. |
| `qed.deco.mark(b, ns, from, to) -> id`, `qed.deco.range(b, ns, id) -> from, to \| nil` | A range anchor, never drawn. Text inserted at or before `from` shifts it, at or after `to` leaves it; an edit overlapping its inside (a reload touching it included) or a clear removes it (`range` then returns nil). |
| `qed.deco.inline(b, ns, pos, text, {rev?}) -> true \| nil, err` | One per buffer: dimmed text at the cursor, not in the buffer, continuation lines on reserved rows. Shown while the cursor stays at `pos` without a selection. Core handles its keys before anything else: `Tab` inserts it, `Ctrl+Right` its next word (the rest stays), any other key, a click or an edit drops it. Nothing is set and `err` is `stale`, `not at cursor`, `selection` or `empty` otherwise. |
| `qed.deco.clear(b, ns, from_row?, to_row?)` | Decorations, marks and the inline ghost touching the rows; all when omitted. |

Cost (`bench_decorations`, debug build, 10k-line buffer): 10k decorations add ~40 us per keystroke (anchor shift) and ~0.17 ms per frame; 50k add ~160 us and ~1.2 ms.

### Processes, timers
| Function | Notes |
|---|---|
| ⏳ `qed.spawn{cmd \| argv, stdin?, cwd?, env?, on_line?} -> {code, stdout, stderr} \| nil, err` | Async on `subprocess.odin`. `cwd` defaults to the root. `nil, "cannot start <cmd>: <err>"` when it cannot start (an `argv` program or the `cwd` missing); under `cmd` a missing program is exit 127. Past 32 MiB of stored output the process group is killed and it returns `nil, "output too large"`. stderr is always stored until the result is collected, so a long-lived `on_line` or `spawn_bg` process is killed once its uncollected stderr reaches 32 MiB. |
| `qed.spawn_bg{...} -> proc \| nil, err` | `proc:kill()`, ⏳ `proc:wait()`. Killed on unload and on quit. Fails like `spawn`. |
| ⏳ `qed.sleep(ms)` | `qed.sleep(0)` yields to the next main-loop iteration: a long loop calls it now and then to stay inside the slice budget. |
| `qed.defer(ms, fn)`, `qed.every(ms, fn) -> timer` | Stop with `timer:stop()`. |

### Files, JSON, paths, config
| Function | Notes |
|---|---|
| `qed.fs.read`, `.write` (atomic; `{exclusive = true}` creates, failing on a taken name), `.exists` (`{follow = false}`: a dangling symlink exists), `.stat`, `.list` | Synchronous. |
| `buffer:line_list() -> qed.List` | A core list handle over the buffer's lines (an edit, reload or close shows on the next frame: the filter is recomputed keeping the selected line, a closed buffer empties it); items reach Lua as `{label, buf, pos}` (`pos.col` the first non-blank). Under a filter field matches stay in buffer order and `:N` / `:N:M` selects that row; a bare number puts row N first, then the text matches; a view opens on the match nearest the cursor. |
| `qed.fs.walk{root?, dotfiles?, ignored?} -> qed.List` | A core handle over every path under `root` (default the root): threaded walk, background prewarm when a view opens over it, shared by equal options, rerun after `qed.fs` writes under its root (a stale walk serves its old items until the rerun lands); dotfiles and the root's ignore set drop unless asked. `h:count()` (`nil, "pending"` until `h:ready()`), `h:ignore(paths|false)` (the ignore set of every walk of that root; `false`: not known yet, no background walk), `h:release()`, `h:within(paths)` (keep listed paths, ancestors and what is under a listed dir), `h:union(paths)` (add missing paths, e.g. deleted files). Items `{label, path, dir?, depth?}`. |
| `qed.fs.copy(src, dst)`, `.rename(src, dst)`, `.remove(path)`, `.mkdir(path)` | `true` or `nil, "exists"\|"not found"\|"into itself"\|"not a file, dir or link"\|"the root"\|"failed: <path>"`. Never overwrite; symlinks are copied as links and never followed; fifos and devices are refused (skipped inside a copied dir); rename works across filesystems (mtimes kept) and repaths open buffers; `remove` refuses the root and its ancestors. Every write, `qed.fs.write` too, restales the walks under it. |
| `qed.fs.dirs{path?, dotfiles?} -> qed.List` | A core list handle over `path`'s subdirs (default the root), or under a `path` field over the dir its text names, prefix-matched. Items stay in core; activate/change hand Lua `{label, path}`. Freed when collected or when the creating plugin unloads (also for other plugins holding it). |
| `qed.json.decode`, `.encode` | `core:encoding/json` |
| `qed.path.join/dir/base/rel/abs`, `qed.shell_quote` | |
| `qed.parse_locations(text, {cwd?}) -> {label, path, pos}[]` | Parses `file:row:col: msg`, `file:row:col`, `file:row: msg` and `file:row` lines (CRLF ok; the shortest file wins, so `a:b.txt:4: m` is `a:b.txt`) into `qed.pick` items. Relative files resolve against `cwd` (default the root); lines naming a missing file are skipped; labels are root-relative. `{}` when nothing parses. |
| `qed.root()`, `qed.version` | |
| `qed.new_buf{text?, language?} -> buf \| nil, err` | Opens a clean unnamed buffer holding `text` (replaces the untouched welcome scratch) and switches to it; `nil, err` on an unknown language. |
| `qed.config_path()`, `qed.config_defaults()`, `qed.config_schema()` | The user config file path (`""` without a home), the embedded `config/config.json` text and the embedded `config/schema.json` text (per core key, dotted with `*` for one segment: `{description, choices?, min?}`). |
| `qed.config_set(keys, value) -> true \| nil, err`, `qed.config_unset(keys) -> true \| nil, err` | Write or remove one key of the user config.json (`keys`: a top-level key or a path list) through the same writer as theme persist and the Plugins pane's `e`: nothing else is touched, a file that does not parse is never overwritten (`err`), an empty table is written as a list, empty parents go with an unset key. The config hot reload applies it (polled at once, silently, as an own write). |
| `qed.plugins() -> {id, display, description, state, bundled, options?, info?}[]` | Every plugin in load order; `options` and `info` are copies of its `qed.options` defaults and info, once loaded. |
| `qed.set_root(path, {discard?}) -> true \| nil, err, info` | Switch the working root: closes buffers outside it, restarts LSP, resets the tree, fires `root_changed`. While an unsaved outside buffer is not in `discard` (buffer objects) it closes nothing and returns `nil, "unsaved", {total, unsaved, bufs}`. `nil, "not a directory: ..."`. |
| `qed.options(defaults, info?) -> table` | Declares this plugin's config keys and defaults, returns the merged config. Setup only, once per load; raises otherwise. `enabled` and `keybinds` are reserved and raise. Objects merge per key, lists and other values replace; a user value whose type differs from the default's warns and keeps the default; `null` drops a default. `info` maps option keys to a description or `{description?, choices?}` for the settings menu (an object option's description covers its leaves); a key missing from `defaults`, an unknown field, empty choices or a default outside them raise. |
| `qed.meta{display_name?, description?}` | Plugin metadata. Setup only, once per load; unknown fields, a non-string or empty `display_name` and a non-string `description` raise. `description` is one line for the Plugins pane. Must come before any `qed.command`. A display name another loaded plugin uses, or a core log label (`PLUGIN_RESERVED_LABELS`), raises. |
| `qed.config() -> table` | This plugin's merged subtree. Read-only. |
| `qed.opt(key)` | Read-only core knob. |
| ⏳ `qed.lsp.format(b) -> true \| nil, err` | Core LSP formatting. `err`: `disabled` (`lsp.enabled` off), `no server`, `unavailable`, `stale`, `timeout` (`plugin_hook_timeout_ms`) or `error`. |

### Type stubs
- `plugins/meta/qed.lua` (`---@meta`) is maintained by hand next to `src/plugin_api.odin`. Tests fail if a registered `qed.*` function or a method of a qed object (view, list, handle, timer, proc) is missing from it, or if it declares one that does not exist.
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
| Errors | Every Odin→Lua entry goes through resume/pcall with a traceback. Only load and setup errors mark the plugin errored (unloaded). A Lua error in a command, handler, timer or any other task is logged and the plugin stays loaded; a repeat of the plugin's last error logs again only at the 2nd, 4th, 8th, ... repeat (`(repeated N times)`). A task over its budget or out of memory is stopped with a warning. All errors are logged as `.Error` under the plugin's display name and the traceback at `.Debug`. Each plugin's last error is kept for the Plugins pane. A memory cap turns OOM into a catchable `LUA_ERRMEM`. |
| Modules | `modules.git` became `plugins.git`, and phase 11 removed `.Git`: the Git tab is the `git` plugin's (through `filetree` exports since M6), conflicts are the `conflict` plugin's since M7. Phase 13 made `modules.lsp` the top-level `lsp` section, gated on `LSP_ENABLED`. M7 made `modules.ai` the bundled `ai` plugin. |

Hot reload mechanics:
- `plugins_poll` runs in the disk poll, before the config reload. It rescans bundled plugins plus `Plugins.user_dir` (headless sessions have none and never poll).
- `Plugin.stamp` hashes mtime and size of a single-file plugin, or of every `*.lua` file under a dir plugin. Dot entries are skipped, and symlinks below the top-level entry are not followed. Cost is ~13 us per file (`bench_plugin_poll`).
- On any difference `plugins_sync` unloads removed, changed or shadow-swapped plugins while they are still in the list, rebuilds the list in load order, then loads. The Plugins pane keeps its selection by name.
- Unload frees the plugin's tasks first (their `__close` runs), then hooks, timers, processes (whole process group) and pooled threads.
- A load after startup queues `startup` for that plugin only (`PluginQueued.only`).
- Config hot reload (`plugins_config_apply`): re-merge each loaded plugin's config, apply `enabled` flips and config-driven reloads (`Plugin.cfg_sig`; subscribers adopt the new signature), flush `config_changed`, then `plugins_rebind`, each loaded plugin's unknown keys (`Plugin.unknown`, computed at merge) and the unknown-plugin warning. Outside a config apply, a load warns its own unknown keys. A config that fails to parse leaves plugin state alone.
- Commands registered after the first full bind (`Plugins.bound`) report their own key problems, except inside that window (`binds_deferred`).

### Plugins pane (the `manager` plugin)
*Plugin Manager: Open* (palette, no default bind) mounts it on qed.ui. `e`, `r`, `l` are its scoped commands
*Enable/Disable*, *Reload*, *Show Log* (rebindable under `plugins.manager.keybinds`). Rows: Name, Description,
Source (`bundled`/`user`), Status, Load; the selected row's last error is the footer. Enter opens a user
plugin's file, or a bundled one's embedded source read-only (a fork hint into the user dir). `e` writes only
`plugins.<id>.enabled`; enabling, disabling and reloading run at the next flush (`qed.plugin_enable/reload`).
It needs Lua: with Lua failed to start there is no list (it was core for that reason before).

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
  - An edit after an await follows the pattern: read `rev`, await, then edit with `{rev = r}`. If the rev is stale, the edit returns `nil, "stale"` and the plugin drops the result, the same pattern LSP formatting already uses.
  - Edits validate before the first primitive runs, so a group never half-applies.
- **GC.** Lua's collector is stopped; the scheduler steps it between slices (2 ms per pump or keystroke, then up to 8 ms more paying for what was allocated since, 32 ms past half the cap, back to back while idle; a cycle per doubling of the heap or halfway to the cap; one `lua_gc` step is bounded, see `lib/lua/PATCHES.md`), so a slice never pays for a collection. `collectgarbage` takes only `collect`, `count` and `step`.
- **Hook budgets.** A `lua_sethook` count hook runs every 100k instructions and checks the wall time of the current resume slice. Time spent waiting in a yield doesn't count.

  | Entry | Soft (Debug log) | Hard |
  |---|---|---|
  | events, timers | 50 ms | `plugin_slice_max_ms` (1 s): the task stops, a warning is logged; a repeating timer or hook stopped 3 times in a row is removed with an error |
  | commands, `when` | n/a | `plugin_command_max_ms` (5 s): the task stops, a warning is logged |
  | `setup` | 2 ms | 1 s: the plugin is marked errored |

  A stopped task, a task's out-of-memory error and a task's own Lua error leave the plugin loaded. The memory cap is shared by every plugin, so the task that hits it may not be the one holding the memory: qed runs a full collection, stops only that task and logs one rate-limited error with the cap and the usage after collection; it never disables a plugin. An exported function runs under its caller's task budget.

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
| Deterministic spawn | `qed.spawn` routes through `subprocess_start`, so `t.stub` scripts already cover fake formatters and git. Add `e2e_spawn_fake(pattern, {stdout, code, delay_ms})`, a table the spawn binding consults first under test (no fork), so ordering and timeouts are exact. |
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
| 11 | A file tree status provider (replaced by the `filetree` exports in M6); the Git tab's scan, sizes, renames, deleted files, ignored set and preview base move to `plugins/git/tree.lua`. `git.odin`, `ctx.base`, the `.Git` module and `g_git_loaded` are gone; *File Tree: Git* becomes *File Tree: Changed*. | minor |
| 12 | Query-driven `qed.pick` (`query`, `on_query`, `picker:set`), the opening command's chord closes a modal, `ctx.files` expands scoped-tab dirs. Project search moves to `plugins/search` (*Find in Files* and the tree's *Search*); `projsearch.odin` and `projsearch_min_query` (now `plugins.search.min_query`) are gone. | minor |
| 13 | `qed.meta{display_name}`, display names everywhere a plugin is named, automatic `<display name>: ` command prefix, `qed.message` without `source`, keybinds under `plugins.<id>.keybinds` (plugin binds leave the top-level `keybinds`), the `Lua` LSP settings go out only under the config dir, `modules.lsp` becomes `lsp` and `.Lsp` leaves the `Module` enum, `pickers` becomes `settings` (`plugins.settings`), the `tasks` plugin is dropped (`plugins.tasks`, its picker and `tasks N` segment; `qed.term` stays). | minor |
| M1 | `qed.ui.open` and views (set/append/update/text/close/wait), queued `activate`/`change`/`query`/`close`, exclusive panes persisted by `id`, `ctx.view`; `qed.pick/prompt/confirm/pane` become prelude sugar (`pick` over an open pane is a child, not `"busy"`); `search` streams parallel `rg --line-buffered` into a key-sorted query pane. | minor |
| M2 | Palette core-built on a commands list source; core list handles (`qed.fs.dirs`), `path` field mode, `qed.set_root`; the cwd picker becomes the bundled `workspace` plugin (*Workspace: Open Directory*, tree *Workspace: Open Selected Directory*), `cwdpick.odin` and the top-level `Change Working Directory` keybind are gone. | minor |
| M3 | Accessor-backed list sources, pane-scoped commands (`scope` on `qed.command` and `qed.ui.open`, bare keys, `ctx.view`), `qed.buf.line_list`; line find becomes the bundled `goto` plugin (*Go To: Line*, `plugins.goto.keybinds`); `ctx.items`, `qed.shortcut`, `v:scroll`; markdown preview Back/Forward, `linefind.odin` and the top-level `Find Line` keybind are gone; Message Log, Plugins pane and LSP rename prompt core-built on the model. | minor |
| M4 | `qed.fs.walk` handles (`count`, `ready`, `within`, `union`), `qed.fs.copy/rename/remove/mkdir`; the file tree core-built on the pane model; `qed.ui.open` tabs, marks, footer chips and input, tree lists, `v:preview`, `v:expand`; `search` stacks as a child over the tree. | minor |
| M5 | The file tree becomes the bundled `filetree` plugin (*File Tree: All* replaces *File Tree*, binds under `plugins.filetree.keybinds`); `filetree.odin` becomes `walk.odin`; a temporary provider shim (gone in M6); `toggle = false`, `jump_closes`, `v:select`, `v:expand()`, `h:ignore(false)`, `qed.close{discard}`. | minor |
| M6 | `qed.export`/`qed.plugin`/`qed.caller`, `qed:emit` + `qed:on("<plugin>:<event>")`, `plugin_loaded`/`plugin_unloaded`; `filetree` exports `set_tab`/`remove_tab`/`set_marks`/`set_ignored`/`open`, `v:tab(i, tabs)`; the `git` plugin adds the Git tab (*Git: Changes*, `Alt+g`, `plugins.git.keybinds.Changes`; *File Tree: Changed* is gone); `treeshim.odin`, the provider shim and the `.Provider` task kind are gone; task errors no longer disable a plugin. | minor |
| M7 | The merge-conflict UI becomes the bundled `conflict` plugin (*Conflict: Resolve*, `Alt+m`, `plugins.conflict.keybinds.Resolve`; the top-level `Git: Resolve Conflict` bind warns where it moved); the bundled `ai` plugin (*AI: Edit Selection*, *Cancel Edits*, *Toggle Inline Completion*, `plugins.ai.*`, binds under `plugins.ai.keybinds`); `qed.buf.find_lines` (lists, `word`), `qed.buf.big`, `qed.text.diff`/`diff_rows`, `qed.deco.mark`/`range`/`inline`, theme tint keys as deco alphas, blended spans, `buf_changed`'s `typed`/`lo`/`hi`, change detection every flush round, hunk-applied reloads; `conflict.odin`, the core `merge` pane, `aiedit.odin`, `llm.odin`, `fim.odin`, `modules.ai` and `.Ai` are gone. | minor |
| M8 | The module system is removed (`module.odin`, `Module`, `module_enabled`, `Command.module`, `config_module_defs`, the `modules` parsing); old `modules.ai/git/lsp` keys still warn "moved to". | minor |
| M9 | Config key review: one `CONFIG_MOVED` table drives every "moved to" warning; `filetree_show_dotfiles`/`_ignored`/`_diff_only` become `plugins.filetree.show_dotfiles`/`show_ignored`/`diff_only` (live), `filetree_list_*`/`code_list_*`/`preview_*_width` become `split_tree_*`/`split_code_*`/`split_preview_*`, `plugins.ai.chat_command` becomes `edit_command`, the `format` knobs become `on_save`/`trim_whitespace_on_save`/`final_newline_on_save`; *Diff: Toggle View*, *Message Log: Open*, *Plugins: Open*, *Go to: Line*; the workspace picker follows the tree's dotfiles (`filetree` export `dotfiles`); markdown Back/Forward use `bind_from`; a disk reload is one undo step (cleared above `big_file_bytes`). | minor |
| later | The remaining panes: the pane model's M steps ([panes.md](panes.md) §7). `qed --test-plugin`. | |

## 9. Decisions

1. 1-based rows and byte columns, half-open ranges.
2. Vendor the Lua source in `lib/lua` and build it static, since `vendor:lua` uses the system library on macOS and Linux arm64.
3. Load and setup errors disable the plugin; any other Lua error only logs (collapsed when it repeats).
4. Default keys are declared via `key=` in `qed.command`, overridable by `plugins.<id>.keybinds[name]`.
5. Git: diff engine and tree rendering core, plumbing (including the Git tab's data) in Lua.
6. One `format` plugin orders save fixups before formatting. No hook priorities.
7. Formatter config lives in `plugins.format.commands.<lang>`.
8. The stub is auto-written to `$XDG_DATA_HOME/qed/lua/qed.lua` and fed to lua-ls via `Lua.workspace.library`, sent only when the working root is under the config dir. No Lua type file is written.
9. AI moved in M7 once decorations existed. The inline ghost stays core: accepting and dismissing it are keystroke-path work, so Lua only supplies the text.
10. One Lua state with a per-plugin `_ENV`.
11. A user plugin with a bundled name replaces the bundled one.
12. Background sessions are core `qed.term`; the bundled `tasks` plugin was dropped in phase 13.
13. `Enter` on a bundled plugin in the Plugins pane opens its embedded source read-only. A separate explicit *Fork Plugin* command may come later.
14. One shared knob, `plugin_hook_timeout_ms`, bounds both `buf_pre_save` and `quit`.

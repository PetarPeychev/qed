# Note: pane model

Design for one UI abstraction shared by core and Lua. Status: decided. Build steps are in §7 and tracked in TODO.md.

## 1. Goal

Core keeps UI drawing, the buffer/editing machinery and the Lua API. Everything else becomes bundled Lua plugins.
There is one Odin `Pane` model: core builds it for its own panes, Lua builds it through `qed.ui.open`, and both run
the same render, key, mouse and paste code (D6).

Core owns every key, mouse event, filter, scroll and draw. Lua gets queued semantic events (`activate`, `change`,
`query`, `tab`, `close`), flushed after input dispatch and before render. Big lists stay in core behind list handles;
only visible or selected items cross into Lua.

## 2. Inventory

Refs are phase-11 `src/` unless noted.

### Shared primitives today

| Primitive | Where | What it gives |
|---|---|---|
| `TextField` | `textfield.odin:6`, key `:113`, render `:219` | single-line edit, buffer-parity binds, selection, paste flatten |
| `FuzzyList` | `overlay.odin:9` | field + `matches` + selected/scroll + `Fuzzy` ranker; `fuzzy_list_key` `:189` |
| Centered list render/mouse | `overlay.odin:216`, `:98` | `pane_center(PALETTE_WIDTH, 2+rows)`, label + dim right detail, scrollbar |
| `overlay_layout` / `overlay_split` | `overlay.odin:277`, `:259` | full-size box with `PICKER_MARGIN_X/Y`; list/preview split by min/max classes |
| `overlay_list_mouse` | `overlay.odin:139` | wheel, click row, double-click activate, field click, click-outside close |
| `Preview` | `preview.odin:32`; `set_file` `:97`, `set_text` `:128`, `set_buffer` `:219`, `set_diff` `:321` | highlighted file/buffer/text view, hex for binary, diff with ghost rows, focus row |
| `dialog_*` | `confirm.odin` | question + vertical action list |
| `pane_*` | `pane.odin` | box, hline, scrollbar, fill row, text |
| `Overlay` vtable | `editor.odin:233` | `{active, dispatch, render, mouse, paste}`; first active wins input and render |

### Focus-taking overlays (priority order, `editor.odin:241`)

17 overlays, ~7.8k lines, each hand-rolling layout, key switch, mouse and render.

| Pane | Source (lines) | Placement | Parts | Input beyond core nav | Per-key / per-frame work |
|---|---|---|---|---|---|
| Terminal | `terminal.odin` 990 | full | box, title in border, vterm grid | everything raw to PTY; `Alt+t` defocus; Esc at prompt; drag-select; scrollback | grid walk per frame |
| Message Log | `log.odin:305-618` | full | title, list (time, source, text; level fg; bg-only selection), footer hints + 5 chips | `d/i/w/e/h` toggles, `Shift+Up/Down` range, Copy, follows bottom | filter over ring (`LOG_MAX` 1000) 2x per frame |
| Plugins pane | `plugin.odin:1545-1833` | full | columns (name/source/state/ms), footer = hints or error; Enter on bundled swaps body to read-only `Preview` | `e` enable, `r` reload, `l` log, Enter open | trivial |
| AI edit prompt | `aiedit.odin` 93 | center, 1 row | `AI edit: ` field | Enter submit | none |
| Command palette | `palette.odin:307-411` | center | `> ` field, list (name + shortcut) | own chord closes; contextual table | fuzzy over ~100 names per key; live bind per row per frame |
| Plugin UI (`qed.pick/prompt/confirm`) | `plugin_ui.odin:9-394` | center, or split when items have `path` | field, list (+ multi range), preview / prompt / dialog | `on_change`, `on_query` (phase 12) | fuzzy per key |
| `qed.pane` | `plugin_ui.odin:47` | full | title, colored lines, footer | scroll, Esc | none |
| Change Working Directory | `cwdpick.odin` 316 | center | path field, dir list, nested confirm | Tab or `/` drills in, Backspace after `/` drops a segment | `read_directory` + prefix match per key |
| Line find | `linefind.odin` 240 | split, field full width | field, numbered lines, buffer preview | `:N[:M]` jump syntax | fuzzy over all lines per key |
| Find / replace | `find.odin` 405 | top-right box | 2 fields, `.*` `Aa` chips, `n/m` | Alt+c/r/a, Tab, Enter step/replace, undo pass-through | full-buffer scan per key |
| Project search | `plugins/search` (phase 12) | split, field over list column | query field + count, hint, `path:row text`, preview | debounced rg via `on_query` | debounce 120 ms, async rg |
| LSP rename | `rename.odin` 85 | center, 1 row | `Rename to: ` field | Enter submit | none |
| File tree | `filetree.odin` 2352 | split, tabs row, field over list column | tabs (All/Open/Changed/Unsaved), filter + count, tree list (indent, icons, git bar, `+N -N`, rename suffix), preview (file/buffer/diff), footer chips; `New:`/`Rename:` footer field; 3 nested confirms | rebindable Ctrl-chord commands + scoped palette (af9e4d4), type-to-filter, tab chords, multi range | debounced filter over a threaded walk + cache + prewarm, cap 500; preview debounced 80 ms |
| Quit / Close / Conflict dialogs | `confirm.odin` 271 | center | question + actions | none | none |
| Merge dialog | `conflict.odin:255-303` | center | Keep Ours/Theirs/Both | none | none |

The file tree is the only pane that renders under another (palette or plugin UI over it, `editor.odin:1232`), and
`plugin_overlay_open` exempts it from `"busy"`: a special-cased 2-deep stack.

### Passive popups and chrome

| Surface | Source | Notes |
|---|---|---|
| Completion | `completion.odin:447` | anchored at caret; shares typing keys; LSP |
| Hover / Diagnostic | `editor.odin:1301` / `:1287` | at cursor; markdown / wrapped text |
| Inspect Tokens | `inspect.odin:32` | top-right, re-queries tree-sitter per frame |
| Status bar | `editor.odin:1811` | builtins + pushed plugin segments |
| Welcome | `editor.odin:1875` | art + live keybind hints; shown before plugins load |

### Inconsistencies the model removes

| Area | Today | After |
|---|---|---|
| Split field width | full width (line find), list column (search, tree, path picks) | list column everywhere (D3) |
| Count indicator | tree and search only | any list with `count` |
| Single-letter keys | log, Plugins pane: hardcoded | pane-scoped commands (D4) |
| Nesting | `"busy"` plus the tree exemption | pane kinds (D5) |

## 3. Model

### Principles

1. **One struct, two authors.** `Pane` is plain Odin data. Core panes attach Odin handler procs, Lua panes attach
   registry refs. One `pane_render`, `pane_key`, `pane_mouse`, `pane_paste`.
2. **Core owns interaction.** Keys, mouse, editing, fuzzy filtering, tree expand, scrolling, preview loading,
   debouncing.
3. **Data in bulk, never per row.** Big sets are core list handles; small sets are pushed whole; per-row styling is a
   keyed mark map pushed on change.
4. **Sizes are knob classes, not numbers.** Lua names a class; the class maps to existing config keys.

### Components

| Component | Fields | Core behavior | Replaces |
|---|---|---|---|
| `Pane` | `id`, `owner`, `kind`, `parent`, `place`, `size`, `title`, `tabs`, `fields[]`, `body`, `footer`, `scope`, `toggle` | layout, stacking, click-outside close, toggle chord, paste routing | `Overlay` vtable + 17 structs |
| `Field` | `prompt`, `text`, `hint`, `mode` = `filter` / `query` / `input` / `path`, `count`, `esc_clears` | `filter` re-ranks per key; `query` debounces then emits `query`; `input` returns text on Enter; `path` = cwdpick semantics; Tab cycles fields | `FuzzyList.field`, find/replace pair, prompts |
| `List` | `items` (table) or a list handle, `multi`, `tree`, `follow`, `sel` = `invert` / `bg`, `columns`, `max` (shows `N+`), `empty` | selection, range, scroll, fuzzy, tree expand, keep selection by key on refresh | `FuzzyList`, tree entries, log rows, plugin rows, dialog actions |
| `Item` | `label`, `detail`, `key` (default `path` or `label`), `path`, `pos`, `buf`, `depth`, `dir`, `fg`, `value` | | `PluginPickItem`, `FileEntry`, `Match` |
| `Mark` | `bar`, `fg`, `suffix`, `sizes` (`+N -N`), `hidden` | applied at draw by key; dirs inherit `bar` from descendants | `FileTree.status/diffsize/renames/ignored/deleted` |
| `Preview` | `auto` (from item `path`/`pos`/`buf`), `text{lines, language}`, `diff{path, base}`, `none` | debounced load, hidden below the split minimum, wheel scroll | 4 `preview_set_*` callers |
| `Text` body | styled lines or markdown | wrap/clip, scroll | `qed.pane`, inspect, dialog question, welcome |
| `Tabs` | labels, active, per-tab command | Left/Right, click, chord; emits `tab` | tree tabs |
| `Footer` | `hints` (`{cmd, label}` via `command_shortcut`), `chips` (`{label, on, cmd}`), or a footer `Field` | live keybind strings, right-aligned chips | tree / log / Plugins footers |
| `Term` body | session name | raw input to PTY | terminal interior |

Dialog = `Text` + `List` of actions. Prompt = one `input` field. Palette = `filter` field + commands handle.

### Placement

| `place` | Geometry | Used by |
|---|---|---|
| `center` | `pane_center(width class, rows)`, shrinks to content | palette, pickers, prompts, dialogs, cwd picker |
| `full` | screen minus `PICKER_MARGIN_X/Y` and status rows | log, Plugins pane, `qed.pane`, terminal |
| `split` | `full` + list/preview split; tabs over both, field over the list column, preview full height (D3) | file tree, line find, search, path picks |
| `corner` | top-right box below row 1 | find bar, inspect |
| `cursor` | below caret, flips above (core only) | completion, hover, diag |
| `screen` | whole text area, no box | welcome |

Inside the box, a fixed vertical stack: `[tabs | title]` / `[fields]` / body / `[footer]`, each row only if set. No
layout DSL, no nesting beyond this stack.

### Size classes

| Class | Width | Height | Keys |
|---|---|---|---|
| `palette` | `PALETTE_WIDTH` | content, max `palette_max_rows` | `palette_max_rows` |
| `split:tree` | `filetree_list_*` + `preview_*` | full | 4 |
| `split:code` | `code_list_*` + `preview_*` | full | 4 |
| `dialog` | content, `<= screen - 4` | content | none |
| `corner:find` / `corner:inspect` | `FIND_BOX_WIDTH` / `INSPECT_BOX_WIDTH` | content | consts |

A new class only comes with a new config key, so there is still one place per knob.

### Pane kinds (D5)

The plugin picks the kind per open. There is no user setting.

| Kind | How | Rule |
|---|---|---|
| Exclusive | default | Opening one closes the open exclusive pane. State (query, selection, expanded dirs, tab, scroll) persists by `id`, so reopening restores it. This replaces the pane swap TODO. |
| Child | `parent = ctx.view`, or any `qed.confirm/prompt/pick` opened while a pane is open | Stacks on its parent and takes input. Esc returns to the parent. Closing the parent closes its children. |

While a plugin's confirm or prompt is open, opening another exclusive pane returns `"busy"` instead of cancelling it (decided at M0 review). Core safety dialogs still go on top.
| Passive | `focus = false` | Never takes input; drawn under focused panes. |

Core safety dialogs (quit, close, conflict) are always on top. `"busy"` is returned only while one is showing.
Unloading a plugin closes its panes and their children, kills their `change`/`query` tasks and releases refs.

### Input

Generic dispatch, in order:

| Key | Behavior |
|---|---|
| `toggle` chord | close |
| Command Palette chord | with `scope`: the pane's scoped palette over the pane |
| pane-scoped command chord | run it (`ctx.view` set) |
| Esc | clear a non-empty `esc_clears` field, else close (a waiter gets `nil`) |
| Enter | `input` field: submit; list: `activate` with the selection (range when `multi`) |
| Up/Down, PgUp/PgDn | move selection, or scroll a text/preview body |
| Shift+Up/Down | extend range when `multi` |
| Left/Right | tabs when the pane has tabs, else field caret |
| Tab | next field; `path` field: complete |
| anything else | focused field; a change re-filters (`filter`) or arms the debounce (`query`) |

Custom keys are pane-scoped commands (D4): `qed.command{name, scope = <pane scope>, key, run}`, rebindable, listed in
that pane's scoped Ctrl+P. A single-letter default works only when no field would take the printable (log and Plugins
panes have no field). Log `d/i/w/e/h` and Plugins `e/r/l` become core scoped commands with those defaults.

Mouse is all core: wheel, click select, double-click `activate`, click tab, click/drag in a field, click a chip runs
its command, click outside closes an exclusive pane.

### Events (D8)

Events are queued during dispatch and flushed after it, before render (`main.odin:189`). A handler that does not wait
lands in the same frame. Lua never runs synchronously per keystroke.

| Event | When | Coalescing |
|---|---|---|
| `activate(v, items)` | Enter / double-click | none |
| `change(v, item)` | highlight changed | once per flush; previous task killed |
| `query(v, text)` | `query` field changed | core debounce (120 ms); previous task killed |
| `tab(v, i)` | tab changed | none |
| `close(v)` | any close | none |

Accepted limitation: no plugin can intercept arbitrary raw keys. That rules out modal editing (a vim mode) and
leader-key sequences unless they are added to core. A synchronous key filter with a strict budget could be added later
if ever needed.

## 4. List handles (D2)

Crossing cost, vendored Lua 5.4 at `-O2`, items `{label, path, detail, depth}`, Lua build + C read
(C bench at design time):

| Items | Lua build | C read+copy | Total |
|---|---|---|---|
| 1k | 1.3 ms | 0.4 ms | ~2 ms |
| 10k | 16 ms | 4 ms | ~20 ms |
| 100k | 277 ms | 62 ms | ~340 ms |

100k trips the 200 ms event hard budget and costs ~20 MB of the 64 MB `plugin_memory_mb`. So big or editor-internal
sets are **core-owned list handles**: userdata that Lua creates, passes to views and queries, but never materializes.
Only visible or selected items cross. Small Lua lists (pickers, search hits capped at 500, tasks, git refs, locations)
stay plain tables.

### Constructors

| Constructor | Items | Core work | User |
|---|---|---|---|
| `qed.fs.walk{root, dotfiles?, ignored?}` | `{path, label, dir, depth}` | threaded walk, cache, prewarm; same args share one walk; restaled by `qed.fs.*` writes under its root, its own ignore set changing, and a new handle | file tree, path pickers |
| `qed.buf.line_list(b)` | `{row, label}` | live over the buffer; a `:N[:M]` filter selects that row instead of fuzzy | line find |
| `qed.fs.dirs(path)` | `{path, label}` | follows a `path` field: read dir + prefix match per key | cwd picker |
| `qed.command_list(scope?)` | `{name, shortcut, owner}` | `when` gating, live binds per visible row | palette |
| `qed.log_list{levels?, source?}` | `{time, level, source, text}` | ring view, follows new lines | Message Log |

### Methods

| Method | Notes | User |
|---|---|---|
| `h:count() -> n`, `h:ready() -> bool` | `ready` is false while a walk runs | tree count, empty text |
| `h:get(i) -> item`, `h:index(key) -> i \| nil` | one item at a time | restore selection, reveal current file |
| ⏳ `h:wait()` | resolves once the walk is done | tools that need the full set |
| `h:within(paths) -> h2` | keep items under `paths` (table or handle; a dir keeps its descendants) | tree tabs Open / Unsaved / Git over the walk |
| `h:union(paths) -> h2` | add virtual paths (table or handle) not on disk | deleted files in the Git tab |

Views take either: `view:set(h)` or `view:set(items)`. `ctx.files` on a narrowed handle expands a selected dir to its
in-scope files in core. A handle is freed when Lua collects it; a view holds its own reference.

Rejected: passing the set as one newline-joined string. It still copies every path into Lua and leaves per-key
filtering to Lua. An `h:join()` export may be added if a plugin ever needs the whole set as text (e.g. feeding a tool).

## 5. Lua API

```lua
---@class qed.UiSpec
---@field id? string             -- persisted state + toggle-reopen
---@field kind? "exclusive"|"child"|"passive"  -- default exclusive; child implied by parent
---@field parent? qed.View       -- usually ctx.view
---@field place "center"|"full"|"split"|"corner"
---@field size? string           -- knob class
---@field title? string
---@field tabs? {label: string, cmd?: string}[]
---@field fields? qed.UiField[]  -- {prompt?, text?, hint?, mode?, count?, esc_clears?}
---@field list? {items?: qed.UiItem[]|qed.List, multi?: boolean, tree?: boolean, follow?: boolean, sel?: "invert"|"bg", columns?: table, empty?: string, max?: integer}
---@field preview? "auto"|false
---@field text? (string|{text: string, color?: string})[]
---@field footer? {hints?: table[], chips?: table[]}
---@field scope? string           -- pane-scoped commands + scoped Ctrl+P
---@field toggle? string          -- command whose chord closes it
---@field on? {activate?: function, change?: function, query?: function, tab?: function, close?: function}

---@return qed.View|nil, "busy"|nil
function qed.ui.open(spec) end
-- view: set, append, update, marks, preview, footer, title, tab, close, wait
```

| View method | Use |
|---|---|
| `v:set(items \| h, {selected?, keep?, more?, hint?})` | replace (phase 12 `picker:set`); `keep` reselects by key |
| `v:append(items)` | streaming (rg `on_line`) |
| `v:update(key, fields)` | one row changed (task state) |
| `v:marks(map, {replace?})` | per-row styling by key |
| `v:preview(spec)` | answer an async preview (diff base) |

`qed.pick`, `qed.prompt`, `qed.confirm` and `qed.pane` become ~10-line wrappers in an embedded prelude over
`qed.ui.open` + `v:wait()`; `wait` resolves on `activate` (value) or `close` (`nil`).

```lua
function qed.confirm(question, choices)
	local v, busy = qed.ui.open{place = "center", size = "dialog", text = {question},
		list = {items = choices or {"Yes", "No"}}}
	if not v then return nil, busy end
	local _, i = v:wait()
	return i
end
```

Project search (phase 12 plugin after M1):

```lua
qed.ui.open{
	id = "search", place = "split", size = "split:code", toggle = "Find in Files",
	fields = {{mode = "query", count = true, text = start}},
	list = {max = 500, empty = "Type at least 2 characters to search"},
	preview = "auto",
	on = {
		query = function(v, text)
			v:set({})
			if #text < min_query then return end
			local batch = {}
			qed.spawn{cmd = rg_cmd(text), on_line = function(line)
				batch[#batch + 1] = parse(line)
				if #batch == 50 then v:append(batch); batch = {} end
			end}
			v:append(batch)
		end,
		activate = function(v, items) v:close(); qed.jump(items[1].path, items[1].pos) end,
	},
}
```

File tree (shape, after M6):

```lua
local walk = qed.fs.walk{root = qed.root(), dotfiles = cfg.dotfiles, ignored = cfg.ignored}
local v = qed.ui.open{
	id = "filetree", place = "split", size = "split:tree", scope = "filetree",
	tabs = tab_labels(),                      -- All, Open, Unsaved, plus tabs added by other plugins
	fields = {{mode = "filter", hint = "type to filter", count = true, esc_clears = true}},
	list = {items = walk, tree = true, multi = true},
	preview = "auto",
	on = {
		tab = function(v, i) v:set(tabs[i].list(walk)); v:marks(tabs[i].marks or {}, {replace = true}) end,
		activate = function(v, items) open_or_expand(items) end,
		change = function(v, item) if tabs[cur].preview then ask_preview(v, item) end end,
	},
}
qed.command{name = "Delete", scope = "filetree", key = "delete", run = function(ctx)
	if qed.confirm("Delete " .. #ctx.files .. " files?") == 1 then for _, p in ipairs(ctx.files) do qed.fs.remove(p) end end
end}
```

## 6. Plugin communication (D10)

| Mechanism | API | Rules |
|---|---|---|
| Exports | `qed.export{fn = ...}` in setup; `qed.plugin(id) -> table \| nil` | `nil` when not loaded, which doubles as the installed check. Functions run against the owner's own state. Calls after the owner unloads raise. `qed.caller()` inside an export returns the calling plugin's id, so the owner can track per-caller registrations and drop them on `plugin_unloaded`. Tables received across plugins are read-only by convention. |
| Custom events | `qed.emit("git:status", data)`, `qed.on("git:status", fn)` | Names are namespaced `<plugin>:<event>`. Queued like core events. Handlers are removed on unload. |
| Lifecycle events | `plugin_loaded(id)`, `plugin_unloaded(id)` | For hot reload. |

Lifecycle stays two-step. `setup` registers the plugin's own things (`qed.options`, `qed.meta`, `qed.export`,
commands, handlers) and must not call other plugins. Cross-plugin calls happen in the `startup` event (fires after all
plugins load) and on `plugin_loaded`. No dependency declarations and no third init step: micro's `preinit` is covered
by `qed.options`, `postinit` is `startup`.

Git and the file tree do not depend on each other. The file tree exports `set_tab{label, paths, virtual?, cmd?,
detail?, preview?, missing?}`, `remove_tab(label)`, `set_marks(marks)`, `set_ignored(paths|false)` and `open(label)`,
all kept per caller. Git, when `qed.plugin("filetree")` is non-nil at `startup` or on `plugin_loaded("filetree")`,
sets a tab labeled "Git" whose `paths` are its changed files and `virtual` its deleted ones, pushes status marks and
its ignored set, and answers `preview(path)` with the base text (M6 as built).

## 7. Migration

Each step ships green with its e2e tests moved over. UX is unchanged except where a decision says so.

| Step | Scope | Closes / validates |
|---|---|---|
| M0 (done) | Odin `Pane`, stack, kinds, generic render/key/mouse/paste. Port the 4 core dialogs and `qed.confirm/prompt` onto it as children. | "Collapse the four dialogs" TODO; layout, stack, children |
| M1 (done) | `qed.ui.open`, queued events, prelude `qed.pick/prompt/confirm/pane`, exclusive persistence by `id`, one split layout (D3). Port phase 12 search to a `query` field + `append` (D9). | pane swap TODO; events through flush, split + preview |
| M2 (done) | Palette core-built on `qed.command_list`. Cwd picker becomes a Lua plugin on `qed.fs.dirs` + a `path` field (needs `qed.set_root` and an unsaved-outside-root query). | "Collapse the centered pickers" TODO; handles, `path` field, child confirm |
| M3 (done) | Line find becomes a Lua plugin on `qed.buf.line_list` (field moves over the list column). Message Log and Plugins pane core-built with pane-scoped commands (D4), chips, `sel = bg`, columns, text body swap. Rename prompt on the model (core caller). | scoped commands, footer chips |
| M4 (done) | Extract the walk service from `filetree.odin` behind `qed.fs.walk` (`within`, `union`). Add `qed.fs.copy/rename/remove/mkdir`. Core file tree rebuilt on the model over walk handles (still Odin, provider API intact). | tree items, tabs, marks, footer field, prewarm under the model |
| M5 (done) | File tree becomes a bundled `filetree` plugin (D7); core keeps only the walk service and pane machinery. The Changed tab keeps working through a temporary provider shim. | the model under the hardest pane |
| M6 (done) | Plugin communication (D10): `qed.export/plugin/caller`, `qed.emit` + namespaced `qed.on`, `plugin_loaded/unloaded`. Git adds its tab and marks through filetree exports. Remove `qed.filetree.*` and the shim. | first real cross-plugin user |
| M7 (done) | Conflict UI (the `conflict` plugin) and AI (the `ai` plugin: aiedit, then fim) ported onto the model and decorations. | range-anchored tints and spans, `confirm` choices, inline ghost with no Lua on the keystroke path (D8) |
| M8 | Remove the module system (`modules.*`, `module_enabled`). | |
| M9 | Review every bundled plugin's config keys (existing TODO). | |
| later | Inspect, hover/diag/completion on `cursor`/`corner`; terminal chrome on a `Term` body (core). | shared renderer only |

### M0 as built

How the stack and the old `Overlay` path coexist is in DESIGN.md (Panes). Deviations from §3/§8:

| Area | Built | Why |
|---|---|---|
| Struct | `Pane` has only the fields M0 uses (`id`, `owner`, `kind`, `parent`, `size`, `fields`, `text`, `list`, `on`) plus `handle`, `safety`, `dead`, `over` and a `ctx` payload (target buffer id; M1 adds the Lua refs there). `place`, `title`, `tabs`, `footer`, `scope`, `toggle` come with the step that needs them. | No speculative fields. |
| Ids | `id` is the string name (core: `quit`, `close`, `conflict`, `merge`); `handle` is a per-open `u64` that waits and `parent` use. | `id` keeps its §5 meaning (persisted state); one string can be open twice. |
| Safety | A `safety` flag on an Exclusive pane, not a fourth kind. Opening one closes nothing and is a no-op while the same dialog is open; other root panes are inserted below it, children right after their parent's subtree. | D5 says "always on top"; replacing an open pane would drop a plugin's wait. |
| Legacy parent | A child over an unported overlay stores the overlay's `active` flag in `over`; `pane_stack_sync` closes it when the overlay closes. An Exclusive pane does not close an open overlay. | Temporary, removed with the last overlay. |
| Events | `qed.confirm/prompt` still resume their waiter from dispatch (`Plugins.answer`), not through a queue. | The D8 queue lands with `qed.ui.open` in M1. |
| Nested confirms | The file tree's and cwd picker's confirms stay inside those overlays, through `dialog_*` adapters over the pane procs. | They move with M2 (cwd picker) and M4 (tree). |
| Dialog text | Built once at open. Close, conflict and merge act on the buffer in `ctx.buf` (a plugin may switch buffers meanwhile) and bail if it is gone; quit re-checks every buffer at execute, so only its text can lag. | Plugin tasks keep running while a dialog has input. |
| Unload | Marks the owner's panes `dead`; `pane_stack_sync` closes them and resolves other plugins' children with `nil` later. | No Lua runs inside an unload or the reload loop. |

### M1 as built

Views, events and the prelude are in DESIGN.md (Panes). Deviations from §3/§5:

| Area | Built | Why |
|---|---|---|
| Struct | `Pane` adds `place`, `title`, field `mode`/`count`, a styled `text` body with scroll, `PaneList` (items, matches, sel, scroll, anchor, multi, max, more, empty, hint, restore), `auto_preview` + `Preview`, `footer` hints, `toggle`, query debounce state. No tabs, marks, chips, columns, tree, scope, field `hint`/`esc_clears`, `path` mode. | Only what M1's ports use. |
| Lua refs | In `Plugins.views` (`UiView`, keyed by handle), not `Pane.ctx`. | The close event is flushed after the Pane is gone; its refs must outlive it. |
| Activate | Never closes the pane. `v:wait()` resolves on the next activate or the close; the prelude closes after it. | One shape for pickers and for panes whose activate does something else (tree expand). |
| `wait` | Returns `items, index, text` (`nil, nil, text` on close). | Prompt needs the text; `qed.pick{on_query}` returns the query even on Esc. |
| Item key | `key`, default `label`. | Search hits share a path; the tree will pass `key = path`. |
| Toggle | Default: the opening command's chord. A `toggle = <visible command name>` spec field overrides it (added for the markdown preview, which reopens from a link handler). | Panes opened from handlers have no command of their own. |
| Kinds | `kind = "exclusive"\|"child"`, passive is `focus = false`. `kind = "child"` without `parent` stacks on the focus (a pane or a core overlay), else opens exclusive. | The sugar needs D5's "pick/prompt/confirm opened while a pane is open is a child". |
| Busy | Exclusive opens are refused while a `modal` pane is live (M0: any plugin pane). The sugar sets `modal`; a non-modal pane is replaced and its waiters get `nil` like Esc. `qed.pick` over an open pane is now a child, not `"busy"`. `nil, "closed"` when `parent` is gone. | Modality, not waiting, is what must not be cancelled. |
| Focus | A `kind = "child"` open from a task the user did not start (timer, event, handler) stacks only on the caller's own pane; over another plugin's pane or a core overlay it returns `"busy"`. User commands keep stacking per D5. `ctx.view` goes only to the view's own plugin. | A background task must not steal focus from someone else's pane. |
| Sorted lists | `list.sort = true` keeps items ordered by key; `append` binary-inserts and keeps selection and scroll on their item once the user moved. Under a filter, `append`/`update` re-rank fully (O(n log n)) and keep the selection, anchor and scroll. | Streaming search output arrives unordered. |
| Methods | `set`, `append`, `update`, `text`, `close`, `wait`. `text` replaces the text body (`qed.pane`'s `set`). `set` has `selected`, `more`, `hint`; no `keep`. | No `marks`/`preview`/`footer`/`title`/`tab` user yet. |
| Sizes | `palette`, `dialog`, `split:code`. | No tree yet. |
| Prelude | `src/prelude.lua` returns an installer that `plugin_qed_push` runs on each plugin's `qed` table. | Each plugin's `qed.ui.open` carries its owner as an upvalue. `on_query`/`picker:set` stay as sugar (6 lines); no bundled plugin uses them. |
| Search | Parallel `rg --line-buffered` streamed through `spawn_bg{on_line}` into `append` on a `sort` list keyed `file\0row`; rows are deduped; the previous results stay up until the first new hit; Enter opens a visible hit while rg still runs; `max = 500`, the 501st hit kills rg and shows `500+` (which 500 is nondeterministic, shown sorted, as in phase 12). The plugin kills its rg on requery and close. A spawn error or rg exit code above 1 with no hits shows `Search failed: ...`. Query and selection persist through core `id`, also across a plugin reload. | `--sort path` is single-threaded and block-buffered (first hit 1-2 s on a large tree). |
| Kill | Task kill frees only the foreground `qed.spawn` the task waits on; `spawn_bg` processes stay with the plugin until it kills them or unloads. | Keeps the pre-save timeout and query supersede killing formatters and searches without reaching into background work. |
| Markdown body | `markdown = text` (full, no list/text) makes the text body core-rendered markdown (`md_render` at the text width, cached in a per-pane arena keyed on width, invalidated by `v:markdown` and retheme). Home/End scroll a text body; its scroll persists by `id`. | The plugin cannot know the pane width and highlight colors are not theme keys, so core renders. |
| Links, backdrop | Markdown spans carry their link target; a click on an `#anchor` scrolls in core unless the view has `on.link` (M3), other targets queue `on.link(v, target)`. `backdrop = "dim"\|"blank"` fades or clears everything drawn before the pane (editor and panes below) except the status rows; set per pane (`plugins.markdown.backdrop`), no global knob. | The plugin owns link policy; core owns hit-testing and scrolling. |
| Width cap | `max_width = n` caps a `center` or `full` box (borders included), centered. Plugins may pass it from their own option (`plugins.markdown.max_width`); size classes still cover the shared core sizes. | A per-plugin knob needs no new class. |
| Layout | Line find is untouched (M3), so D3 changes nothing visible in M1: plugin split panes already had the field over the list column. Palette and cwd picker stay overlays, so "Collapse the centered pickers" stays for M2. | |

### M2 as built

List sources, the `path` field and the palette are in DESIGN.md (Panes). Deviations from §3/§4:

| Area | Built | Why |
|---|---|---|
| Handle type | A core `ListSource{kind, filetree, path, dotfiles}` (plus a dir cache) on `PaneList.source`; core fills `list.items` (`pane_list_load`). Lua holds a `qed.List` table naming a `PluginList` record; `list.items = h` copies the source into the pane, so the view outlives the handle. M3/M4 add a kind and a fill case; a shared walk adds its own refcount. | Value sources need no shared state yet. |
| `qed.command_list` | Core only (`.Commands`), no Lua constructor. | The palette is core (D1); no plugin lists commands. |
| Methods | None (`count`, `ready`, `get`, `index`, `wait`, `within`, `union`), no `view:set(h)`; `v:set(items)` unbinds the source, `v:append`/`v:update` raise on it. | No user until M3/M4. |
| Identity | One locked registry metatable, compared by identity; `__gc` reads the table's `id`. A handle dies with the plugin that made it. | No forging by `__name`. |
| Materialization | Activate and change hand Lua `{label, path?, detail?}` built from the core items; the view's Lua item table stays empty. | Only touched items cross. |
| `qed.fs.dirs{path?, dotfiles?}` | `path` defaults to the root; under a `path` field the field's text decides. `dotfiles` is the caller's (the picker passes `filetree_show_dotfiles`, not the tree's runtime toggle). The base dir's entries are cached until its segment changes. | Core stays out of the tree's state (M5); a 50k-entry dir is read once, not per key. |
| `path` field | Reports its text resolved to an absolute path (`~`, root-relative, cleaned) in activate, `wait` and close. Double-click drills in instead of activating. | Lua needs no `~` expansion; same UX as before. |
| Palette over the tree | A Child with `over = &filetree.active` until the tree is a pane (M4). | Smallest step; the render special case is gone. |
| Core chord | `Pane.chord` (a core command name) beside the plugin `toggle` id. Enter on an empty core list does nothing. | The palette's own chord closes it; Enter with no match kept it open before. |
| Palette rows | Keyed by command identity (core label, plugin command id), resolved at activate and draw; a removed command's row goes dead. The palette is `modal`. | Removal need not close it; a timer cannot replace it (the M1 focus rule). |
| Root change | `qed.set_root(path, {discard?})` returns `nil, "unsaved", {total, unsaved, bufs}` and closes nothing while an unsaved outside buffer is unapproved; the `workspace` plugin asks (child `qed.confirm`) and calls again with `info.bufs`. It closes the picker before switching and reopens it by `id` for the confirm, so cancel leaves it as typed. The tree's `ConfirmRoot` mode is gone. | Core never discards unsaved work unasked; approval by id closes the confirm-yield race. |
| Names | *Workspace: Open Directory*, the tree's *Workspace: Open Selected Directory*, bind `plugins.workspace.keybinds["Open Directory"]` (the old top-level `Change Working Directory` key warns where it moved). Plugin messages read `Workspace: Not a directory: ...`. | Phase 13 namespacing (Petar's naming). |

### M3 as built

Sources, scoped commands and the ported panes are in DESIGN.md (Panes). Deviations from §3/§4:

| Area | Built | Why |
|---|---|---|
| Sources | `list_count` / `list_text` (what a filter matches, borrowed) / `list_item(i)` (built on demand, temp or borrowed strings) per `ListSource.kind`; `PaneList.items` holds only Lua items. An empty filter leaves the list unfiltered (`filtered = false`, no index array). A test-only counter (`when ODIN_TEST`) counts built items. Small sources keep a cache (commands: names + ids; dirs: names + matching rows; log: entry seqs, recomputed on `log_seq` or a filter change). | A 1M-line buffer opens with only the visible rows built; a filter is one pass over borrowed text. |
| Scope | `Command.scope: string` (`""` editor, `filetree`, `log`, `plugins`, or a plugin pane's) replaces `filetree: bool`; core pane commands live in one `pane_commands` table. `ListSource.scope` replaces `ListSource.filetree`. | One rule for the tree, core panes and Lua panes. |
| Bare keys | `Command.ch`: a bare printable bind (`"d"`), refused in the editor and tree scopes (`bind_bare_ok`), and fires only in a pane without fields. | D4: single-key defaults stay where no field takes printables. |
| Dispatch | `pane_key`: toggle chord, then with `scope`: Command Palette chord opens the scoped palette as a child, then core and plugin scoped chords. A core pane's `chord` also closes it from any of its children. | The scoped palette and the source view are children. |
| Footer | `chips` (`{label, cmd, on}`, right-aligned, live key, lit when on, click runs the command); `on.footer` (core) returns an error line that replaces the footer. Core keeps chip state in sync itself. | Lua chips wait for a user. |
| Columns | `list_columns` per source (Lines: number + text; Plugins: name, source, state, ms); items carry `cells`. No Lua spec field. | No Lua user. |
| Rows | Item `color` (theme key), `PaneList.sel_bg` (selection tints bg only), `follow`/`stick` (stick to the end, unstuck by moving up or a wheel up, re-stuck at the end). | Log and Plugins pane. |
| Body swap | The Plugins pane's source view is a child pane over the same box with a `body_preview` (a `Preview` as the body); Esc and a click outside return. | Reuses the stack instead of a per-pane mode. |
| Activate | Core panes without `on.activate` ignore Enter; `keep` leaves a core pane open on activate (Plugins pane). | |
| Line find | `qed.buf.line_list` + bundled `goto` plugin (`Go To: Line`, `Ctrl+g`). Core owns the `:N[:M]` spec, buffer-order matches, the initial selection nearest the cursor (a saved key is not restored for a line list) and the buffer preview (`PaneItem.buf`). Enter with no match does nothing (it closed before). | Matches the other panes; Lua sees only the activated line. |
| Rename | A center `input` pane (`rename`, `modal`). | |
| Live sources | `list_stamp` per source (buffer `rev`, `log_seq` + filters, plugin count; 0 = gone or static). `pane_list_fit` (each render and before input) refilters keeping the selected item when it changes or the source is gone; `list_text`/`list_item` read a stale index as empty. Log rows hold entry seqs: eviction shifts positions so the selection and range stay on their entries, and a range never sticks to the end. | Edits, reloads and a closed buffer used to index out of range. |
| Bind clashes | Core pane command binds that collide in one scope (chord, bare key, a borrowed bind) are reported and dropped, checked after every bind is set so swaps work. | Same rule as plugin binds. |
| `ctx.items` | Any plugin's command run while a pane with a list has focus gets its selection (`ctx.items`; Lua values for a Lua list, built items for a source) and `ctx.files` (their paths); `ctx.view` stays owner-only. | M6: tree commands from other plugins. |
| Markdown history | The preview opens with `scope = "markdown"`; anchor clicks reach `on.link` when set, `v:scroll` reads and sets the body scroll, *Markdown: Back*/*Forward* (keys of *Jump Back*/*Jump Forward* via `qed.shortcut` at load) step a `{path, buf, scroll}` history; file switches go through `qed.jump`. | |
| Backdrop | `message_log_backdrop`, `plugins_pane_backdrop` (default `"none"`). | Per pane, Petar's call. |

### M4 as built

The walk service, the tree pane and the new Lua pieces are in DESIGN.md (Panes, File tree). Deviations from §3/§4/§5:

| Area | Built | Why |
|---|---|---|
| Walk | `Walk{root, dotfiles, ignored}` records in `Editor.walks`, refcounted by sources, shared by equal options, freed by `walk_gc` once unreferenced and its prewarm landed. Per-walk staleness: a write restales only walks whose root can contain it; a stale walk serves its old candidates while the prewarm reruns, and the landing bumps `Walk.gen` (the stamp) so lists refill. Each root has its ignore set (`walk_ignore_set`; the core tree feeds the provider's, Lua `h:ignore(paths)`), and only a changed set restales. | A filtered list must not stall on an unrelated write; M6 git feeds `h:ignore` directly. |
| Narrowing | `within(paths)` / `union(paths)` build a refcounted `WalkScope{listed, closure, virtual}`; listed paths keep their descendants and skip the dotfiles/ignored rules; `union` on an un-narrowed walk sets `all` (normal rules plus the virtual paths). Tables only, not handles; `within` on a narrowed handle raises. `count()` returns `nil, "pending"` until `ready()` (and starts the prewarm), never walking inside a Lua slice; a listed scope is always ready. No `get`/`index`/`wait`. | The tree's tabs need nothing more. |
| Source | `ListSource.kind = .Walk`, self-filtering: `list_walk_fill` builds `entries` (tree rows by lazy readdir, or ranked paths under a filter, capped at `list.max`, default 500, `more` past it, narrowing the previous hits), keeping the selected path. A filter change is debounced (`WALK_FILTER_DEBOUNCE_MS`, `refill_due`), the preview too (`WALK_PREVIEW_DEBOUNCE_MS`, `preview_due`), both flushed by `pane_stack_pump`. Stamp = `walk_gen + 1`. The count shows only under a filter. | Same latency as the old tree; generic panes keep per-key filtering. |
| Tree list | `list.tree` (walk sources only): `PaneList.expanded` (scoped tabs default expanded), indent and icons at draw, Enter or double-click on one dir toggles it (with a filter: clears it and reveals the dir) before `activate`, `on.expand`; open buffers get the accent and unsaved `●` built in. `PaneSaved.expanded` persists it by `id`. | Expansion is core (D2); buffers are editor state. |
| Marks | `Pane.marks` by item key: `bar`, `fg`, `suffix`, `added`/`removed`, `dim` (inherited by descendants in a tree, skipped when selected). No propagation to parent dirs: the caller passes dir marks (the core tree uses the provider's propagated status). | The rank (deleted shows as modified upward) is the provider's, not generic. |
| Selection | A refill keeps the selected and anchor paths. `change` is tracked by item key for walk lists (`notified_key`), since every refill rebuilds the rows. `v:reveal(path)` clears the filter, expands the ancestors and selects; `v:set(h, {selected = key})` selects after a swap. Tree confirms freeze their targets at open. | A Lua tree selects what it just created; a refill under a confirm must not change what it deletes. |
| Tabs | `Pane.tabs{label, cmd}` in the title row; Left/Right (no wrap), click, and a tab's `cmd` chord (on the active tab it closes); `on.tab`. `v:tab(i)` sets without the event. | |
| Footer | `chips` from Lua; `v:footer{hints?, chips?, input?}`; the footer input (`Pane.footer_field`) takes every key, Enter/Esc end it with `on.submit(text, ok)` (Lua: `text` or `nil`). | New:/Rename: and M5's prompts. |
| Preview | `on.preview` (core) answers first; the tree uses it for the Changed tab's provider diff. Lua: `v:preview(false \| "auto" \| {path, base?, diff_only?})`. | A plugin with an async base turns auto off and answers per change. |
| Tree pane | `filetree_open_scope` opens a `split:tree` pane (`id = "filetree"`, scope `filetree`, `keep`); `filetree_source_sync` rebuilds source, tabs, chips and marks from `FileTree` (scope, toggles, provider status). Delete and close confirms are child dialogs (`filetree_delete`, `filetree_close`). `FileTree` keeps only provider status, toggles, clipboard and the prompt mode. | |
| `over` | The palette and confirms over the tree are plain children; `Pane.over` stays only for a plugin pick opened by a user command over the terminal, find bar or AI prompt. | Still reachable from a command that waited. |
| Search | `plugins/search` opens with `kind = "child"`: over any focused pane (tree, Message Log, Plugins pane, markdown preview) it stacks and Esc returns there. | The tree is an exclusive pane now. |
| fs writes | `qed.fs.copy/rename/remove/mkdir` (`fs_*` in `filetree.odin`) refuse an existing target, a target inside the source, special files (skipped inside a copied dir) and the root or its ancestors; symlinks are copied as links and never followed; data streams through a fixed buffer; rename copies + removes only on `EXDEV` (mtimes kept; a failed remove drops the copy and fails) and repaths buffers. `qed.fs.write` restales walks too. The tree's paste, rename, delete and New dir use them. | |
| M5 needs | Spec: `size = "split:tree"`, `tabs`, `tab`, field `hint`/`esc_clears`/`count`, `list{items = walk, tree, multi, max}`, `footer{hints, chips}`, `scope`, `on{activate, tab, expand, submit, change, close}`; methods `set(h, {selected})`, `marks`, `footer`, `tab`, `preview`, `expand`, `reveal`; handles `qed.fs.walk`, `within`, `union`, `ignore`; writes `qed.fs.*`; `ctx.files` expanding dirs on narrowed handles. Lua `list.columns` + item `cells` came along (Plugins-pane style rows). | |

### M5 as built

The plugin and the walk service are in DESIGN.md (Walk service, File tree); the shim went in M6.
Deviations from §3/§5/§6:

| Area | Built | Why |
|---|---|---|
| Core | `filetree.odin` is `walk.odin`: walks, scopes, tree rows/expand/reveal, `fs_*`. Gone: `FileTree`, the tab/toggle/clipboard/prompt/confirm code, the 12 `filetree` pane commands, the 4 *File Tree* core commands, `Pane.on.preview`, `close_question`. Constants are `WALK_*`. | D7. |
| Names | Display name "File Tree": *All* (was *File Tree*), *Open*, *Changed*, *Unsaved*; tree commands gain the prefix (*File Tree: Copy*, ...). Binds move to `plugins.filetree.keybinds` (`"All"` for the old `"File Tree"`), old top-level keys warn where. Messages read `File Tree: ...` (were `Files: ...`). | Phase 13 naming. |
| Knobs | `filetree_show_dotfiles`/`_ignored`/`_diff_only` stay top-level, read with `qed.opt` at load; `filetree_list_*` stay the `split:tree` class. | The workspace picker shares the dotfiles knob; M9 reviews plugin keys. |
| Borrowed binds | *Copy*, *Cut*, *Paste*, *Close Buffers*, *Select All* use `qed.command{bind_from = "<core command>"}`: the bind is read from the core command at every rebind. | One config entry drives both, as for core pane commands. |
| Shim | `treeshim.odin`: the git side unchanged; the tree side is `qed.filetree.listen(fn)`, `state()`, `request(kind, path?)`. Status crosses as a normalized Lua table in the registry; propagation, marks, scopes and preview are Lua. | One file to delete in M6, no Odin status model left. |
| API | `toggle = false`; `jump_closes` (`qed.jump` closes the tree, which core used to do by name); `v:selection() -> item, row, anchor, count` and `v:select(row, anchor?)` (Select All, the row above a delete, the item to preview on the Changed tab); `v:on(event, fn\|false)` (`change` only on the Changed tab); `v:expand()` toggles all; `v:marks{detail, total}`; `h:ignore(false)` (status not pushed yet); `h:release()`; `qed.close(b, {discard = ids})`; `qed.fs.exists(p, {follow = false})`; `qed.fs.write(p, data, {exclusive = true})`. | The tree needed each; no other user yet. |
| Restore | A field given an empty `text` keeps the selection/expanded restore; a pane a background task opens leaves the message line alone. | The tree starts with an empty filter and restores its selection; its root-change reopen must not eat the "Working directory" message. |
| Preview | The Changed tab turns auto off and answers with `v:preview{path, base}`; the base is asked after an 80 ms sleep in `change` (killed by the next change). A tab switch blanks while waiting, a status push keeps the old rows. | Same debounce and keep rules as the core tree. |
| Root change | The plugin reopens the view on `root_changed`, then `v:expand(scope ~= "All")` resets expansion. A provider coming or going also reopens it (tabs are fixed per open). | No `v:tabs`; reopen is cheaper than a new method. |
| Welcome | The welcome hint for the tree is looked up among plugin commands and dropped without it. The welcome gate now applies only to the editor palette, so a scoped palette (tree, log) lists all its commands on welcome. | D1; the tree's Ctrl+P on welcome listed only plugin commands. |
| UX changes | New/Rename/Paste under an active filter clear the filter to reveal the result (`v:reveal`). | `v:reveal` clears the filter. |
| Tests | `t.ui()` reports the pane `id` (search's tests wait for `"search"`, the tree is a view too); `e2e_mouse` and `nav_alt` flush like the main loop. | The tree activates through queued events. |
| Scale | A status push is diffed against the last one and processed in 4000-path chunks with `qed.sleep(0)` between; marks are built once per status and pushed in chunks (`total` sizes the store), tab switches flip `detail` instead of resending; narrowed handles are cached per tab and status and released when replaced; a large rebuild yields between `within` and the refill. Core: scope paths in one buffer, `union` shares its base, readdir with `d_type`, a per-scope row cache, arenas for entry paths and mark keys. A push that only moved sizes keeps the Changed handle. Measured on WSL2 (`bench_filetree_changed`, every push changes the sizes): no filetree slice over ~50 ms at 30k changed files (push 14 ms, tab switch 39, open Changed 46); at 50k pushes stay under 25 ms and only the first narrowed fill after an open or a path change, one core call reading every listed dir, reaches ~70-80 ms. | The 200 ms provider budget disabled the plugin at ~30k files. |

### M6 as built

Communication is in DESIGN.md (Plugins, File tree, Git tab) and plugins.md (Plugin communication). Deviations from §6:

| Area | Built | Why |
|---|---|---|
| Tab API | `set_tab(spec)` adds or replaces the caller's tab by label; `remove_tab(label)`; no `tab` object. `paths`/`virtual` are lists; passing the same tables keeps the narrowed handle. | A returned `tab:set` would run the owner's code outside the export proxy, so it would not raise after an unload. |
| Exports | `qed.plugin` builds a fresh proxy per call (C closures with owner, load generation, caller, name); the functions are looked up at call time, so a held proxy keeps no unloaded env alive. A call is a `pcallk` in the caller's task: it may wait, its time counts to the caller, and `qed.caller()` reads a per-coroutine call stack. Unloading the owner kills the tasks inside its calls; qed closures carry the load generation, so kept code from an old load raises. | "Exported calls run in the caller's task"; no new task kind. |
| Setup | `qed.plugin` raises during any plugin's setup (not `nil`). | A silent `nil` would read as "not installed". |
| Callbacks | `preview` and `missing` are plain functions in the spec, called by the tree (`preview` under pcall, falling back to a plain preview). The tree drops them on `plugin_unloaded`. | Fewer moving parts than an event round trip; the window between an unload and that event is covered by the pcall and by task errors no longer disabling a plugin. |
| Sync | Exports only store state and defer one `sync` (`qed.defer(0)`), so the 50k-mark push runs in the tree's own task, chunked as in M5. | Keeps the tree's work out of the caller's slices. |
| Tabs at runtime | `v:tab(i, tabs)` replaces the tab row in place; added tabs sit between Open and Unsaved. A tab coming or going no longer reopens the view. | Git attaches at `startup`, possibly after the tree opened; a reopen dropped the typed filter. |
| Ignore set | `set_ignored(paths\|false)` export; the tree feeds its walks. Without a caller the set is `{}`. | The tree owns its walks; the set dies with them (walks are freed when unreferenced). |
| Refresh | The tree emits `filetree:refresh` (custom event) on open and after its file operations; git scans on it. | The provider's `refresh` callback, as an event. |
| Marks, propagation | Git computes the marks (bars propagated up dirs, deleted fg, rename suffix, sizes, dim ignored) and the path lists, chunked every 2000 paths; the tree only merges callers' marks and pushes them. `detail` per tab shows suffix and sizes. | Status semantics are git's; the tree stays generic. |
| Chord | *Git: Changes* (`Alt+g`, `plugins.git.keybinds.Changes`, `welcome`), hidden while `filetree` is not loaded; it is the Git tab's `cmd`, so over the tree it switches or closes like any tab chord. *File Tree: Changed* is gone; the old top-level `File Tree: Changed` bind warns it moved to `plugins/git/keybinds/"Changes"`. | The tab is git's. |
| Toggle Diff | Stays *File Tree: Toggle Diff* (`Alt+d`, `filetree_diff_only`): the diff chip shows on any tab with `preview`, the command is offered while one exists. | Diff-only is a property of the tree's diff preview, not of git. |
| Restore | Enter on a missing path calls the tab's `missing` in the tree's activate task; an activate task may open a child on its own view or its children, so git's confirm may stack over the tree. *Git: Restore File* stays a tree-scoped command. | The provider ran `open_deleted` as a git command task. |
| Startup | The Git tab exists only after git's `startup` (it used to exist from git's setup). Tests that open the tree before the first pump settle first. | Two-step lifecycle. |
| Errors | A task's Lua error no longer disables its plugin (Petar); only load and setup errors do. Errors are rate-limited per plugin (3 per second, the rest summarized), known messages show a count, and only a message's first occurrence logs a traceback; the disk log also rotates mid-session. | A race against an unload must not take a plugin down. |
| Removed | `treeshim.odin`, `Plugins.shim`, `qed.filetree.*`, the `.Provider` task kind, `PluginQueued.ref`, the M5 status tests (ported to `e2e_filetree_tab_test.odin` on the exports). | |
| Scale | `bench_filetree_changed` now drives the real git plugin over faked git output (every push moves the sizes) and reports the max slice of both plugins. WSL2, M6 vs M5 on the same bench: 30k changed: git slices <= 49 ms (M5 up to 95), filetree <= 44 ms (M5 54); 50k: git pushes <= 56 ms (M5 up to 194), filetree <= 84 ms (M5 92). The largest remaining slice is the first narrowed fill after an open (~85-90 ms at 50k), in git's task when *Git: Changes* opens the tree. | |

### M7 as built (conflict)

The merge-conflict UI is the bundled `conflict` plugin (DESIGN.md Merge conflicts, plugins.md API rows).

| Area | Built | Why |
|---|---|---|
| Home | Its own plugin, not `git`. | Markers are text: a conflicted file copied out of a repo, or git disabled, still gets them. Neither plugin needs the other. |
| Rescans | `buf_open`, `buf_reload`, `buf_changed` (coalesced), `startup` (hot reload): clear the namespace and push everything again. A buffer with no `<<<<<<<` line costs one `qed.buf.find_lines` and nothing is cleared. | Spans drop on any edited row; a full re-push keeps the result equal to the old per-frame scan. A diff of old and new blocks would miss a paste of identical text over a block (its spans drop, the text compares equal). |
| API | `qed.buf.find_lines(b, prefix)`; `qed.text.diff(a, b)`; a deco `alpha` may be a theme tint key (`conflict`, `conflict_marker`, `conflict_word`), resolved per frame; span `alpha` blends `bg` over the line background (the old `diff_bg` path). `qed.confirm(question, choices)` already existed. | Exact old colors, live theme changes without a re-push, and no 1 MB text copy per keystroke. The word span is a 15-line Lua port of `diff_word_span`; the line pairing reuses the core Myers engine so pairs match. |
| Anchors | No new anchor kind: tints shift and shrink with edits in core, spans drop and come back in the same flush (before the frame). | The rescan runs before render, so a stale frame never shows. |
| Resolve | `qed.confirm("Resolve merge conflict:", {"Keep Ours", "Keep Theirs", "Keep Both"})`, a child dialog instead of the exclusive `merge` pane; one `qed.edit` group; rescan right after. | The edit lands after the flush's change check, so its `buf_changed` would come a frame late. |
| Name, key | *Conflict: Resolve* (was *Git: Resolve Conflict*), `Alt+m`, `plugins.conflict.keybinds.Resolve`; the old top-level bind warns where it moved. Messages say `Conflict:`, not `Git:`. | Phase 13 naming. |
| Marker fg | A whole-line `fg` span; it keeps the syntax attributes (bold, italic) the old full color override dropped. | Spans compose with syntax by design. |
| fim | The ghost line's background takes the cursor row's decoration tints. | It took the conflict tint from `merge_side` before. |
| Removed | `conflict.odin`, `conflict_test.odin` (ported to `plugins/conflict/test.lua`), `MergeSide` in `editor_line_bg`, the core `merge` pane. Tests that used `merge_dialog_open` as a generic exclusive pane use `test_dialog_open`. | |
| Scale | `bench_conflict_keystroke` (debug build, WSL2, 20k lines): no markers +0.4 ms per keystroke; 200 blocks (1800 decorations) ~6-7 ms per keystroke, max slice 8-13 ms; frames drop from 1.45 ms to 0.6 ms (no per-frame scan). | Well inside the 50 ms soft budget. |

### M7 as built: AI

The plugin is in DESIGN.md (AI plugin); the primitives in plugins.md (Decorations, Events). Deviations from §7:

| Area | Built | Why |
|---|---|---|
| Range tracking | `qed.deco.mark`/`range`: a byte-position anchor shifted by the primitives and removed when an edit overlaps its inside. The plugin cancels on `buf_changed` when its mark is gone and re-tints from the mark. | The old content search (`llm_locate`, per render and per edit) could relocate onto a duplicate of the block; an anchor is exact and costs nothing per frame. |
| Tint | A plain decoration tint with the theme tint name `"ai_edit"` (`qed.deco.tint` takes a tint name, resolved per frame). The fixed AI layer in `editor_line_bg` is gone, so the AI tint now sits with the other decoration tints under the current line. | Themes keep their `ai_edit` strength without a plugin-readable tint API. |
| Inline ghost | Core (`DecoStore.inline`, `qed.deco.inline`): render, row reservation, `Tab` / `Ctrl+Right` / any-key dismiss, all in `editor_dispatch_key`. Any edit clears it. | D8: no raw-key interception by plugins. |
| Trigger | `buf_changed` gets `typed` (the latest change was typing); the plugin debounces with `qed.defer` and kills the pending timer and `curl` on the next typed change. Paste, undo, accepts and plugin edits do not ask. | The old trigger list (printable, Enter, Backspace, Delete; no Ctrl/Alt) without a raw key event. |
| HTTP | Still `curl` through `qed.spawn_bg`; no `qed.http`. | Reuses what exists. |
| Idle cost | The plugin subscribes to `buf_changed` only while a request runs or completion is on. | No task per keystroke for an idle plugin. |
| Prompt | `qed.prompt{prompt = "AI edit:"}`, a modal child pane, replaces the `aiedit` overlay. | Last overlay besides terminal and find. |
| Messages | Same texts minus the redundant `AI edit` prefix, now attributed `AI: ...` (e.g. `AI: Edit applied`, `AI: Edit cancelled: block edited`). The `AI:N` count is a right-side plugin segment. | Plugin messages always carry the display name. |
| Removed | `aiedit.odin`, `llm.odin`, `fim.odin`, `llm_test.odin`, `subprocess_start`, `modules.ai`, `.Ai`, `AI_ENABLED`, the `LLM_*` globals, `editor_modules_sync`, `t.module`; `AI`/`FIM` leave the reserved log labels. `module.odin` is left as empty scaffolding for M8. | |

## 8. Decisions

| # | Decision |
|---|---|
| D1 | Core builds only what must work without Lua: palette, Plugins pane, Message Log, quit/close/conflict dialogs. Everything else is Lua. |
| D2 | Big sets are core-owned list handles passed to views; Lua queries count/one item/narrow/union, never materializes. Small lists are plain tables. No "core source" pane modes. |
| D3 | One split layout: tabs over both columns, field over the list column, preview full height. Line find changes visibly. |
| D4 | Single-letter pane keys become pane-scoped commands with single-key defaults, rebindable, listed in the pane's scoped Ctrl+P. |
| D5 | Three kinds chosen per open: Exclusive (default, persisted by `id`), Child, Passive. Safety dialogs on top; `"busy"` only under one. Commands in a pane get `ctx.view`. |
| D6 | Core panes use the same model and code path. |
| D7 | The file tree is fully a Lua plugin on walk handles, the pane model and `qed.fs` writes. |
| D8 | Events queue and flush after dispatch, before render. No raw-key interception by plugins. |
| D9 | Phase 12 shipped as is; it migrates to the model in M1. |
| D10 | Exports via `qed.export` / `qed.plugin`, namespaced custom events, `plugin_loaded/unloaded`. Two-step lifecycle: setup registers, `startup` and `plugin_loaded` cross plugins. |

Related, built in phase 13: `qed.options` (done), `qed.meta{display_name}` with an automatic `<Display>: <name>`
palette prefix, and messages and keybinds namespaced per plugin (`plugins.<id>.keybinds`, which is where plugin
pane-scoped command binds live).

## 9. Risks

| Risk | Answer |
|---|---|
| Generic render slower than hand-written | Same cell writes; one map hit per visible row for marks. Bench the tree render before/after M4. |
| Lua latency on toggles (tree chips) | Same frame via flush; a handler that yields shows one stale frame. Core-built panes keep core toggles. |
| Spec grows into a widget toolkit | Only the components in §3; a new one needs a real pane. |
| Memory cap | 500-item lists ~100 KB; big data stays in handles. |

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
| `qed.fs.walk{root, dotfiles?, ignored?}` | `{path, label, dir, depth}` | threaded walk, cache, prewarm; same args share one walk; invalidated by `qed.fs.*` writes, root change and the disk poll | file tree, path pickers |
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

Git and the file tree do not depend on each other. The file tree exports `add_tab{label, list, marks?, preview?,
open_missing?} -> tab` (`tab:set{...}`, `tab:remove()`) and `set_marks(marks)` for the All tab. Git, when
`qed.plugin("filetree")` is non-nil at `startup` or on `plugin_loaded("filetree")`, adds a tab labeled "Git" (the
label is git-specific now, so it may say Git) whose `list` narrows the walk to changed paths plus deleted ones (`within` + `union`), pushes
status marks, and answers `preview(path)` with the base text. `qed.filetree.provide/set_status/set_base` is removed in
M6.

## 7. Migration

Each step ships green with its e2e tests moved over. UX is unchanged except where a decision says so.

| Step | Scope | Closes / validates |
|---|---|---|
| M0 (done) | Odin `Pane`, stack, kinds, generic render/key/mouse/paste. Port the 4 core dialogs and `qed.confirm/prompt` onto it as children. | "Collapse the four dialogs" TODO; layout, stack, children |
| M1 | `qed.ui.open`, queued events, prelude `qed.pick/prompt/confirm/pane`, exclusive persistence by `id`, one split layout (D3). Port phase 12 search to a `query` field + `append` (D9). | pane swap TODO; events through flush, split + preview |
| M2 | Palette core-built on `qed.command_list`. Cwd picker becomes a Lua plugin on `qed.fs.dirs` + a `path` field (needs `qed.set_root` and an unsaved-outside-root query). | "Collapse the centered pickers" TODO; handles, `path` field, child confirm |
| M3 | Line find becomes a Lua plugin on `qed.buf.line_list` (field moves over the list column). Message Log and Plugins pane core-built with pane-scoped commands (D4), chips, `sel = bg`, columns, text body swap. Rename prompt on the model (core caller). | scoped commands, footer chips |
| M4 | Extract the walk service from `filetree.odin` behind `qed.fs.walk` (`within`, `union`). Add `qed.fs.copy/rename/remove/mkdir`. Core file tree rebuilt on the model over walk handles (still Odin, provider API intact). | tree items, tabs, marks, footer field, prewarm under the model |
| M5 | File tree becomes a bundled `filetree` plugin (D7); core keeps only the walk service and pane machinery. The Changed tab keeps working through a temporary provider shim. | the model under the hardest pane |
| M6 | Plugin communication (D10): `qed.export/plugin/caller`, `qed.emit` + namespaced `qed.on`, `plugin_loaded/unloaded`. Git adds its tab and marks through filetree exports. Remove `qed.filetree.*` and the shim. | first real cross-plugin user |
| M7 | Conflict UI and AI (aiedit, then fim) ported onto the model and decorations. | |
| M8 | Remove the module system (`modules.*`, `module_enabled`). | |
| M9 | Review every bundled plugin's config keys (existing TODO). | |
| later | Inspect, hover/diag/completion on `cursor`/`corner`; terminal chrome on a `Term` body (core). | shared renderer only |

### M0 as built

How the stack and the old `Overlay` path coexist is in DESIGN.md (Panes). Deviations from §3/§8:

| Area | Built | Why |
|---|---|---|
| Struct | `Pane` has only the fields M0 uses (`id`, `owner`, `kind`, `parent`, `size`, `fields`, `text`, `list`, `on`) plus `handle`, `safety`, `over`. `place`, `title`, `tabs`, `footer`, `scope`, `toggle` come with the step that needs them. | No speculative fields. |
| Ids | `id` is the string name (core: `quit`, `close`, `conflict`, `merge`); `handle` is a per-open `u64` that waits and `parent` use. | `id` keeps its §5 meaning (persisted state); one string can be open twice. |
| Safety | A `safety` flag on an Exclusive pane, not a fourth kind. Opening one closes nothing; every other pane is inserted below it. | D5 says "always on top"; replacing an open pane would drop a plugin's wait. |
| Legacy parent | A child over an unported overlay stores the overlay's `active` flag in `over`; `pane_stack_sync` closes it when the overlay closes. An Exclusive pane does not close an open overlay. | Temporary, removed with the last overlay. |
| Events | `qed.confirm/prompt` still resume their waiter from dispatch (`Plugins.answer`), not through a queue. | The D8 queue lands with `qed.ui.open` in M1. |
| Nested confirms | The file tree's and cwd picker's confirms stay inside those overlays, through `dialog_*` adapters over the pane procs. | They move with M2 (cwd picker) and M4 (tree). |
| Dialog text | Built once at open (the quit dialog lists modified buffers at open, not per frame). | Nothing can change it while the dialog has input. |

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

# Note: declarative UI (`qed.ui`)

Reference for the node-tree UI as built on branch `ui-redesign`. Core owns the engine (`src/ui.odin` layout and
render, `ui_input.odin` routing, `ui_api.odin` Lua bindings, `ui_list.odin` lists); bundled plugins compose the
screen (`plugins/layout`, `plugins/palette`). Examples use `local ui = qed.ui`.

## 1. Model

- **One tree.** A root with six layer outlets, bottom to top: `background`, `base`, `popup`, `pane`,
  `notification`, `alert`. Every tree enters through `ui.mount(outlet, tree)`.
- **Declarative.** A plugin hands core a node table; core marshals it into its own nodes. Lua never runs during
  layout or render. A failed `mount`/`update` raises and keeps the last good tree.
- **Ownership.** A plugin owns its trees. Others extend them only through `ui.outlet{id}` slots the owner declares;
  outlet ids are global, a mount waits until its outlet exists, the first outlet in resolve order takes it.
  Mounts, internal buffers and lists unmount/close when their plugin unloads.
- **Draw order** per layer: laid-out content of every mount, then floats in tree order.

## 2. Mounts, references, identity, state

| Call | Does |
|---|---|
| `ui.mount(outlet, tree) -> handle` | mount into a layer or an outlet id |
| `handle:update(tree)` | replace the tree; state survives for nodes with the same identity |
| `handle:unmount()` | remove; a no-op when gone |
| `ui.node(id) -> ref` | `ref:focus()`, `ref:state()`, `ref:set_state(patch)`, `ref:rect()` |

- Identity: `id` (per plugin: `ui.node` only sees the caller's nodes), else `key` among siblings, else type + raw
  positional index (a `false` or `nil` hole keeps later siblings' identity). Duplicate ids or sibling keys raise.
- State is core's, keyed by identity, never in the node table: `highlighted` (column, row, virtual_column),
  `offset` (scroll), `scroll` (editor; per editor node and buffer). `set_state` changes only named fields, fires
  nothing, and a new `highlighted` scrolls into view. `state()` reports `highlighted` only while that key is in the
  data. States of id'd nodes live until their plugin unloads; others go with their node.
- Replaced trees are freed at the next frame; when a handler changes a mount, bubbling stops.

## 3. Layout

Size forms for `width`/`height`: `n` cells, `"N%"` of the available area, `"fit"` (natural size),
`{form, min =, max =}` (`{"fit", max = 12}`). The area always wins over `min`.

| Prop | Meaning |
|---|---|
| `grow = n` | share leftover main-axis space by weight; growers start at `min` |
| `drop = n` | hide when space runs out, highest first (last on ties) |
| `margin` | outside the node: number, `{x =, y =}` or named sides `{top =, right =, bottom =, left =}` |
| `float` | `"parent"` or `"screen"`; absent = laid out by the parent |
| `anchor` | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`, `cursor` (float under an editor: below the caret, flips above) |
| `gap`, `separator` | cells between children; a `pane_border` rule taking one extra cell |
| `align` | cross placement: column `left/center/right`, row `top/center/bottom`, text lines `left/center/right` |

- Cross axis stretches unless the child is sized, then `align` places it (default start).
- Centering snap: only `"N%"` sizes shrink by one when the leftover is odd (never below `min`); `n` and `"fit"`
  keep their size and the odd cell goes after the node.
- Defaults: text and containers fit; an editor grows on an axis with no size; natural size of an editor is its line
  count x 0; of a virtual list its record count.
- `scroll` reserves its right column for the bar (header too) and lays its child out at `max(natural, view)`.

## 4. Nodes

Positional values are children, named values are props. Common props: `id`, `key`, sizing and floating, `scope`,
`on`, style fields `fg`, `bg` (theme color keys), `bold`, `italic`, `underline`.

| Node | Children | Props |
|---|---|---|
| `column`, `row` | nodes | `gap`, `align`, `separator`, `highlight_style` (the child whose `key` is `highlighted`) |
| `box` | exactly one laid out | `border`, `title` |
| `scroll` | exactly one laid out | `header` (a laid-out node pinned above) |
| `text` | strings and spans `{fg =, bold =, "text", ...}` | `wrap` (by cluster), `align`; overflow clips with `…` |
| `editor` | floating only | `buffer`, `placeholder`, `line_numbers` (gutter with diff marks and diagnostics, current-line tint), `syntax`, `wrap` (writes the buffer's flag; absent = the buffer's), `readonly` |
| `virtual_column` | none | `data` (a `qed.List` or `qed.FuzzyList`), `item = function(record) -> node`, `highlight_style` |
| `outlet` | none | `id` |

- `editor`: without `scope = "editor"` it is a view (click places the caret, wheel scrolls). With it, typing and
  paste insert, and the `editor` scope's core commands edit (`Editor: Left` ... `Dedent`, plus Undo, Redo, Copy,
  Cut, Paste, Select All borrowing the global binds). `scope = "editor"` on another node type raises.
- `virtual_column`: `item` runs in a batched step between layout passes, only for records coming into view, cached
  per record until that record changes, the query changes, or `data`/`item` identity changes on `update`. Items are
  one row; items far outside the window are evicted. An `item` error draws an error row.

## 5. Events, keys, focus

- Handlers `on = {key, paste, click, double_click, wheel}`, `function(event) -> handled`, synchronous (no yields).
  Key events carry `chord` (`"Ctrl+s"`, `"Shift+Up"`, `"Esc"`, `"x"`) and `text`; mouse events `x`, `y` (1-based,
  node-relative) and `button`. A double click fires the `click` bubble, then the `double_click` bubble.
- Keys: from the focused node up to the root; at each node its `scope` names in order (commands of that scope on
  their chord), then `on.key`, then an editor's typing. Then plugin global binds, then core global binds (both by
  chord). A command of a scope acts on the node whose scope matched. Unknown scope names warn once.
- Focus: exactly one node, set by its owner with `ref:focus()` (any node with an id). Editors focus themselves on a
  click. When the focused node leaves the tree, focus returns to the most recent node still there (16 deep).
- Mouse: the topmost node under the pointer bubbles to the root; unhandled, the next node below continues. Scroll
  takes the wheel natively, editors take click, drag and wheel.
- Keybinds accept named keys with modifiers: `Up Down Left Right Enter Esc Tab Backspace Delete Insert Home End
  PgUp PgDn Space F1..F12`.

## 6. Data

| Call | Does |
|---|---|
| `qed.list.new{key = "path"}` | a core-owned list of plain record tables; `key` names the identity field |
| `list:append(record)`, `list:insert(position, record)` | add (sorted lists insert in place; `insert` raises on them) |
| `list:set(key, fields)` | merge into a record (not its key field); rebuilds that record's item |
| `list:remove(key)`, `list:clear()` | |
| `list:get(key)`, `list:at(index)`, `list:index_of(key)`, `list:count()` | absent -> `nil` |
| `list:sort(field, {reverse})` | numbers numeric, strings bytewise |
| `qed.fuzzy.list(list, {field = "name"}) -> matches` | live filtered view sorted by score; follows its source |
| `matches:set_query(text)`, `matches:positions(key)` | refilter in core; matched byte offsets (1-based) |

Views follow data with no `update`. Change records with `set`; mutating a record table directly is not seen.
Lists are garbage-collected; mounts and buffers are closed explicitly (or on unload); subscriptions die with their
target.

## 7. Buffers

Buffers are objects everywhere: `qed.buf.current()`, `qed.buf.list()`, `qed.open`, `qed.new_buf`, `ctx.buf`,
buffer event arguments and `qed.set_root` info all give them (one interned object per buffer per plugin, so `==` and
table keys work). `qed.buf` itself keeps only `create{internal = true}`, `get(id)`, `current()` and `list()`; every
per-buffer call is a method: `buffer:text()`, `buffer:cursor()`, `buffer:insert(pos, text)`, ...,
`buffer:on("change", fn) -> {remove}`, `buffer:close()` (frees an internal buffer, closes a file buffer like
`qed.close`), and find: `buffer:find(query, {regex, case_sensitive}) -> index, count`, `buffer:find_step(direction)`,
`buffer:find_replace(text, {all})`, `buffer:find_clear()` (core matches and highlights; one find at a time). Other
APIs taking a buffer (`qed.edit`, `qed.jump`, `qed.deco.*`, `qed.close`) take objects. Internal buffers fire only
per-buffer events, never `buf_changed`. A buffer object's methods carry the plugin that made it.
The global bus is `qed:on(event, fn)` / `qed:emit("<id>:<event>", data)`; `message` reports the message line.

## 8. Worked example: the command palette (`plugins/palette/init.lua`)

```lua
local function command_row(record)
	return ui.row{
		on = {
			click = function() ui.node("palette_results"):set_state{highlighted = record.name} return true end,
			double_click = function() run_command(record.name) return true end,
		},
		ui.text{grow = 1, " ", table.unpack(name_spans(record, palette.matches:positions(record.name)))},
		ui.text{fg = "pane_shortcut_foreground", record.shortcut, " "},
	}
end

local function build(matches, query, empty)
	return ui.column{float = "screen", width = "100%", height = "100%",
		on = {click = function() close_palette() return true end},
		ui.box{id = "palette", float = "screen", anchor = "top", width = options.width, height = "fit",
			margin = {top = 3, right = 2, bottom = 2, left = 2},
			border = true, title = "Command Palette", bg = "pane_background", fg = "pane_foreground",
			on = {click = function() return true end},
			ui.column{
				ui.row{
					ui.text{fg = "pane_prompt_foreground", "> "},
					ui.editor{id = "palette_query", buffer = query, height = 1, grow = 1,
						scope = {"palette", "editor"}, placeholder = "Type a command"},
				},
				empty and ui.text{fg = "pane_dim_foreground", " No matching commands"} or false,
				ui.scroll{height = {"fit", max = qed.opt("palette_max_rows")},
					ui.virtual_column{id = "palette_results", data = matches, item = command_row,
						highlight_style = {bg = "pane_selection_background", fg = "pane_selection_foreground"}}},
			},
		},
	}
end

local function open_palette()
	local commands = qed.list.new{key = "name"}
	for _, command in ipairs(qed.commands()) do
		if command.scope == "global" and command.owner ~= "palette" then
			commands:append{name = command.name, shortcut = command.shortcut}
		end
	end
	local matches = qed.fuzzy.list(commands, {field = "name"})
	local query = qed.buf.create{internal = true}
	local empty = false
	local handle = ui.mount("pane", build(matches, query, empty))
	query:on("change", function()
		matches:set_query(query:text())
		if (matches:count() == 0) ~= empty then
			empty = not empty
			handle:update(build(matches, query, empty))
		end
		highlight_first(matches)
	end)
	palette = {matches = matches, query = query, handle = handle}
	ui.node("palette_query"):focus()
	highlight_first(matches)
end

qed.command{name = "Open", bind_from = "Command Palette", run = open_palette}
qed.command{name = "Next", scope = "palette", key = "Down", run = function() move_highlight(1) end}
qed.command{name = "Previous", scope = "palette", key = "Up", run = function() move_highlight(-1) end}
qed.command{name = "Run", scope = "palette", key = "Enter", run = run_highlighted}
qed.command{name = "Close", scope = "palette", key = "Esc", run = close_palette}
```

The field lists `palette` before `editor`, so Up/Down/Enter/Esc reach the palette's commands before the editor's.
The full-screen column closes on an outside click; the box swallows clicks inside.

## Open

- Not built: `image`, `terminal`, `virtual_row` nodes, `qed.markdown.parse`, resizable containers, multi-row
  virtual items, plain-table `data`, `focus`/`blur`/`state`/`drag`/`release` events, span `on.click`, keyboard
  scrolling of `scroll`.
- Per-view editor state (cursor, wrap) instead of the buffer's.
- List navigation helpers and the fuzzy span builder, once a second picker exists.
- `qed.commands()`, `qed.fs.walk`, `qed.buffers()` returning `qed.List`; the palette listing the scope chain.
- Deleting `qed.ui.open`, the remaining old panes (file tree, log, settings, terminal) and the old key matcher.
- Completion and hover as `cursor`-anchored plugin floats (they are core-drawn at the caret today).

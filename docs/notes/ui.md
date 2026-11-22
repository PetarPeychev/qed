# Note: declarative UI (`qed.ui`)

Reference for the node-tree UI. Every surface (editor, status, palette, file tree, popups, terminal, dialogs) is a node
in one tree. Core owns the engine (layout, render, diff, focus, hit-testing) and the heavy leaves; bundled plugins
compose the default UI over the same API user plugins get. Examples use `local ui = qed.ui`.

## 1. Model

- **One tree.** `root` (core) has six fixed layer nodes as children. Draw order is tree order.
- **Declarative.** A plugin hands core a node table; core diffs it against the previous tree by node identity and keeps
  widget state. There is no render function: Lua builds trees on demand, never per frame.
- **Data in core.** The tree lives in core. A failing `update` keeps the last good tree. There is no fallback UI.
- **Ownership.** Each plugin owns its trees entirely. Another plugin extends a tree only through an outlet the owner
  declares.
- **Outlets.** `ui.outlet{id, accepts?}` is a transparent slot: nodes mounted into it act as children of the outlet's
  parent at the outlet's position. Several mounts sit in mount order. Per-type child limits count the parent's total,
  mounts included.
- **Layers are outlets** in core's root tree. Every tree enters the screen through `ui.mount(outlet_id, tree)`.

Layers, bottom to top:

| Layer | Holds |
|---|---|
| `background` | welcome screen |
| `base` | the layout (editor, status, side panels) |
| `popup` | hover, completion, floating find |
| `pane` | palette, file tree, pickers, settings |
| `notification` | toasts |
| `alert` | core safety dialogs; open to plugins without restriction |

The default UI is a set of purpose-specific bundled plugins; `layout` owns the screen tree mounted in `base` and
declares the outlets other plugins extend (status segments, side panels, editor popups).

## 2. Node references and handles

| Call | Returns / does |
|---|---|
| `ui.mount(outlet_id, tree) -> handle` | Mounts `tree` into an outlet (a layer id or a plugin-declared outlet). |
| `handle:update(tree)` | Replaces the mounted tree; core diffs by identity, state survives for matching nodes. |
| `handle:state() -> snapshot` | Widget state of the mounted tree keyed by node id: `{results = {highlighted = "a.lua"}}`. |
| `handle:set_state(patch)` | Changes only the named fields; no tree rebuild. Cheap enough per keystroke. |
| `handle:unmount()` | Removes the tree. |
| `handle:focus(id)` | Moves the global focus to node `id`. |
| `ui.node(id) -> ref` | Reference to any node by id: `ref:focus()`, `ref:state()`, `ref:set_state(patch)`. |

Identity:

| Rule | Detail |
|---|---|
| Default identity | node type + position among siblings |
| `id` | overrides position: state follows the node when it moves; addressable by `ui.node`, focus and state snapshots. Unique across the whole tree. |
| `key` | identity among siblings for list children (rows of a column, records of a virtual list) |

State:

| Rule | Detail |
|---|---|
| State vs props | State is what core widgets change without Lua (highlight, scroll offset, cursor, selection, divider sizes). Props are everything the plugin decides; plugin-driven changes go through `update`. |
| Location | State lives in core per node identity, never in Lua and never in the node table. |
| Seeding | `set_state` right after `mount`, before the first frame. |
| Persistence | Within a session core keeps a node's state across unmount and remount when it has an `id`. Across sessions the plugin reads `state()` and seeds it back. |

```lua
local finder = ui.mount("pane", build_finder())
finder:set_state{finder_results = {highlighted = last_path}}
ui.node("finder_query"):focus()
```

## 3. Sizing and positioning

### Size forms (`width`, `height`)

| Form | Meaning |
|---|---|
| `n` | fixed cells |
| `"N%"` | percent of the available area (container for laid-out children, parent rect or screen for floats), floored |
| `{percent, min, max}` | percent clamped to `min..max` |
| `"fit"` | bottom-up natural size; `grow` children count as their min |

- The available area always wins over `min`: a node never exceeds the space it is given or the screen.
- **Centering snap:** on a centered axis the size shrinks by 1 when the leftover is odd, for every size form.
- Small leaves default to `"fit"`; big leaves (editor, terminal) default to `grow = 1`.

### Layout props (children of a container)

| Prop | Meaning |
|---|---|
| `width`, `height` | size forms above, along either axis |
| `grow = n` | shares leftover main-axis space by weight |
| `drop = n` | hides the child when space runs out, higher `drop` first |
| cross axis | stretches unless the child is sized; container `align` positions it |

### Floating

| Prop | Meaning |
|---|---|
| `float` | absent: laid out by the parent. `"parent"`: positioned against the parent's rect. `"screen"`: against the screen. |
| `anchor` | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right`, `cursor` |
| `width`, `height` | size forms, resolved against the parent rect, the screen, or (laid out) the space given |
| `margin` | minimum gap to each of the four edges of the reference rect; a node never exceeds it |
| `anchor = "cursor"` | only with `float = "parent"` under an editor node; sits below the caret, flips above when it does not fit, follows the cursor without `update` calls |

Children: positional values are laid-out children (per-type limits count only non-floating ones); a floating child may
sit at any position and does not take layout space.

```lua
local toast = ui.mount("notification", ui.box{
    float = "screen", anchor = "bottom_right", margin = 1, width = "fit", height = "fit",
    ui.text{fg = "warning", "Saved with CRLF line endings"},
})
```

## 4. Node types

Common props on every node: `id`, `key`, sizing and floating props (section 3), `on` (section 8), `scope` (section 8),
style fields where the node draws (section 5).

Universal rule: positional values are children, named values are props.

| Node | Children | State | Natural size | Focus |
|---|---|---|---|---|
| `column` | any nodes, stacked vertically | `{highlighted}` | sum of heights + gaps x widest child, + padding | see section 8 |
| `row` | any nodes, side by side | `{highlighted}` | sum of widths + gaps x tallest child, + padding | see section 8 |
| `box` | exactly 1 | none | child + border | not focusable |
| `scroll` | exactly 1, plus slot `header` | `{offset}` | child natural size | not focusable; takes the wheel |
| `text` | strings and spans | none | longest line x line count | never |
| `editor` | none (floating only) | `{cursor, selection, scroll}` | grows | focusable; typing edits its buffer |
| `image` | none | none | see Open | never |
| `terminal` | none (floating only) | `{scroll}` | grows | focusable; raw keys and program mouse |
| `virtual_column` | none (no plain children) | `{highlighted}` | estimated | see section 8 |
| `virtual_row` | none (no plain children) | `{highlighted}` | estimated | see section 8 |
| `outlet` | none; mounts act as the parent's children | none | of its mounts | n/a |

### column / row

| Prop | Meaning |
|---|---|
| `gap` | cells between children |
| `padding` | inner space |
| `align` | cross-axis placement of unsized children |
| `separator` | rule drawn between children |
| `highlight_style` | style of the child whose `key` equals state `highlighted` |

- A column or row with keyed children is a list. There is no list node and no `empty` prop.
- `highlighted` is empty by default (a plain container). Core draws the highlight and scrolls it into view inside an
  enclosing `scroll`. Movement, skipping and multi-select are plugin code: events + `set_state`.
- Tables are rows with identical child size specs; fit widths come from `qed.text.width(text)`.
- Trees are columns of indented rows; expansion is plugin state.
- Tabs are a highlighted row plus plugin-switched content.
- Resizable column / row (divider drag, state `{sizes}`) replaces split.

```lua
local tab_names = {"All", "Open", "Git"}
local tab_cells = {}
for i, name in ipairs(tab_names) do
    tab_cells[i] = ui.text{key = name, " " .. name .. " "}
end
local tab_strip = ui.row{id = "tree_tabs", separator = true, highlight_style = {bg = "selection", bold = true},
    table.unpack(tab_cells)}
```

### box

| Prop | Meaning |
|---|---|
| `border` | border style |
| `title` | text in the top border |

```lua
local dialog = ui.box{float = "screen", anchor = "center", width = "fit", height = "fit",
    border = "single", title = "Unsaved changes",
    ui.text{"Save main.odin before closing?"}}
```

### scroll

| Prop / slot | Meaning |
|---|---|
| child | exactly one positional child |
| `header` | node pinned above the content, same width as the content; layout only (a floating node here raises) |

- Owns the offset, the scrollbar and the wheel.
- Scroll protocol between `scroll` and its content: content reports total rows, renders a requested row range, and asks
  to bring a row into view. Plain containers pass range requests down to nested virtual lists.
- Lists, tables, trees, text and markdown are always wrapped in a `scroll` to scroll; editor and terminal scroll
  themselves.

```lua
local log_view = ui.scroll{id = "log_scroll", grow = 1,
    header = ui.row{ui.text{width = 8, bold = true, "Time"}, ui.text{grow = 1, bold = true, "Message"}},
    ui.virtual_column{id = "log_rows", data = qed.log.list(), item = log_row}}
```

### text

| Prop | Meaning |
|---|---|
| `wrap` | wrap long lines |
| `align` | horizontal alignment of lines |
| style fields | node `bg` fills the node's area; span `bg` covers the span |

- `ui.text` is the outermost span; children are strings or nested spans, which inherit and override style.
- `\n` splits lines; tabs expand to `tab_width`.
- No state, no focus.

```lua
local hint_line = ui.text{fg = "comment",
    "Press ", {fg = "accent", bold = true, qed.shortcut("Command Palette")}, " for commands"}
```

### editor

| Prop | Meaning |
|---|---|
| `buffer` | a `qed.buffer` object |
| `placeholder` | text shown while the buffer is empty |
| `line_numbers`, `diff_marks` | gutter features |
| `wrap` | soft wrap |
| `highlight` | syntax highlighting |
| `decorations` | draw `qed.deco` decorations |
| `current_line_style` | style of the cursor line |
| `readonly` | no edits from input |

- Minimal defaults: every feature is off until the node turns it on (the `layout` plugin turns them on for the main
  view).
- A single-line field is `height = 1` plus key handlers for Enter; there is no `single_line` prop and no `ui.input`.
- State lives on the buffer until views get their own (two editors over one buffer share cursor and scroll).
- Preview panes are a read-only internal buffer in an editor with `highlight` and `diff_marks`.
- Cursor popups are floating children with `anchor = "cursor"`.

```lua
local message_buffer = qed.buffer{internal = true}
local commit_field = ui.editor{id = "commit_message", buffer = message_buffer, height = 3, wrap = true,
    placeholder = "Commit message"}
```

### image

| Prop | Meaning |
|---|---|
| `path` | image file, drawn with the kitty graphics protocol |

```lua
local screenshot = ui.image{path = screenshot_path, width = 40, height = 12}
```

### terminal

| Prop | Meaning |
|---|---|
| `session` | a `qed.term.create` session handle |

- Grows by default; its size resizes the PTY.
- Internal scrollback, state `{scroll}`.
- Focused: raw keys and program mouse. Process exit fires `exit`.

```lua
local build_session = qed.term.create{name = "build", cmd = "./build.sh"}
local build_view = ui.terminal{id = "build_terminal", session = build_session,
    on = {exit = function(event) qed.message("build exited " .. event.code) end}}
```

### virtual_column / virtual_row

| Prop | Meaning |
|---|---|
| `data` | a `qed.list` handle, or a plain table (wrapped in a list automatically) |
| `item = function(record) -> node` | builds the node for one record |
| `highlight_style` | as on column / row |

- No plain children; nest anywhere.
- `item` is a pure function of the record, called only for records coming into view, cached per record. The cache
  clears on `update` (new closure) and per record on list changes.
- Identity is the list's `key` field; `highlighted` holds a key.
- Sizes are estimated; exact for one-row items.
- Grouping and trees are flattened lists with a `kind` field plus `insert` / `remove`. 2D grids do not exist.

```lua
local function buffer_row(record)
    return ui.row{ui.text{grow = 1, record.name}, ui.text{fg = "comment", record.modified and "●" or ""}}
end
local buffer_list = ui.virtual_column{id = "buffer_list", data = qed.buffers(), item = buffer_row,
    highlight_style = {bg = "selection"}}
```

### outlet

| Prop | Meaning |
|---|---|
| `id` | the name `ui.mount` targets |
| `accepts = "float"` | optional; restricts what may be mounted (see Open) |

```lua
local status_bar = ui.row{id = "status", height = 1, bg = "status_bg",
    ui.text{grow = 1, current_path}, ui.outlet{id = "status_right"}, ui.text{language_name}}
```

### Markdown

Not a node: `qed.markdown.parse(text, {dir, styles})` returns an opaque subtree of generic nodes (text, column, row,
image). Headings and links carry ids / keys for anchors, link events and source mapping.

```lua
local readme_view = ui.scroll{id = "readme_scroll", grow = 1,
    qed.markdown.parse(readme_text, {dir = project_dir})}
```

## 5. Styles

| Field | Value |
|---|---|
| `fg`, `bg` | theme color keys |
| `bold`, `italic`, `underline` | booleans |

No `reverse`. A style is a plain table of these fields (`highlight_style = {bg = "selection"}`); spans and drawing
nodes take the fields directly.

## 6. Lists and data

`qed.list` is a core-owned record list. Views over it are notified of changes; no `update` is needed for data
changes.

| Call | Does |
|---|---|
| `qed.list.new{fields = {...}, key = "path"}` | new list; `key` names the identity field |
| `list:append(record)` | adds at the end, or in sort position when sorted |
| `list:insert(position, record)` | adds at a position |
| `list:set(key, fields)` | changes fields of one record |
| `list:remove(key)` | removes one record |
| `list:clear()`, `list:count()`, `list:get(...)` | |
| `list:sort(field, {reverse})` | sorts; later inserts land in place |

Built-in lists:

| Source | Records |
|---|---|
| `qed.fs.walk{...}` | paths under a root |
| `qed.commands()` | core and plugin commands |
| `qed.buffers()` | open buffers |
| `qed.log.list()` | message log entries |

| Helper | Does |
|---|---|
| `qed.fuzzy.match(list, query, {field, limit})` | list handle sorted by score; records carry `positions` (matched byte offsets) |
| `qed.spawn{..., on_lines = function(lines)}` | streams output lines, batched per tick |

```lua
local matches = qed.list.new{fields = {"path", "row", "text"}, key = "id"}
matches:sort("path")
qed.spawn{argv = {"rg", "--vimgrep", query}, on_lines = function(lines)
    for _, line in ipairs(lines) do
        local path, row, text = line:match("^(.-):(%d+):%d+:(.*)$")
        if path then matches:append{id = path .. "\0" .. row, path = path, row = tonumber(row), text = text} end
    end
end}
```

## 7. Buffers for editors

| Call | Does |
|---|---|
| `qed.buffer{internal = true}` | new buffer; `internal` (default `false`) keeps it out of the buffer list, LSP, git and autosave |
| `buffer:close()` | frees it; the plugin owns the buffer's lifetime |

Text fields, previews and prompts are editors over internal buffers. A helper like `text_field` must keep one buffer
per node id.

## 8. Events and focus

### Focus

- Exactly one focused node globally. The plugin declares it (`ref:focus()`, `handle:focus(id)`).
- Keys go to the focused node, then bubble up the focus chain to `root`, then to the global keybinds. There is no
  `focus = false`.
- Events never cross layers except by this bubbling.

### Handlers

`on = {event = handler}` on any node. A handler returning `true` marks the event handled and stops bubbling.

| Event | Fires on |
|---|---|
| `key` | focused node and ancestors |
| `paste` | focused node and ancestors |
| `click`, `double_click` | node under the pointer, then ancestors |
| `drag`, `release` | node under the pointer, then ancestors |
| `wheel` | node under the pointer, then ancestors |
| `focus`, `blur` | node gaining / losing focus |
| `state` | node whose state the user changed (one event for every state field) |
| `exit` | terminal whose process exited |

### Scopes

- `scope = "name"` on any node activates the commands of that scope while focus is inside the node.
- Inner scopes shadow outer ones. The palette lists the active scope chain plus global commands.
- At each node, a scoped binding is checked before the node's raw `on.key`.

### Terminal escape

No intercept mechanism. A terminal's escape chord is a focused zero-size child with its own scope binding the chord;
other keys bubble on to the terminal.

```lua
local terminal_panel = ui.box{float = "screen", anchor = "center", width = "90%", height = "80%", border = "single",
    ui.terminal{id = "shell_terminal", session = shell_session,
        ui.text{id = "shell_escape", float = "parent", width = 0, height = 0, scope = "terminal_escape"}}}
```

## 9. Stacking and hit-testing

| Rule | Detail |
|---|---|
| Draw order | tree order: layers bottom to top, within a layer mount order, within a tree children after parents |
| Floating child | draws above its parent's subtree, inside the parent's layer |
| Mouse hit-test | reverse draw order; the topmost node under the pointer receives the event, which bubbles to its ancestors |
| Keys | focus chain only (section 8) |

## 10. Performance rules

| Rule | Detail |
|---|---|
| Keystrokes | Lua handlers on keys are allowed and stay light. |
| Render path | Lua never runs during layout or render. |
| Per-key updates | prefer `set_state` (state only) over `update`; rebuild per key only small trees |
| Lists | large data lives in `qed.list`; `item` runs only for records entering view |
| GC | collect in the idle gap after a frame, in bounded steps (best variant in the bench); generational mode is the worst |

Bench (Ryzen 7 8845HS, 160x48, list navigation per arrow key):

| Case | N | p50 ms | p99 ms |
|---|---|---|---|
| core moves highlight, no Lua | 100k | 0.19 | 0.38 |
| Lua handler + `set_state`-style setter | 100k | 0.19 | 0.40 to 0.46 |
| full tree rebuild per key | 1k | 1.3 to 2.3 | 3.8 (quiet heap) to 31 (loaded) |
| full tree rebuild per key | 10k | 13 to 16 | 32 to 73 |
| full tree rebuild per key | 100k | 136 to 146 | 600+ |

- A Lua call per key costs about 5 us.
- Rebuild cost is linear, about 1.1 to 1.5 us per row before GC; an 8 ms budget caps a rebuilt tree near 5k nodes
  without GC, about 2k with GC.
- Idle-time GC cuts rebuild p99 at 1k from 31 to 7.5 ms (loaded heap). Generational GC is the worst variant (10k: p50
  50 ms). The current GC step has no hard cap: single steps reached 48 to 81 ms.

## 11. Worked examples

### Command palette

```lua
local ui = qed.ui

local function name_spans(record)
    local matched = {}
    for _, offset in ipairs(record.positions or {}) do matched[offset] = true end
    local spans = {}
    for offset = 1, #record.name do
        local character = record.name:sub(offset, offset)
        spans[#spans + 1] = matched[offset] and {fg = "accent", bold = true, character} or character
    end
    return spans
end

local function command_row(record)
    return ui.row{
        ui.text{grow = 1, table.unpack(name_spans(record))},
        ui.text{fg = "comment", record.shortcut or ""},
    }
end

local function open_palette()
    local query_buffer = qed.buffer{internal = true}
    local all_commands = qed.commands()
    local results = all_commands
    local palette
    local subscription

    local function close_palette()
        subscription:off()
        palette:unmount()
        query_buffer:close()
    end

    local function build()
        return ui.box{
            id = "palette", float = "screen", anchor = "center", width = 60, height = "fit", margin = 2,
            border = "single", scope = "palette",
            on = {key = function(event)
                local highlighted = palette:state().palette_results.highlighted
                if event.key == "down" or event.key == "up" then
                    local next_key = neighbour_key(results, highlighted, event.key == "down" and 1 or -1)
                    palette:set_state{palette_results = {highlighted = next_key}}
                    return true
                elseif event.key == "enter" and highlighted then
                    close_palette()
                    qed.run(highlighted)
                    return true
                elseif event.key == "escape" then
                    close_palette()
                    return true
                end
            end},
            ui.column{
                ui.row{
                    ui.text{fg = "comment", "> "},
                    ui.editor{id = "palette_query", buffer = query_buffer, height = 1, grow = 1,
                        placeholder = "Type a command"},
                },
                ui.scroll{height = math.min(results:count(), 8),
                    ui.virtual_column{id = "palette_results", data = results, item = command_row,
                        highlight_style = {bg = "selection"}}},
            },
        }
    end

    palette = ui.mount("pane", build())
    palette:focus("palette_query")

    subscription = qed.on("buf_changed", function(changed_buffer)
        if changed_buffer ~= query_buffer then return end
        local query = query_buffer:text()
        results = query == "" and all_commands or qed.fuzzy.match(all_commands, query, {field = "name"})
        palette:update(build())
        local first = results:count() > 0 and results:get(1).name or nil
        palette:set_state{palette_results = {highlighted = first}}
    end)
end
```

### File finder with header

```lua
local ui = qed.ui

local function file_row(record)
    return ui.row{
        ui.text{grow = 1, record.path},
        ui.text{width = 4, align = "right", fg = "comment", record.dir and "dir" or ""},
    }
end

local function open_file_finder()
    local query_buffer = qed.buffer{internal = true}
    local preview_buffer = nil
    local all_files = qed.fs.walk{}
    local matches = all_files
    local finder
    local show_preview

    local query_subscription

    local function close_finder()
        query_subscription:off()
        finder:unmount()
        query_buffer:close()
        if preview_buffer then preview_buffer:close() end
    end

    local function finder_keys(event)
        local highlighted = finder:state().finder_results.highlighted
        if event.key == "enter" and highlighted then
            close_finder()
            qed.open(highlighted)
            return true
        elseif event.key == "escape" then
            close_finder()
            return true
        end
    end

    local function build()
        return ui.box{
            id = "finder", float = "screen", anchor = "center", width = "100%", height = "100%",
            margin = {8, 3}, border = "single", title = "Find File", scope = "finder",
            on = {key = finder_keys},
            ui.column{
                ui.editor{id = "finder_query", buffer = query_buffer, height = 1, placeholder = "type to filter"},
                ui.row{grow = 1, separator = true,
                    ui.scroll{width = {40, min = 30, max = 60},
                        header = ui.row{
                            ui.text{grow = 1, bold = true, "Path"},
                            ui.text{width = 4, align = "right", bold = true, "Kind"},
                        },
                        ui.virtual_column{id = "finder_results", data = matches, item = file_row,
                            highlight_style = {bg = "selection"},
                            on = {state = function(event) show_preview(event.state.highlighted) end}},
                    },
                    preview_buffer and ui.editor{id = "finder_preview", buffer = preview_buffer, grow = 1, drop = 1,
                        readonly = true, highlight = true, line_numbers = true} or nil,
                },
            },
        }
    end

    show_preview = function(path)
        if preview_buffer then preview_buffer:close() end
        preview_buffer = path and qed.buffer{internal = true, path = path} or nil
        finder:update(build())
    end

    finder = ui.mount("pane", build())
    finder:focus("finder_query")

    query_subscription = qed.on("buf_changed", function(changed_buffer)
        if changed_buffer ~= query_buffer then return end
        local query = query_buffer:text()
        matches = query == "" and all_files or qed.fuzzy.match(all_files, query, {field = "path", limit = 500})
        finder:update(build())
    end)
end
```

## Open

From the design:
- Keybind config format for scopes.
- Focus after unmount.
- Buffer events for internal buffers (per-buffer subscription? separate internal / external events?).
- Handler signature.
- Buffer async load / reload API for `qed.buffer{path}` (cheap enough to throw away and reload).
- GC step cap: fix now or TODO.

Contradictory or underspecified (found writing this note):
- CLAUDE.md's UI row says "positioned panes" and lists list, tree, markdown and preview as core leaves; the node set
  has no pane type, no list / tree / preview node, and markdown is `qed.markdown.parse`.
- Key order at one node: where core-native behaviour (editor typing and arrows, terminal raw keys, scroll wheel) sits
  relative to scoped bindings and `on.key`. If the palette's query editor consumes Up / Down natively, the box never
  sees them.
- Which nodes can hold focus: "one focused leaf" vs field-less list panes (Message Log, Plugins, file tree without
  filter) that need keys on a column or a zero-size node.
- Terminal escape needs a child under `ui.terminal`, a leaf; the same applies to cursor popups under `ui.editor`.
  Whether leaves accept floating children generally, and whether a terminal still gets raw keys while focus is on
  its descendant, is not stated.
- `anchor = "cursor"`: the earlier `target` (editor id) and `flip` props vs the later "float = parent under an
  editor" rule; completion needs an anchor column (word start, not caret) and must dodge rows reserved by the inline
  ghost.
- Ids unique across the tree: no namespacing between plugins; collision behaviour (raise? per-plugin prefix?) is
  unspecified. Layer ids share this space.
- Identity by position with outlets: whether mounted nodes count toward the parent's positional identity.
- What happens to mounts when their outlet disappears (unmounted, kept, re-attached); this replaces the old
  `parent` close-with behaviour.
- `accepts = "float"?`: values and meaning (float-only vs laid-out default), and whether layer outlets lay out their
  children (`base`) or require floats (`pane`, `popup`).
- `pane:raise()` has no counterpart on mount handles; layer name `pane` remains although the pane type is gone, and
  the "default layer" has no meaning when `ui.mount` always names an outlet.
- `handle:focus(id)` and `ui.node(id):focus()` overlap.
- Initial focus on mount: only by a call after `mount`, or a prop.
- Size "fit up to N rows" (palette: at most 8 rows) is not expressible; the example computes `height` in Lua.
- `{percent, min, max}` table shape (positional percent? `"40%"` string inside?).
- `margin` and `padding` forms (one number, `{x, y}`, four sides); margin on laid-out (non-floating) children.
- `align` means cross-axis placement on containers and line alignment on text; unclear whether it is a container
  prop or per child.
- `separator`: value type, rule style, whether it consumes a `gap` cell, and joins into a box border (`├─┤`).
- `box.border` values and title alignment.
- Span constructor: plain tables (`{fg = ..., "text"}`) vs a `ui.span`; the examples use plain tables.
- `text` truncation: ellipsis, clip direction (status path shortens from the left), interaction with `drop`.
- Resizable column / row: prop name, divider drawing, min sizes; it is absent from the final node list.
- Multi-select: `highlighted` holds one key; how several selected rows are drawn without rebuilding (rebuild clears
  the virtual `item` cache).
- `highlight_style` composition with the row's own styles (bg-only selection vs replace).
- When `highlighted` names a key no longer in `data` (after a fuzzy refilter): cleared, kept, moved.
- Positional access on lists: `get(...)` signature (key or index); moving the highlight needs a neighbour lookup
  (`neighbour_key` in the palette example has no API behind it).
- `qed.list.new{fields}`: what `fields` declares (schema, types for `sort`).
- `qed.fuzzy.match` result: snapshot or live (does it refilter when the source list grows, as a streaming walk does).
- `qed.commands()` already exists returning a plain table; `qed.buffers()` vs the existing `qed.buf.list()`.
- `qed.buffer` objects vs the existing `qed.buf.*` numeric buffer ids; no read API (`buffer:text()` in the palette
  example is assumed).
- `qed.spawn` yields and today takes `on_line`; streaming with `on_lines` while the caller continues may belong on
  `spawn_bg`.
- Observing an input editor's text: no event is decided; the palette example subscribes to global `buf_changed`.
- Handlers today run as coroutines; a `key` handler must return `true` synchronously to stop bubbling. Whether UI
  handlers may yield is unstated.
- `state` event: coalescing, whether `set_state` fires it, and its payload.
- Event list gaps: link activation in parsed markdown, mouse move / hover, layout or resize notification (markdown
  source-row sync needs the laid-out row mapping), outside-click (every picker closes on a click outside).
- Modal (block other exclusive opens) and backdrop (dim / blank below a pane) have no replacement.
- Keyboard scrolling of a `scroll` (markdown preview Up / Down / PgUp) and whether `editor` / `terminal` may sit
  inside a `scroll`.
- Natural size of `scroll` (child total or capped), of virtual lists under `"fit"`, of `editor` when not growing, and
  of `image` (pixel size / cell size?).
- Query debounce and task cancellation (search `rg` restarts) are no longer core; no timer helper is named.
- Preview swap: the finder replaces the preview buffer per highlight change; with no async load this blocks on large
  files.
- Optional children: the finder drops the preview with `cond and node or nil`; a `nil` hole mid-list ends a Lua
  sequence, so optional children need a rule (skip `nil`? `false` placeholders?).
- The finder previews on the `state` event; keyboard moves done with `set_state` only reach it if `set_state` fires
  `state`, otherwise every mover must call the preview itself.
- Header vs content width under a `scroll`: whether the scrollbar column is outside both, so header and rows align.

---@meta

---Rows and columns are 1-based; columns are byte offsets. `col = #line + 1` is the caret at end of line.
---@class qed.Pos
---@field row integer
---@field col integer

---A buffer object (`qed.buf.current()`, `qed.open`, ...).
---@alias qed.Buf qed.BufferObject

---@class qed.Ctx
---@field buf qed.BufferObject|nil the current buffer (nil on the welcome screen)
---@field path string|nil the current buffer's path, `""` for an unnamed buffer (nil on the welcome screen)
---@field language string|nil
---@field root string
---@field selection_text string|nil the selected text, read on first access; nil once the buffer changed since the command was invoked
---@field items (string|qed.UiItem)[]|nil while a pane with a list has focus (any plugin's command, e.g. a scoped one): its selection, the range with `multi`
---@field item string|qed.UiItem|nil while a pane with a list has focus (the file tree or any other): the item under the cursor, shaped like an entry of `items`
---@field view qed.View|nil a view of this plugin that has focus (a `scope` command's chord or its scoped Ctrl+P)
---@field files string[]|nil the focused pane's selected items' paths, else in the file tree every selected path, in tree order; on a scoped tab (Open, Changed, Unsaved) a selected dir stands for its in-scope files

---@class qed.CommandSpec
---@field name string bare name; the palette shows `<display name>: <name>`
---@field run fun(ctx: qed.Ctx)
---@field when? fun(ctx: qed.Ctx): boolean
---@field key? string default chord, overridden by config `plugins.<id>.keybinds[keybind]`; a bare key (`"x"`) is allowed outside the editor scope and fires only in a pane without fields
---@field bind_from? string without `key`: take the bind of this core command (e.g. `"Copy"`), re-read at every rebind so it follows that command's config
---@field scope? string `"global"` (default), a core pane's scope (`"log"`, `"plugins"`), a `qed.ui.open{scope}` (the file tree's is `"filetree"`) or a `qed.ui` node scope: the command runs on its chord while focus is inside a node or pane of that scope
---@field welcome? boolean also offered on the welcome screen (no buffer)
---@field keybind? string the key in `plugins.<id>.keybinds`, default `name`; commands sharing it share the bind and the first `key` among them

---@class qed.Meta
---@field display_name? string shown wherever the plugin is named (palette prefix, message and log labels, Plugins pane); default the id title-cased (`my_tools` is "My Tools")
---@field description? string one line shown in the Plugins pane

---@class qed.Stat
---@field size integer
---@field mtime number unix seconds
---@field type "file"|"dir"|"link"|"other"

---@alias qed.Level "debug"|"info"|"warn"|"error"

qed = {}

---@type string
qed.version = ""

---Writes `text` to the Message Log (Alt+L) under this plugin's display name; never shown on the status line. Raises on an unknown level.
---@param text any
---@param level? qed.Level default `"info"`
function qed.log(text, level) end

---Shows `text` on the message line as `<display name>: text` and logs it; `""` clears the message line. Raises on an unknown level.
---@param text any
---@param level? qed.Level default `"info"`
function qed.message(text, level) end

---@class qed.CommandHandle
---@field id integer
local CommandHandle = {}
---Unregisters the command. A no-op if it is already gone.
function CommandHandle:remove() end

---Registers `<display name>: <name>`. A visible name may be registered once per scope (one editor and one file tree command); taken names and bare names equal to a core command of that scope raise.
---@param spec qed.CommandSpec
---@return qed.CommandHandle
function qed.command(spec) end

---Run a builtin or plugin command by its visible name (`"Git: Set Diff Base"`). A bare name also resolves to the caller's own editor command (bare names never equal a core command). `nil, "unavailable"` when a core command does not apply now or a plugin command's `when` returns false; raises on an unknown name.
---@param name string
---@return true|nil ok
---@return "unavailable"|nil err
function qed.run(name) end

---Every change to `b` while `fn` runs is one undo step; an error inside `fn` rolls it back.
---Returns `nil, "stale"` without calling `fn` if `opts.rev` is stale.
---@param buffer qed.Buf
---@param fn fun()
---@param opts? {rev?: integer}
---@return true|nil ok
---@return "stale"|nil err
function qed.edit(buffer, fn, opts) end

---Open (or switch to) a file. Relative paths resolve against `qed.root()`.
---@param path string
---@return qed.BufferObject|nil buffer
---@return string|nil err
function qed.open(path) end

---Opens a new unnamed buffer (the untouched welcome scratch is replaced) holding `text` as its clean content, and switches to it. Saving it asks for a file name. `nil, err` on an unknown `language`.
---@param opts {text?: string, language?: string}
---@return qed.BufferObject|nil buffer
---@return string|nil err
function qed.new_buf(opts) end

---The user config file path (`$XDG_CONFIG_HOME/qed/config.json`, else `~/.config/qed/config.json`); `""` without a home.
---@return string
function qed.config_path() end

---The embedded default `config/config.json` text.
---@return string
function qed.config_defaults() end

---The embedded `config/schema.json` text: per core key (dotted, `*` matches one segment) `{description, choices?, min?}`.
---@return string
function qed.config_schema() end

---Writes one key into the user config.json (a sparse diff; nothing else is touched, defaults never materialize); the config hot reload applies it. `keys` is a top-level key or a path (`{"plugins", "ai", "enabled"}`). An empty table is written as a list.
---@param keys string|string[]
---@param value any
---@return true|nil ok
---@return string|nil err "no config file" or "cannot write config.json (unwritable or not valid JSON)"
function qed.config_set(keys, value) end

---Removes one key from the user config.json, restoring its default; empty parent objects go too.
---@param keys string|string[]
---@return true|nil ok
---@return string|nil err
function qed.config_unset(keys) end

---@class qed.CommandInfo
---@field name string visible name
---@field shortcut string the live bind, `""` when unbound
---@field scope string `"global"`, `"editor"` (editor nodes), `"filetree"`, `"log"`, `"plugins"` or a pane's or node's scope
---@field owner? string plugin id; nil for core commands
---@field keybind? string its key in `keybinds` (core) or `plugins.<owner>.keybinds`; nil for a core command borrowing another's bind
---@field key? string the default bind (with `keybind`)

---Every core and plugin command.
---@return qed.CommandInfo[]
function qed.commands() end

---@class qed.PluginInfo
---@field id string
---@field display string
---@field description string
---@field state "enabled"|"disabled"|"errored"
---@field bundled boolean
---@field options? table its `qed.options` defaults (a copy), once loaded
---@field info? table<string, string|qed.OptionInfo> its `qed.options` info (a copy)
---@field error string the last load or task error, "" when none
---@field load_ms number how long its setup took
---@field main string its main file: a path for a user plugin, `<id>/init.lua` for a bundled one
---@field fork string the path a copy would take to override a bundled one

---Every plugin, bundled then user, in load order.
---@return qed.PluginInfo[]
function qed.plugins() end

---Enables or disables another plugin at the next flush and persists `plugins.<id>.enabled` (removed when it matches the default).
---@param id string
---@param enabled boolean
---@return true|nil ok
---@return "no such plugin"|nil err
function qed.plugin_enable(id, enabled) end

---Reloads another plugin at the next flush.
---@param id string
---@return true|nil ok
---@return "no such plugin"|"disabled"|nil err
function qed.plugin_reload(id) end

---A plugin's main source text (bundled plugins are embedded).
---@param id string
---@return string|nil text
---@return "no such plugin"|"no source"|nil err
function qed.plugin_source(id) end

---Save through the full pipeline. Fails without saving if the file changed on disk
---(the conflict dialog opens only for the current buffer). Waits for `buf_pre_save` handlers.
---@param buffer qed.Buf
---@return true|nil ok
---@return "no file name"|"changed on disk"|"save in progress"|nil err
function qed.save(buffer) end

---Close a buffer. Returns `nil, "unsaved"` and keeps it open if it has unsaved changes, unless its id is in `discard` (approved, e.g. by a confirm).
---@param buffer qed.Buf
---@param opts? {discard?: qed.BufferObject[]}
---@return true|nil ok
---@return "unsaved"|nil err
function qed.close(buffer, opts) end

---Switch to buffer `target` or open the path `target` (relative to `qed.root()`), move the cursor to `pos` (clamped, a col inside a UTF-8 sequence snaps back), and record the jump from where you were. Closes the file tree if it is open.
---@param target qed.Buf|string
---@param pos qed.Pos
---@return true|nil ok
---@return string|nil err "cannot open <path>" when a path fails to open
function qed.jump(target, pos) end

---The working root: the directory qed was started in or last switched to. Relative paths in `qed.*` resolve against it.
---@return string
function qed.root() end

---Opens a URL with the platform opener (macOS `open`; WSL `wslview`, else `explorer.exe`; Linux `xdg-open`), detached. `nil, err` when no opener is found or it cannot start.
---@param url string
---@return true|nil
---@return string|nil err
function qed.open_url(url) end

---@class qed.Unsaved
---@field total integer buffers outside the new root
---@field unsaved integer of them unsaved
---@field bufs qed.BufferObject[] the unsaved ones

---Switches the working root to the directory `path` (relative to `qed.root()`): closes every buffer outside it, restarts the language servers, drops saved pane selections and expanded dirs and fires `root_changed`. A no-op on the current root. While an unsaved buffer outside it is not in `discard`, closes nothing and returns `nil, "unsaved", info`; ask, then call again with `{discard = info.bufs}`.
---@param path string
---@param opts? {discard?: qed.BufferObject[]} unsaved buffer ids that may be closed
---@return true|nil ok
---@return "unsaved"|string|nil err `"unsaved"`, or "not a directory: <path>"
---@return qed.Unsaved|nil info with `"unsaved"`
function qed.set_root(path, opts) end

---@class qed.OptionInfo
---@field description? string one line for the settings menu
---@field choices? string[] the allowed values of a string option (the default must be one)

---Declares this plugin's config keys and defaults; returns the merged config (`plugins.<id>` over `defaults`; `enabled` and `keybinds` are reserved). Setup only, once per load.
---Objects merge per key, lists and other values replace; a user value whose type differs from the default's warns and keeps the default, and `null` drops a default.
---`info` maps option keys to a description or `{description?, choices?}` (the settings menu shows them); a key not in `defaults` raises.
---@generic T: table
---@param defaults T
---@param info? table<string, string|qed.OptionInfo>
---@return T
function qed.options(defaults, info) end

---Sets plugin metadata. Setup only, once per load, before any `qed.command`. Unknown fields, a display name another loaded plugin uses, and core log labels ("LSP", "Plugins", ...) raise.
---@param meta qed.Meta
function qed.meta(meta) end

---This plugin's merged config (a fresh copy each call).
---@return table
function qed.config() end

---Read-only core knob, e.g. `"tab_width"`, `"theme"`, `"lsp.completion_max_rows"`.
---@param key string
---@return integer|boolean|string
function qed.opt(key) end

---POSIX single-quotes `s` so it is one literal shell word.
---@param text string
---@return string
function qed.shell_quote(text) end

---Parses compiler/grep output (`file:row:col: msg`, `file:row:col`, `file:row: msg`, `file:row`) into `qed.pick` items with a root-relative `label`, an absolute `path` and the parsed `pos`.
---Lines naming a missing file are skipped; `{}` when nothing parses. `cwd` resolves relative files, default `qed.root()`.
---@param text string
---@param opts? {cwd?: string}
---@return {label: string, path: string, pos: qed.Pos}[]
function qed.parse_locations(text, opts) end

---@alias qed.Event "startup"|"buf_open"|"buf_close"|"buf_enter"|"buf_pre_save"|"buf_save"|"buf_reload"|"buf_changed"|"cursor_moved"|"language_changed"|"root_changed"|"config_changed"|"theme_changed"|"term_open"|"term_exit"|"term_close"|"quit"|"plugin_loaded"|"plugin_unloaded"|"message"|string

---@class qed.Handle
---@field id integer
local Handle = {}
---Unregisters the handler. A no-op if it is already gone.
function Handle:off() end

---Handlers run as coroutines in plugin load order. `buf_changed(b, rev, typed, lo, hi)` (`typed`: the latest change was the user typing a character, Enter, Backspace or Delete;
---`lo..hi`: the rows touched since the last delivery to any subscriber, in current rows; rows above `lo` are unchanged, rows below `hi` only shifted; a rev change with no recorded edit carries the whole buffer) and
---`cursor_moved(b)` fire at most once per main-loop iteration, and again within the same flush for changes a handler made. Save waits for
---`buf_pre_save(b)` handlers and quit for `quit` handlers, up to `plugin_hook_timeout_ms`.
---`config_changed(changed)`: `changed` is a set of this plugin's top-level config keys whose merged value changed (`{}` when only core config did); apply just those to keep live toggles of the others.
---`root_changed(old, new)`, `term_open(name)`, `term_exit(name, code)`, `term_close(name)`, `buf_close(b, path)`; other buffer events get `b`.
---`plugin_loaded(id)` and `plugin_unloaded(id)` fire for other plugins after startup (hot reload, enable, disable, an error).
---A `"<plugin>:<event>"` name subscribes to that plugin's `qed:emit` and gets its `data`.
---@param event qed.Event
---@param fn function
---@return qed.Handle
function qed:on(event, fn) end

---Queues a custom event for `qed:on(name)` handlers. `name` must be `"<this plugin's id>:<event>"`; every handler gets the same `data` (read-only by convention).
---@param name string
---@param data? any
function qed:emit(name, data) end

---Publishes functions other plugins reach through `qed.plugin(id)`. Setup only, once per load. They run in the caller's task against this plugin's state.
---@param fns table<string, function>
function qed.export(fns) end

---Another plugin's exports, or nil when it is not loaded (the installed check). Raises during setup: call it from `startup` or `plugin_loaded`.
---Each call raises once that plugin unloads or reloads; fetch again on `plugin_loaded`. Tables passed either way are read-only by convention.
---The exports see the plugin that called `qed.plugin` as their `qed.caller()`. Calls from a coroutine the plugin created itself raise.
---@param id string
---@return table|nil
function qed.plugin(id) end

---Inside an exported function: the id of the plugin that called it (nil elsewhere), to key per-caller state dropped on `plugin_unloaded`.
---@return string|nil
function qed.caller() end

---@class qed.SpawnSpec
---@field cmd? string run under `sh -c`
---@field argv? string[] run directly
---@field stdin? string
---@field cwd? string defaults to `qed.root()`
---@field env? table<string, string> merged over the editor's environment
---@field on_line? fun(line: string) each stdout line as it arrives; delivered lines are left out of `stdout`

---@class qed.SpawnResult
---@field code integer
---@field stdout string
---@field stderr string

---Waits for the process to exit. `nil, "cannot start <cmd>: <err>"` when the process cannot start (an `argv` program or the `cwd` missing); under `cmd` a missing program is the shell's exit 127.
---@param spec qed.SpawnSpec
---@return qed.SpawnResult|nil
---@return string|nil err
function qed.spawn(spec) end

---@class qed.Proc
---@field id integer
---@field pid? integer
local Proc = {}
---Kills the process; a no-op if it already exited.
function Proc:kill() end
---Waits for the process to exit. The result is handed out once; later calls return nil, "process is gone".
---@return qed.SpawnResult|nil
---@return string|nil err
function Proc:wait() end

---Runs in the background; killed when the plugin unloads and on quit. `nil, err` like `qed.spawn` when it cannot start.
---@param spec qed.SpawnSpec
---@return qed.Proc|nil
---@return string|nil err
function qed.spawn_bg(spec) end

---Waits `ms` milliseconds. `qed.sleep(0)` yields until the next main-loop iteration: a long loop calls it now and then to stay inside the slice budget.
---@param ms integer
function qed.sleep(ms) end

---@class qed.Timer
---@field id integer
local Timer = {}
---Cancels the timer. A no-op if it already fired or was stopped.
function Timer:stop() end

---Runs `fn` once after `ms` milliseconds.
---@param ms integer
---@param fn fun()
---@return qed.Timer
function qed.defer(ms, fn) end

---Runs `fn` every `ms` milliseconds; a tick is skipped while the previous one still runs.
---@param ms integer
---@param fn fun()
---@return qed.Timer
function qed.every(ms, fn) end

---@class qed.UiItem
---@field label? string defaults to `path`
---@field detail? string shown dim, right-aligned
---@field value? any carried through untouched
---@field path? string previewed by a split pane with `preview = "auto"`; a `qed.pick` item with a path switches it to the list + file preview layout
---@field pos? qed.Pos preview focus row (and column)
---@field buf? qed.Buf previewed live from this open buffer (unsaved edits included) instead of `path`
---@field key? string identity for `View:update`, `View:marks` and for restoring the selection by `id` (default `label`; a walk item's is its path)
---@field cells? string[] one string per `list.columns` entry
---@field dir? boolean walk items: a directory
---@field depth? integer walk items: tree depth (0 at the root)
---Other fields of a Lua item are kept: `activate`, `change` and `ctx.items` hand back the same table.

---@alias qed.PaneLine string|{text: string, color?: string} color is a theme color key, e.g. `"error_foreground"`

---@class qed.UiField
---@field prompt? string prefix, default `"> "`
---@field text? string initial text, fully selected unless `mode` is input or path
---@field mode? "filter"|"query"|"input"|"path" filter (default) fuzzy-filters the list per key; query fires `on.query` at open and 120 ms after typing stops; input submits its text on Enter; path drives a `qed.fs.dirs` list (Tab or `/` at the end drills into the highlighted dir, Backspace after `/` drops a segment) and submits on Enter, its text reported as an absolute path (`~` and relative to `qed.root()` resolved)
---@field count? boolean shows the match count (`N+` past `list.max` or after `set{more}`) at the end of the row
---@field hint? string dim placeholder while the field is empty
---@field esc_clears? boolean Esc clears the non-empty field instead of closing the pane

---A core-owned item source (`qed.fs.dirs`, `qed.fs.walk`). Items live in core and are built only when drawn; only activated or changed ones reach Lua, as `{label, path?, detail?, buf?, pos?, dir?, depth?}` tables. Freed when collected or when its plugin unloads (a handle passed to another plugin dies with its owner); an open view keeps its own copy.
---@class qed.PaneSource
---@field id integer
local PaneSource = {}
---Walk handles: the number of items, or `nil, "pending"` while `ready()` is false (it starts the background walk; a `within` handle is always ready).
---@return integer|nil
---@return "pending"|nil err
function PaneSource:count() end
---Walk handles: replaces the ignore set of every walk of this root (paths hidden unless `ignored`); a change reruns them. `false` marks it not known yet: no background walk runs and `View:expand(true)` refuses until a list arrives.
---@param paths string[]|false
function PaneSource:ignore(paths) end
---Walk handles: false while the walk (or its background prewarm) is still running.
---@return boolean
function PaneSource:ready() end
---Walk handles: a new handle keeping only `paths`, their ancestors and everything under a listed dir. Listed paths ignore the dotfiles and ignored rules. Raises on an already narrowed handle.
---@param paths string[]
---@return qed.PaneSource
function PaneSource:within(paths) end
---Walk handles: a new handle that also lists `paths` (and their missing parent dirs) when they are not on disk, e.g. deleted files. It shares the narrowed handle's paths instead of copying them.
---@param paths string[]
---@return qed.PaneSource
function PaneSource:union(paths) end

---The visible rows of this walk as a tree list (`max` caps narrowed results).
---@param opts? {max?: integer}
---@return qed.TreeList
function PaneSource:tree(opts) end
---Walk handles: frees the handle now instead of at collection; a view keeps its own copy.
function PaneSource:release() end

---@class qed.UiList
---@field items? (string|qed.UiItem)[]|qed.PaneSource
---@field multi? boolean Shift+Up/Down selects a range
---@field max? integer items past it are dropped and the count shows `N+`
---@field empty? string dim hint while the list is empty
---@field selected? integer item index to start on
---@field sort? boolean keep the items ordered by key: `append` inserts in place and the selection follows its item once the user moved it
---@field tree? boolean a `qed.fs.walk` list shown as a tree: indent, expand icons, Enter or double-click on a dir toggles it (a filter shows ranked paths; Enter on a dir clears it and reveals the dir); open buffers get an accent, unsaved ones `●`
---@field columns? qed.UiColumn[] items draw their `cells` in these columns, two spaces apart; a title on any column adds a header row and a rule under it that stay put while the list scrolls

---@class qed.UiColumn
---@field title? string header text, drawn bold
---@field width? integer|"fit"|"fill" a positive integer is fixed; `"fit"` grows to the widest cell seen (title included, the first 1000 items and every drawn row; it never shrinks while the pane is open); `"fill"` (default) shares what is left with the other fill columns. Too narrow a pane shrinks fill columns first, then fit columns down to their `min`; cells that do not fit end in `…`
---@field min? integer `"fit"` or `"fill"`: never narrower than this (a fit column's default is its title width)
---@field max? integer `"fit"`: never wider than this
---@field right? boolean right-align the cells; the title stays left-aligned

---@class qed.UiHandlers
---@field activate? fun(v: qed.View, items: (string|qed.UiItem)[]) Enter or double-click: the selection (the range with `multi`), `{}` for a pane without a list; the pane stays open
---@field change? fun(v: qed.View, item: string|qed.UiItem) the highlighted item changed (not at open, also after `View:set`); a newer change kills the previous run
---@field query? fun(v: qed.View, text: string) the query field settled; a newer query and the close kill the previous run and the `qed.spawn` it waits on (`qed.spawn_bg` processes stay the plugin's to kill)
---@field close? fun(v: qed.View) any close: Esc, click outside, the opening command's chord, `View:close`, a parent closing, an exclusive pane replacing it
---@field link? fun(v: qed.View, target: string) a click on a link in a `markdown` body: the raw destination (URL, relative path, `path#anchor`); `#anchor` links come here too when this handler is set (call `View:anchor`), else core scrolls them
---@field tab? fun(v: qed.View, i: integer) the user switched tabs (Left/Right, a click or a tab's chord)
---@field expand? fun(v: qed.View, item: qed.UiItem, open: boolean) the user expanded or collapsed a dir of a tree list
---@field submit? fun(v: qed.View, text: string|nil) the footer input (`View:footer{input}`) was submitted (a `chord` input: the captured chord), or cancelled with Esc (`nil`)

---@class qed.UiSpec
---@field id? string the selected item's key, a tree's expanded dirs and the text body's scroll persist (never the fields' text) under it across opens (and plugin reloads); a field given a non-empty `text` skips restoring the selection
---@field modal? boolean exclusive opens are refused as busy while it is open (`qed.pick`, `qed.prompt` and `qed.confirm` set it); a non-modal pane is replaced and its waiters get `nil`
---@field place? "center"|"full"|"split" center (default) is a centered box, full fills the screen, split puts a full-height preview column beside the fields and list
---@field size? "palette"|"dialog"|"split:code"|"split:tree" center: palette (default, fixed width) or dialog (fits the content); split: split:code (default, the `split_code_*` widths) or split:tree (the `split_tree_*` widths)
---@field tabs? (string|{label: string, cmd?: string})[] a tab row over both columns; Left/Right and clicks switch, a tab's `cmd` (visible command name) chord switches to it and on the active tab closes the pane
---@field tab? integer the tab to start on
---@field kind? "exclusive"|"child" exclusive (default) closes the open exclusive pane; child stacks on what has focus (a pane or a core overlay), else opens exclusive; outside a user's command it stacks only on the plugin's own pane (from a view's `activate`, also on that view and its children), else returns busy
---@field parent? qed.View stack on this view (usually `ctx.view`): Esc returns to it, closing it closes this one
---@field focus? boolean false opens a passive pane: drawn under focused panes, never takes input
---@field title? string
---@field fields? qed.UiField[] Tab cycles them
---@field list? qed.UiList
---@field preview? "auto"|false split: previews the selected item's `path` at `pos.row`
---@field text? qed.PaneLine[] lines above the list (center) or the scrollable body (full or split without a list)
---@field markdown? string full only, without list or text: the body is this markdown, rendered by core at the pane width (the LSP hover renderer); arrows, PgUp/PgDn, Home/End and the wheel scroll it
---@field markdown_dir? string with `markdown`: the directory relative image paths resolve against (images show through terminal graphics, see `image_protocol`)
---@field toggle? string|false visible name of the command whose chord closes the pane (default: the command that opened it); needed when opening from a handler; `false`: no chord closes it (tabs' chords still do)
---@field jump_closes? boolean `qed.jump` closes the pane (a hub like the file tree, left once a child picker jumps)
---@field info? string full or split only: a strip above the footer showing this text wrapped to the pane width (never truncated while 3 list rows remain), e.g. the selected item's description; `View:info` replaces it
---@field backdrop? "none"|"dim"|"blank" what happens to everything drawn under the pane (the editor and panes below, never the status rows): left alone (default), faded (theme tint `pane_backdrop`) or cleared to the background
---@field max_width? integer center or full: the box is at most this many columns wide, borders included, and stays centered (e.g. from the plugin's own option)
---@field footer? {hints?: {label: string, cmd?: string}[], chips?: {label: string, cmd: string, on?: boolean}[]} bottom row; a hint or chip with `cmd` (visible command name) is prefixed with that command's live shortcut; chips are right-aligned, lit when `on`, and a click runs `cmd`
---@field scope? string commands registered with this `scope` run on their chord while the pane has focus (with `ctx.view`), and Ctrl+P opens a palette of just them
---@field on? qed.UiHandlers handlers run as tasks after input dispatch, before the next frame

---Methods that change the view return `true`, or `nil, "closed"` once it is closed; methods that return a value return `nil, "closed"` instead of it.
---@class qed.View
---@field id integer
local View = {}
---Replaces the items, or swaps in a list handle (then `selected` is an item key, a path for a walk). `selected` is the item index to highlight (default 1, or the item restored by `id`), `more` shows the count as `N+`, `hint` replaces `list.empty` while the list is empty, `columns` replaces `list.columns` (items, not handles).
---@param items (string|qed.UiItem)[]|qed.PaneSource
---@param opts? {selected?: integer|string, more?: boolean, hint?: string, columns?: qed.UiColumn[]}
---@return true|nil ok
---@return "closed"|nil err
function View:set(items, opts) end
---Adds items at the end and keeps the selection. Raises on a list backed by a `qed.PaneSource` (replace it with `View:set`).
---@param items (string|qed.UiItem)[]
---@return true|nil ok
---@return "closed"|nil err
function View:append(items) end
---Merges `fields` into the item whose key is `key` (a string item becomes `{label = s}` first). `nil, "not found"` when no item has that key. Raises on a list backed by a `qed.PaneSource`.
---@param key string
---@param fields qed.UiItem
---@return true|nil ok
---@return "not found"|"closed"|nil err
function View:update(key, fields) end
---Replaces the text lines.
---@param lines qed.PaneLine[]
---@return true|nil ok
---@return "closed"|nil err
function View:text(lines) end
---Replaces the info strip text (`""` hides the strip). Full or split panes only.
---@param text string
---@return true|nil ok
---@return "closed"|nil err
function View:info(text) end
---Replaces the markdown body, keeping the scroll position. Raises for a view opened without `markdown`.
---@param text string
---@return true|nil ok
---@return "closed"|nil err
function View:markdown(text) end
---Scrolls a markdown body to the heading with this GitHub slug and returns the heading's source line, or `nil, "not found"`. Raises for a view opened without `markdown`.
---@param slug string
---@return integer|nil source
---@return "not found"|"closed"|nil err
function View:anchor(slug) end
---Top row (1-based) of a text or markdown body, clamped to what can show; scrolls there first when `row` is given. Once closed, a markdown body's `close` handler still reads its last top row.
---@param row? integer
---@return integer|nil
---@return "closed"|nil err
function View:scroll(row) end
---Source line (1-based buffer row) of the markdown line shown on terminal row `row` (1-based; default the body's top, clamped to the shown rows), and the terminal row used. Code and table rows map to their own line, other blocks (reflowed text) to their first. Works in the `close` handler on the last shown rows; nil when nothing is shown.
---@param row? integer
---@return integer|nil source
---@return integer|nil row
function View:source_line(row) end
---Scrolls a markdown body so the block holding source line `source` starts on terminal row `row` (1-based; default and clamp: the body's rows), clamped at the document ends. Returns the new top row.
---@param source integer
---@param row? integer
---@return integer|nil
---@return "closed"|nil err
function View:source_scroll(source, row) end
---Closes the pane and its children; a no-op once closed.
function View:close() end
---Per-row styling by item key (a walk list's keys are paths, relative ones resolved against the root): `bar` (theme color of a `▌` in the left column), `fg` (theme color), `suffix` (drawn after the label), `added`/`removed` (a right-aligned `+N -N`), `dim` (dims the row and, in a tree, everything under it unless selected). `false` drops a key; `replace` clears the rest first. Validated before anything changes.
---@param marks table<string, {bar?: string, fg?: string, suffix?: string, added?: integer, removed?: integer, dim?: boolean}|false>
---`detail = false` hides every `suffix` and `added`/`removed` until `detail = true` (no marks resent); `total` sizes the store for a push split into chunks.
---@param opts? {replace?: boolean, detail?: boolean, total?: integer}
---@return true|nil ok
---@return "closed"|nil err
function View:marks(marks, opts) end
---Replaces the footer `hints` and/or `chips` (e.g. a chip's `on`), or turns the footer into an input field (`input = {prompt?, text?}`; Enter or Esc fires `on.submit`; `input = false` drops it). `mode = "chord"` captures the next bindable key instead: `on.submit` gets its config string (`"Ctrl+k"`, `"Alt+F"`, `"x"`), Esc cancels.
---@param spec {hints?: {label: string, cmd?: string}[], chips?: {label: string, cmd: string, on?: boolean}[], input?: {prompt?: string, text?: string, mode?: "input"|"chord"}|false}
---@return true|nil ok
---@return "closed"|nil err
function View:footer(spec) end
---The active tab; with `i`, switches to it first (no `on.tab`); with `tabs`, replaces the tab row first.
---@param i? integer
---@param tabs? (string|{label: string, cmd?: string})[]
---@return integer|nil
---@return "closed"|nil err
function View:tab(i, tabs) end
---`false` stops the auto preview (the plugin shows its own), `"auto"` resumes it; a table shows `path` now, diffed against `base` (raw bytes) when given, only the changed hunks unless `diff_only = false`.
---@param spec false|"auto"|{path: string, base?: string, diff_only?: boolean}
---@return true|nil ok
---@return "closed"|nil err
function View:preview(spec) end
---Tree lists: `true`/`false` expands or collapses every dir (`nil, "loading"` while the walk's ignore set is still loading); no argument collapses every dir when a shown one is expanded, else expands all; a path and a boolean (default true) sets one dir.
---@param what? boolean|string
---@param open? boolean
---@return true|nil ok
---@return "loading"|"closed"|nil err
function View:expand(what, open) end
---Tree lists: clears the filter, expands `path`'s ancestors and selects it. `nil, "not listed"` when it is not in the list.
---@param path string
---@return true|nil ok
---@return "not listed"|"closed"|nil err
function View:reveal(path) end
---The highlighted item, its row, the range's other end (`multi`) and the row count (rows are 1-based visible positions; a tree's rows follow its expanded dirs). Returns nothing once closed.
---@return qed.UiItem|string|nil item
---@return integer|nil row
---@return integer|nil anchor
---@return integer|nil count
function View:selection() end
---Selects `row` (clamped); `anchor` makes a range (`multi`). Raises on a view without a list.
---@param row integer
---@param anchor? integer
---@return true|nil ok
---@return "closed"|nil err
function View:select(row, anchor) end
---Sets (`fn`) or drops (`false`) a handler after open, e.g. `change` only while it has work to do.
---@param event "activate"|"change"|"query"|"close"|"link"|"tab"|"expand"|"submit"
---@param fn function|false
---@return true|nil ok
---@return "closed"|nil err
function View:on(event, fn) end
---Waits for the next `activate` or the close. Returns the activated items and the first one's index, or `nil, nil` on close, then the first field's text (also on close). Returns `nil` at once when already closed.
---@return (string|qed.UiItem)[]|nil items
---@return integer|nil index
---@return string|nil text
function View:wait() end

qed.ui = {}

---Opens a pane. Returns `nil, "busy"` while a quit, close or conflict dialog shows, or when an exclusive open meets a `modal` pane; `nil, "closed"` when `parent` is gone. Raises in `setup`.
---A command of the view's own plugin run while the view has focus (a `scope` command's chord, or its scoped Ctrl+P) gets it as `ctx.view`.
---@param spec qed.UiSpec
---@return qed.View|nil
---@return "busy"|"closed"|nil err
function qed.ui.open(spec) end

---@class qed.Node: table

---@class qed.MountHandle
---@field id integer
local MountHandle = {}

---Replaces the mounted tree; state survives for nodes with the same identity (id, key, or type + position).
---@param tree qed.Node
function MountHandle:update(tree) end

---Removes the tree; `result` goes to a task already waiting on it (wait before unmounting). A no-op when already unmounted.
---@param result? any
function MountHandle:unmount(result) end

---Waits (in a command, handler or timer) until the tree is unmounted and returns the `unmount` result, or nil.
---@return any
function MountHandle:wait() end

---@class qed.NodeRef
local NodeRef = {}

---Moves the global focus to this node. `nil, "no such node"` when it is not in the tree.
---@return true|nil
---@return string|nil err
function NodeRef:focus() end

---The node's widget state: `highlighted` (lists), `offset` (scroll), `scroll` (editor, 1-based top row).
---@return table|nil
function NodeRef:state() end

---Changes only the named state fields (`highlighted`, `offset`, `scroll`); no rebuild. A new `highlighted` scrolls into view.
---@param patch table
function NodeRef:set_state(patch) end

---The node's last laid-out rect, 1-based screen cells: `{x, y, width, height}`; nil when hidden or absent.
---@return {x: integer, y: integer, width: integer, height: integer}|nil
function NodeRef:rect() end

---Mounts `tree` into an outlet: a layer (`background`, `base`, `popup`, `pane`, `notification`, `alert`) or a plugin's `qed.ui.outlet` id. Unmounted when the plugin unloads.
---@param outlet string
---@param tree qed.Node
---@return qed.MountHandle
function qed.ui.mount(outlet, tree) end

---A reference to the node with this `id`.
---@param id string
---@return qed.NodeRef
function qed.ui.node(id) end

---Children stacked vertically. Props: `gap`, `align`, `separator`, `highlight_style`, plus common props (`id`, `key`, `width`, `height`, `grow`, `drop`, `margin`, `float`, `anchor`, `scope`, `on`, style fields).
---@param props table
---@return qed.Node
function qed.ui.column(props) end

---Children side by side. Props as `column`.
---@param props table
---@return qed.Node
function qed.ui.row(props) end

---Exactly one laid-out child. Props: `border`, `title`.
---@param props table
---@return qed.Node
function qed.ui.box(props) end

---Exactly one laid-out child, scrolled; slot `header` pinned above it. Takes the wheel.
---@param props table
---@return qed.Node
function qed.ui.scroll(props) end

---Strings and spans (`{fg = "...", bold = true, "text", ...}`) as children. Props: `wrap`, `align`.
---@param props table
---@return qed.Node
function qed.ui.text(props) end

---A view over a buffer. Props: `buffer`, `placeholder`, `line_numbers`, `highlight`, `wrap`, `readonly`, `current_line_style`. Typing inserts; movement and editing are the `editor` scope's commands.
---@param props table
---@return qed.Node
function qed.ui.editor(props) end

---Rows built by `item(record)` for the records of `data` (a `qed.list`) in view. Props: `data`, `item`, `highlight_style`.
---@param props table
---@return qed.Node
function qed.ui.virtual_column(props) end

---An image file drawn with kitty graphics placeholders (alt text `[image: name]` without graphics). Prop: `path` (relative to the root).
---@param props table
---@return qed.Node
function qed.ui.image(props) end

---A qed.term session's screen; it takes keys, paste and the mouse while focused (Esc goes to the program in alt-screen, otherwise through the scope). Prop: `session`.
---@param props table
---@return qed.Node
function qed.ui.terminal(props) end

qed.markdown = {}

---The rendered document as a node to place in a `ui.scroll` (which owns its offset, bar and wheel). One core-rendered node, laid out at the scroll's width. `opts` are node props: `id`, `dir` (relative links and images), `margin`, `on.link(event)` (`event.target`; an unhandled `#slug` scrolls the holding scroll to that heading). State: `rows`, `sources` (source rows of the visible lines), `heading` (source row of the last `heading` set); `set_state{source = row, at = terminal_row}` (that row's first line lands on the terminal row, as near as the document allows) or `{heading = slug}` moves the holding scroll.
---@param text string
---@param opts? table
---@return qed.Node
function qed.markdown.parse(text, opts) end


---A full-screen float holding panes: a click outside them calls `on_dismiss`, a click on one stays with it. Props: `on_dismiss`, `id`, and the panes as children.
---@param props table
---@return qed.Node
function qed.ui.dismissable(props) end

---The scopes of the focused node and its ancestors, innermost first (what a palette lists over a pane).
---@return string[]
function qed.ui.focus_scopes() end

---A transparent slot other plugins mount into with `qed.ui.mount(id, tree)`. Prop: `id`.
---@param props table
---@return qed.Node
function qed.ui.outlet(props) end

---@class qed.List
local List = {}
---@param record table
function List:append(record) end
---@param position integer
---@param record table
function List:insert(position, record) end
---Merges `fields` into the record (not its key field) and rebuilds that record's item.
---@param key string|integer
---@param fields table
---@return true|nil
function List:set(key, fields) end
---@param key string|integer
function List:remove(key) end
function List:clear() end
---@param key string|integer
---@return table|nil
function List:get(key) end
---@param index integer
---@return table|nil
function List:at(index) end
---@param key string|integer
---@return integer|nil
function List:index_of(key) end
---@return integer
function List:count() end
---@param field string
---@param opts? {reverse?: boolean}
function List:sort(field, opts) end

---A live filtered view of a `qed.List`, sorted by score; records are the source's own tables.
---@class qed.FuzzyList
local FuzzyList = {}
---@param key string|integer
---@return table|nil
function FuzzyList:get(key) end
---@param index integer
---@return table|nil
function FuzzyList:at(index) end
---@param key string|integer
---@return integer|nil
function FuzzyList:index_of(key) end
---@return integer
function FuzzyList:count() end
---Re-filters in core; views update without a tree update.
---@param query string
function FuzzyList:set_query(query) end
---The record's matched byte offsets (1-based) for the current query; nil when it does not match.
---@param key string|integer
---@return integer[]|nil
function FuzzyList:positions(key) end

---The visible rows of a walk as a list a `virtual_column` reads (from `walk:tree{max?}`): records `{path, name, depth, dir, expanded}` keyed by `path`. Reading dirs runs in slices; `loading()` is true while some are unread.
---@class qed.LinesList
local LinesList = {}
---@param key string
---@return table|nil
function LinesList:get(key) end
---@param index integer
---@return table|nil
function LinesList:at(index) end
---@param key string
---@return integer|nil
function LinesList:index_of(key) end
---@return integer
function LinesList:count() end
---@param query string
function LinesList:set_query(query) end

---@class qed.TreeList
local TreeList = {}
---@param key string
---@return table|nil
function TreeList:get(key) end
---@param index integer
---@return table|nil
function TreeList:at(index) end
---@param key string
---@return integer|nil
function TreeList:index_of(key) end
---@return integer
function TreeList:count() end
---Narrows to the fuzzy matches of `query` over every path (flat rows); "" shows the tree again.
---@param query string
function TreeList:set_query(query) end
---@param path string
---@param on? boolean default true
function TreeList:expand(path, on) end
---@param path string
---@return boolean expanded
function TreeList:toggle(path) end
---@param path string
---@return boolean
function TreeList:expanded(path) end
---Expands the path's ancestors; true when the row is shown now.
---@param path string
---@return boolean
function TreeList:reveal(path) end
---False when the walk's ignore set is not known yet (it would descend into ignored dirs).
---@param on? boolean default true
---@return boolean
function TreeList:expand_all(on) end
---@return boolean
function TreeList:loading() end
---True when a narrowed list holds only the first `max` matches.
---@return boolean
function TreeList:more() end

qed.list = {}

---A core-owned record list; `key` names the identity field.
---@param spec {key: string}
---@return qed.List
function qed.list.new(spec) end

qed.fuzzy = {}

---A live filtered view of `source` sorted by score (`matches:positions(key)` gives the matched offsets).
---@param source qed.List
---@param spec {field: string}
---@return qed.FuzzyList
function qed.fuzzy.list(source, spec) end

---@class qed.PickSpec
---@field items (string|qed.UiItem)[]
---@field prompt? string replaces the `>` prefix
---@field selected? integer|string item index or label to start on
---@field on? {change?: fun(_: nil, item: string|qed.UiItem)} the highlighted item changed (live preview); the first argument is always nil

---Waits for a fuzzy pick (the bundled `dialog` plugin, on qed.ui). Returns the chosen item (the value passed in), or `nil` on Esc. Items with a `path` get a list + read-only file preview (centered on `pos.row`). `on.change(nil, item)` runs on every move.
---The opening command's chord closes it like Esc. Stacks on an open pane or overlay (outside a user's command only on the plugin's own pane, or from a view's `activate` on that view and its children); otherwise `nil, "busy"` only while a quit, close or conflict dialog shows.
---@param spec qed.PickSpec
---@return string|qed.UiItem|nil
---@return "busy"|nil err
function qed.pick(spec) end

---Waits for a line of text. `nil` on Esc. Opens over an open pane (Esc returns to it; closing that pane closes this one with `nil`).
---Returns `nil, "busy"` only while a quit, close or conflict dialog shows. While it is open, other exclusive panes are refused as busy.
---@param spec {prompt: string, text?: string}
---@return string|nil
---@return "busy"|nil err
function qed.prompt(spec) end

---Waits for a choice. Returns its 1-based index, `nil` on Esc. Opens over an open pane (Esc returns to it; closing that pane closes this one with `nil`).
---Returns `nil, "busy"` only while a quit, close or conflict dialog shows. While it is open, other exclusive panes are refused as busy.
---@param spec {question: string, choices?: string[]} `choices` defaults to `{"Yes", "No"}`
---@return integer|nil
---@return "busy"|nil err
function qed.confirm(spec) end

---Language names as `qed.buf.language` returns them.
---@return string[]
function qed.languages() end

---A live core list of message log entries `{seq, level, source, text, time, seeded}` (key `seq`): new entries append, evicted ones leave.
---@param filter? {levels?: {debug?: boolean, info?: boolean, warn?: boolean, error?: boolean}, history?: boolean, source?: string}
---@return qed.List
function qed.messages(filter) end

qed.theme = {}

---Applies a theme. With `persist`, also writes it as config `theme` (only that key); `nil, err` on an unknown name or a failed write.
---@param name string
---@param opts? {persist?: boolean}
---@return true|nil ok
---@return string|nil err
function qed.theme.set(name, opts) end

---Bundled and user theme names, sorted.
---@return string[]
function qed.theme.list() end

---The theme on screen.
---@return string
function qed.theme.current() end

---A theme icon, e.g. `"status_branch"`.
---@param name string
---@return string
function qed.theme.icon(name) end

---The bundled `filetree` plugin's exports (`qed.plugin("filetree")`). Everything is kept per calling plugin and dropped when it unloads.
---@class filetree.Exports
local FileTree = {}

---@class filetree.Tab
---@field label string unique; added tabs sit between Open and Unsaved
---@field paths string[] listed paths (absolute) and their descendants; pass the same table again to keep the tree's narrowed list
---@field virtual? string[] paths not on disk to list too (deleted files)
---@field cmd? string a command whose chord selects the tab (shown in the tab row)
---@field detail? boolean show mark suffixes and `+N -N` sizes on this tab
---@field preview? fun(path: string): string|nil runs in the tree's task after the preview debounce; a string is the base the file is diffed against, nil previews it plainly
---@field missing? fun(path: string) Enter on a listed path missing on disk
---@field empty? string dim hint while the tab lists nothing

---Adds the caller's tab, or replaces the one with this label.
---@param tab filetree.Tab
function FileTree.set_tab(tab) end

---@param label string
function FileTree.remove_tab(label) end

---Row marks by absolute path, shown on every tab; replaces the caller's last marks.
---@param marks table<string, {bar?: string, fg?: string, suffix?: string, added?: integer, removed?: integer, dim?: boolean}>
function FileTree.set_marks(marks) end

---Paths the tree hides unless *Toggle Ignored*; false holds the background walk until the set is known.
---@param paths string[]|false
function FileTree.set_ignored(paths) end

---Opens the tree on a tab (a built-in label or an added one).
---@param label string
function FileTree.open(label) end

---The live show-dotfiles state, *Toggle Dotfiles* included.
---@return boolean
function FileTree.dotfiles() end

qed.term = {}

---@class qed.TermSpec
---@field name string unique; `"shell"` is the default session and cannot be created
---@field cmd? string shell command run with `/bin/sh -c`; nil runs an interactive `$SHELL`
---@field cwd? string defaults to the working root; relative to it
---@field env? table<string, string> added to qed's environment
---@field restart? boolean if the name is running, restart it with this spec instead of failing
---@field detach? boolean survives the plugin's unload (otherwise closed with it)

---@class qed.TermState
---@field name string
---@field running boolean
---@field code? integer exit code of the last run (128 + signal when killed)
---@field pid? integer while running
---@field busy? boolean while running: a program other than the session's own process holds the foreground

---Starts a named session in the background (PTY + emulator, not shown). Fails with `nil, "already running"` unless `restart`.
---An exited session of the same name is replaced.
---@param spec qed.TermSpec
---@return true|nil ok
---@return "already running"|"cannot start"|nil err
function qed.term.create(spec) end

---Starts the default `"shell"` session if it is not running. The bundled `terminal` plugin shows sessions:
---`qed.plugin("terminal").show(name)` and `.hide()`. Raises during `setup`.
---@return true|nil ok
---@return "terminal unavailable"|nil err
function qed.term.shell() end

---Kills the session's process group. Its output stays; `term_exit` fires. Raises for `"shell"`.
---@param name string
---@return true|nil ok
---@return "no such session"|nil err
function qed.term.kill(name) end

---Kills (without `term_exit`) and respawns with the same spec on a fresh screen. Raises for `"shell"`.
---@param name string
---@return true|nil ok
---@return "no such session"|"cannot start"|nil err
function qed.term.restart(name) end

---Writes raw bytes to the session's input (`"\r"` is Enter). Unread input is buffered up to 1 MiB, the rest dropped.
---@param name string
---@param text string
---@return true|nil ok
---@return "no such session"|"not running"|nil err
function qed.term.send(name, text) end

---State of the named session, or nil if there is none.
---@param name string
---@return qed.TermState|nil
function qed.term.state(name) end

---Every session, in creation order.
---@return qed.TermState[]
function qed.term.list() end

---Kills the session and frees its scrollback. Raises for `"shell"`.
---@param name string
---@return true|nil ok
---@return "no such session"|nil err
function qed.term.close(name) end

qed.deco = {}

---A namespace owned by this plugin; the same name returns the same id. Unload clears all of them.
---@param name string
---@return integer
function qed.deco.ns(name) end

---Mark column glyph (shown where the diff base has no mark).
---@param buffer qed.Buf
---@param ns integer
---@param row integer
---@param glyph string one single-width character
---@param opts {color: string} theme color key
function qed.deco.gutter(buffer, ns, row, glyph, opts) end

---Line background tint, stacked over the diff hunk tint and under the current-line tint.
---@param buffer qed.Buf
---@param ns integer
---@param from_row integer
---@param to_row integer inclusive
---@param opts {color: string, alpha?: number|string} `color` a theme color key; `alpha` 0..1, or a theme tint key (`"conflict"`, `"ai_edit"`) resolved per frame, default the theme's `decoration` tint
function qed.deco.tint(buffer, ns, from_row, to_row, opts) end

---Virtual rows below (or above) a row, one clipped screen row each.
---@param buffer qed.Buf
---@param ns integer
---@param row integer
---@param lines string|string[]
---@param opts? {above?: boolean, color?: string}
function qed.deco.ghost(buffer, ns, row, lines, opts) end

---Style over a range; dropped when any of its rows is edited.
---@param buffer qed.Buf
---@param ns integer
---@param from qed.Pos
---@param to qed.Pos
---@param style {fg?: string, bg?: string, alpha?: number|string, bold?: boolean, underline?: boolean} `alpha` (a number or theme tint key) blends `bg` over the line background instead of painting it solid
function qed.deco.span(buffer, ns, from, to, style) end

---Virtual text after the end of a row, clipped to the window.
---@param buffer qed.Buf
---@param ns integer
---@param row integer
---@param text string
---@param opts {color: string} theme color key
function qed.deco.eol(buffer, ns, row, text, opts) end

---A range anchor that follows edits: text inserted before it shifts it, an edit touching its inside (or a reload) removes it. Never drawn.
---@param buffer qed.Buf
---@param ns integer
---@param from qed.Pos
---@param to qed.Pos
---@return integer id
function qed.deco.mark(buffer, ns, from, to) end

---Where the mark is now, or nil once an edit touched its inside, a reload dropped it or it was cleared.
---@param buffer qed.Buf
---@param ns integer
---@param id integer
---@return qed.Pos|nil from
---@return qed.Pos|nil to
function qed.deco.range(buffer, ns, id) end

---Dimmed inline text at the cursor, not part of the buffer (one per buffer). Shown while the cursor stays at `pos` without a selection; core handles the keys: Tab inserts it, Ctrl+Right its next word, any other key, a click or an edit drops it.
---Fails (nothing shown) when `opts.rev` is stale, `pos` is not the cursor, a selection is active or `text` is empty.
---@param buffer qed.Buf
---@param ns integer
---@param pos qed.Pos
---@param text string may span lines
---@param opts? {rev?: integer}
---@return true|nil ok
---@return "stale"|"not at cursor"|"selection"|"empty"|nil err
function qed.deco.inline(buffer, ns, pos, text, opts) end

---Removes the namespace's decorations, marks and inline text touching rows from_row..to_row (all when omitted).
---@param buffer qed.Buf
---@param ns integer
---@param from_row? integer
---@param to_row? integer
function qed.deco.clear(buffer, ns, from_row, to_row) end

qed.status = {}

---@class qed.StatusSegment
---@field text string|{text: string, color?: string}[] chunks paint in their own colors; `""` hides the segment but keeps its place
---@field color? string theme color key
---@field sep? string text before the segment, default two spaces
---@field side? "left"|"right" default "left" (after the builtins and the `[n/m]` buffer counter)
---@field early? boolean left side only: before `[n/m]` and the diff base label (the git segments)
---@field drop? integer drop rank when the bar is too narrow (lowest first, 0 never), default 1

---Sets or replaces this plugin's status bar segment `id`.
---@param id string
---@param seg qed.StatusSegment
function qed.status.set(id, seg) end

---Removes this plugin's segment `id`. A no-op if it is not set.
---@param id string
function qed.status.clear(id) end

qed.clipboard = {}

---System clipboard text via the external clipboard tool; falls back to qed's internal register when none is available.
---@return string
function qed.clipboard.get() end

---Replaces the system clipboard text (or qed's internal register when no clipboard tool is available).
---@param text string
function qed.clipboard.set(text) end

qed.buf = {}

---The current buffer, or nil on the welcome screen.
---@return qed.BufferObject|nil
function qed.buf.current() end

---All open buffers in tab order; empty on the welcome screen.
---@return qed.BufferObject[]
function qed.buf.list() end

---@class qed.BufferObject
---@field id integer
local BufferObject = {}

---Closes the buffer: frees an internal buffer; closes a file buffer like `qed.close`.
---@param opts? {discard?: qed.BufferObject[]}
---@return true|nil
---@return string|nil err
function BufferObject:close(opts) end

---Starts a search owned by the calling plugin: highlights every match, selects the one at or after the cursor. Several can exist; closed on plugin unload.
---@param query string
---@param opts? {regex?: boolean, case_sensitive?: boolean}
---@return qed.Search
function BufferObject:find(query, opts) end

---@class qed.Search
---@field id integer
local Search = {}

---Changes the query and options; returns index, count, capped, or `nil, "invalid pattern"`.
---@param query string
---@param opts? {regex?: boolean, case_sensitive?: boolean}
---@return integer|nil index
---@return integer|string count
---@return boolean|nil capped
function Search:update(query, opts) end

---Current index (1-based, 0 when none), count and whether the count hit the cap; rescans after buffer edits.
---@return integer|nil index
---@return integer|string count
---@return boolean|nil capped
function Search:result() end

---Selects the next (`1`) or previous (`-1`) match, wrapping.
---@param direction integer
---@return integer|nil index
---@return integer|string count
---@return boolean|nil capped
function Search:step(direction) end

---Replaces the current match, or every match with `all`, as one undo step. Returns the number replaced.
---@param text string
---@param opts? {all?: boolean}
---@return integer
function Search:replace(text, opts) end

---Ends the search and its highlights.
function Search:close() end

---True while the buffer is open; never raises.
---@return boolean
function BufferObject:valid() end

---The buffer's file path, or `""` for an unnamed buffer. Raises "buffer closed" for a stale id (as do all `qed.buf` calls taking `b`).
---@return string
function BufferObject:path() end

---Language name, e.g. `"odin"`; see `qed.languages()`.
---@return string
function BufferObject:language() end

---True if there are unsaved changes.
---@return boolean
function BufferObject:modified() end

---True for a buffer opened from a big file (highlighting, bracket matching and LSP are off).
---@return boolean
function BufferObject:big() end

---Edit counter; changes on every edit, so equal values mean unchanged text. Pass it as `opts.rev` to guard stale writes.
---@return integer
function BufferObject:rev() end

---Number of lines; an empty buffer has 1.
---@return integer
function BufferObject:line_count() end

---Rows `from..to`, inclusive. Defaults to the whole buffer.
---@param from? integer
---@param to? integer
---@return string[]
function BufferObject:lines(from, to) end

---Text of `row` without its newline. Raises if `row` is out of range.
---@param row integer
---@return string
function BufferObject:line(row) end

---Rows whose text starts with `prefix` (plain bytes), in order. Cheap on big buffers, so a `buf_changed` handler can find marker lines without copying the text.
---With a list of prefixes, also returns each row's prefix index (the first that matches). `word`: the prefix must be followed by the line end or a space.
---@param prefix string|string[]
---@param opts? {word?: boolean}
---@return integer[] rows
---@return integer[]? kinds
function BufferObject:find_lines(prefix, opts) end

---Rows ending in spaces or tabs, in order, with each run's span: `from[i]` is its first column, `to[i]` the line end (`#line + 1`). One core pass, no text copy.
---@return integer[] rows
---@return integer[] from
---@return integer[] to
function BufferObject:find_trailing() end

---The whole text, lines joined with LF regardless of the file's line endings.
---@return string
function BufferObject:text() end

---Insert `text` at `pos`. Cursor and selection shift with the edit. One undo step unless inside `qed.edit`. Raises on an out-of-range `pos` or a `col` inside a UTF-8 sequence.
---@param pos qed.Pos
---@param text string valid UTF-8; CRLF and CR become LF
---@return qed.Pos end_pos
function BufferObject:insert(pos, text) end

---Delete the half-open range `[from, to)`.
---@param from qed.Pos
---@param to qed.Pos
---@return string deleted
function BufferObject:delete(from, to) end

---Replace the half-open range `[from, to)` with `text`. Cursor and selection shift; one undo step unless inside `qed.edit`. Raises if `to` is before `from`.
---@param from qed.Pos
---@param to qed.Pos
---@param text string
---@return qed.Pos end_pos
function BufferObject:replace(from, to, text) end

---Replace the whole text with a minimal line diff, so the cursor, undo and highlight
---keep their place. One undo step. Returns `nil, "stale"` without editing if `opts.rev` is stale.
---@param text string
---@param opts? {rev?: integer}
---@return true|nil ok
---@return "stale"|nil err
function BufferObject:set_text(text, opts) end

---The caret position.
---@return qed.Pos
function BufferObject:cursor() end

---Move the caret to `pos`, clear the selection and scroll it into view if it is current.
---@param pos qed.Pos
function BufferObject:set_cursor(pos) end

---Terminal row (1-based) showing buffer row `row` (default the caret's visual row), or nil when off screen or `b` is not current.
---@param row? integer
---@return integer|nil
function BufferObject:screen_row(row) end

---Scrolls the editor so buffer row `row` sits on terminal row `screen_row` (clamped to the text area), clamped at the buffer ends. `nil, "not current"` if `b` is not current.
---@param row integer
---@param screen_row integer
---@return true|nil ok
---@return "not current"|nil err
function BufferObject:set_screen_row(row, screen_row) end

---Selection as `from, to` in document order, or nil when nothing is selected.
---@return qed.Pos|nil from
---@return qed.Pos|nil to
function BufferObject:selection() end

---Select from `anchor` to `cursor`; the caret ends at `cursor`, so a backward selection is allowed.
---@param anchor qed.Pos
---@param cursor qed.Pos
function BufferObject:set_selection(anchor, cursor) end

---Set the buffer's language by name and re-highlight. `nil, err` on an unknown name.
---@param name string language name as `qed.buf.language` returns it
---@return true|nil ok
---@return string|nil err
function BufferObject:set_language(name) end

---`"auto"` detects from the content. `width` defaults to the current width.
---@param style "tabs"|"spaces"|"auto"
---@param width? integer
function BufferObject:set_indent(style, width) end

---The buffer's indent style and width.
---@return "tabs"|"spaces" style
---@return integer width
function BufferObject:indent() end

---Diff base: drives the gutter marks, diff-view ghost rows, change navigation and revert hunk.
---Each plugin keeps its own base per buffer; the base of the plugin that first set one most recently wins,
---and clearing it with `nil` (or unloading) reveals the one beneath. Another plugin's base is never touched.
---@param text string|nil raw bytes (need not be UTF-8)
---@param opts? {label?: string} label shown in the status bar: `±base` when omitted, nothing when `""`
---@return true
function BufferObject:set_base(text, opts) end

---The id of the plugin whose diff base is shown, or nil when the buffer has none.
---@return string|nil
function BufferObject:base() end

---A live list over the buffer's lines, for a `virtual_column`: records `{key = tostring(row), row, col, label = line text}`, built only when read, `col` the first non-blank. An edit, a reload or the buffer closing shows on the next frame (a closed buffer empties it). `set_query(text)` keeps matches in buffer order; `:N` or `:N:M` keeps row N alone (column M, past the end clamps), a bare number lists row N first, then the text matches.
---@return qed.LinesList
function BufferObject:line_list() end

---A new internal buffer (not in the buffer list, no LSP, git or autosave) as a buffer object: every `qed.buf.*` function is a method with the buffer bound (`buffer:text()`). The plugin owns it; `buffer:close()` frees it.
---With `path`, it holds a copy of that file (an open buffer's live text, else the head of the file on disk) in its language: a read-only preview under a `readonly` editor node.
---@param spec {internal: true, path?: string}
---@return qed.BufferObject
function qed.buf.create(spec) end


---Subscribes to a buffer's events (`"change"`); handlers get the `buf_changed` arguments. Internal buffers fire only these.
---@param event "change"
---@param handler function
---@return {remove: fun()}
function BufferObject:on(event, handler) end


qed.fs = {}

---File contents, or `nil, err` (missing, unreadable). Relative paths resolve against `qed.root()`.
---@param path string
---@return string|nil data
---@return string|nil err
function qed.fs.read(path) end

---Atomic: writes a temp file in the same dir, then renames. `exclusive` creates the file instead and fails with `nil, "exists"` if the name is taken (also by a dangling symlink); missing parent dirs are created either way.
---@param path string
---@param data string
---@param opts? {exclusive?: boolean}
---@return true|nil ok
---@return string|nil err
function qed.fs.write(path, data, opts) end

---True if the path exists (file, dir or other). Relative paths resolve against `qed.root()`. `follow = false` checks the name itself, so a dangling symlink exists.
---@param path string
---@param opts? {follow?: boolean}
---@return boolean
function qed.fs.exists(path, opts) end

---Size, mtime and type of `path`, or `nil, err` if it does not exist. Relative paths resolve against `qed.root()`.
---@param path string
---@return qed.Stat|nil
---@return string|nil err
function qed.fs.stat(path) end

---Entry names, sorted.
---@param dir string
---@return string[]|nil
---@return string|nil err
function qed.fs.list(dir) end

---A list handle over the subdirectories of `path` (default `qed.root()`; symlinks to dirs included, dotfiles only with `dotfiles`), items `{label = name, path}` sorted by name. Under a `path` field it follows the field instead: the dir its text names, prefix-matched (smart case) against the last segment; a dir is read once while its segment stays the same.
---@param opts? {path?: string, dotfiles?: boolean}
---@return qed.PaneSource
function qed.fs.dirs(opts) end

---A list handle over every file and dir under `root` (default `qed.root()`): a threaded parallel walk, prewarmed in the background when a view opens over it, shared by handles with the same options, rerun after `qed.fs` writes under its root (serving the old items until the rerun lands). Dotfiles and the root's ignore set (`List:ignore`) are left out unless `dotfiles`/`ignored`. Items `{label, path, dir?, depth?}`. A filter field ranks paths (capped at `list.max`, default 500, narrowing the previous hits as the query grows), debounced.
---@param opts? {root?: string, dotfiles?: boolean, ignored?: boolean}
---@return qed.PaneSource
function qed.fs.walk(opts) end

---Copies a file or dir tree (modes kept, symlinks copied as links, fifos and devices skipped). Refuses an existing `dst`, a `dst` inside `src` and a special `src`; creates missing parent dirs.
---@param src string
---@param dst string
---@return true|nil ok
---@return "exists"|"not found"|string|nil err
function qed.fs.copy(src, dst) end

---Moves a file or dir, across filesystems too (mtimes kept), and repaths open buffers under it. Refuses an existing `dst` or a `dst` inside `src`.
---@param src string
---@param dst string
---@return true|nil ok
---@return "exists"|"not found"|string|nil err
function qed.fs.rename(src, dst) end

---Deletes a file or a dir tree; symlinks are removed, never followed. Refuses the root and its ancestors. Open buffers stay.
---@param path string
---@return true|nil ok
---@return "not found"|string|nil err
function qed.fs.remove(path) end

---Creates a dir and its missing parents. Refuses an existing path.
---@param path string
---@return true|nil ok
---@return "exists"|string|nil err
function qed.fs.mkdir(path) end

qed.json = {}

---Parses JSON into Lua values, or `nil, err` on invalid input. Whole numbers decode as integers.
---@param text string
---@return any
---@return string|nil err
function qed.json.decode(text) end

---Serializes a Lua value to compact JSON. Raises on functions, userdata, NaN or infinity, non-string/integer keys and over-deep nesting.
---@param value any
---@return string
function qed.json.encode(value) end

qed.path = {}

---Joins and cleans the parts with `/`.
---@param ... string
---@return string
function qed.path.join(...) end

---Everything before the last path element, as in `dirname`.
---@param path string
---@return string
function qed.path.dir(path) end

---The last path element, as in `basename`.
---@param path string
---@return string
function qed.path.base(path) end

---`p` relative to `base`, or `nil, err` when no relative path exists. Both are made absolute against `qed.root()` first; the result may start with `..` when `p` is not under `base`.
---@param path string
---@param base? string defaults to `qed.root()`
---@return string|nil
---@return string|nil err
function qed.path.rel(path, base) end

---Absolute, cleaned form; relative paths resolve against `qed.root()`. Symlinks are not resolved and the path need not exist.
---@param path string
---@return string
function qed.path.abs(path) end

qed.lsp = {}

---Waits for the language server to format `b` and applies the edits as one undo step.
---Fails with "disabled" (`lsp.enabled` off), "no server", "unavailable" (not ready or no
---formatting support), "stale" (buffer changed meanwhile), "timeout" (no reply within
---`plugin_hook_timeout_ms`) or "error" (already logged).
---@param buffer qed.Buf
---@return true|nil ok
---@return "disabled"|"no server"|"unavailable"|"stale"|"timeout"|"error"|nil err
function qed.lsp.format(buffer) end

qed.text = {}

---Display width in terminal columns, grapheme-aware: wide characters count 2, combining marks 0, tabs advance to the next tab stop.
---@param text string
---@return integer
function qed.text.width(text) end

---@class qed.DiffHunk
---@field a integer first row of the run in the old list (where it would be for an insertion)
---@field a_count integer rows removed from the old list
---@field b integer first row of the run in the new list
---@field b_count integer rows added from the new list

---Line diff of two string lists (the diff engine behind the gutter), as runs of changed rows. `nil` when the lists differ too much for the engine's edit-distance cap.
---@param old_lines string[]
---@param new_lines string[]
---@return qed.DiffHunk[]|nil
function qed.text.diff(old_lines, new_lines) end

---@class qed.DiffRowsHunk: qed.DiffHunk
---@field spans? integer[][] with `words`: per paired row (`a + k - 1` with `b + k - 1`), `{a_from, a_to, b_from, b_to}`, the differing columns (`to` exclusive; equal when a side has no change)

---`qed.text.diff` of two row ranges of one buffer, read in core (no text copied into Lua). Hunk rows are buffer rows; `lo > hi` (by one) is an empty side.
---@param buffer qed.Buf
---@param a_lo integer
---@param a_hi integer
---@param b_lo integer
---@param b_hi integer
---@param opts? {words?: boolean}
---@return qed.DiffRowsHunk[]|nil
function qed.text.diff_rows(buffer, a_lo, a_hi, b_lo, b_hi, opts) end

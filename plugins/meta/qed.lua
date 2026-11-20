---@meta

---Rows and columns are 1-based; columns are byte offsets. `col = #line + 1` is the caret at end of line.
---@class qed.Pos
---@field row integer
---@field col integer

---Buffer id. `nil` or `0` means the current buffer.
---@alias qed.Buf integer|nil

---@class qed.Ctx
---@field buf integer|nil current buffer id (nil on the welcome screen)
---@field path string|nil
---@field language string|nil
---@field root string
---@field selection_text string|nil
---@field items (string|qed.UiItem)[]|nil while a pane with a list has focus (any plugin's command, e.g. a scoped one): its selection, the range with `multi`
---@field file string|nil file tree only: the entry under the cursor (absolute)
---@field files string[]|nil the focused pane's selected items' paths, else in the file tree every selected path, in tree order; on a scoped tab (Open, Changed, Unsaved) a selected dir stands for its in-scope files

---@class qed.CommandSpec
---@field name string bare name; the palette shows `<display name>: <name>`
---@field run fun(ctx: qed.Ctx)
---@field when? fun(ctx: qed.Ctx): boolean
---@field key? string default chord, overridden by config `plugins.<id>.keybinds[keybind]`; a bare key (`"x"`) is allowed outside the editor scope and fires only in a pane without fields
---@field bind_from? string without `key`: take the bind of this core command (e.g. `"Copy"`), re-read at every rebind so it follows that command's config
---@field scope? string `"editor"` (default), a core pane's scope (`"log"`, `"plugins"`) or a `qed.ui.open{scope}` (the file tree's is `"filetree"`): the command runs on its chord while a pane of that scope has focus and is listed in that pane's Ctrl+P
---@field welcome? boolean also offered on the welcome screen (no buffer)
---@field keybind? string the key in `plugins.<id>.keybinds`, default `name`; commands sharing it share the bind and the first `key` among them

---@class qed.Meta
---@field display_name? string shown wherever the plugin is named (palette prefix, message and log labels, Plugins pane); default the id title-cased (`my_tools` is "My Tools")

---@class qed.Stat
---@field size integer
---@field mtime number unix seconds
---@field type "file"|"dir"|"link"|"other"

---@alias qed.Level "debug"|"info"|"warn"|"error"

qed = {}

---@type string
qed.version = ""

---Writes `text` to the Message Log (Alt+L) under this plugin's display name; never shown on the status line. Raises on an unknown level.
---@param level qed.Level
---@param text any
function qed.log(level, text) end

---Shows `text` on the message line as `<display name>: text`. Raises on an unknown level or option.
---@param text any
---@param opts? qed.Level|{level?: qed.Level}
function qed.message(text, opts) end

---@class qed.CommandHandle
---@field id integer
local CommandHandle = {}
---Unregisters the command. Returns false if it is already gone.
---@return boolean
function CommandHandle:remove() end

---Registers `<display name>: <name>`. A visible name may be registered once per scope (one editor and one file tree command); taken names and bare names equal to a core command of that scope raise.
---@param spec qed.CommandSpec
---@return qed.CommandHandle
function qed.command(spec) end

---Run a builtin or plugin command by its visible name (`"Git: Set Diff Base"`). A bare name also resolves to the caller's own editor command (bare names never equal a core command).
---@param name string
---@return boolean ran
function qed.run(name) end

---The live shortcut of a core or plugin editor command by visible name (`""` when unbound), `nil` for an unknown name.
---@param name string
---@return string|nil
function qed.shortcut(name) end

---Every change to `b` while `fn` runs is one undo step; an error inside `fn` rolls it back.
---Returns false without calling `fn` if `opts.rev` is stale.
---@param b qed.Buf
---@param fn fun()
---@param opts? {rev?: integer}
---@return boolean
function qed.edit(b, fn, opts) end

---Open (or switch to) a file. Relative paths resolve against `qed.root()`.
---@param path string
---@return integer|nil b
---@return string|nil err
function qed.open(path) end

---Save through the full pipeline. Fails without saving if the file changed on disk
---(the conflict dialog opens only for the current buffer). Waits for `buf_pre_save` handlers.
---@param b qed.Buf
---@return boolean|nil ok
---@return string|nil err "no file name" or "changed on disk"
function qed.save(b) end

---Close a buffer. Returns false and keeps it open if it has unsaved changes, unless its id is in `discard` (approved, e.g. by a confirm).
---@param b qed.Buf
---@param opts? {discard?: integer[]}
---@return boolean
function qed.close(b, opts) end

---Switch to buffer `target` or open the path `target` (relative to `qed.root()`), move the cursor to `pos` (clamped, a col inside a UTF-8 sequence snaps back), and record the jump from where you were. Closes the file tree if it is open.
---@param target qed.Buf|string
---@param pos qed.Pos
---@return nil
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
---@field bufs integer[] the unsaved ones' ids

---Switches the working root to the directory `path` (relative to `qed.root()`): closes every buffer outside it, restarts the language servers, drops saved pane selections and expanded dirs and fires `root_changed`. A no-op on the current root. While an unsaved buffer outside it is not in `discard`, closes nothing and returns `nil, "unsaved", info`; ask, then call again with `{discard = info.bufs}`.
---@param path string
---@param opts? {discard?: integer[]} unsaved buffer ids that may be closed
---@return true|nil ok
---@return "unsaved"|string|nil err `"unsaved"`, or "not a directory: <path>"
---@return qed.Unsaved|nil info with `"unsaved"`
function qed.set_root(path, opts) end

---Declares this plugin's config keys and defaults; returns the merged config (`plugins.<id>` over `defaults`; `enabled` and `keybinds` are reserved). Setup only, once per load.
---@generic T: table
---@param defaults T
---@return T
function qed.options(defaults) end

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
---@param s string
---@return string
function qed.shell_quote(s) end

---Parses compiler/grep output (`file:row:col: msg`, `file:row:col`, `file:row: msg`, `file:row`) into `qed.pick` items with a root-relative `label`, an absolute `path` and the parsed `pos`.
---Lines naming a missing file are skipped; `{}` when nothing parses. `cwd` resolves relative files, default `qed.root()`.
---@param text string
---@param opts? {cwd?: string}
---@return {label: string, path: string, pos: qed.Pos}[]
function qed.parse_locations(text, opts) end

---@alias qed.Event "startup"|"buf_open"|"buf_close"|"buf_enter"|"buf_pre_save"|"buf_save"|"buf_reload"|"buf_changed"|"cursor_moved"|"language_changed"|"root_changed"|"config_changed"|"theme_changed"|"term_open"|"term_exit"|"term_close"|"quit"

---@class qed.Handle
---@field id integer
local Handle = {}
---Unregisters the handler. A no-op if it is already gone.
function Handle:off() end

---Handlers run as coroutines in plugin load order. `buf_changed(b, rev)` and
---`cursor_moved(b)` fire at most once per main-loop iteration. Save waits for
---`buf_pre_save(b)` handlers and quit for `quit` handlers, up to `plugin_hook_timeout_ms`.
---`root_changed(old, new)`, `term_open(name)`, `term_exit(name, code)`, `term_close(name)`, `buf_close(b, path)`; other buffer events get `b`.
---@param event qed.Event
---@param fn function
---@return qed.Handle
function qed.on(event, fn) end

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

---Waits for the process to exit.
---@param spec qed.SpawnSpec
---@return qed.SpawnResult
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

---Runs in the background; killed when the plugin unloads and on quit.
---@param spec qed.SpawnSpec
---@return qed.Proc
function qed.spawn_bg(spec) end

---Waits `ms` milliseconds.
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
---@field pos? qed.Pos preview focus row
---@field key? string identity for `View:update`, `View:marks` and for restoring the selection by `id` (default `label`; a walk item's is its path)
---@field cells? string[] one string per `list.columns` entry
---@field dir? boolean walk items: a directory
---@field depth? integer walk items: tree depth (0 at the root)

---@alias qed.PaneLine string|{text: string, color?: string} color is a theme color key, e.g. `"error_foreground"`

---@class qed.UiField
---@field prompt? string prefix, default `"> "`
---@field text? string initial text, fully selected unless `mode` is input or path; without it a pane with an `id` restores the last text
---@field mode? "filter"|"query"|"input"|"path" filter (default) fuzzy-filters the list per key; query fires `on.query` at open and 120 ms after typing stops; input submits its text on Enter; path drives a `qed.fs.dirs` list (Tab or `/` at the end drills into the highlighted dir, Backspace after `/` drops a segment) and submits on Enter, its text reported as an absolute path (`~` and relative to `qed.root()` resolved)
---@field count? boolean shows the match count (`N+` past `list.max` or after `set{more}`) at the end of the row
---@field hint? string dim placeholder while the field is empty
---@field esc_clears? boolean Esc clears the non-empty field instead of closing the pane

---A core-owned item source (`qed.fs.dirs`, `qed.buf.line_list`, `qed.fs.walk`). Items live in core and are built only when drawn; only activated or changed ones reach Lua, as `{label, path?, detail?, buf?, pos?, dir?, depth?}` tables. Freed when collected or when its plugin unloads (a handle passed to another plugin dies with its owner); an open view keeps its own copy.
---@class qed.List
---@field id integer
local List = {}
---Walk handles: the number of items, or `nil, "pending"` while `ready()` is false (it starts the background walk; a `within` handle is always ready).
---@return integer|nil
---@return "pending"|nil err
function List:count() end
---Walk handles: replaces the ignore set of every walk of this root (paths hidden unless `ignored`); a change reruns them. `false` marks it not known yet: no background walk runs and `View:expand(true)` refuses until a list arrives.
---@param paths string[]|false
function List:ignore(paths) end
---Walk handles: false while the walk (or its background prewarm) is still running.
---@return boolean
function List:ready() end
---Walk handles: a new handle keeping only `paths`, their ancestors and everything under a listed dir. Listed paths ignore the dotfiles and ignored rules. Raises on an already narrowed handle.
---@param paths string[]
---@return qed.List
function List:within(paths) end
---Walk handles: a new handle that also lists `paths` (and their missing parent dirs) when they are not on disk, e.g. deleted files. It shares the narrowed handle's paths instead of copying them.
---@param paths string[]
---@return qed.List
function List:union(paths) end
---Walk handles: frees the handle now instead of at collection; a view keeps its own copy.
function List:release() end

---@class qed.UiList
---@field items? (string|qed.UiItem)[]|qed.List
---@field multi? boolean Shift+Up/Down selects a range
---@field max? integer items past it are dropped and the count shows `N+`
---@field empty? string dim hint while the list is empty
---@field selected? integer item index to start on
---@field sort? boolean keep the items ordered by key: `append` inserts in place and the selection follows its item once the user moved it
---@field tree? boolean a `qed.fs.walk` list shown as a tree: indent, expand icons, Enter or double-click on a dir toggles it (a filter shows ranked paths; Enter on a dir clears it and reveals the dir); open buffers get an accent, unsaved ones `●`
---@field columns? {width?: integer, right?: boolean}[] items draw their `cells` in these columns (width 0 takes the rest)

---@class qed.UiHandlers
---@field activate? fun(v: qed.View, items: (string|qed.UiItem)[]) Enter or double-click: the selection (the range with `multi`), `{}` for a pane without a list; the pane stays open
---@field change? fun(v: qed.View, item: string|qed.UiItem) the highlighted item changed (not at open, also after `View:set`); a newer change kills the previous run
---@field query? fun(v: qed.View, text: string) the query field settled; a newer query and the close kill the previous run and the `qed.spawn` it waits on (`qed.spawn_bg` processes stay the plugin's to kill)
---@field close? fun(v: qed.View) any close: Esc, click outside, the opening command's chord, `View:close`, a parent closing, an exclusive pane replacing it
---@field link? fun(v: qed.View, target: string) a click on a link in a `markdown` body: the raw destination (URL, relative path, `path#anchor`); `#anchor` links come here too when this handler is set (call `View:anchor`), else core scrolls them
---@field tab? fun(v: qed.View, i: integer) the user switched tabs (Left/Right, a click or a tab's chord)
---@field expand? fun(v: qed.View, item: qed.UiItem, open: boolean) the user expanded or collapsed a dir of a tree list
---@field submit? fun(v: qed.View, text: string|nil) the footer input (`View:footer{input}`) was submitted, or cancelled with Esc (`nil`)

---@class qed.UiSpec
---@field id? string the fields' text, the selected item's key and the text body's scroll persist under it across opens (and plugin reloads); a field given a non-empty `text` skips restoring the selection
---@field modal? boolean exclusive opens are refused as busy while it is open (`qed.pick/prompt/confirm` set it); a non-modal pane is replaced and its waiters get `nil`
---@field place? "center"|"full"|"split" center (default) is a centered box, full fills the screen, split puts a full-height preview column beside the fields and list
---@field size? "palette"|"dialog"|"split:code"|"split:tree" center: palette (default, fixed width) or dialog (fits the content); split: split:code (default) or split:tree (the `filetree_list_*` widths)
---@field tabs? (string|{label: string, cmd?: string})[] a tab row over both columns; Left/Right and clicks switch, a tab's `cmd` (visible command name) chord switches to it and on the active tab closes the pane
---@field tab? integer the tab to start on
---@field kind? "exclusive"|"child" exclusive (default) closes the open exclusive pane; child stacks on what has focus (a pane or a core overlay), else opens exclusive; outside a user's command it stacks only on the plugin's own pane, else returns busy
---@field parent? qed.View stack on this view (usually `ctx.view`): Esc returns to it, closing it closes this one
---@field focus? boolean false opens a passive pane: drawn under focused panes, never takes input
---@field title? string
---@field fields? qed.UiField[] Tab cycles them
---@field list? qed.UiList
---@field preview? "auto"|false split: previews the selected item's `path` at `pos.row`
---@field text? qed.PaneLine[] lines above the list (center) or the scrollable body (full or split without a list)
---@field markdown? string full only, without list or text: the body is this markdown, rendered by core at the pane width (the LSP hover renderer); arrows, PgUp/PgDn, Home/End and the wheel scroll it
---@field toggle? string|false visible name of the command whose chord closes the pane (default: the command that opened it); needed when opening from a handler; `false`: no chord closes it (tabs' chords still do)
---@field jump_closes? boolean `qed.jump` closes the pane (a hub like the file tree, left once a child picker jumps)
---@field backdrop? "none"|"dim"|"blank" what happens to everything drawn under the pane (the editor and panes below, never the status rows): left alone (default), faded (theme tint `pane_backdrop`) or cleared to the background
---@field max_width? integer center or full: the box is at most this many columns wide, borders included, and stays centered (e.g. from the plugin's own option)
---@field footer? {hints?: {label: string, cmd?: string}[], chips?: {label: string, cmd: string, on?: boolean}[]} bottom row; a hint or chip with `cmd` (visible command name) is prefixed with that command's live shortcut; chips are right-aligned, lit when `on`, and a click runs `cmd`
---@field scope? string commands registered with this `scope` run on their chord while the pane has focus (with `ctx.view`), and Ctrl+P opens a palette of just them
---@field on? qed.UiHandlers handlers run as tasks after input dispatch, before the next frame

---@class qed.View
---@field id integer
local View = {}
---Replaces the items, or swaps in a list handle (then `selected` is an item key, a path for a walk). `selected` is the item index to highlight (default 1, or the item restored by `id`), `more` shows the count as `N+`, `hint` replaces `list.empty` while the list is empty. Returns false once closed.
---@param items (string|qed.UiItem)[]|qed.List
---@param opts? {selected?: integer|string, more?: boolean, hint?: string}
---@return boolean
function View:set(items, opts) end
---Adds items at the end and keeps the selection. Returns false once closed. Raises on a list backed by a `qed.List` (replace it with `View:set`).
---@param items (string|qed.UiItem)[]
---@return boolean
function View:append(items) end
---Merges `fields` into the item whose key is `key` (a string item becomes `{label = s}` first). Returns false if closed or not found. Raises on a list backed by a `qed.List`.
---@param key string
---@param fields qed.UiItem
---@return boolean
function View:update(key, fields) end
---Replaces the text lines. Returns false once closed.
---@param lines qed.PaneLine[]
---@return boolean
function View:text(lines) end
---Replaces the markdown body, keeping the scroll position. Raises for a view opened without `markdown`; returns false once closed.
---@param text string
---@return boolean
function View:markdown(text) end
---Scrolls a markdown body to the heading with this GitHub slug. Returns whether it found one.
---@param slug string
---@return boolean
function View:anchor(slug) end
---Top row (1-based) of a text or markdown body; scrolls there first when `row` is given. Returns false once closed.
---@param row? integer
---@return integer|false
function View:scroll(row) end
---Closes the pane and its children; a no-op once closed.
function View:close() end
---Per-row styling by item key (a walk list's keys are paths, relative ones resolved against the root): `bar` (theme color of a `▌` in the left column), `fg` (theme color), `suffix` (drawn after the label), `added`/`removed` (a right-aligned `+N -N`), `dim` (dims the row and, in a tree, everything under it unless selected). `false` drops a key; `replace` clears the rest first. Validated before anything changes. Returns false once closed.
---@param marks table<string, {bar?: string, fg?: string, suffix?: string, added?: integer, removed?: integer, dim?: boolean}|false>
---`detail = false` hides every `suffix` and `added`/`removed` until `detail = true` (no marks resent); `total` sizes the store for a push split into chunks.
---@param opts? {replace?: boolean, detail?: boolean, total?: integer}
---@return boolean
function View:marks(marks, opts) end
---Replaces the footer `hints` and/or `chips` (e.g. a chip's `on`), or turns the footer into an input field (`input = {prompt?, text?}`; Enter or Esc fires `on.submit`; `input = false` drops it). Returns false once closed.
---@param spec {hints?: {label: string, cmd?: string}[], chips?: {label: string, cmd: string, on?: boolean}[], input?: {prompt?: string, text?: string}|false}
---@return boolean
function View:footer(spec) end
---The active tab; with `i`, switches to it first (no `on.tab`). Returns false once closed.
---@param i? integer
---@return integer|false
function View:tab(i) end
---`false` stops the auto preview (the plugin shows its own), `"auto"` resumes it; a table shows `path` now, diffed against `base` (raw bytes) when given, only the changed hunks unless `diff_only = false`. Returns false once closed.
---@param spec false|"auto"|{path: string, base?: string, diff_only?: boolean}
---@return boolean
function View:preview(spec) end
---Tree lists: `true`/`false` expands or collapses every dir (false while the walk's ignore set is still loading); no argument collapses every dir when a shown one is expanded, else expands all; a path and a boolean (default true) sets one dir. Returns false once closed.
---@param what? boolean|string
---@param open? boolean
---@return boolean
function View:expand(what, open) end
---Tree lists: clears the filter, expands `path`'s ancestors and selects it. Returns whether it is listed.
---@param path string
---@return boolean
function View:reveal(path) end
---The highlighted item, its row, the range's other end (`multi`) and the row count (rows are 1-based visible positions; a tree's rows follow its expanded dirs). Returns nothing once closed.
---@return qed.UiItem|string|nil item
---@return integer|nil row
---@return integer|nil anchor
---@return integer count
function View:selection() end
---Selects `row` (clamped); `anchor` makes a range (`multi`). Returns false once closed.
---@param row integer
---@param anchor? integer
---@return boolean
function View:select(row, anchor) end
---Sets (`fn`) or drops (`false`) a handler after open, e.g. `change` only while it has work to do.
---@param event "activate"|"change"|"query"|"close"|"link"|"tab"|"expand"|"submit"
---@param fn function|false
---@return boolean
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

---@class qed.PickSpec
---@field items? (string|qed.UiItem)[] required unless `on_query` is set
---@field prompt? string replaces the `>` prefix
---@field initial? integer|string item index or label to start on
---@field on_change? fun(item: string|qed.UiItem) the highlighted item changed (live preview), also after `Picker:set`
---@field multi? boolean Shift+Up/Down selects a range; returns the items in list order
---@field query? string initial query text, fully selected
---@field on_query? fun(query: string, picker: qed.Picker) the plugin supplies the items (no fuzzy filter, list + preview layout); runs at open and 120 ms after the query stops changing; the previous run is killed with its processes, and so is the last one when the picker closes

---@class qed.Picker
---@field id integer
local Picker = {}
---Replaces the items of an open `on_query` picker (`View:set`). Returns false once the picker is closed.
---@param items (string|qed.UiItem)[]
---@param opts? {selected?: integer, more?: boolean, hint?: string}
---@return boolean
function Picker:set(items, opts) end

---Waits for a fuzzy pick (a `qed.ui.open` child pane). Returns the chosen item (the value passed in), or `nil` on Esc.
---The opening command's chord closes it like Esc. Stacks on an open pane or overlay (outside a user's command only on the plugin's own pane); otherwise `nil, "busy"` only while a quit, close or conflict dialog shows.
---With `on_query`, a third value is the final query text (also on Esc), and Enter while a query is due or running waits for its `set`.
---@param spec qed.PickSpec
---@return string|qed.UiItem|(string|qed.UiItem)[]|nil
---@return "busy"|nil err
---@return string|nil query
function qed.pick(spec) end

---Waits for a line of text. `nil` on Esc. Opens over an open pane (Esc returns to it; closing that pane closes this one with `nil`).
---Returns `nil, "busy"` only while a quit, close or conflict dialog shows. While it is open, other exclusive panes are refused as busy.
---@param spec {prompt: string, text?: string}
---@return string|nil
---@return "busy"|nil err
function qed.prompt(spec) end

---Waits for a choice. Returns its 1-based index, `nil` on Esc. Opens over an open pane (Esc returns to it; closing that pane closes this one with `nil`).
---Returns `nil, "busy"` only while a quit, close or conflict dialog shows. While it is open, other exclusive panes are refused as busy.
---@param question string
---@param choices? string[] defaults to `{"Yes", "No"}`
---@return integer|nil
---@return "busy"|nil err
function qed.confirm(question, choices) end

---@class qed.Pane
---@field id integer
local Pane = {}
---Returns false once the pane is closed.
---@param lines qed.PaneLine[]
---@return boolean
function Pane:set(lines) end
---Closes the pane if it is still the one showing; otherwise a no-op.
function Pane:close() end

---Read-only exclusive `full` pane (arrows/wheel scroll, Esc closes). `nil, "busy"` like an exclusive `qed.ui.open`.
---@param spec {title: string, lines: qed.PaneLine[], footer?: string}
---@return qed.Pane|nil
---@return "busy"|nil err
function qed.pane(spec) end

---Language names as `qed.buf.language` returns them.
---@return string[]
function qed.languages() end

qed.theme = {}

---Applies a theme. With `persist`, also writes it as config `theme` (only that key); fails on an unknown name or a failed write.
---@param name string
---@param opts? {persist?: boolean}
---@return boolean|nil ok
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

qed.filetree = {}

---@class qed.ProviderSpec
---@field refresh? fun() the tree wants fresh status (opened, root changed, a tree file operation); answer with `set_status`
---@field preview? fun(path: string) the Changed tab wants a base for `path`; answer with `set_base`
---@field open_deleted? fun(ctx: qed.Ctx) runs as a file tree command on `Enter` over a listed deleted file that is missing on disk

---@class qed.FileStatus
---@field mark "added"|"modified"|"deleted"
---@field from? string the old path of a rename (shown as `new  ← old`)
---@field added? integer lines added (shown as `+N -N` on the Changed tab)
---@field removed? integer lines removed

---Claims the file tree's Changed tab. Callbacks run as queued coroutines. Calling again replaces the callbacks and keeps the status. `nil` drops it.
---@param spec qed.ProviderSpec|nil
---@return true|nil ok `nil, "taken by <plugin>"` while another plugin holds the tab
---@return string? err
function qed.filetree.provide(spec) end

---Replaces the tree's status: bars, the Changed tab, sizes, rename labels and deleted ghost rows. `ignored` paths hide unless *Toggle Ignored*.
---@param files table<string, qed.FileStatus> keyed by path (relative paths resolve against the root)
---@param ignored? string[]
function qed.filetree.set_status(files, ignored) end

---Answers the `preview(path)` callback: the Changed tab previews `path` diffed against `text` (raw bytes; binary shows a hexdump); `nil` shows it plainly. A path not asked for last is ignored.
---@param path string
---@param text string|nil
function qed.filetree.set_base(path, text) end

---TEMPORARY until the plugin communication step: the `filetree` plugin's side of the provider. `fn(kind)` runs queued when the provider comes or goes (`"provider"`), pushes status (`"status"`) or answers a preview (`"base"`). One listener; `nil, "taken by <plugin>"` while another holds it.
---@param fn fun(kind: "provider"|"status"|"base")
---@return true|nil ok
---@return string? err
function qed.filetree.listen(fn) end

---TEMPORARY: the provider's last push, paths absolute. `files`/`ignored` are nil until the first push; `base_path`/`base` are set once the last asked preview is answered (`base` nil: show the file plainly).
---@return {provider: boolean, files?: table<string, qed.FileStatus>, ignored?: string[], base_path?: string, base?: string}
function qed.filetree.state() end

---TEMPORARY: asks the provider to `refresh`, to `preview` `path` (a new ask drops the last answer) or to `open_deleted` with the current ctx. False when it has no such callback.
---@param kind "refresh"|"preview"|"open_deleted"
---@param path? string
---@return boolean
function qed.filetree.request(kind, path) end

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
---@return string|nil name
---@return "already running"|"cannot start"|nil err
function qed.term.create(spec) end

---Shows the session in the terminal pane overlay (`"shell"` starts the default shell if needed, like Alt+t). Raises during `setup`.
---@param name string
---@return boolean|nil ok
---@return "no such session"|"terminal unavailable"|nil err
function qed.term.show(name) end

---Hides the terminal pane; sessions keep running.
function qed.term.hide() end

---Kills the session's process group. Its output stays; `term_exit` fires. Raises for `"shell"`.
---@param name string
---@return boolean|nil ok
---@return "no such session"|nil err
function qed.term.kill(name) end

---Kills (without `term_exit`) and respawns with the same spec on a fresh screen. Raises for `"shell"`.
---@param name string
---@return boolean|nil ok
---@return "no such session"|"cannot start"|nil err
function qed.term.restart(name) end

---Writes raw bytes to the session's input (`"\r"` is Enter). Unread input is buffered up to 1 MiB, the rest dropped.
---@param name string
---@param text string
---@return boolean|nil ok
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
---@return boolean|nil ok
---@return "no such session"|nil err
function qed.term.close(name) end

qed.deco = {}

---A namespace owned by this plugin; the same name returns the same id. Unload clears all of them.
---@param name string
---@return integer
function qed.deco.ns(name) end

---Mark column glyph (shown where the diff base has no mark).
---@param b qed.Buf
---@param ns integer
---@param row integer
---@param glyph string one single-width character
---@param color string theme color key
function qed.deco.gutter(b, ns, row, glyph, color) end

---Line background tint, stacked over diff/conflict tints and under the AI and current-line tints.
---@param b qed.Buf
---@param ns integer
---@param from_row integer
---@param to_row integer inclusive
---@param color string theme color key
---@param alpha? number 0..1, default the theme's `decoration` tint
function qed.deco.tint(b, ns, from_row, to_row, color, alpha) end

---Virtual rows below (or above) a row, one clipped screen row each.
---@param b qed.Buf
---@param ns integer
---@param row integer
---@param lines string|string[]
---@param opts? {above?: boolean, color?: string}
function qed.deco.ghost(b, ns, row, lines, opts) end

---Style over a range; dropped when any of its rows is edited.
---@param b qed.Buf
---@param ns integer
---@param from qed.Pos
---@param to qed.Pos
---@param style {fg?: string, bg?: string, bold?: boolean, underline?: boolean}
function qed.deco.span(b, ns, from, to, style) end

---Virtual text after the end of a row, clipped to the window.
---@param b qed.Buf
---@param ns integer
---@param row integer
---@param text string
---@param color string theme color key
function qed.deco.eol(b, ns, row, text, color) end

---Removes the namespace's decorations touching rows from_row..to_row (all when omitted).
---@param b qed.Buf
---@param ns integer
---@param from_row? integer
---@param to_row? integer
function qed.deco.clear(b, ns, from_row, to_row) end

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

---Id of the current buffer, or nil on the welcome screen.
---@return integer|nil
function qed.buf.current() end

---Ids of all open buffers in tab order; empty on the welcome screen.
---@return integer[]
function qed.buf.list() end

---True if `b` is the id of an open buffer. Unlike other `qed.buf` calls it never raises, and nil or 0 is not "current" here.
---@param b integer|nil
---@return boolean
function qed.buf.valid(b) end

---The buffer's file path, or `""` for an unnamed buffer. Raises "buffer closed" for a stale id (as do all `qed.buf` calls taking `b`).
---@param b qed.Buf
---@return string
function qed.buf.path(b) end

---Language name, e.g. `"odin"`; see `qed.languages()`.
---@param b qed.Buf
---@return string
function qed.buf.language(b) end

---True if there are unsaved changes.
---@param b qed.Buf
---@return boolean
function qed.buf.modified(b) end

---Edit counter; changes on every edit, so equal values mean unchanged text. Pass it as `opts.rev` to guard stale writes.
---@param b qed.Buf
---@return integer
function qed.buf.rev(b) end

---Number of lines; an empty buffer has 1.
---@param b qed.Buf
---@return integer
function qed.buf.line_count(b) end

---Rows `from..to`, inclusive. Defaults to the whole buffer.
---@param b qed.Buf
---@param from? integer
---@param to? integer
---@return string[]
function qed.buf.lines(b, from, to) end

---Text of `row` without its newline. Raises if `row` is out of range.
---@param b qed.Buf
---@param row integer
---@return string
function qed.buf.line(b, row) end

---The whole text, lines joined with LF regardless of the file's line endings.
---@param b qed.Buf
---@return string
function qed.buf.text(b) end

---Insert `text` at `pos`. Cursor and selection shift with the edit. One undo step unless inside `qed.edit`. Raises on an out-of-range `pos` or a `col` inside a UTF-8 sequence.
---@param b qed.Buf
---@param pos qed.Pos
---@param text string valid UTF-8; CRLF and CR become LF
---@return qed.Pos end_pos
function qed.buf.insert(b, pos, text) end

---Delete the half-open range `[from, to)`.
---@param b qed.Buf
---@param from qed.Pos
---@param to qed.Pos
---@return string deleted
function qed.buf.delete(b, from, to) end

---Replace the half-open range `[from, to)` with `text`. Cursor and selection shift; one undo step unless inside `qed.edit`. Raises if `to` is before `from`.
---@param b qed.Buf
---@param from qed.Pos
---@param to qed.Pos
---@param text string
---@return qed.Pos end_pos
function qed.buf.replace(b, from, to, text) end

---Replace the whole text with a minimal line diff, so the cursor, undo and highlight
---keep their place. One undo step. Returns false without editing if `opts.rev` is stale.
---@param b qed.Buf
---@param text string
---@param opts? {rev?: integer}
---@return boolean
function qed.buf.set_text(b, text, opts) end

---The caret position.
---@param b qed.Buf
---@return qed.Pos
function qed.buf.cursor(b) end

---Move the caret to `pos`, clear the selection and scroll it into view if `b` is current.
---@param b qed.Buf
---@param pos qed.Pos
function qed.buf.set_cursor(b, pos) end

---Selection as `from, to` in document order, or nil when nothing is selected.
---@param b qed.Buf
---@return qed.Pos|nil from
---@return qed.Pos|nil to
function qed.buf.selection(b) end

---Select from `anchor` to `cursor`; the caret ends at `cursor`, so a backward selection is allowed.
---@param b qed.Buf
---@param anchor qed.Pos
---@param cursor qed.Pos
function qed.buf.set_selection(b, anchor, cursor) end

---Set the buffer's language by name and re-highlight. Raises on an unknown name; false if it was already that language.
---@param b qed.Buf
---@param name string language name as `qed.buf.language` returns it
---@return boolean changed
function qed.buf.set_language(b, name) end

---`"auto"` detects from the content. `width` defaults to the current width.
---@param b qed.Buf
---@param style "tabs"|"spaces"|"auto"
---@param width? integer
function qed.buf.set_indent(b, style, width) end

---The buffer's indent style and width.
---@param b qed.Buf
---@return "tabs"|"spaces" style
---@return integer width
function qed.buf.indent(b) end

---Diff base: drives the gutter marks, diff-view ghost rows, change navigation and revert hunk.
---Each plugin keeps its own base per buffer; the base of the plugin that first set one most recently wins,
---and clearing it with `nil` (or unloading) reveals the one beneath. Another plugin's base is never touched.
---@param b qed.Buf
---@param text string|nil raw bytes (need not be UTF-8)
---@param opts? {label?: string} label shown in the status bar: `±base` when omitted, nothing when `""`
---@return boolean active true when this plugin's base is the one shown
function qed.buf.set_base(b, text, opts) end

---A list handle over the buffer's lines. An edit, a disk reload or the buffer closing shows on the next frame: a filter is recomputed keeping the selected line (a `:N` past the end clamps), a closed buffer empties the list. Items reach Lua as `{label = line text, buf, pos = {row, col}}`, `col` the first non-blank. Under a filter field matches stay in buffer order, and an all-digit `:N` or `:N:M` selects that row (column `M`) instead of matching. A view over it opens on the match nearest the cursor.
---@param b qed.Buf
---@return qed.List
function qed.buf.line_list(b) end

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
---@return boolean|nil ok
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
---@return qed.List
function qed.fs.dirs(opts) end

---A list handle over every file and dir under `root` (default `qed.root()`): a threaded parallel walk, prewarmed in the background when a view opens over it, shared by handles with the same options, rerun after `qed.fs` writes under its root (serving the old items until the rerun lands). Dotfiles and the root's ignore set (`List:ignore`, or the file tree status provider's) are left out unless `dotfiles`/`ignored`. Items `{label, path, dir?, depth?}`. A filter field ranks paths (capped at `list.max`, default 500, narrowing the previous hits as the query grows), debounced.
---@param opts? {root?: string, dotfiles?: boolean, ignored?: boolean}
---@return qed.List
function qed.fs.walk(opts) end

---Copies a file or dir tree (modes kept, symlinks copied as links, fifos and devices skipped). Refuses an existing `dst`, a `dst` inside `src` and a special `src`; creates missing parent dirs.
---@param src string
---@param dst string
---@return boolean|nil ok
---@return "exists"|"not found"|string|nil err
function qed.fs.copy(src, dst) end

---Moves a file or dir, across filesystems too (mtimes kept), and repaths open buffers under it. Refuses an existing `dst` or a `dst` inside `src`.
---@param src string
---@param dst string
---@return boolean|nil ok
---@return "exists"|"not found"|string|nil err
function qed.fs.rename(src, dst) end

---Deletes a file or a dir tree; symlinks are removed, never followed. Refuses the root and its ancestors. Open buffers stay.
---@param path string
---@return boolean|nil ok
---@return "not found"|string|nil err
function qed.fs.remove(path) end

---Creates a dir and its missing parents. Refuses an existing path.
---@param path string
---@return boolean|nil ok
---@return "exists"|string|nil err
function qed.fs.mkdir(path) end

qed.json = {}

---Parses JSON into Lua values, or `nil, err` on invalid input. Whole numbers decode as integers.
---@param s string
---@return any
---@return string|nil err
function qed.json.decode(s) end

---Serializes a Lua value to compact JSON. Raises on functions, userdata, NaN or infinity, non-string/integer keys and over-deep nesting.
---@param v any
---@return string
function qed.json.encode(v) end

qed.path = {}

---Joins and cleans the parts with `/`.
---@param ... string
---@return string
function qed.path.join(...) end

---Everything before the last path element, as in `dirname`.
---@param p string
---@return string
function qed.path.dir(p) end

---The last path element, as in `basename`.
---@param p string
---@return string
function qed.path.base(p) end

---`p` relative to `base`, or `nil, err` when no relative path exists. Both are made absolute against `qed.root()` first; the result may start with `..` when `p` is not under `base`.
---@param p string
---@param base? string defaults to `qed.root()`
---@return string|nil
---@return string|nil err
function qed.path.rel(p, base) end

---Absolute, cleaned form; relative paths resolve against `qed.root()`. Symlinks are not resolved and the path need not exist.
---@param p string
---@return string
function qed.path.abs(p) end

qed.lsp = {}

---Waits for the language server to format `b` and applies the edits as one undo step.
---Fails with "disabled" (LSP module off), "no server", "unavailable" (not ready or no
---formatting support), "stale" (buffer changed meanwhile) or "error" (already logged).
---@param b qed.Buf
---@return boolean ok
---@return "disabled"|"no server"|"unavailable"|"stale"|"error"|nil err
function qed.lsp.format(b) end

qed.text = {}

---Display width in terminal columns, grapheme-aware: wide characters count 2, combining marks 0, tabs advance to the next tab stop.
---@param s string
---@return integer
function qed.text.width(s) end

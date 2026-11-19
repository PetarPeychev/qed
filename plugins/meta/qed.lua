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
---@field file string|nil file tree only: the entry under the cursor (absolute)
---@field files string[]|nil file tree only: every selected path, in tree order; on a scoped tab (Open, Changed, Unsaved) a selected dir stands for its in-scope files

---@class qed.CommandSpec
---@field name string bare name; the palette shows `<display name>: <name>`
---@field run fun(ctx: qed.Ctx)
---@field when? fun(ctx: qed.Ctx): boolean
---@field key? string default chord, overridden by config `plugins.<id>.keybinds[keybind]`
---@field scope? "editor"|"filetree"
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

---Close a buffer. Returns false and keeps it open if it has unsaved changes.
---@param b qed.Buf
---@return boolean
function qed.close(b) end

---Switch to buffer `target` or open the path `target` (relative to `qed.root()`), move the cursor to `pos` (clamped, a col inside a UTF-8 sequence snaps back), and record the jump from where you were. Closes the file tree if it is open.
---@param target qed.Buf|string
---@param pos qed.Pos
---@return nil
---@return string|nil err "cannot open <path>" when a path fails to open
function qed.jump(target, pos) end

---The working root: the directory qed was started in or last switched to. Relative paths in `qed.*` resolve against it.
---@return string
function qed.root() end

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

---@class qed.PickItem
---@field label? string defaults to `path`
---@field detail? string shown dim, right-aligned
---@field value? any carried through untouched
---@field path? string any item with a path switches to the list + file preview layout
---@field pos? qed.Pos preview focus row

---@class qed.PickSpec
---@field items? (string|qed.PickItem)[] required unless `on_query` is set
---@field prompt? string replaces the `>` prefix
---@field initial? integer|string item index or label to start on
---@field on_change? fun(item: string|qed.PickItem) the highlighted item changed (live preview), also after `Picker:set`
---@field multi? boolean Shift+Up/Down selects a range; returns the items in list order
---@field query? string initial query text, fully selected
---@field on_query? fun(query: string, picker: qed.Picker) the plugin supplies the items (no fuzzy filter, list + preview layout); runs at open and 120 ms after the query stops changing; the previous run is killed with the process it waits on, and so is the last one when the picker closes

---@class qed.Picker
---@field id integer
local Picker = {}
---Replaces the items of an open `on_query` picker. `selected` is the item index to highlight (default 1), `more` shows the count as `N+`, `hint` is dim text shown while `items` is empty. Returns false once the picker is closed.
---@param items (string|qed.PickItem)[]
---@param opts? {selected?: integer, more?: boolean, hint?: string}
---@return boolean
function Picker:set(items, opts) end

---Waits for a fuzzy pick. Returns the chosen item (the value passed in), or `nil` on Esc.
---The opening command's chord closes it like Esc. Returns `nil, "busy"` while another pane or overlay is open (the file tree excepted).
---With `on_query`, a third value is the final query text (also on Esc), and Enter while a query is due or running waits for its `set`.
---@param spec qed.PickSpec
---@return string|qed.PickItem|(string|qed.PickItem)[]|nil
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

---@alias qed.PaneLine string|{text: string, color?: string} color is a theme color key, e.g. `"error_foreground"`

---@class qed.Pane
---@field id integer
local Pane = {}
---Returns false once the pane is closed.
---@param lines qed.PaneLine[]
---@return boolean
function Pane:set(lines) end
---Closes the pane if it is still the one showing; otherwise a no-op.
function Pane:close() end

---Read-only floating pane (arrows/wheel scroll, Esc closes). `nil, "busy"` while another pane or overlay is open.
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

---Answers the `preview(path)` callback: the Changed tab previews `path` diffed against `text` (raw bytes; binary shows a hexdump); `nil` shows it plainly.
---@param path string
---@param text string|nil
function qed.filetree.set_base(path, text) end

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

qed.fs = {}

---File contents, or `nil, err` (missing, unreadable). Relative paths resolve against `qed.root()`.
---@param path string
---@return string|nil data
---@return string|nil err
function qed.fs.read(path) end

---Atomic: writes a temp file in the same dir, then renames.
---@param path string
---@param data string
---@return boolean|nil ok
---@return string|nil err
function qed.fs.write(path, data) end

---True if the path exists (file, dir or other). Relative paths resolve against `qed.root()`.
---@param path string
---@return boolean
function qed.fs.exists(path) end

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

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
---@field files string[]|nil file tree only: every selected path, in tree order
---@field base {ref: string, label: string, merge: boolean} diff base (`ref` "HEAD" when unset; `merge` means the merge base of `ref` and HEAD)

---@class qed.CommandSpec
---@field name string
---@field run fun(ctx: qed.Ctx)
---@field when? fun(ctx: qed.Ctx): boolean
---@field key? string default chord, overridden by config `keybinds[name]`
---@field scope? "editor"|"filetree"
---@field welcome? boolean also offered on the welcome screen (no buffer)

---@class qed.Stat
---@field size integer
---@field mtime number unix seconds
---@field type "file"|"dir"|"link"|"other"

---@alias qed.Level "debug"|"info"|"warn"|"error"

qed = {}

---@type string
qed.version = ""

---@param level qed.Level
---@param text any
function qed.log(level, text) end

---Shows `text` on the message line, attributed to this plugin unless `opts.source` says otherwise (`""` is bare).
---@param text any
---@param opts? qed.Level|{level?: qed.Level, source?: string}
function qed.message(text, opts) end

---@class qed.CommandHandle
---@field id integer
local CommandHandle = {}
---Unregisters the command. Returns false if it is already gone.
---@return boolean
function CommandHandle:remove() end

---A name may be registered once per scope; builtin names are refused.
---@param spec qed.CommandSpec
---@return qed.CommandHandle
function qed.command(spec) end

---Run a builtin or plugin command by name.
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

---Switch to `b`, move the cursor to `pos`, and record the jump. Closes the file tree if it is open.
---@param b qed.Buf
---@param pos qed.Pos
function qed.jump(b, pos) end

---@return string
function qed.root() end

---This plugin's merged config (a fresh copy each call).
---@return table
function qed.config() end

---Read-only core knob, e.g. `"tab_width"`, `"theme"`, `"modules.lsp.completion_max_rows"`.
---@param key string
---@return integer|boolean|string
function qed.opt(key) end

---@param s string
---@return string
function qed.shell_quote(s) end

---@alias qed.Event "startup"|"buf_open"|"buf_close"|"buf_enter"|"buf_pre_save"|"buf_save"|"buf_reload"|"buf_changed"|"cursor_moved"|"language_changed"|"root_changed"|"config_changed"|"theme_changed"|"term_exit"|"quit"

---@class qed.Handle
---@field id integer
local Handle = {}
function Handle:off() end

---Handlers run as coroutines in plugin load order. `buf_changed(b, rev)` and
---`cursor_moved(b)` fire at most once per main-loop iteration. Save waits for
---`buf_pre_save(b)` handlers and quit for `quit` handlers, up to `plugin_hook_timeout_ms`.
---`root_changed(old, new)`, `term_exit(name, code)`, `buf_close(b, path)`; other buffer events get `b`.
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
---@field items (string|qed.PickItem)[]
---@field prompt? string replaces the `>` prefix
---@field initial? integer|string item index or label to start on
---@field on_change? fun(item: string|qed.PickItem) the highlighted item changed (live preview)
---@field multi? boolean Shift+Up/Down selects a range; returns the items in list order

---Waits for a fuzzy pick. Returns the chosen item (the value passed in), or `nil` on Esc.
---Returns `nil, "busy"` when another overlay is open.
---@param spec qed.PickSpec
---@return string|qed.PickItem|(string|qed.PickItem)[]|nil
---@return "busy"|nil err
function qed.pick(spec) end

---Waits for a line of text. `nil` on Esc, `nil, "busy"` when another overlay is open.
---@param spec {prompt: string, text?: string}
---@return string|nil
---@return "busy"|nil err
function qed.prompt(spec) end

---Waits for a choice. Returns its 1-based index, `nil` on Esc, `nil, "busy"` when another overlay is open.
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
function Pane:close() end

---Read-only floating pane (arrows/wheel scroll, Esc closes). `nil, "busy"` when another overlay is open.
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

qed.clipboard = {}

---@return string
function qed.clipboard.get() end

---@param text string
function qed.clipboard.set(text) end

qed.buf = {}

---@return integer|nil
function qed.buf.current() end

---@return integer[]
function qed.buf.list() end

---@param b integer|nil
---@return boolean
function qed.buf.valid(b) end

---@param b qed.Buf
---@return string
function qed.buf.path(b) end

---@param b qed.Buf
---@return string
function qed.buf.language(b) end

---@param b qed.Buf
---@return boolean
function qed.buf.modified(b) end

---@param b qed.Buf
---@return integer
function qed.buf.rev(b) end

---@param b qed.Buf
---@return integer
function qed.buf.line_count(b) end

---Rows `from..to`, inclusive. Defaults to the whole buffer.
---@param b qed.Buf
---@param from? integer
---@param to? integer
---@return string[]
function qed.buf.lines(b, from, to) end

---@param b qed.Buf
---@param row integer
---@return string
function qed.buf.line(b, row) end

---@param b qed.Buf
---@return string
function qed.buf.text(b) end

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

---@param b qed.Buf
---@return qed.Pos
function qed.buf.cursor(b) end

---@param b qed.Buf
---@param pos qed.Pos
function qed.buf.set_cursor(b, pos) end

---@param b qed.Buf
---@return qed.Pos|nil from
---@return qed.Pos|nil to
function qed.buf.selection(b) end

---@param b qed.Buf
---@param anchor qed.Pos
---@param cursor qed.Pos
function qed.buf.set_selection(b, anchor, cursor) end

---@param b qed.Buf
---@param name string language name as `qed.buf.language` returns it
---@return boolean changed
function qed.buf.set_language(b, name) end

---`"auto"` detects from the content. `width` defaults to the current width.
---@param b qed.Buf
---@param style "tabs"|"spaces"|"auto"
---@param width? integer
function qed.buf.set_indent(b, style, width) end

---@param b qed.Buf
---@return "tabs"|"spaces" style
---@return integer width
function qed.buf.indent(b) end

qed.fs = {}

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

---@param path string
---@return boolean
function qed.fs.exists(path) end

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

---@param s string
---@return any
---@return string|nil err
function qed.json.decode(s) end

---@param v any
---@return string
function qed.json.encode(v) end

qed.path = {}

---@param ... string
---@return string
function qed.path.join(...) end

---@param p string
---@return string
function qed.path.dir(p) end

---@param p string
---@return string
function qed.path.base(p) end

---@param p string
---@param base? string defaults to `qed.root()`
---@return string|nil
---@return string|nil err
function qed.path.rel(p, base) end

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

---@param s string
---@return integer
function qed.text.width(s) end

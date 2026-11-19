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

---@class qed.CommandSpec
---@field name string
---@field run fun(ctx: qed.Ctx)
---@field when? fun(ctx: qed.Ctx): boolean
---@field key? string default chord, overridden by config `keybinds[name]`
---@field scope? "editor"|"filetree"

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

---@param text any
---@param level? qed.Level
function qed.message(text, level) end

---@param spec qed.CommandSpec
function qed.command(spec) end

---Run a builtin or plugin command by name.
---@param name string
---@return boolean ran
function qed.run(name) end

---Everything `fn` does to `b` is one undo step; an error inside `fn` rolls it back.
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

---@param b qed.Buf
function qed.save(b) end

---Close a buffer. Returns false and keeps it open if it has unsaved changes.
---@param b qed.Buf
---@return boolean
function qed.close(b) end

---Switch to `b`, move the cursor to `pos`, and record the jump.
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
---@param text string
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
function qed.buf.set_language(b, name) end

---@param b qed.Buf
---@param style "tabs"|"spaces"
---@param width? integer
function qed.buf.set_indent(b, style, width) end

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

qed.text = {}

---@param s string
---@return integer
function qed.text.width(s) end

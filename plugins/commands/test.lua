local T = {}

local function message_is(t, text)
	return function() return (t.message()) == text end
end

local function expect_message(t, text, level, source)
	t.wait(message_is(t, text))
	local _, lvl, src = t.message()
	t.eq(lvl, level or "info", "message level")
	if source then
		t.eq(src, source, "message source")
	end
end

local function idle(t)
	qed.message("idle", {source = ""})
end

local function clipboard_is(text)
	return function() return qed.clipboard.get() == text end
end

local function one(t, spec)
	t.config{list = {spec}}
end

local function chord_runs(t)
	idle(t)
	t.key("Alt+j")
	return (pcall(t.wait, message_is(t, "ran"), 300))
end

function T.message_first_line(t)
	t.open("a.txt", "x")
	one(t, {name = "Hello", run = "echo hi there; echo second"})
	qed.run("Hello")
	expect_message(t, "hi there", "info", "Hello")
end

function T.message_done_without_output(t)
	one(t, {name = "Quiet", run = "true"})
	qed.run("Quiet")
	expect_message(t, "done", "info", "Quiet")
end

function T.message_failure_uses_stderr(t)
	one(t, {name = "Boom", run = "echo out; echo boom >&2; exit 3"})
	qed.run("Boom")
	expect_message(t, "failed (exit 3): boom", "error", "Boom")
end

function T.message_failure_falls_back_to_stdout(t)
	one(t, {name = "Boom", run = "echo only-out; exit 1"})
	qed.run("Boom")
	expect_message(t, "failed (exit 1): only-out", "error")
end

function T.missing_tool(t)
	one(t, {name = "Missing", run = "qed_no_such_tool_zzz"})
	qed.run("Missing")
	t.wait(function() return (t.message()):match("^failed %(exit 127%)") ~= nil end)
end

function T.placeholders_are_quoted(t)
	local b = t.open("sub dir/it's a.txt", "say \"it's\" now\nbaz qux")
	local path = qed.buf.path(b)
	qed.buf.set_selection(b, {row = 1, col = 5}, {row = 1, col = 11})
	one(t, {name = "Args", output = "clipboard", run = "printf '%s|' {file} {dir} {root} {name} {stem} {ext} {line} {col} {selection} {files} {base} {unknown}"})
	qed.run("Args")
	local want = table.concat({path, qed.path.dir(path), qed.root(), "it's a.txt", "it's a", "txt", "1", "11", "\"it's\"", path, "HEAD", "{unknown}"}, "|") .. "|"
	t.wait(clipboard_is(want))
	expect_message(t, "copied output", "info", "Args")
end

function T.word_placeholder(t)
	local b = t.open("w.txt", "baz qux_1 end")
	qed.buf.set_cursor(b, {row = 1, col = 6})
	one(t, {name = "Word", output = "clipboard", run = "printf '%s' {word}"})
	qed.run("Word")
	t.wait(clipboard_is("qux_1"))
end

function T.stem_and_ext_edge_cases(t)
	t.open(".bashrc", "x")
	one(t, {name = "Name", output = "clipboard", run = "printf '%s|' {name} {stem} {ext}"})
	qed.run("Name")
	t.wait(clipboard_is(".bashrc|.bashrc||"))
end

function T.env_vars(t)
	local b = t.open("e f.txt", "one\ntwo")
	qed.buf.set_cursor(b, {row = 2, col = 3})
	one(t, {name = "Env", output = "clipboard", env = {MINE = "{name} raw"}, run = "printf '%s|' \"$QED_FILE\" \"$QED_LINE\" \"$QED_COL\" \"$QED_NAME\" \"$QED_ROOT\" \"$QED_WORD\" \"$QED_BASE\" \"$MINE\""})
	qed.run("Env")
	t.wait(clipboard_is(table.concat({qed.buf.path(b), "2", "3", "e f.txt", qed.root(), "two", "HEAD", "e f.txt raw"}, "|") .. "|"))
end

function T.cwd_default_and_placeholder(t)
	t.open("deep/x.txt", "x")
	one(t, {name = "Pwd", run = "pwd"})
	qed.run("Pwd")
	expect_message(t, qed.root())
	one(t, {name = "Pwd", run = "pwd", cwd = "{dir}"})
	qed.run("Pwd")
	expect_message(t, qed.path.join(qed.root(), "deep"))
end

local function clip_run(t, name, want)
	qed.clipboard.set("stale")
	qed.run(name)
	t.wait(clipboard_is(want))
end

function T.stdin_modes(t)
	local b = t.open("in.txt", "alpha\nbeta")
	one(t, {name = "Cat", output = "clipboard", run = "cat"})
	clip_run(t, "Cat", "")
	one(t, {name = "Cat", output = "clipboard", stdin = "buffer", run = "cat"})
	clip_run(t, "Cat", "alpha\nbeta")
	qed.buf.set_selection(b, {row = 1, col = 2}, {row = 2, col = 3})
	one(t, {name = "Cat", output = "clipboard", stdin = "selection", run = "cat"})
	clip_run(t, "Cat", "lpha\nbe")
	one(t, {name = "Cat", output = "clipboard", stdin = "selection-or-buffer", run = "cat; echo"})
	clip_run(t, "Cat", "lpha\nbe")
	qed.buf.set_cursor(b, {row = 1, col = 1})
	clip_run(t, "Cat", "alpha\nbeta")
	one(t, {name = "Cat", output = "clipboard", stdin = "selection", run = "cat"})
	clip_run(t, "Cat", "")
end

function T.replace_buffer(t)
	local b = t.open("s.txt", "c\na\nb\n")
	one(t, {name = "Sort", output = "replace", stdin = "buffer", run = "sort"})
	qed.run("Sort")
	expect_message(t, "done", "info", "Sort")
	t.eq(qed.buf.text(b), "a\nb\nc\n")
	t.key("Ctrl+z")
	t.eq(qed.buf.text(b), "c\na\nb\n", "one undo step restores the buffer")
end

function T.replace_buffer_without_final_newline(t)
	local b = t.open("s.txt", "c\na\nb")
	one(t, {name = "Sort", output = "replace", stdin = "buffer", save = "none", run = "sort"})
	qed.run("Sort")
	expect_message(t, "done")
	t.eq(qed.buf.text(b), "a\nb\nc", "the tool's added newline is dropped")
end

function T.replace_selection(t)
	local b = t.open("s.txt", "x\nc\na\nb\ny")
	qed.buf.set_selection(b, {row = 2, col = 1}, {row = 4, col = 2})
	one(t, {name = "Sort", output = "replace", stdin = "selection", run = "sort"})
	qed.run("Sort")
	expect_message(t, "done")
	t.eq(qed.buf.text(b), "x\na\nb\nc\ny")
	local from, to = qed.buf.selection(b)
	t.eq(from.row, 2, "selection keeps the replaced range")
	t.eq(to.row, 4)
	t.eq(to.col, 2)
	t.key("Ctrl+z")
	t.eq(qed.buf.text(b), "x\nc\na\nb\ny", "one undo step")
end

function T.replace_failure_leaves_buffer(t)
	local b = t.open("s.txt", "keep")
	one(t, {name = "Bad", output = "replace", stdin = "buffer", run = "echo partial; echo nope >&2; exit 2"})
	qed.run("Bad")
	expect_message(t, "failed (exit 2): nope", "error")
	t.eq(qed.buf.text(b), "keep")
	t.ok(not qed.buf.modified(b), "untouched")
end

function T.replace_rev_guard(t)
	local b = t.open("s.txt", "messy")
	t.fake_spawn("fakesort", {stdout = "TIDY", delay_ms = 50})
	one(t, {name = "Sort", output = "replace", stdin = "buffer", run = "fakesort"})
	qed.run("Sort")
	t.type("!")
	expect_message(t, "skipped: buffer changed", "warn")
	t.eq(qed.buf.text(b), "!messy")
end

function T.insert_at_cursor(t)
	local b = t.open("i.txt", "ab")
	qed.buf.set_cursor(b, {row = 1, col = 2})
	one(t, {name = "Ins", output = "insert", run = "printf 'X\\nY\\n'"})
	qed.run("Ins")
	expect_message(t, "done")
	t.eq(qed.buf.text(b), "aX\nYb")
	local c = qed.buf.cursor(b)
	t.eq(c.row, 2, "cursor after the insert")
	t.eq(c.col, 2)
	t.key("Ctrl+z")
	t.eq(qed.buf.text(b), "ab")
end

function T.save_current_default(t)
	local b = t.open("s.txt", "old")
	t.type("new ")
	one(t, {name = "Show", run = "cat {file}"})
	qed.run("Show")
	expect_message(t, "new old")
	t.ok(not qed.buf.modified(b), "saved before running")
end

function T.save_defaults_to_none_for_edit_outputs(t)
	local b = t.open("s.txt", "old")
	t.type("new ")
	one(t, {name = "Show", output = "clipboard", run = "cat {file}"})
	qed.run("Show")
	t.wait(clipboard_is("old"))
	one(t, {name = "Up", output = "replace", stdin = "buffer", run = "tr a-z A-Z"})
	qed.run("Up")
	expect_message(t, "done")
	t.eq(qed.buf.text(b), "NEW OLD")
	t.eq(qed.fs.read(qed.buf.path(b)), "old", "replace does not save first")
end

function T.save_none(t)
	local b = t.open("s.txt", "old")
	t.type("new ")
	one(t, {name = "Show", output = "clipboard", save = "none", run = "cat {file}"})
	qed.run("Show")
	t.wait(clipboard_is("old"))
	t.ok(qed.buf.modified(b), "not saved")
end

function T.save_all(t)
	local a = t.open("a.txt", "a")
	t.type("1")
	local b = t.open("b.txt", "b")
	t.type("2")
	one(t, {name = "Show", output = "clipboard", save = "all", run = "cat a.txt b.txt"})
	qed.run("Show")
	t.wait(clipboard_is("1a2b"))
	t.ok(not qed.buf.modified(a) and not qed.buf.modified(b), "every buffer saved")
	local c = t.open("c.txt", "c")
	t.type("3")
	one(t, {name = "Show", run = "cat a.txt c.txt"})
	qed.run("Show")
	expect_message(t, "1a3c")
end

function T.when_language(t)
	t.open("a.txt", "x")
	one(t, {name = "Py", key = "Alt+j", run = "echo ran", when = {language = {"python", "go"}}})
	t.ok(not chord_runs(t), "hidden for text")
	t.open("a.py", "x")
	t.ok(chord_runs(t), "runs for python")
end

function T.when_glob(t)
	t.open("a.txt", "x")
	one(t, {name = "Test", key = "Alt+j", run = "echo ran", when = {glob = "*.test.ts"}})
	t.ok(not chord_runs(t), "no match")
	t.open("src/x.test.ts", "x")
	t.ok(chord_runs(t), "basename glob")
	one(t, {name = "Test", key = "Alt+j", run = "echo ran", when = {glob = {"lib/**/*.ts"}}})
	t.ok(not chord_runs(t), "path glob is root-relative")
	t.open("lib/a/b/y.ts", "x")
	t.ok(chord_runs(t), "** spans dirs")
end

function T.when_selection(t)
	local b = t.open("a.txt", "hello")
	one(t, {name = "Sel", key = "Alt+j", run = "echo ran", when = {selection = true}})
	t.ok(not chord_runs(t), "needs a selection")
	qed.buf.set_selection(b, {row = 1, col = 1}, {row = 1, col = 3})
	t.ok(chord_runs(t), "runs with a selection")
	one(t, {name = "Sel", key = "Alt+j", run = "echo ran", when = {selection = false}})
	t.ok(not chord_runs(t), "selection = false hides it")
end

function T.when_git(t)
	t.open("a.txt", "x")
	one(t, {name = "Repo", key = "Alt+j", run = "echo ran", when = {git = true}})
	t.ok(not chord_runs(t), "not a repo")
	qed.fs.write(qed.path.join(qed.root(), ".git"), "gitdir: elsewhere")
	t.ok(chord_runs(t), "a .git entry marks the repo")
end

function T.when_exists(t)
	t.open("a.txt", "x")
	one(t, {name = "Npm", key = "Alt+j", run = "echo ran", when = {exists = {"package.json", "lock"}}})
	qed.fs.write(qed.path.join(qed.root(), "package.json"), "{}")
	t.ok(not chord_runs(t), "every file must exist")
	qed.fs.write(qed.path.join(qed.root(), "lock"), "")
	t.ok(chord_runs(t), "all present")
end

function T.edit_outputs_need_a_buffer(t)
	one(t, {name = "Ed", key = "Alt+j", output = "insert", run = "echo ran"})
	t.open("a.txt", "x")
	t.key("Alt+j")
	t.wait(function() return qed.buf.text() == "ranx" end)
end

function T.filetree_scope(t)
	t.open("a.txt", "a")
	t.open("b c.txt", "b")
	one(t, {name = "Files", key = "Alt+j", output = "clipboard", run = "printf '%s|' {file} - {files}", when = {pane = "filetree"}})
	qed.clipboard.set("before")
	t.key("Alt+j")
	t.pump(30)
	t.eq(qed.clipboard.get(), "before", "a filetree command is inert in the editor")
	t.key("Alt+f")
	t.ok(t.editor().tree, "tree open")
	t.key("Shift+Down")
	t.key("Alt+j")
	local root = qed.root()
	local a, bc = qed.path.join(root, "a.txt"), qed.path.join(root, "b c.txt")
	t.wait(clipboard_is(("%s|-|%s|%s|"):format(bc, a, bc)))
	t.ok(t.editor().tree, "the tree stays open for clipboard output")
	t.key("Up")
	t.key("Alt+j")
	t.wait(clipboard_is(("%s|-|%s|"):format(a, a)))
end

function T.filetree_glob_checks_every_file(t)
	t.open("a.txt", "a")
	t.open("b.md", "b")
	one(t, {name = "Txt", key = "Alt+j", run = "echo ran", when = {pane = "filetree", glob = "*.txt"}})
	t.key("Alt+f")
	t.ok(chord_runs(t), "cursor entry a.txt matches")
	t.key("Shift+Down")
	t.ok(not chord_runs(t), "b.md in the selection does not")
end

function T.both_panes(t)
	t.open("a.txt", "a")
	one(t, {name = "Both", key = "Alt+j", run = "echo ran", when = {pane = {"editor", "filetree"}}})
	t.ok(chord_runs(t), "editor")
	t.key("Alt+f")
	t.ok(chord_runs(t), "filetree")
end

function T.locations_jump(t)
	t.open("a.txt", "one\nneedle here\nthree")
	t.open("b.txt", "x\ny\nneedle\n")
	t.open("start.txt", "")
	one(t, {name = "Grep", output = "locations", run = "grep -n needle a.txt b.txt; echo 'missing.txt:3: gone'"})
	qed.run("Grep")
	t.wait(function() return t.ui() ~= nil end)
	local ui = t.ui()
	t.eq(ui.kind, "pick")
	t.eq(ui.matches, 2, "lines naming missing files are skipped")
	t.eq(ui.selected, "a.txt:2: needle here")
	t.key("Down")
	t.key("Enter")
	t.wait(function() return qed.path.base(qed.buf.path()) == "b.txt" end)
	t.eq(qed.buf.cursor().row, 3)
	t.eq(qed.buf.cursor().col, 1)
end

function T.locations_with_columns(t)
	t.open("c.txt", "abc\ndéf ghi\n")
	one(t, {name = "Loc", output = "locations", run = "printf 'c.txt:2:3: in a char\\nc.txt:9:99: past the end\\n'"})
	qed.run("Loc")
	t.wait(function() return t.ui() ~= nil end)
	t.eq(t.ui().selected, "c.txt:2:3: in a char")
	t.key("Enter")
	t.wait(function() return t.ui() == nil end)
	t.eq(qed.buf.cursor().row, 2)
	t.eq(qed.buf.cursor().col, 2, "a column inside a UTF-8 sequence snaps back")
	qed.run("Loc")
	t.wait(function() return t.ui() ~= nil end)
	t.key("Down")
	t.key("Enter")
	t.wait(function() return qed.buf.cursor().row == 3 end)
	t.eq(qed.buf.cursor().col, 1, "positions clamp to the buffer")
end

function T.locations_from_filetree(t)
	t.open("a.txt", "one\nneedle")
	one(t, {name = "Grep", key = "Alt+j", output = "locations", run = "grep -Hn needle {files}", when = {pane = "filetree"}})
	t.key("Alt+f")
	t.key("Alt+j")
	t.wait(function() return t.ui() ~= nil end)
	t.eq(t.ui().selected, "a.txt:2: needle")
	t.key("Enter")
	t.wait(function() return not t.editor().tree end)
	t.eq(qed.path.base(qed.buf.path()), "a.txt", "the jump closes the tree")
	t.eq(qed.buf.cursor().row, 2)
end

function T.locations_without_message(t)
	t.open("c.txt", "abc\ndef\n")
	one(t, {name = "Loc", output = "locations", run = "printf 'c.txt:2:3\\nc.txt:1\\n12:30 meeting\\n'"})
	qed.run("Loc")
	t.wait(function() return t.ui() ~= nil end)
	t.eq(t.ui().matches, 2)
	t.eq(t.ui().selected, "c.txt:2:3")
	t.key("Down")
	t.eq(t.ui().selected, "c.txt:1")
	t.key("Esc")
end

function T.locations_empty_is_success(t)
	t.open("a.txt", "nothing")
	one(t, {name = "Grep", output = "locations", run = "grep -n needle a.txt"})
	qed.run("Grep")
	expect_message(t, "no locations", "info", "Grep")
	one(t, {name = "Grep", output = "locations", run = "grep -n needle nope.txt"})
	qed.run("Grep")
	t.wait(function() return (t.message()):match("^failed %(exit 2%)") ~= nil end)
end

function T.locations_from_stderr(t)
	t.open("a.txt", "one\ntwo")
	one(t, {name = "Cc", output = "locations", run = "echo 'a.txt:2:1: error: bad' >&2; exit 1"})
	qed.run("Cc")
	t.wait(function() return t.ui() ~= nil end)
	t.eq(t.ui().selected, "a.txt:2:1: error: bad")
	t.key("Esc")
end

function T.log_pane(t)
	t.open("a.txt", "x")
	one(t, {name = "Log", output = "log", run = "echo out1; echo out2; echo err >&2; exit 2"})
	qed.run("Log")
	t.wait(function() return t.editor().pane ~= nil end)
	local pane = t.editor().pane
	t.eq(pane.title, "Log")
	t.eq(#pane.lines, 3)
	t.eq(pane.lines[1].text, "out1")
	t.eq(pane.lines[2].text, "out2")
	t.eq(pane.lines[3].text, "err")
	t.eq(pane.lines[3].color, "error_foreground")
	t.eq(pane.footer, "exit 2  ·  Esc close")
	expect_message(t, "failed (exit 2): err", "error")
	t.key("Esc")
	t.ok(t.editor().pane == nil, "Esc closes the log")
	one(t, {name = "Log", output = "log", run = "echo fine"})
	qed.run("Log")
	t.wait(function() return t.editor().pane ~= nil end)
	t.eq(t.editor().pane.footer, "exit 0  ·  Esc close")
	t.key("Esc")
end

function T.terminal_output(t)
	t.open("a.txt", "x")
	one(t, {name = "Term", output = "terminal", run = "echo {name}"})
	qed.run("Term")
	t.pump(20)
	t.ok(t.editor().terminal, "the terminal pane is shown")
end

function T.cancel(t)
	t.open("a.txt", "x")
	t.fake_spawn("slowtool", {stdout = "late", delay_ms = 5000})
	one(t, {name = "Slow", run = "slowtool"})
	qed.run("Slow")
	t.wait(message_is(t, "running…"))
	qed.run("Slow")
	expect_message(t, "already running", "warn")
	qed.run("Commands: Cancel")
	expect_message(t, "cancelled", "warn", "Slow")
	t.fake_spawn("quick", {stdout = "ok"})
	one(t, {name = "Quick", run = "quick"})
	qed.run("Quick")
	expect_message(t, "ok")
end

function T.cancel_hidden_when_idle(t)
	t.open("a.txt", "x")
	one(t, {name = "Q", run = "true"})
	idle(t)
	t.ok(qed.run("Commands: Cancel"), "runs without effect")
	t.pump(20)
	t.eq((t.message()), "idle")
end

function T.invalid_entries_warn(t)
	one(t, {name = "Good", run = "echo good", bogus = 1})
	t.ok(t.log_has("warn", "", "ignoring unknown key \"bogus\""), "unknown keys warn")
	t.config{list = {
		{name = "Save", run = "echo x"},
		{name = "", run = "x"},
		{name = "NoRun"},
		{name = "BadOut", run = "x", output = "task"},
		{name = "BadPane", run = "x", output = "replace", when = {pane = "filetree"}},
		{name = "BadKey", run = "x", key = "Hyper+x"},
		{name = "Dupe", run = "echo first"},
		{name = "Dupe", run = "echo second"},
		{name = "Good", run = "echo good"},
	}}
	t.ok(t.log_has("warn", "", "\"Save\": command 'Save' already exists"), "a builtin name is refused")
	t.ok(t.log_has("warn", "", "list[2].name must be a non-empty string"), "empty name")
	t.ok(t.log_has("warn", "", "\"NoRun\": run must be a non-empty string"), "missing run")
	t.ok(t.log_has("warn", "", "unknown output \"task\""), "bad output")
	t.ok(t.log_has("warn", "", "\"BadPane\": output replace/insert"), "edit output in the tree")
	t.ok(t.log_has("warn", "", "invalid key 'Hyper+x'"), "bad key")
	t.ok(t.log_has("warn", "", "\"Dupe\": command 'Dupe' already exists"), "duplicate name")
	qed.run("Dupe")
	expect_message(t, "first")
	qed.run("Good")
	expect_message(t, "good")
end

function T.quoted_placeholders_refused(t)
	t.config{list = {
		{name = "Single", run = "cat '{file}'"},
		{name = "Double", run = "echo \"x {selection}\""},
		{name = "Escaped", run = "echo \\\"{name}"},
		{name = "Awk", run = "printf 'a b\\n' | awk '{print $2}'"},
	}}
	t.ok(t.log_has("warn", "", "\"Single\": {file} is inside quotes"), "single quotes refused")
	t.ok(t.log_has("warn", "", "\"Double\": {selection} is inside quotes"), "double quotes refused")
	t.ok(not pcall(qed.run, "Single"), "not registered")
	t.open("x y.txt", "")
	qed.run("Escaped")
	expect_message(t, "\"x y.txt")
	qed.run("Awk")
	expect_message(t, "b", "info", "Awk")
end

function T.large_selection(t)
	local rows = {}
	for i = 1, 20000 do
		rows[i] = ("line %05d of a big buffer"):format(20001 - i)
	end
	local b = t.open("big.txt", table.concat(rows, "\n"))
	t.key("Ctrl+a")
	one(t, {name = "Sort", output = "replace", stdin = "selection", run = "sort"})
	qed.run("Sort")
	expect_message(t, "done")
	t.eq(qed.buf.line(b, 1), "line 00001 of a big buffer", "a selection over 128 KiB goes through stdin")
	t.eq(qed.buf.line_count(b), 20000)
	t.key("Ctrl+a")
	one(t, {name = "Echo", run = "echo {selection}"})
	qed.run("Echo")
	t.wait(function() return (t.message()):match("command argument too long") ~= nil end)
	local text, level = t.message()
	t.eq(level, "error")
	t.ok(not text:match("%.lua:%d+:"), "no Lua position in the message: " .. text)
end

function T.cancel_kills_descendants(t)
	t.open("a.txt", "x")
	one(t, {name = "Tree", run = "sleep 3071 & sleep 3071; wait"})
	qed.run("Tree")
	local function count()
		local f = io.popen("ps -eo args | grep -c '^sleep 3071$'")
		local n = f:read("a")
		f:close()
		return n
	end
	t.wait(function() return count() == "2\n" end)
	qed.run("Commands: Cancel")
	expect_message(t, "cancelled", "warn")
	t.wait(function() return count() == "0\n" end)
end

function T.running_hint_cleared(t)
	t.open("a.txt", "x")
	t.fake_spawn("slowlog", {stdout = "out", delay_ms = 600})
	one(t, {name = "Slow", output = "log", run = "slowlog"})
	qed.run("Slow")
	t.wait(message_is(t, "running…"))
	t.wait(function() return t.editor().pane ~= nil end)
	t.eq((t.message()), "", "the hint is cleared")
	t.key("Esc")
end

function T.filetree_ignores_buffer_selection(t)
	local b = t.open("a.txt", "hello")
	qed.buf.set_selection(b, {row = 1, col = 1}, {row = 1, col = 3})
	one(t, {name = "Sel", key = "Alt+j", output = "clipboard", run = "printf '[%s]' {selection}", when = {pane = "filetree", selection = false}})
	t.key("Alt+f")
	idle(t)
	t.key("Alt+j")
	t.wait(clipboard_is("[]"))
end

function T.unchanged_list_keeps_commands(t)
	t.open("a.txt", "x")
	local list = {{name = "One", run = "echo one", when = {pane = "editor", glob = {"*.txt"}}, env = {B = "2", A = "1"}}}
	one(t, list[1])
	t.key("Ctrl+p")
	t.ok(t.editor().palette, "palette open")
	t.config({list = list, other = 1}, {hot = true})
	t.ok(t.editor().palette, "an identical list does not re-register (the palette stays open)")
	t.config({list = {{name = "Two", run = "echo two"}}}, {hot = true})
	t.ok(not t.editor().palette, "a changed list re-registers")
end

function T.hot_reregister(t)
	t.open("a.txt", "x")
	one(t, {name = "One", run = "echo one"})
	qed.run("One")
	expect_message(t, "one")
	t.config({list = {{name = "Two", run = "echo two"}, {name = "One", run = "echo uno"}}}, {hot = true})
	qed.run("One")
	expect_message(t, "uno", "info", "One")
	qed.run("Two")
	expect_message(t, "two")
	t.config({list = {{name = "Two", run = "echo two", key = "Alt+j"}}}, {hot = true})
	t.ok(not pcall(qed.run, "One"), "a removed command is gone")
	idle(t)
	t.key("Alt+j")
	expect_message(t, "two")
	t.config({list = {}}, {hot = true})
	t.ok(not pcall(qed.run, "Two"), "an emptied list removes everything")
end

return T

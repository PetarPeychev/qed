local T = {}

local function disk(b)
	return qed.fs.read(qed.buf.path(b))
end

local function saved(b)
	return function() return not qed.buf.modified(b) end
end

local function message_is(t, text)
	return function() return (t.message()) == text end
end

local function expect_cursor(t, b, row, col)
	local c = qed.buf.cursor(b)
	t.eq(c.row, row, "cursor row")
	t.eq(c.col, col, "cursor col")
end

function T.document_external(t)
	local b = t.open("a.txt", "hello\nworld")
	t.config{commands = {text = t.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Document")
	t.wait(message_is(t, "Formatted"))
	local _, level, source = t.message()
	t.eq(level, "info")
	t.eq(source, "Format")
	t.expect_line(1, "HELLO")
	t.expect_line(2, "WORLD")
	t.ok(t.log_has("debug", "Format", "ran "), "the run leaves a Debug trail entry")
	t.key("Ctrl+z")
	t.expect_line(1, "hello")
	t.expect_line(2, "world")
	t.ok(not qed.buf.modified(b), "one undo step reverts the format")
	t.key("Ctrl+y")
	t.expect_line(1, "HELLO")
end

function T.document_no_changes(t)
	t.open("a.txt", "same\n")
	t.config{commands = {text = t.stub("cat")}}
	local rev = qed.buf.rev()
	qed.run("Format: Document")
	t.wait(message_is(t, "No formatting changes"))
	t.eq(qed.buf.rev(), rev, "an identical result does not edit")
end

function T.on_save_external(t)
	local b = t.open("a.txt", "hello\nworld")
	t.config{on_save = true, commands = {text = t.stub("tr 'a-z' 'A-Z'")}}
	t.type("x")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.expect_line(1, "XHELLO")
	t.eq(disk(b), "XHELLO\nWORLD", "the formatted bytes are saved")
	t.key("Ctrl+z")
	t.expect_line(1, "xhello")
	t.expect_line(2, "world")
end

function T.on_save_off_does_not_format(t)
	local b = t.open("a.txt", "hello")
	t.config{commands = {text = t.stub("tr 'a-z' 'A-Z'")}}
	t.type("x")
	t.key("Ctrl+s")
	t.ok(not qed.buf.modified(b), "the save does not wait")
	t.eq(disk(b), "xhello")
end

local function probe(t, args, filter)
	local b = t.open("sub dir/a b.txt", "hello")
	local dir = qed.path.dir(qed.buf.path(b))
	local pwd = qed.path.join(dir, "pwd.out")
	local argv = qed.path.join(dir, "args.out")
	local stub = t.stub(("pwd > %s\nprintf '%%s\\n' \"$@\" > %s\n%s"):format(qed.shell_quote(pwd), qed.shell_quote(argv), filter))
	t.config{commands = {text = stub .. args}}
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	t.eq(qed.fs.read(pwd), dir .. "\n", "the formatter runs in the file's dir")
	return b, qed.fs.read(argv)
end

function T.file_placeholder(t)
	local b, args = probe(t, " --stdin-filename {file} -", "cat")
	t.eq(args, "--stdin-filename\n" .. qed.buf.path(b) .. "\n-\n", "{file} becomes the quoted absolute path")
	t.eq((t.message()), "No formatting changes")
end

function T.without_placeholder(t)
	local _, args = probe(t, "", "tr 'a-z' 'A-Z'")
	t.eq(args, "\n")
	t.expect_line(1, "HELLO")
end

function T.missing_tool(t)
	local b = t.open("a.txt", "keep\nthis")
	t.config{on_save = true, commands = {text = "qed_no_such_formatter_zzz --stdin"}}
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	local text, level = t.message()
	t.eq(text, "Formatter not found: qed_no_such_formatter_zzz")
	t.eq(level, "error")
	t.expect_line(1, "keep")
	t.expect_line(2, "this")
	t.type("!")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.eq(disk(b), "!keep\nthis", "a missing formatter still saves, unformatted")
end

function T.failing_tool(t)
	t.open("a.txt", "keep")
	t.config{commands = {text = t.stub("echo partial; exit 3")}}
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	local text, level = t.message()
	t.ok(text:match(" failed$"), "names the failed tool: " .. text)
	t.eq(level, "error")
	t.expect_line(1, "keep")
end

function T.empty_output_fails(t)
	t.open("a.txt", "keep")
	t.fake_spawn("fakefmt", {stdout = ""})
	t.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	t.wait(message_is(t, "fakefmt failed"))
	t.expect_line(1, "keep")
end

function T.rev_guard_document(t)
	local b = t.open("a.txt", "messy")
	t.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 50})
	t.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	t.type("!")
	t.wait(message_is(t, "skipped: buffer changed"))
	local _, level = t.message()
	t.eq(level, "warn")
	t.eq(qed.buf.text(b), "!messy", "a stale result is dropped")
end

function T.rev_guard_on_save(t)
	local b = t.open("a.txt", "messy")
	t.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 50})
	t.config{on_save = true, commands = {text = "fakefmt"}}
	t.key("Ctrl+s")
	t.type("!")
	t.wait(function() return disk(b) == "!messy" end)
	t.eq(qed.buf.text(b), "!messy", "typing during the format wins")
	t.ok(not qed.buf.modified(b), "the typed text is saved")
end

function T.minimal_diff_keeps_cursor(t)
	local b = t.open("a.txt", "a = 1\nb=2\nc = 3\nd = 4")
	qed.buf.set_cursor(b, {row = 4, col = 3})
	t.fake_spawn("fakefmt", {stdout = "import x\na = 1\nb = 2\nc = 3\nd = 4"})
	t.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	t.wait(message_is(t, "Formatted"))
	t.expect_line(3, "b = 2")
	expect_cursor(t, b, 5, 3)
	t.key("Ctrl+z")
	t.eq(qed.buf.text(b), "a = 1\nb=2\nc = 3\nd = 4", "one undo step restores the input")
	expect_cursor(t, b, 4, 3)
end

function T.minimal_diff_changed_line(t)
	local b = t.open("a.txt", "keep\nx=1\nkeep")
	qed.buf.set_cursor(b, {row = 2, col = 4})
	t.fake_spawn("fakefmt", {stdout = "keep\nx = 1\nkeep"})
	t.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	t.wait(message_is(t, "Formatted"))
	expect_cursor(t, b, 2, 4)
	local before = qed.buf.rev(b)
	t.ok(qed.buf.set_text(b, "keep\nx = 1\nkeep"), "set_text accepts identical text")
	t.eq(qed.buf.rev(b), before, "identical text does not edit")
	t.ok(not qed.buf.set_text(b, "other", {rev = before - 1}), "a stale rev is refused")
	t.eq(qed.buf.text(b), "keep\nx = 1\nkeep")
end

function T.trailing_newline(t)
	local b = t.open("a.py", "x=1")
	t.fake_spawn("fakefmt", {stdout = "x = 1\n"})
	t.config{on_save = true, commands = {python = "fakefmt"}}
	t.type(" ")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.eq(qed.buf.line_count(b), 2, "the formatter's final newline becomes an empty last line")
	t.eq(disk(b), "x = 1\n")
	t.type("#")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.eq(disk(b), "x = 1\n", "an already terminated file keeps one newline")
end

function T.lsp_fallback_without_server(t)
	t.open("a.txt", "plain")
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	local text, level = t.message()
	t.eq(text, "No language server for this buffer")
	t.eq(level, "error")
end

function T.trim_whitespace(t)
	local b = t.open("a.txt", "foo   \n\tbar\t\n   \nbaz")
	t.config{trim_whitespace_on_save = true}
	t.key("Ctrl+s")
	t.expect_line(1, "foo")
	t.expect_line(2, "\tbar")
	t.expect_line(3, "")
	t.expect_line(4, "baz")
	t.eq(disk(b), "foo\n\tbar\n\nbaz")
	t.key("Ctrl+z")
	t.expect_line(1, "foo   ")
	t.expect_line(2, "\tbar\t")
	t.expect_line(3, "   ")
end

function T.trim_cursor_clamped(t)
	local b = t.open("a.txt", "word    \nnext")
	t.config{trim_whitespace_on_save = true}
	qed.buf.set_cursor(b, {row = 1, col = 8})
	t.key("Ctrl+s")
	t.expect_line(1, "word")
	expect_cursor(t, b, 1, 5)
end

function T.final_newline(t)
	local b = t.open("a.txt", "alpha\nbeta")
	t.config{final_newline_on_save = true}
	qed.buf.set_cursor(b, {row = 2, col = 5})
	t.key("Ctrl+s")
	t.eq(qed.buf.line_count(b), 3)
	t.expect_line(3, "")
	t.eq(disk(b), "alpha\nbeta\n")
	expect_cursor(t, b, 2, 5)
	t.key("Ctrl+s")
	t.eq(qed.buf.line_count(b), 3, "no second empty line")
end

function T.markdown_fixups(t)
	local b = t.open("notes.md", "break2  \nbreak3   \none \ntab \t\n   \nlast")
	t.eq(qed.buf.language(b), "markdown")
	t.config{trim_whitespace_on_save = true, final_newline_on_save = true}
	t.key("Ctrl+s")
	t.expect_line(1, "break2  ")
	t.expect_line(2, "break3   ")
	t.expect_line(3, "one")
	t.expect_line(4, "tab")
	t.expect_line(5, "")
	t.eq(qed.buf.line_count(b), 7)
	t.eq(disk(b), "break2  \nbreak3   \none\ntab\n\nlast\n")
end

function T.trim_newline_no_double(t)
	local b = t.open("a.txt", "end\n   ")
	t.config{trim_whitespace_on_save = true, final_newline_on_save = true}
	t.key("Ctrl+s")
	t.eq(qed.buf.line_count(b), 2)
	t.expect_line(2, "")
	t.eq(disk(b), "end\n")
end

function T.fixups_off_identical(t)
	local seed = "keep  \ntrailing\t\nno newline"
	local b = t.open("a.txt", seed)
	local rev = qed.buf.rev(b)
	t.key("Ctrl+s")
	t.eq(qed.buf.rev(b), rev, "no edits with every knob off")
	t.eq(disk(b), seed)
end

function T.trim_before_format(t)
	local b = t.open("a.txt", "foo   \nbar\t")
	local seen = qed.path.join(qed.path.dir(qed.buf.path(b)), "seen.out")
	t.config{
		trim_whitespace_on_save = true,
		on_save = true,
		commands = {text = t.stub("tee " .. qed.shell_quote(seen))},
	}
	t.key("Ctrl+s")
	t.wait(function() return not qed.buf.modified(b) and qed.fs.exists(seen) end)
	t.eq(qed.fs.read(seen), "foo\nbar", "the formatter's stdin is already trimmed")
end

function T.quit_save_all(t)
	local b = t.open("a.txt", "foo  \nbar")
	t.config{
		on_save = true,
		trim_whitespace_on_save = true,
		final_newline_on_save = true,
		commands = {text = t.stub("tr 'a-z' 'A-Z'")},
	}
	t.type("z")
	t.key("Ctrl+q")
	t.eq(t.editor().dialog, "quit")
	t.key("Enter")
	t.wait(function() return t.editor().quit end)
	t.eq(disk(b), "ZFOO\nBAR\n")
end

function T.close_save(t)
	qed.close(qed.buf.current())
	local b = t.open("a.txt", "baz  ")
	local path = qed.buf.path(b)
	t.config{trim_whitespace_on_save = true}
	t.type("!")
	t.key("Ctrl+w")
	t.eq(t.editor().dialog, "close")
	t.key("Enter")
	t.eq(qed.fs.read(path), "!baz")
	t.ok(not qed.buf.valid(b), "the saved buffer closes")
	t.ok(t.editor().welcome, "saving the last buffer closes it back to the welcome screen")
end

function T.conflict_overwrite(t)
	local b = t.open("a.txt", "first  \nsecond")
	t.config{
		on_save = true,
		trim_whitespace_on_save = true,
		commands = {text = t.stub("tr 'a-z' 'A-Z'")},
	}
	t.type("X")
	qed.fs.write(qed.buf.path(b), "DISK\n")
	t.poll_disk()
	t.key("Ctrl+s")
	t.wait(function() return t.editor().dialog == "conflict" end)
	t.key("Down")
	t.key("Enter")
	t.wait(saved(b))
	t.eq(disk(b), "XFIRST\nSECOND")
	t.eq(t.editor().disk_conflict, false, "the conflict is resolved")
end

function T.late_result_after_timeout(t)
	local b = t.open("a.txt", "messy")
	t.hook_timeout(50)
	t.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 300})
	t.config{on_save = true, commands = {text = "fakefmt"}}
	t.type("!")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.eq(disk(b), "!messy", "the timed-out save goes ahead unformatted")
	t.ok(t.log_has("warn", "Format", "stopped it and saving"), "the slow handler is named")
	t.pump(400)
	t.eq(qed.buf.text(b), "!messy", "nothing lands after the save")
	t.ok(not qed.buf.modified(b), "the buffer stays saved")
end

function T.late_result_after_close(t)
	local b = t.open("a.txt", "messy")
	local path = qed.buf.path(b)
	t.hook_timeout(50)
	t.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 300})
	t.config{on_save = true, commands = {text = "fakefmt"}}
	t.type("!")
	t.key("Ctrl+w")
	t.key("Enter")
	t.wait(function() return not qed.buf.valid(b) end)
	t.eq(qed.fs.read(path), "!messy")
	t.pump(400)
end

function T.non_utf8_output(t)
	local b = t.open("a.txt", "caf\xe9")
	t.config{commands = {text = t.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	local text, level = t.message()
	t.ok(text:match("failed: .*UTF%-8"), "reports the invalid output: " .. text)
	t.eq(level, "error")
	t.eq(qed.buf.text(b), "caf\xe9")
end

function T.lsp_disabled(t)
	t.open("a.txt", "plain")
	t.lsp(false)
	qed.run("Format: Document")
	t.wait(function() return t.message() ~= "" end)
	t.eq((t.message()), "No formatter for this buffer")
end

function T.save_all_formats_every_buffer(t)
	local stub = t.stub("tr 'a-z' 'A-Z'")
	local a = t.open("a.txt", "first")
	t.type("x")
	local b = t.open("b.txt", "second")
	t.type("y")
	t.config{on_save = true, commands = {text = stub}}
	t.key("Ctrl+q")
	t.key("Enter")
	t.wait(function() return t.editor().quit end)
	t.eq(disk(a), "XFIRST", "the non-current buffer is formatted")
	t.eq(disk(b), "YSECOND")
end

function T.toggle_survives_reload(t)
	local b = t.open("a.txt", "pad  ")
	qed.run("Format: Toggle Trim Whitespace on Save")
	t.config({final_newline_on_save = true}, {hot = true})
	t.key("Ctrl+s")
	t.eq(disk(b), "pad\n", "the runtime toggle survives an unrelated reload, the changed knob applies")
	t.config({final_newline_on_save = true, trim_whitespace_on_save = true}, {hot = true})
	t.config({final_newline_on_save = true, trim_whitespace_on_save = false}, {hot = true})
	qed.buf.set_cursor(b, {row = 1, col = 4})
	t.type("  ")
	t.key("Ctrl+s")
	t.eq(disk(b), "pad  \n", "a changed knob overrides the toggle")
end

function T.toggle_trim(t)
	local b = t.open("a.txt", "top\n\n\nbottom")
	qed.run("Format: Toggle Trim Whitespace on Save")
	t.eq((t.message()), "Trim whitespace on save: on")
	qed.buf.set_cursor(b, {row = 2, col = 1})
	t.type("  ")
	qed.buf.set_cursor(b, {row = 3, col = 1})
	t.type("   ")
	t.key("Ctrl+s")
	t.expect_line(2, "")
	t.expect_line(3, "")
	expect_cursor(t, b, 3, 1)
	t.eq(disk(b), "top\n\n\nbottom")
end

function T.toggles(t)
	local b = t.open("a.txt", "pad  ")
	t.config{commands = {text = t.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Toggle Trim Whitespace on Save")
	qed.run("Format: Toggle Final Newline on Save")
	t.eq((t.message()), "Final newline on save: on")
	qed.run("Format: Toggle on Save")
	t.eq((t.message()), "Format on save: on")
	t.key("Ctrl+s")
	t.wait(saved(b))
	t.eq(disk(b), "PAD\n")
	qed.run("Format: Toggle on Save")
	t.eq((t.message()), "Format on save: off")
	t.type("x")
	t.key("Ctrl+s")
	t.eq(disk(b), "xPAD\n")
end

return T

local tests = {}

local function disk(buffer)
	return qed.fs.read(buffer:path())
end

local function saved(buffer)
	return function() return not buffer:modified() end
end

local function message_is(test, text)
	return function() return (test.message()) == text end
end

local function expect_cursor(test, buffer, row, col)
	local cursor = buffer:cursor()
	test.eq(cursor.row, row, "cursor row")
	test.eq(cursor.col, col, "cursor col")
end

function tests.document_external(test)
	local buffer = test.open("a.txt", "hello\nworld")
	test.config{commands = {text = test.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Document")
	test.wait(message_is(test, "Formatted"))
	local _, level, source = test.message()
	test.eq(level, "info")
	test.eq(source, "Format")
	test.expect_line(1, "HELLO")
	test.expect_line(2, "WORLD")
	test.ok(test.log_has("debug", "Format", "ran "), "the run leaves a Debug trail entry")
	test.key("Ctrl+z")
	test.expect_line(1, "hello")
	test.expect_line(2, "world")
	test.ok(not buffer:modified(), "one undo step reverts the format")
	test.key("Ctrl+y")
	test.expect_line(1, "HELLO")
end

function tests.document_no_changes(test)
	test.open("a.txt", "same\n")
	test.config{commands = {text = test.stub("cat")}}
	local rev = qed.buf.current():rev()
	qed.run("Format: Document")
	test.wait(message_is(test, "No formatting changes"))
	test.eq(qed.buf.current():rev(), rev, "an identical result does not edit")
end

function tests.on_save_external(test)
	local buffer = test.open("a.txt", "hello\nworld")
	test.config{on_save = true, commands = {text = test.stub("tr 'a-z' 'A-Z'")}}
	test.type("x")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.expect_line(1, "XHELLO")
	test.eq(disk(buffer), "XHELLO\nWORLD", "the formatted bytes are saved")
	test.key("Ctrl+z")
	test.expect_line(1, "xhello")
	test.expect_line(2, "world")
end

function tests.on_save_off_does_not_format(test)
	local buffer = test.open("a.txt", "hello")
	test.config{commands = {text = test.stub("tr 'a-z' 'A-Z'")}}
	test.type("x")
	test.key("Ctrl+s")
	test.ok(not buffer:modified(), "the save does not wait")
	test.eq(disk(buffer), "xhello")
end

local function probe(test, args, filter)
	local buffer = test.open("sub dir/a b.txt", "hello")
	local dir = qed.path.dir(buffer:path())
	local pwd = qed.path.join(dir, "pwd.out")
	local argv = qed.path.join(dir, "args.out")
	local stub = test.stub(("pwd > %s\nprintf '%%s\\n' \"$@\" > %s\n%s"):format(qed.shell_quote(pwd), qed.shell_quote(argv), filter))
	test.config{commands = {text = stub .. args}}
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	test.eq(qed.fs.read(pwd), dir .. "\n", "the formatter runs in the file's dir")
	return buffer, qed.fs.read(argv)
end

function tests.file_placeholder(test)
	local buffer, args = probe(test, " --stdin-filename {file} -", "cat")
	test.eq(args, "--stdin-filename\n" .. buffer:path() .. "\n-\n", "{file} becomes the quoted absolute path")
	test.eq((test.message()), "No formatting changes")
end

function tests.without_placeholder(test)
	local _, args = probe(test, "", "tr 'a-z' 'A-Z'")
	test.eq(args, "\n")
	test.expect_line(1, "HELLO")
end

function tests.missing_tool(test)
	local buffer = test.open("a.txt", "keep\nthis")
	test.config{on_save = true, commands = {text = "qed_no_such_formatter_zzz --stdin"}}
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	local text, level = test.message()
	test.eq(text, "Formatter not found: qed_no_such_formatter_zzz")
	test.eq(level, "error")
	test.expect_line(1, "keep")
	test.expect_line(2, "this")
	test.type("!")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.eq(disk(buffer), "!keep\nthis", "a missing formatter still saves, unformatted")
end

function tests.failing_tool(test)
	test.open("a.txt", "keep")
	test.config{commands = {text = test.stub("echo partial; exit 3")}}
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	local text, level = test.message()
	test.ok(text:match(" failed$"), "names the failed tool: " .. text)
	test.eq(level, "error")
	test.expect_line(1, "keep")
end

function tests.empty_output_fails(test)
	test.open("a.txt", "keep")
	test.fake_spawn("fakefmt", {stdout = ""})
	test.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	test.wait(message_is(test, "fakefmt failed"))
	test.expect_line(1, "keep")
end

function tests.rev_guard_document(test)
	local buffer = test.open("a.txt", "messy")
	test.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 50})
	test.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	test.type("!")
	test.wait(message_is(test, "skipped: buffer changed"))
	local _, level = test.message()
	test.eq(level, "warn")
	test.eq(buffer:text(), "!messy", "a stale result is dropped")
end

function tests.rev_guard_on_save(test)
	local buffer = test.open("a.txt", "messy")
	test.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 50})
	test.config{on_save = true, commands = {text = "fakefmt"}}
	test.key("Ctrl+s")
	test.type("!")
	test.wait(function() return disk(buffer) == "!messy" end)
	test.eq(buffer:text(), "!messy", "typing during the format wins")
	test.ok(not buffer:modified(), "the typed text is saved")
end

function tests.minimal_diff_keeps_cursor(test)
	local buffer = test.open("a.txt", "a = 1\nb=2\nc = 3\nd = 4")
	buffer:set_cursor({row = 4, col = 3})
	test.fake_spawn("fakefmt", {stdout = "import x\na = 1\nb = 2\nc = 3\nd = 4"})
	test.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	test.wait(message_is(test, "Formatted"))
	test.expect_line(3, "b = 2")
	expect_cursor(test, buffer, 5, 3)
	test.key("Ctrl+z")
	test.eq(buffer:text(), "a = 1\nb=2\nc = 3\nd = 4", "one undo step restores the input")
	expect_cursor(test, buffer, 4, 3)
end

function tests.minimal_diff_changed_line(test)
	local buffer = test.open("a.txt", "keep\nx=1\nkeep")
	buffer:set_cursor({row = 2, col = 4})
	test.fake_spawn("fakefmt", {stdout = "keep\nx = 1\nkeep"})
	test.config{commands = {text = "fakefmt"}}
	qed.run("Format: Document")
	test.wait(message_is(test, "Formatted"))
	expect_cursor(test, buffer, 2, 4)
	local before = buffer:rev()
	test.ok(buffer:set_text("keep\nx = 1\nkeep"), "set_text accepts identical text")
	test.eq(buffer:rev(), before, "identical text does not edit")
	test.ok(not buffer:set_text("other", {rev = before - 1}), "a stale rev is refused")
	test.eq(buffer:text(), "keep\nx = 1\nkeep")
end

function tests.trailing_newline(test)
	local buffer = test.open("a.py", "x=1")
	test.fake_spawn("fakefmt", {stdout = "x = 1\n"})
	test.config{on_save = true, commands = {python = "fakefmt"}}
	test.type(" ")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.eq(buffer:line_count(), 2, "the formatter's final newline becomes an empty last line")
	test.eq(disk(buffer), "x = 1\n")
	test.type("#")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.eq(disk(buffer), "x = 1\n", "an already terminated file keeps one newline")
end

function tests.lsp_fallback_without_server(test)
	test.open("a.txt", "plain")
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	local text, level = test.message()
	test.eq(text, "No language server for this buffer")
	test.eq(level, "error")
end

function tests.trim_whitespace(test)
	local buffer = test.open("a.txt", "foo   \n\tbar\t\n   \nbaz")
	test.config{trim_whitespace_on_save = true}
	test.key("Ctrl+s")
	test.expect_line(1, "foo")
	test.expect_line(2, "\tbar")
	test.expect_line(3, "")
	test.expect_line(4, "baz")
	test.eq(disk(buffer), "foo\n\tbar\n\nbaz")
	test.key("Ctrl+z")
	test.expect_line(1, "foo   ")
	test.expect_line(2, "\tbar\t")
	test.expect_line(3, "   ")
end

function tests.trim_cursor_clamped(test)
	local buffer = test.open("a.txt", "word    \nnext")
	test.config{trim_whitespace_on_save = true}
	buffer:set_cursor({row = 1, col = 8})
	test.key("Ctrl+s")
	test.expect_line(1, "word")
	expect_cursor(test, buffer, 1, 5)
end

function tests.final_newline(test)
	local buffer = test.open("a.txt", "alpha\nbeta")
	test.config{final_newline_on_save = true}
	buffer:set_cursor({row = 2, col = 5})
	test.key("Ctrl+s")
	test.eq(buffer:line_count(), 3)
	test.expect_line(3, "")
	test.eq(disk(buffer), "alpha\nbeta\n")
	expect_cursor(test, buffer, 2, 5)
	test.key("Ctrl+s")
	test.eq(buffer:line_count(), 3, "no second empty line")
end

function tests.markdown_fixups(test)
	local buffer = test.open("notes.md", "break2  \nbreak3   \none \ntab \t\n   \nlast")
	test.eq(buffer:language(), "markdown")
	test.config{trim_whitespace_on_save = true, final_newline_on_save = true}
	test.key("Ctrl+s")
	test.expect_line(1, "break2  ")
	test.expect_line(2, "break3   ")
	test.expect_line(3, "one")
	test.expect_line(4, "tab")
	test.expect_line(5, "")
	test.eq(buffer:line_count(), 7)
	test.eq(disk(buffer), "break2  \nbreak3   \none\ntab\n\nlast\n")
end

function tests.trim_newline_no_double(test)
	local buffer = test.open("a.txt", "end\n   ")
	test.config{trim_whitespace_on_save = true, final_newline_on_save = true}
	test.key("Ctrl+s")
	test.eq(buffer:line_count(), 2)
	test.expect_line(2, "")
	test.eq(disk(buffer), "end\n")
end

function tests.fixups_off_identical(test)
	local seed = "keep  \ntrailing\t\nno newline"
	local buffer = test.open("a.txt", seed)
	local rev = buffer:rev()
	test.key("Ctrl+s")
	test.eq(buffer:rev(), rev, "no edits with every knob off")
	test.eq(disk(buffer), seed)
end

function tests.trim_before_format(test)
	local buffer = test.open("a.txt", "foo   \nbar\t")
	local seen = qed.path.join(qed.path.dir(buffer:path()), "seen.out")
	test.config{
		trim_whitespace_on_save = true,
		on_save = true,
		commands = {text = test.stub("tee " .. qed.shell_quote(seen))},
	}
	test.key("Ctrl+s")
	test.wait(function() return not buffer:modified() and qed.fs.exists(seen) end)
	test.eq(qed.fs.read(seen), "foo\nbar", "the formatter's stdin is already trimmed")
end

function tests.quit_save_all(test)
	local buffer = test.open("a.txt", "foo  \nbar")
	test.config{
		on_save = true,
		trim_whitespace_on_save = true,
		final_newline_on_save = true,
		commands = {text = test.stub("tr 'a-z' 'A-Z'")},
	}
	test.type("z")
	test.key("Ctrl+q")
	test.eq(test.editor().dialog, "quit")
	test.key("Enter")
	test.wait(function() return test.editor().quit end)
	test.eq(disk(buffer), "ZFOO\nBAR\n")
end

function tests.close_save(test)
	qed.close(qed.buf.current())
	local buffer = test.open("a.txt", "baz  ")
	local path = buffer:path()
	test.config{trim_whitespace_on_save = true}
	test.type("!")
	test.key("Ctrl+w")
	test.eq(test.editor().dialog, "close")
	test.key("Enter")
	test.eq(qed.fs.read(path), "!baz")
	test.ok(not buffer:valid(), "the saved buffer closes")
	test.ok(test.editor().welcome, "saving the last buffer closes it back to the welcome screen")
end

function tests.conflict_overwrite(test)
	local buffer = test.open("a.txt", "first  \nsecond")
	test.config{
		on_save = true,
		trim_whitespace_on_save = true,
		commands = {text = test.stub("tr 'a-z' 'A-Z'")},
	}
	test.type("X")
	qed.fs.write(buffer:path(), "DISK\n")
	test.poll_disk()
	test.key("Ctrl+s")
	test.wait(function() return test.editor().dialog == "conflict" end)
	test.key("Down")
	test.key("Enter")
	test.wait(saved(buffer))
	test.eq(disk(buffer), "XFIRST\nSECOND")
	test.eq(test.editor().disk_conflict, false, "the conflict is resolved")
end

function tests.late_result_after_timeout(test)
	local buffer = test.open("a.txt", "messy")
	test.hook_timeout(50)
	test.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 300})
	test.config{on_save = true, commands = {text = "fakefmt"}}
	test.type("!")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.eq(disk(buffer), "!messy", "the timed-out save goes ahead unformatted")
	test.ok(test.log_has("warn", "Format", "stopped it and saving"), "the slow handler is named")
	test.pump(400)
	test.eq(buffer:text(), "!messy", "nothing lands after the save")
	test.ok(not buffer:modified(), "the buffer stays saved")
end

function tests.late_result_after_close(test)
	local buffer = test.open("a.txt", "messy")
	local path = buffer:path()
	test.hook_timeout(50)
	test.fake_spawn("fakefmt", {stdout = "TIDY\n", delay_ms = 300})
	test.config{on_save = true, commands = {text = "fakefmt"}}
	test.type("!")
	test.key("Ctrl+w")
	test.key("Enter")
	test.wait(function() return not buffer:valid() end)
	test.eq(qed.fs.read(path), "!messy")
	test.pump(400)
end

function tests.non_utf8_output(test)
	local buffer = test.open("a.txt", "caf\xe9")
	test.config{commands = {text = test.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	local text, level = test.message()
	test.ok(text:match("failed: .*UTF%-8"), "reports the invalid output: " .. text)
	test.eq(level, "error")
	test.eq(buffer:text(), "caf\xe9")
end

function tests.lsp_disabled(test)
	test.open("a.txt", "plain")
	test.lsp(false)
	qed.run("Format: Document")
	test.wait(function() return test.message() ~= "" end)
	test.eq((test.message()), "No formatter for this buffer")
end

function tests.save_all_formats_every_buffer(test)
	local stub = test.stub("tr 'a-z' 'A-Z'")
	local first_buffer = test.open("a.txt", "first")
	test.type("x")
	local buffer = test.open("b.txt", "second")
	test.type("y")
	test.config{on_save = true, commands = {text = stub}}
	test.key("Ctrl+q")
	test.key("Enter")
	test.wait(function() return test.editor().quit end)
	test.eq(disk(first_buffer), "XFIRST", "the non-current buffer is formatted")
	test.eq(disk(buffer), "YSECOND")
end

function tests.toggle_survives_reload(test)
	local buffer = test.open("a.txt", "pad  ")
	qed.run("Format: Toggle Trim Whitespace on Save")
	test.config({final_newline_on_save = true}, {hot = true})
	test.key("Ctrl+s")
	test.eq(disk(buffer), "pad\n", "the runtime toggle survives an unrelated reload, the changed knob applies")
	test.config({final_newline_on_save = true, trim_whitespace_on_save = true}, {hot = true})
	test.config({final_newline_on_save = true, trim_whitespace_on_save = false}, {hot = true})
	buffer:set_cursor({row = 1, col = 4})
	test.type("  ")
	test.key("Ctrl+s")
	test.eq(disk(buffer), "pad  \n", "a changed knob overrides the toggle")
end

function tests.toggle_trim(test)
	local buffer = test.open("a.txt", "top\n\n\nbottom")
	qed.run("Format: Toggle Trim Whitespace on Save")
	test.eq((test.message()), "Trim whitespace on save: on")
	buffer:set_cursor({row = 2, col = 1})
	test.type("  ")
	buffer:set_cursor({row = 3, col = 1})
	test.type("   ")
	test.key("Ctrl+s")
	test.expect_line(2, "")
	test.expect_line(3, "")
	expect_cursor(test, buffer, 3, 1)
	test.eq(disk(buffer), "top\n\n\nbottom")
end

function tests.toggles(test)
	local buffer = test.open("a.txt", "pad  ")
	test.config{commands = {text = test.stub("tr 'a-z' 'A-Z'")}}
	qed.run("Format: Toggle Trim Whitespace on Save")
	qed.run("Format: Toggle Final Newline on Save")
	test.eq((test.message()), "Final newline on save: on")
	qed.run("Format: Toggle on Save")
	test.eq((test.message()), "On save: on")
	test.key("Ctrl+s")
	test.wait(saved(buffer))
	test.eq(disk(buffer), "PAD\n")
	qed.run("Format: Toggle on Save")
	test.eq((test.message()), "On save: off")
	test.type("x")
	test.key("Ctrl+s")
	test.eq(disk(buffer), "xPAD\n")
end

return tests

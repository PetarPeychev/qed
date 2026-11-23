local tests = {}

local REPLY = "printf 'Sure, here is the rewrite:\\n```odin\\nreplaced_line := 42\\n```\\nDone.\\n'"
local GHOST = '{"choices":[{"message":{"content":"AAA\\nBBB"}}]}'

local function message_is(test, text)
	return function() return (test.message()) == text end
end

local function select_line(buffer, row)
	buffer:set_selection({row = row, col = 1}, {row = row, col = #buffer:line(row) + 1})
end

local function send(test, instruction)
	test.key("Ctrl+k")
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "prompt" end)
	test.type(instruction)
	test.key("Enter")
end

function tests.edit_applies_fenced_block(test)
	test.config{edit_command = test.stub(REPLY)}
	local buffer = test.open("a.odin", "alpha\n    target line\ngamma")
	select_line(buffer, 2)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit applied"))
	local _, level, source = test.message()
	test.eq(level, "info")
	test.eq(source, "AI")
	test.expect_line(2, "    replaced_line := 42")
	test.eq(buffer:line_count(), 3)
	local from, to = buffer:selection()
	test.eq(from.row, 2, "the selection covers the new text")
	test.eq(to.col, #"    replaced_line := 42" + 1)
	test.key("Ctrl+z")
	test.expect_line(2, "    target line")
	test.eq(buffer:line_count(), 3)
end

function tests.edit_prompt_carries_file_and_instruction(test)
	local dir = qed.root()
	local out = qed.path.join(dir, "prompt.out")
	test.config{edit_command = test.stub(("cat > %s\n%s"):format(qed.shell_quote(out), REPLY))}
	local buffer = test.open("a.odin", "alpha\n    target line\ngamma")
	select_line(buffer, 2)
	send(test, "make it 42")
	test.wait(message_is(test, "Edit applied"))
	local prompt = qed.fs.read(out)
	test.ok(prompt:find("alpha\n<<<SELECT\n    target line\nSELECT>>>\ngamma", 1, true), "the selection is marked in the whole file")
	test.ok(prompt:find("Instruction: make it 42", 1, true), "the instruction is filled in")
	test.ok(prompt:find(buffer:path(), 1, true), "the path is filled in")
	test.ok(test.log_has("debug", "AI", "prompt ("), "the prompt is traced at Debug")
	test.ok(test.log_has("debug", "AI", "response ("), "the response is traced at Debug")
end

function tests.edit_lands_on_its_range_among_duplicates(test)
	test.config{edit_command = test.stub(REPLY)}
	local buffer = test.open("a.odin", "    target line\nmiddle\n    target line\nend")
	select_line(buffer, 3)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit applied"))
	test.expect_line(1, "    target line")
	test.expect_line(3, "    replaced_line := 42")
end

function tests.edit_follows_edits_elsewhere(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 200})
	local buffer = test.open("a.txt", "one\ntwo\nthree")
	select_line(buffer, 2)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit sent (1 running)"))
	test.ok(test.screen(22):find("AI:1", 1, true), "the running count shows in the status bar")
	buffer:insert({row = 1, col = 1}, "zero\n")
	test.step()
	test.wait(message_is(test, "Edit applied"))
	test.expect_line(3, "new")
	test.expect_line(4, "three")
	test.ok(not test.screen(22):find("AI:", 1, true), "the count goes with the last request")
end

function tests.editing_the_range_cancels(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local buffer = test.open("a.txt", "    target line\ngamma")
	select_line(buffer, 1)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit sent (1 running)"))
	test.eq(test.procs(), 1)
	test.type("Z")
	test.eq(test.message(), "Edit cancelled: block edited")
	test.eq(test.procs(), 0, "the command is killed")
	test.expect_line(1, "Z")
end

function tests.second_edit_survives_the_first_landing(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 300})
	local buffer = test.open("a.txt", "one\ntwo\nthree")
	select_line(buffer, 1)
	send(test, "first")
	test.wait(message_is(test, "Edit sent (1 running)"))
	select_line(buffer, 3)
	test.key("Ctrl+k")
	test.wait(function() local ui = test.ui(); return ui ~= nil and ui.kind == "prompt" end)
	test.wait(function() return buffer:line(1) == "new" end)
	test.type("second")
	test.key("Enter")
	test.wait(message_is(test, "Edit sent (1 running)"))
	test.wait(function() return buffer:line(3) == "new" end)
	test.expect_line(2, "two")
end

function tests.prompt_cancel_and_changed_block(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```"})
	local buffer = test.open("a.txt", "one\ntwo")
	select_line(buffer, 1)
	test.key("Ctrl+k")
	test.wait(function() return test.ui() ~= nil end)
	test.key("Esc")
	test.eq(test.ui(), nil)
	test.eq(test.procs(), 0)
	select_line(buffer, 2)
	test.key("Ctrl+k")
	test.wait(function() return test.ui() ~= nil end)
	buffer:insert({row = 2, col = 2}, "X")
	test.type("go")
	test.key("Enter")
	test.wait(message_is(test, "Edit discarded: block changed"))
	test.eq(test.procs(), 0)
	test.expect_line(1, "one")
end

function tests.failed_command_discards(test)
	test.config{edit_command = test.stub("printf '```\\nnew\\n```\\n'; exit 3")}
	local buffer = test.open("a.txt", "hello")
	select_line(buffer, 1)
	send(test, "rewrite")
	test.wait(message_is(test, "Command failed (exit 3)"))
	test.expect_line(1, "hello")
end

function tests.closing_the_buffer_kills_its_edits(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local buffer = test.open("a.txt", "one")
	select_line(buffer, 1)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit sent (1 running)"))
	test.eq(test.procs(), 1)
	test.ok(qed.close(buffer), "an unmodified buffer closes")
	test.step()
	test.eq(test.procs(), 0, "the command is killed")
	test.ok(not test.screen(22):find("AI:", 1, true), "the count goes")
end

function tests.reload_keeps_untouched_edits(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 400})
	local buffer = test.open("a.txt", "one\ntwo\nthree")
	select_line(buffer, 3)
	send(test, "rewrite")
	test.wait(message_is(test, "Edit sent (1 running)"))
	qed.fs.write(buffer:path(), "zero\none\ntwo\nthree")
	test.poll_disk()
	test.step()
	test.eq(test.procs(), 1, "a reload elsewhere keeps the request")
	test.wait(message_is(test, "Edit applied"))
	test.expect_line(4, "new")
	qed.save(buffer)
	test.wait(function() return not buffer:modified() end)
	select_line(buffer, 4)
	send(test, "again")
	test.wait(message_is(test, "Edit sent (1 running)"))
	qed.fs.write(buffer:path(), "zero\none\nTWO\nchanged")
	test.poll_disk()
	test.step()
	test.eq(test.message(), "Edit cancelled: file reloaded")
	test.eq(test.procs(), 0)
end

function tests.tint_marks_the_range_while_running(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local buffer = test.open("a.txt", "one\ntwo\nthree")
	buffer:set_selection({row = 2, col = 1}, {row = 3, col = 1})
	send(test, "rewrite")
	test.wait(message_is(test, "Edit sent (1 running)"))
	buffer:set_cursor({row = 1, col = 1})
	local plain = test.bg(10, 2)
	test.ok(test.bg(10, 1) ~= plain, "the selected row is tinted, a whole-line selection's end row is not")
	qed.run("AI: Cancel Edits")
	test.eq(test.message(), "Cancelled 1 edit(s)")
	test.eq(test.procs(), 0)
	qed.run("AI: Cancel Edits")
	test.eq(test.message(), "No edits running")
	test.eq(test.bg(10, 1), plain, "the tint goes with the request")
end

function tests.edit_takes_the_last_fence_and_keeps_framing(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "Thinking, e.g.\n```lua\nexample()\n```\nSo:\n```lua\n  final()  \n```\n"})
	local buffer = test.open("a.lua", "a\n    old()\nb")
	buffer:set_selection({row = 2, col = 1}, {row = 3, col = 1})
	send(test, "rewrite")
	test.wait(message_is(test, "Edit applied"))
	test.expect_line(2, "    final()")
	test.expect_line(3, "b")
end

function tests.edit_without_a_fence_takes_the_reply(test)
	test.config{edit_command = "fakechat"}
	test.fake_spawn("fakechat", {stdout = "  bare  \n"})
	local buffer = test.open("a.txt", "x old y")
	buffer:set_selection({row = 1, col = 3}, {row = 1, col = 6})
	send(test, "rewrite")
	test.wait(message_is(test, "Edit applied"))
	test.expect_line(1, "x bare y")
end

function tests.edit_empty_result_discarded(test)
	test.config{edit_command = test.stub("printf '   \\n'")}
	local buffer = test.open("a.txt", "hello\nworld")
	select_line(buffer, 1)
	send(test, "rewrite")
	test.wait(message_is(test, "Empty result, discarded"))
	local _, level = test.message()
	test.eq(level, "error")
	test.expect_line(1, "hello")
	test.expect_line(2, "world")
end

function tests.edit_needs_a_selection_and_an_instruction(test)
	test.open("a.txt", "hello")
	test.key("Ctrl+k")
	test.eq(test.message(), "Select a block first")
	test.eq(test.ui(), nil)
	select_line(qed.buf.current(), 1)
	send(test, "")
	test.wait(message_is(test, "Empty instruction"))
	test.eq(test.procs(), 0)
end

-- The first flush only records a new buffer's rev, so settle once before typing.
local function fim_open(test)
	local buffer = test.open("a.txt", "")
	test.step()
	return buffer
end

local function fim_on(test, extra)
	local config = {completion_enabled = true, completion_debounce_ms = 0, completion_api_key_env = "HOME"}
	for key, value in pairs(extra or {}) do
		config[key] = value
	end
	test.config(config)
end

local function ghost_shown(test)
	return function() return test.screen(0):find("abAAA", 1, true) ~= nil end
end

function tests.fim_ghost_lands_and_tab_accepts(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST})
	local buffer = fim_open(test)
	test.type("ab")
	test.wait(ghost_shown(test))
	test.ok(test.screen(1):find("BBB", 1, true), "the second line takes the row below")
	test.ok(test.log_has("debug", "AI", "request fired: prefix=2B suffix=0B"), "the request is traced")
	test.key("Tab")
	test.expect_line(1, "abAAA")
	test.expect_line(2, "BBB")
	test.step()
	test.eq(test.procs(), 0, "an accept is not typing, so no new request")
	test.key("Ctrl+z")
	test.expect_line(1, "ab")
	test.eq(buffer:line_count(), 1)
end

function tests.fim_ctrl_right_accepts_a_word(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST})
	fim_open(test)
	test.type("ab")
	test.wait(ghost_shown(test))
	test.key("Ctrl+Right")
	test.expect_line(1, "abAAA")
	test.ok(test.screen(1):find("BBB", 1, true), "the rest stays shown")
end

function tests.fim_typing_dismisses(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST})
	fim_open(test)
	test.type("ab")
	test.wait(ghost_shown(test))
	test.type("z")
	test.expect_line(1, "abz")
	test.ok(not test.screen(0):find("AAA", 1, true), "an edit drops the ghost")
end

function tests.fim_stale_reply_dropped(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST, delay_ms = 100})
	fim_open(test)
	test.type("ab")
	test.step()
	test.eq(test.procs(), 1)
	test.key("Left")
	test.wait(function() return test.procs() == 0 end)
	test.step()
	test.ok(not test.screen(0):find("AAA", 1, true), "a reply for another cursor is dropped")
	test.ok(test.log_has("debug", "AI", "moved=true"), "and traced")
end

function tests.fim_typing_kills_the_request(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST, delay_ms = 5000})
	fim_open(test)
	test.type("a")
	test.step()
	test.eq(test.procs(), 1)
	test.type("b")
	test.step()
	test.eq(test.procs(), 1, "the old request is killed, a new one runs")
end

function tests.fim_only_on_typing(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = GHOST})
	local buffer = fim_open(test)
	buffer:insert({row = 1, col = 1}, "pasted")
	test.step()
	test.step()
	test.eq(test.procs(), 0, "a plugin edit does not ask")
	test.ok(not test.log_has("debug", "AI", "request fired"))
end

function tests.fim_off_by_default_and_toggle(test)
	test.config{completion_debounce_ms = 0, completion_api_key_env = "HOME"}
	test.fake_spawn("curl", {stdout = GHOST})
	fim_open(test)
	test.type("a")
	test.step()
	test.ok(not test.log_has("debug", "AI", "request fired"), "off by default")
	qed.run("AI: Toggle Inline Completion")
	test.eq(test.message(), "Inline completion: on")
	test.type("b")
	test.wait(ghost_shown(test))
	test.key("Esc")
	test.config{completion_debounce_ms = 0, completion_api_key_env = "HOME", completion_max_tokens = 64}
	test.type("z")
	test.step()
	test.step()
	test.ok(not test.screen(0):find("AAA", 1, true), "a config change keeps the toggled state only until completion_enabled changes")
end

function tests.fim_click_during_debounce_cancels(test)
	fim_on(test, {completion_debounce_ms = 100})
	test.fake_spawn("curl", {stdout = GHOST})
	local buffer = fim_open(test)
	test.type("ab")
	buffer:set_cursor({row = 1, col = 1})
	pcall(test.wait, function() return test.log_has("debug", "AI", "request fired") end, 300)
	test.ok(not test.log_has("debug", "AI", "request fired"), "a moved cursor drops the pending request")
end

function tests.fim_skips_big_buffers_and_caps_context(test)
	fim_on(test)
	test.fake_spawn("curl", {stdout = "{}"})
	local buffer = fim_open(test)
	buffer:insert({row = 1, col = 1}, string.rep("x", 200 * 1024))
	test.step()
	test.type("a")
	test.wait(function() return test.log_has("debug", "AI", "request fired") end)
	test.ok(test.log_has("debug", "AI", "request fired: prefix=65536B suffix=0B"), "the prefix is capped")
	local big = test.open("big.txt", string.rep("abcdefghij\n", 220000))
	test.step()
	test.ok(big:big(), "opened as big")
	test.type("a")
	test.step()
	test.step()
	test.eq(test.procs(), 0, "no request on a big buffer")
end

function tests.fim_header_not_in_argv(test)
	fim_on(test)
	test.fake_spawn("-H @/dev/fd/3 --data-binary @- 3<<EOF\nAuthorization: Bearer $HOME\nEOF", {stdout = GHOST})
	fim_open(test)
	test.type("ab")
	test.wait(ghost_shown(test))
end

function tests.fim_bad_key_env_refused(test)
	fim_on(test, {completion_api_key_env = "HOME; rm -rf x"})
	test.fake_spawn("curl", {stdout = GHOST})
	fim_open(test)
	test.type("a")
	test.step()
	test.step()
	test.eq(test.message(), 'Inline completion: completion_api_key_env "HOME; rm -rf x" is not a variable name')
	test.eq(test.procs(), 0)
end

function tests.fim_missing_key_warns_once(test)
	fim_on(test, {completion_api_key_env = "QED_TEST_NO_SUCH_KEY"})
	fim_open(test)
	test.type("a")
	test.step()
	test.step()
	test.eq(test.message(), "Inline completion: $QED_TEST_NO_SUCH_KEY is not set")
	local _, level = test.message()
	test.eq(level, "warn")
	test.eq(test.procs(), 0)
end

function tests.fim_real_curl(test)
	if not test.sh("command -v curl") then
		return
	end
	local file = qed.path.join(qed.root(), "fim.json")
	qed.fs.write(file, GHOST)
	fim_on(test, {completion_endpoint = "file://" .. file:gsub(" ", "%%20")})
	fim_open(test)
	test.type("ab")
	test.wait(ghost_shown(test))
end

return tests

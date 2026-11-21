local T = {}

local REPLY = "printf 'Sure, here is the rewrite:\\n```odin\\nreplaced_line := 42\\n```\\nDone.\\n'"
local GHOST = '{"choices":[{"message":{"content":"AAA\\nBBB"}}]}'

local function message_is(t, text)
	return function() return (t.message()) == text end
end

local function select_line(b, row)
	qed.buf.set_selection(b, {row = row, col = 1}, {row = row, col = #qed.buf.line(b, row) + 1})
end

local function send(t, instruction)
	t.key("Ctrl+k")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.kind == "prompt" end)
	t.type(instruction)
	t.key("Enter")
end

function T.edit_applies_fenced_block(t)
	t.config{edit_command = t.stub(REPLY)}
	local b = t.open("a.odin", "alpha\n    target line\ngamma")
	select_line(b, 2)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit applied"))
	local _, level, source = t.message()
	t.eq(level, "info")
	t.eq(source, "AI")
	t.expect_line(2, "    replaced_line := 42")
	t.eq(qed.buf.line_count(b), 3)
	local from, to = qed.buf.selection(b)
	t.eq(from.row, 2, "the selection covers the new text")
	t.eq(to.col, #"    replaced_line := 42" + 1)
	t.key("Ctrl+z")
	t.expect_line(2, "    target line")
	t.eq(qed.buf.line_count(b), 3)
end

function T.edit_prompt_carries_file_and_instruction(t)
	local dir = qed.root()
	local out = qed.path.join(dir, "prompt.out")
	t.config{edit_command = t.stub(("cat > %s\n%s"):format(qed.shell_quote(out), REPLY))}
	local b = t.open("a.odin", "alpha\n    target line\ngamma")
	select_line(b, 2)
	send(t, "make it 42")
	t.wait(message_is(t, "Edit applied"))
	local prompt = qed.fs.read(out)
	t.ok(prompt:find("alpha\n<<<SELECT\n    target line\nSELECT>>>\ngamma", 1, true), "the selection is marked in the whole file")
	t.ok(prompt:find("Instruction: make it 42", 1, true), "the instruction is filled in")
	t.ok(prompt:find(qed.buf.path(b), 1, true), "the path is filled in")
	t.ok(t.log_has("debug", "AI", "prompt ("), "the prompt is traced at Debug")
	t.ok(t.log_has("debug", "AI", "response ("), "the response is traced at Debug")
end

function T.edit_lands_on_its_range_among_duplicates(t)
	t.config{edit_command = t.stub(REPLY)}
	local b = t.open("a.odin", "    target line\nmiddle\n    target line\nend")
	select_line(b, 3)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit applied"))
	t.expect_line(1, "    target line")
	t.expect_line(3, "    replaced_line := 42")
end

function T.edit_follows_edits_elsewhere(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 200})
	local b = t.open("a.txt", "one\ntwo\nthree")
	select_line(b, 2)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit sent (1 running)"))
	t.ok(t.screen(22):find("AI:1", 1, true), "the running count shows in the status bar")
	qed.buf.insert(b, {row = 1, col = 1}, "zero\n")
	t.step()
	t.wait(message_is(t, "Edit applied"))
	t.expect_line(3, "new")
	t.expect_line(4, "three")
	t.ok(not t.screen(22):find("AI:", 1, true), "the count goes with the last request")
end

function T.editing_the_range_cancels(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local b = t.open("a.txt", "    target line\ngamma")
	select_line(b, 1)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit sent (1 running)"))
	t.eq(t.procs(), 1)
	t.type("Z")
	t.eq(t.message(), "Edit cancelled: block edited")
	t.eq(t.procs(), 0, "the command is killed")
	t.expect_line(1, "Z")
end

function T.second_edit_survives_the_first_landing(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 300})
	local b = t.open("a.txt", "one\ntwo\nthree")
	select_line(b, 1)
	send(t, "first")
	t.wait(message_is(t, "Edit sent (1 running)"))
	select_line(b, 3)
	t.key("Ctrl+k")
	t.wait(function() local ui = t.ui(); return ui ~= nil and ui.kind == "prompt" end)
	t.wait(function() return qed.buf.line(b, 1) == "new" end)
	t.type("second")
	t.key("Enter")
	t.wait(message_is(t, "Edit sent (1 running)"))
	t.wait(function() return qed.buf.line(b, 3) == "new" end)
	t.expect_line(2, "two")
end

function T.prompt_cancel_and_changed_block(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```"})
	local b = t.open("a.txt", "one\ntwo")
	select_line(b, 1)
	t.key("Ctrl+k")
	t.wait(function() return t.ui() ~= nil end)
	t.key("Esc")
	t.eq(t.ui(), nil)
	t.eq(t.procs(), 0)
	select_line(b, 2)
	t.key("Ctrl+k")
	t.wait(function() return t.ui() ~= nil end)
	qed.buf.insert(b, {row = 2, col = 2}, "X")
	t.type("go")
	t.key("Enter")
	t.wait(message_is(t, "Edit discarded: block changed"))
	t.eq(t.procs(), 0)
	t.expect_line(1, "one")
end

function T.failed_command_discards(t)
	t.config{edit_command = t.stub("printf '```\\nnew\\n```\\n'; exit 3")}
	local b = t.open("a.txt", "hello")
	select_line(b, 1)
	send(t, "rewrite")
	t.wait(message_is(t, "Command failed (exit 3)"))
	t.expect_line(1, "hello")
end

function T.closing_the_buffer_kills_its_edits(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local b = t.open("a.txt", "one")
	select_line(b, 1)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit sent (1 running)"))
	t.eq(t.procs(), 1)
	t.ok(qed.close(b), "an unmodified buffer closes")
	t.step()
	t.eq(t.procs(), 0, "the command is killed")
	t.ok(not t.screen(22):find("AI:", 1, true), "the count goes")
end

function T.reload_keeps_untouched_edits(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 400})
	local b = t.open("a.txt", "one\ntwo\nthree")
	select_line(b, 3)
	send(t, "rewrite")
	t.wait(message_is(t, "Edit sent (1 running)"))
	qed.fs.write(qed.buf.path(b), "zero\none\ntwo\nthree")
	t.poll_disk()
	t.step()
	t.eq(t.procs(), 1, "a reload elsewhere keeps the request")
	t.wait(message_is(t, "Edit applied"))
	t.expect_line(4, "new")
	qed.save(b)
	t.wait(function() return not qed.buf.modified(b) end)
	select_line(b, 4)
	send(t, "again")
	t.wait(message_is(t, "Edit sent (1 running)"))
	qed.fs.write(qed.buf.path(b), "zero\none\nTWO\nchanged")
	t.poll_disk()
	t.step()
	t.eq(t.message(), "Edit cancelled: file reloaded")
	t.eq(t.procs(), 0)
end

function T.tint_marks_the_range_while_running(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "```\nnew\n```", delay_ms = 5000})
	local b = t.open("a.txt", "one\ntwo\nthree")
	qed.buf.set_selection(b, {row = 2, col = 1}, {row = 3, col = 1})
	send(t, "rewrite")
	t.wait(message_is(t, "Edit sent (1 running)"))
	qed.buf.set_cursor(b, {row = 1, col = 1})
	local plain = t.bg(10, 2)
	t.ok(t.bg(10, 1) ~= plain, "the selected row is tinted, a whole-line selection's end row is not")
	qed.run("AI: Cancel Edits")
	t.eq(t.message(), "Cancelled 1 edit(s)")
	t.eq(t.procs(), 0)
	qed.run("AI: Cancel Edits")
	t.eq(t.message(), "No edits running")
	t.eq(t.bg(10, 1), plain, "the tint goes with the request")
end

function T.edit_takes_the_last_fence_and_keeps_framing(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "Thinking, e.g.\n```lua\nexample()\n```\nSo:\n```lua\n  final()  \n```\n"})
	local b = t.open("a.lua", "a\n    old()\nb")
	qed.buf.set_selection(b, {row = 2, col = 1}, {row = 3, col = 1})
	send(t, "rewrite")
	t.wait(message_is(t, "Edit applied"))
	t.expect_line(2, "    final()")
	t.expect_line(3, "b")
end

function T.edit_without_a_fence_takes_the_reply(t)
	t.config{edit_command = "fakechat"}
	t.fake_spawn("fakechat", {stdout = "  bare  \n"})
	local b = t.open("a.txt", "x old y")
	qed.buf.set_selection(b, {row = 1, col = 3}, {row = 1, col = 6})
	send(t, "rewrite")
	t.wait(message_is(t, "Edit applied"))
	t.expect_line(1, "x bare y")
end

function T.edit_empty_result_discarded(t)
	t.config{edit_command = t.stub("printf '   \\n'")}
	local b = t.open("a.txt", "hello\nworld")
	select_line(b, 1)
	send(t, "rewrite")
	t.wait(message_is(t, "Empty result, discarded"))
	local _, level = t.message()
	t.eq(level, "error")
	t.expect_line(1, "hello")
	t.expect_line(2, "world")
end

function T.edit_needs_a_selection_and_an_instruction(t)
	t.open("a.txt", "hello")
	t.key("Ctrl+k")
	t.eq(t.message(), "Select a block first")
	t.eq(t.ui(), nil)
	select_line(qed.buf.current(), 1)
	send(t, "")
	t.wait(message_is(t, "Empty instruction"))
	t.eq(t.procs(), 0)
end

-- The first flush only records a new buffer's rev, so settle once before typing.
local function fim_open(t)
	local b = t.open("a.txt", "")
	t.step()
	return b
end

local function fim_on(t, extra)
	local c = {completion_enabled = true, completion_debounce_ms = 0, completion_api_key_env = "HOME"}
	for k, v in pairs(extra or {}) do
		c[k] = v
	end
	t.config(c)
end

local function ghost_shown(t)
	return function() return t.screen(0):find("abAAA", 1, true) ~= nil end
end

function T.fim_ghost_lands_and_tab_accepts(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST})
	local b = fim_open(t)
	t.type("ab")
	t.wait(ghost_shown(t))
	t.ok(t.screen(1):find("BBB", 1, true), "the second line takes the row below")
	t.ok(t.log_has("debug", "AI", "request fired: prefix=2B suffix=0B"), "the request is traced")
	t.key("Tab")
	t.expect_line(1, "abAAA")
	t.expect_line(2, "BBB")
	t.step()
	t.eq(t.procs(), 0, "an accept is not typing, so no new request")
	t.key("Ctrl+z")
	t.expect_line(1, "ab")
	t.eq(qed.buf.line_count(b), 1)
end

function T.fim_ctrl_right_accepts_a_word(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST})
	fim_open(t)
	t.type("ab")
	t.wait(ghost_shown(t))
	t.key("Ctrl+Right")
	t.expect_line(1, "abAAA")
	t.ok(t.screen(1):find("BBB", 1, true), "the rest stays shown")
end

function T.fim_typing_dismisses(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST})
	fim_open(t)
	t.type("ab")
	t.wait(ghost_shown(t))
	t.type("z")
	t.expect_line(1, "abz")
	t.ok(not t.screen(0):find("AAA", 1, true), "an edit drops the ghost")
end

function T.fim_stale_reply_dropped(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST, delay_ms = 100})
	fim_open(t)
	t.type("ab")
	t.step()
	t.eq(t.procs(), 1)
	t.key("Left")
	t.wait(function() return t.procs() == 0 end)
	t.step()
	t.ok(not t.screen(0):find("AAA", 1, true), "a reply for another cursor is dropped")
	t.ok(t.log_has("debug", "AI", "moved=true"), "and traced")
end

function T.fim_typing_kills_the_request(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST, delay_ms = 5000})
	fim_open(t)
	t.type("a")
	t.step()
	t.eq(t.procs(), 1)
	t.type("b")
	t.step()
	t.eq(t.procs(), 1, "the old request is killed, a new one runs")
end

function T.fim_only_on_typing(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = GHOST})
	local b = fim_open(t)
	qed.buf.insert(b, {row = 1, col = 1}, "pasted")
	t.step()
	t.step()
	t.eq(t.procs(), 0, "a plugin edit does not ask")
	t.ok(not t.log_has("debug", "AI", "request fired"))
end

function T.fim_off_by_default_and_toggle(t)
	t.config{completion_debounce_ms = 0, completion_api_key_env = "HOME"}
	t.fake_spawn("curl", {stdout = GHOST})
	fim_open(t)
	t.type("a")
	t.step()
	t.ok(not t.log_has("debug", "AI", "request fired"), "off by default")
	qed.run("AI: Toggle Inline Completion")
	t.eq(t.message(), "Inline completion: on")
	t.type("b")
	t.wait(ghost_shown(t))
	t.key("Esc")
	t.config{completion_debounce_ms = 0, completion_api_key_env = "HOME", completion_max_tokens = 64}
	t.type("z")
	t.step()
	t.step()
	t.ok(not t.screen(0):find("AAA", 1, true), "a config change keeps the toggled state only until completion_enabled changes")
end

function T.fim_click_during_debounce_cancels(t)
	fim_on(t, {completion_debounce_ms = 100})
	t.fake_spawn("curl", {stdout = GHOST})
	local b = fim_open(t)
	t.type("ab")
	qed.buf.set_cursor(b, {row = 1, col = 1})
	pcall(t.wait, function() return t.log_has("debug", "AI", "request fired") end, 300)
	t.ok(not t.log_has("debug", "AI", "request fired"), "a moved cursor drops the pending request")
end

function T.fim_skips_big_buffers_and_caps_context(t)
	fim_on(t)
	t.fake_spawn("curl", {stdout = "{}"})
	local b = fim_open(t)
	qed.buf.insert(b, {row = 1, col = 1}, string.rep("x", 200 * 1024))
	t.step()
	t.type("a")
	t.wait(function() return t.log_has("debug", "AI", "request fired") end)
	t.ok(t.log_has("debug", "AI", "request fired: prefix=65536B suffix=0B"), "the prefix is capped")
	local big = t.open("big.txt", string.rep("abcdefghij\n", 220000))
	t.step()
	t.ok(qed.buf.big(big), "opened as big")
	t.type("a")
	t.step()
	t.step()
	t.eq(t.procs(), 0, "no request on a big buffer")
end

function T.fim_header_not_in_argv(t)
	fim_on(t)
	t.fake_spawn("-H @/dev/fd/3 --data-binary @- 3<<EOF\nAuthorization: Bearer $HOME\nEOF", {stdout = GHOST})
	fim_open(t)
	t.type("ab")
	t.wait(ghost_shown(t))
end

function T.fim_bad_key_env_refused(t)
	fim_on(t, {completion_api_key_env = "HOME; rm -rf x"})
	t.fake_spawn("curl", {stdout = GHOST})
	fim_open(t)
	t.type("a")
	t.step()
	t.step()
	t.eq(t.message(), 'Inline completion: completion_api_key_env "HOME; rm -rf x" is not a variable name')
	t.eq(t.procs(), 0)
end

function T.fim_missing_key_warns_once(t)
	fim_on(t, {completion_api_key_env = "QED_TEST_NO_SUCH_KEY"})
	fim_open(t)
	t.type("a")
	t.step()
	t.step()
	t.eq(t.message(), "Inline completion: $QED_TEST_NO_SUCH_KEY is not set")
	local _, level = t.message()
	t.eq(level, "warn")
	t.eq(t.procs(), 0)
end

function T.fim_real_curl(t)
	if not t.sh("command -v curl") then
		return
	end
	local file = qed.path.join(qed.root(), "fim.json")
	qed.fs.write(file, GHOST)
	fim_on(t, {completion_endpoint = "file://" .. file:gsub(" ", "%%20")})
	fim_open(t)
	t.type("ab")
	t.wait(ghost_shown(t))
end

return T

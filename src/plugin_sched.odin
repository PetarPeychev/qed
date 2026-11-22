package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import lua "lib:lua"

PLUGIN_HOOK_COUNT :: 100_000
PLUGIN_POOL_MAX :: 16
PLUGIN_FLUSH_ROUNDS :: 16
PLUGIN_LINE_READ_MAX :: 64 * 1024
PLUGIN_SPAWN_READ_MAX :: 1024 * 1024
PLUGIN_SPAWN_OUTPUT_MAX :: 32 * 1024 * 1024
PLUGIN_KILLS_MAX :: 3
PLUGIN_GC_STEP_MS :: 2
PLUGIN_GC_STEP_SIZE_LOG2 :: 9
PLUGIN_GC_HEADROOM :: 1024 * 1024
PLUGIN_GC_DEBT_MS :: 8
PLUGIN_GC_DEBT_STEPS :: 64
PLUGIN_GC_NEAR_CAP_SCALE :: 4

PluginKind :: enum {
	Command,
	When,
	Event,
	Coalesced,
	Timer,
	Setup,
}

PLUGIN_SOFT_MS :: 50
PLUGIN_SETUP_MAX_MS :: 1000

PluginBudget :: struct {
	soft_ms, hard_ms: f64,
}

plugin_budget :: proc(kind: PluginKind) -> PluginBudget {
	switch kind {
	case .Command, .When:
		return {0, f64(PLUGIN_COMMAND_MAX_MS)}
	case .Setup:
		return {2, PLUGIN_SETUP_MAX_MS}
	case .Event, .Coalesced, .Timer:
	}
	return {PLUGIN_SOFT_MS, f64(PLUGIN_SLICE_MAX_MS)}
}

PluginEvent :: enum {
	Startup,
	Buf_Open,
	Buf_Close,
	Buf_Enter,
	Buf_Pre_Save,
	Buf_Save,
	Buf_Reload,
	Buf_Changed,
	Cursor_Moved,
	Language_Changed,
	Root_Changed,
	Config_Changed,
	Theme_Changed,
	Term_Open,
	Term_Exit,
	Term_Close,
	Quit,
	Plugin_Loaded,
	Plugin_Unloaded,
	Custom,
}

plugin_event_names := [PluginEvent]string {
	.Startup          = "startup",
	.Buf_Open         = "buf_open",
	.Buf_Close        = "buf_close",
	.Buf_Enter        = "buf_enter",
	.Buf_Pre_Save     = "buf_pre_save",
	.Buf_Save         = "buf_save",
	.Buf_Reload       = "buf_reload",
	.Buf_Changed      = "buf_changed",
	.Cursor_Moved     = "cursor_moved",
	.Language_Changed = "language_changed",
	.Root_Changed     = "root_changed",
	.Config_Changed   = "config_changed",
	.Theme_Changed    = "theme_changed",
	.Term_Open        = "term_open",
	.Term_Exit        = "term_exit",
	.Term_Close       = "term_close",
	.Quit             = "quit",
	.Plugin_Loaded    = "plugin_loaded",
	.Plugin_Unloaded  = "plugin_unloaded",
	.Custom           = "",
}

PluginWaitKind :: enum {
	None,
	Sleep,
	Proc,
	Save,
	Lsp,
	Pane,
}

PluginWait :: struct {
	kind:  PluginWaitKind,
	until: time.Tick,
	id:    u64,
}

PluginThread :: struct {
	co:  ^lua.State,
	ref: c.int,
}

PluginPooled :: struct {
	thread: PluginThread,
	owner:  string,
}

PluginTask :: struct {
	id:      u64,
	using thread: PluginThread,
	owner:   string,
	kind:    PluginKind,
	event:   PluginEvent,
	wait:    PluginWait,
	command: u64,
	view:    u64,
	source:  u64,
	user:    bool,
	running: bool,
	doomed:  bool,
}

PluginHook :: struct {
	id:    u64,
	event: PluginEvent,
	name:  string,
	owner: string,
	ref:   i32,
	kills: int,
}

PluginTimer :: struct {
	id:       u64,
	owner:    string,
	ref:      i32,
	every_ms: int,
	due:      time.Tick,
	task:     u64,
	kills:    int,
}

PluginProc :: struct {
	id:       u64,
	owner:    string,
	sp:       Subprocess,
	line_ref: i32,
	bg:       bool,
	done:     bool,
	fake:     bool,
	killed:   bool,
	orphan:   bool,
	too_big:  bool,
	due:      time.Tick,
}

PluginSave :: struct {
	id:       u64,
	buf:      u64,
	tasks:    [dynamic]u64,
	deadline: time.Tick,
}

PluginQueued :: struct {
	event:  PluginEvent,
	data:   i32,
	buf:    u64,
	n:      i64,
	a, b:   string,
	only:   string,
	typed:  bool,
	lo, hi: int,
}

PluginLspResult :: struct {
	id:     u64,
	ok:     bool,
	reason: string,
}

PluginFake :: struct {
	pattern, stdout, stderr: string,
	code, delay_ms:          int,
}

PluginSlice :: struct {
	start:   time.Tick,
	hard_ms: f64,
	killed:  bool,
	hot:     ^lua.State,
}

PluginArgs :: enum {
	None,
	Ctx,
	Line,
	Event,
	View,
	View_Item,
	View_Items,
	View_Text,
	View_Int,
	View_Expand,
	View_Submit,
}

PluginStart :: struct {
	ref:      i32,
	args:     PluginArgs,
	line:     string,
	ev:       PluginQueued,
	item_ref: i32,
	item:     int,
	items:    []int,
	pitems:   []PaneItem,
	view_ref: i32,
	command:  u64,
	view:     u64,
	source:   u64,
	user:     bool,
}

plugin_tick_add :: proc(t: time.Tick, ms: int) -> time.Tick {
	return time.tick_add(t, time.Duration(ms) * time.Millisecond)
}

plugin_tick_due :: proc(t, now: time.Tick) -> bool {
	return time.tick_diff(t, now) >= 0
}

plugin_next_id :: proc(p: ^Plugins) -> u64 {
	p.seq += 1
	return p.seq
}

plugin_hook :: proc "c" (L: ^lua.State, ar: rawptr) {
	entry := plugin_entry(L)
	if entry == nil {
		return
	}
	context = entry.ctx
	s := &entry.editor.plugins.slice
	if s.hard_ms <= 0 || (!s.killed && ms_since(s.start) <= s.hard_ms) {
		return
	}
	s.killed = true
	if lua.isyieldable(L) {
		lua.yieldk(L, 0)
		return
	}
	if s.hot == nil && plugin_thread_anchored(&entry.editor.plugins, L) {
		s.hot = L
		lua.sethook(L, plugin_hook, lua.MASKCOUNT, 1)
	}
	lua.pushodinstring(L, fmt.tprintf("exceeded the %.0f ms budget", s.hard_ms))
	lua.error(L)
}

plugin_thread_anchored :: proc(p: ^Plugins, L: ^lua.State) -> bool {
	if L == p.L {
		return true
	}
	for t in p.tasks {
		if t.co == L {
			return true
		}
	}
	for th in p.pool {
		if th.thread.co == L {
			return true
		}
	}
	return false
}

plugin_slice_begin :: proc(p: ^Plugins, kind: PluginKind) -> PluginSlice {
	prev := p.slice
	p.slice = {start = time.tick_now(), hard_ms = plugin_budget(kind).hard_ms}
	return prev
}

plugin_slice_end :: proc(editor: ^Editor, prev: PluginSlice, owner: string, kind: PluginKind, what: string) -> (killed: bool) {
	p := &editor.plugins
	elapsed := time.tick_since(p.slice.start)
	killed = p.slice.killed
	if p.slice.hot != nil {
		lua.sethook(p.slice.hot, plugin_hook, lua.MASKCOUNT, PLUGIN_HOOK_COUNT)
	}
	p.slice = prev
	// the outer slice may be past its limit with too few of its own instructions left for the count hook to see it
	if prev.hard_ms > 0 && !prev.killed && prev.hot == nil && ms_since(prev.start) > prev.hard_ms && p.current != nil && plugin_thread_anchored(p, p.current) {
		p.slice.hot = p.current
		lua.sethook(p.current, plugin_hook, lua.MASKCOUNT, 1)
	}
	soft := plugin_budget(kind).soft_ms
	when ODIN_TEST {
		if test_slice_on {
			test_slice_max[owner] = max(test_slice_max[owner], time.duration_milliseconds(elapsed))
		}
	}
	if ms := time.duration_milliseconds(elapsed); soft > 0 && ms > soft {
		editor_log(editor, .Debug, plugin_label(&editor.plugins, owner), fmt.tprintf("%s took %.2f ms (budget %.0f ms)", what, ms, soft))
	}
	return
}

plugin_kind_label :: proc(kind: PluginKind, ev: PluginEvent) -> string {
	switch kind {
	case .Command:
		return "command"
	case .When:
		return "command when"
	case .Event, .Coalesced:
		return fmt.tprintf("%s handler", plugin_event_names[ev] if ev != .Custom else "custom event")
	case .Timer:
		return "timer"
	case .Setup:
		return "setup"
	}
	return ""
}

plugin_thread_new_c :: proc "c" (L: ^lua.State) -> c.int {
	th := (^PluginThread)(lua.touserdata(L, 1))
	th.co = lua.newthread(L)
	th.ref = lua.L_ref(L, lua.REGISTRYINDEX)
	return 0
}

plugin_thread_get :: proc(editor: ^Editor, owner: string) -> (PluginThread, bool) {
	p := &editor.plugins
	for i := len(p.pool) - 1; i >= 0; i -= 1 {
		if p.pool[i].owner == owner {
			th := p.pool[i].thread
			ordered_remove(&p.pool, i)
			return th, true
		}
	}
	th: PluginThread
	lua.pushcfunction(p.L, plugin_thread_new_c)
	lua.pushlightuserdata(p.L, &th)
	ok, _, _ := plugin_call(editor, 1, 0)
	return th, ok
}

plugin_thread_put :: proc(editor: ^Editor, th: PluginThread, owner: string) {
	p := &editor.plugins
	entry: PluginEntry
	prev := plugin_enter(editor, &entry)
	prev_slice := plugin_slice_begin(p, .Event)
	lua.closethread(th.co, p.current)
	plugin_slice_end(editor, prev_slice, owner, .Event, "__close")
	plugin_leave(editor, prev)
	if len(p.pool) >= PLUGIN_POOL_MAX {
		lua.L_unref(p.L, lua.REGISTRYINDEX, p.pool[0].thread.ref)
		ordered_remove(&p.pool, 0)
	}
	append(&p.pool, PluginPooled{th, owner})
}

plugin_task_index :: proc(p: ^Plugins, id: u64) -> int {
	for t, i in p.tasks {
		if t.id == id {
			return i
		}
	}
	return -1
}

plugin_task_alive :: proc(p: ^Plugins, id: u64) -> bool {
	return id != 0 && plugin_task_index(p, id) >= 0
}

plugin_task_free :: proc(editor: ^Editor, i: int) {
	p := &editor.plugins
	th, owner := p.tasks[i].thread, p.tasks[i].owner
	ordered_remove(&p.tasks, i)
	for j := len(p.calls) - 1; j >= 0; j -= 1 {
		if p.calls[j].co == th.co {
			ordered_remove(&p.calls, j)
		}
	}
	plugin_thread_put(editor, th, owner)
}

plugin_co_k :: proc "c" (L: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	return 0
}

plugin_co_main :: proc "c" (L: ^lua.State) -> c.int {
	entry := plugin_entry(L)
	context = entry.ctx
	start := (^PluginStart)(lua.touserdata(L, 1))
	lua.settop(L, 0)
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.ref))
	nargs: c.int
	switch start.args {
	case .None:
	case .Ctx:
		t := plugin_task_of(&entry.editor.plugins, L)
		plugin_ctx_push(L, entry.editor, t.owner if t != nil else "", true)
		nargs = 1
	case .Line:
		lua.pushodinstring(L, start.line)
		nargs = 1
	case .Event:
		nargs = plugin_event_push(L, start.ev)
	case .View:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		nargs = 1
	case .View_Item:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		if len(start.pitems) > 0 {
			api_pane_item_push(L, start.pitems[0])
		} else {
			lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.item_ref))
			lua.rawgeti(L, -1, lua.Integer(start.item))
			lua.remove(L, -2)
		}
		nargs = 2
	case .View_Items:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		if len(start.pitems) > 0 {
			lua.createtable(L, c.int(len(start.pitems)), 0)
			for it, i in start.pitems {
				api_pane_item_push(L, it)
				lua.rawseti(L, -2, lua.Integer(i + 1))
			}
		} else {
			lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.item_ref))
			lua.createtable(L, c.int(len(start.items)), 0)
			for idx, i in start.items {
				lua.rawgeti(L, -2, lua.Integer(idx + 1))
				lua.rawseti(L, -2, lua.Integer(i + 1))
			}
			lua.remove(L, -2)
		}
		nargs = 2
	case .View_Text:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		lua.pushodinstring(L, start.line)
		nargs = 2
	case .View_Int:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		lua.pushinteger(L, lua.Integer(start.item))
		nargs = 2
	case .View_Expand:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		api_pane_item_push(L, start.pitems[0])
		lua.pushboolean(L, b32(start.item != 0))
		nargs = 3
	case .View_Submit:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(start.view_ref))
		if start.item != 0 {
			lua.pushodinstring(L, start.line)
		} else {
			lua.pushnil(L)
		}
		nargs = 2
	}
	lua.call(L, nargs, 0, 0, plugin_co_k)
	return 0
}

plugin_event_push :: proc(L: ^lua.State, q: PluginQueued) -> c.int {
	#partial switch q.event {
	case .Startup, .Theme_Changed, .Quit:
		return 0
	case .Config_Changed:
		lua.createtable(L, 0, 2)
		for k in strings.split(q.a, "\n", context.temp_allocator) {
			if k != "" {
				lua.pushboolean(L, true)
				lua.setfield(L, -2, strings.clone_to_cstring(k, context.temp_allocator))
			}
		}
		return 1
	case .Buf_Changed:
		lua.pushinteger(L, lua.Integer(q.buf))
		lua.pushinteger(L, lua.Integer(q.n))
		lua.pushboolean(L, b32(q.typed))
		lua.pushinteger(L, lua.Integer(q.lo))
		lua.pushinteger(L, lua.Integer(q.hi))
		return 5
	case .Buf_Close:
		lua.pushinteger(L, lua.Integer(q.buf))
		lua.pushodinstring(L, q.a)
		return 2
	case .Root_Changed:
		lua.pushodinstring(L, q.a)
		lua.pushodinstring(L, q.b)
		return 2
	case .Term_Exit:
		lua.pushodinstring(L, q.a)
		lua.pushinteger(L, lua.Integer(q.n))
		return 2
	case .Term_Open, .Term_Close, .Plugin_Loaded, .Plugin_Unloaded:
		lua.pushodinstring(L, q.a)
		return 1
	case .Custom:
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(q.data))
		return 1
	}
	lua.pushinteger(L, lua.Integer(q.buf))
	return 1
}

plugin_task_start :: proc(editor: ^Editor, owner: string, kind: PluginKind, start: PluginStart) -> (id: u64, finished: bool) {
	p := &editor.plugins
	if p.L == nil {
		return 0, true
	}
	th, ok := plugin_thread_get(editor, owner)
	if !ok {
		if pl := plugin_find(p, owner); pl != nil {
			plugin_error(editor, pl, "cannot start a coroutine (out of memory)", "", false)
		}
		return 0, true
	}
	id = plugin_next_id(p)
	append(&p.tasks, PluginTask{id = id, thread = th, owner = owner, kind = kind, event = start.ev.event, command = start.command, view = start.view, source = start.source, user = start.user})
	start := start
	lua.pushcfunction(th.co, plugin_co_main)
	lua.pushlightuserdata(th.co, &start)
	plugin_task_resume(editor, id, 1)
	return id, !plugin_task_alive(p, id)
}

plugin_traceback_c :: proc "c" (L: ^lua.State) -> c.int {
	context = plugin_entry(L).ctx
	co := (^lua.State)(lua.touserdata(L, 1))
	n: c.size_t
	msg := lua.L_tostring(L, 2, &n)
	if strings.contains(string((cast([^]u8)msg)[:n]), "\nstack traceback:") {
		return 1
	}
	lua.L_traceback(L, co, msg, 0)
	return 1
}

plugin_task_error :: proc(editor: ^Editor, co: ^lua.State) -> (message, traceback: string) {
	p := &editor.plugins
	if lua.checkstack(p.L, 3) == 0 {
		return "error (out of memory)", ""
	}
	lua.pushcfunction(p.L, plugin_traceback_c)
	lua.pushlightuserdata(p.L, co)
	lua.xmove(co, p.L, 1)
	ok, msg, tb := plugin_call(editor, 2, 1)
	if !ok {
		return msg, tb
	}
	full, _ := lua.toodinstring(p.L, -1)
	full = strings.clone(full, context.temp_allocator)
	lua.pop(p.L, 1)
	if i := strings.index(full, "\nstack traceback:"); i >= 0 {
		return full[:i], full[i + 1:]
	}
	return full, ""
}

plugin_task_resume :: proc(editor: ^Editor, id: u64, nargs: c.int) {
	p := &editor.plugins
	i := plugin_task_index(p, id)
	if i < 0 {
		return
	}
	t := &p.tasks[i]
	co, kind, owner, ev, source := t.co, t.kind, t.owner, t.event, t.source
	t.running = true
	t.wait = {}
	p.resumes += 1
	prev_slice := plugin_slice_begin(p, kind)
	entry: PluginEntry
	prev := plugin_enter(editor, &entry)
	from := p.current
	p.current = co
	nres: c.int
	status := lua.resume(co, from, nargs, &nres)
	p.current = from
	plugin_leave(editor, prev)
	label := plugin_kind_label(kind, ev)
	killed := plugin_slice_end(editor, prev_slice, owner, kind, label)
	i = plugin_task_index(p, id)
	if i < 0 {
		return
	}
	t = &p.tasks[i]
	t.running = false
	if t.doomed {
		plugin_task_free(editor, i)
		return
	}
	message, traceback: string
	switch {
	case killed:
		message = fmt.tprintf("%s exceeded its %.0f ms budget and was stopped", label, plugin_budget(kind).hard_ms)
	case status == .YIELD && t.wait.kind == .None:
		message = "coroutine.yield is not allowed in a plugin entry (use qed.sleep, qed.spawn, ...)"
	case status == .YIELD:
		return
	case status == .OK:
		plugin_task_free(editor, i)
		if source != 0 {
			plugin_source_clean(p, source)
		}
		return
	case status == .ERRMEM:
	case:
		message, traceback = plugin_task_error(editor, co)
	}
	i = plugin_task_index(p, id)
	if i >= 0 {
		plugin_task_free(editor, i)
	}
	if status == .ERRMEM {
		lua.gc(p.L, .COLLECT)
		plugin_gc_rebase(p)
		mb :: 1024 * 1024
		message = fmt.tprintf("%s ran out of Lua memory and was stopped (cap %d MB, %.1f MB in use after a full collection)", label, p.mem.cap / mb, f64(p.mem.used) / mb)
	}
	pl := plugin_find(p, owner)
	if pl != nil {
		plugin_error(editor, pl, message, traceback, false, .Warn if killed else .Error)
	}
	if killed && source != 0 && plugin_source_killed(p, source) && pl != nil {
		plugin_error(editor, pl, fmt.tprintf("%s was stopped by its budget %d times in a row and was removed", label, PLUGIN_KILLS_MAX), "", false)
	}
}

plugin_source_killed :: proc(p: ^Plugins, source: u64) -> (removed: bool) {
	if i := plugin_timer_index(p, source); i >= 0 {
		p.timers[i].kills += 1
		if p.timers[i].kills >= PLUGIN_KILLS_MAX {
			plugin_timer_remove(p, i)
			return true
		}
	} else if i := plugin_hook_index(p, source); i >= 0 {
		p.hooks[i].kills += 1
		if p.hooks[i].kills >= PLUGIN_KILLS_MAX {
			plugin_hook_remove(p, i)
			return true
		}
	}
	return false
}

plugin_source_clean :: proc(p: ^Plugins, source: u64) {
	if i := plugin_timer_index(p, source); i >= 0 {
		p.timers[i].kills = 0
	} else if i := plugin_hook_index(p, source); i >= 0 {
		p.hooks[i].kills = 0
	}
}

plugin_task_of :: proc(p: ^Plugins, L: ^lua.State) -> ^PluginTask {
	for &t in p.tasks {
		if t.co == L && t.running {
			return &t
		}
	}
	return nil
}

api_await :: proc(L: ^lua.State, p: ^Plugins, what: string) -> ^PluginTask {
	if p.edit_depth > 0 {
		plugin_raise(L, fmt.tprintf("%s cannot wait inside qed.edit", what))
	}
	t := plugin_task_of(p, L)
	if t == nil || p.current != L || !lua.isyieldable(L) {
		plugin_raise(L, fmt.tprintf("%s can only wait in a command, event handler or timer", what))
	}
	return t
}

plugin_emit :: proc(editor: ^Editor, q: PluginQueued, pending: ^[dynamic]u64 = nil) {
	p := &editor.plugins
	if p.L == nil || p.subs[q.event] == 0 {
		return
	}
	about := q.event == .Plugin_Loaded || q.event == .Plugin_Unloaded
	ids := make([dynamic]u64, context.temp_allocator)
	for pl in p.list {
		if pl.state != .Enabled || (q.only != "" && q.only != pl.name) || (about && pl.name == q.a) {
			continue
		}
		for h in p.hooks {
			if h.event == q.event && h.owner == pl.name && (q.event != .Custom || h.name == q.a) {
				append(&ids, h.id)
			}
		}
	}
	kind := PluginKind.Coalesced if q.event == .Buf_Changed || q.event == .Cursor_Moved else .Event
	for hid in ids {
		owner: string
		ref: i32
		for h in p.hooks {
			if h.id == hid {
				owner, ref = h.owner, h.ref
			}
		}
		if ref == 0 {
			continue
		}
		id, finished := plugin_task_start(editor, owner, kind, {ref = ref, args = .Event, ev = q, source = hid})
		if !finished && pending != nil {
			append(pending, id)
		}
	}
}

plugin_queue :: proc(editor: ^Editor, q: PluginQueued) {
	p := &editor.plugins
	if p.L == nil || p.subs[q.event] == 0 {
		return
	}
	q := q
	q.a = strings.clone(q.a)
	q.b = strings.clone(q.b)
	append(&p.queue, q)
}

plugin_buffers_check :: proc(editor: ^Editor) {
	if editor.welcome {
		return
	}
	for &b in editor.buffers {
		if !b.plugin_seen {
			b.plugin_seen = true
			b.plugin_rev = b.rev
			b.plugin_cursor = b.cursor
			b.plugin_dirty = false
			continue
		}
		if b.rev != b.plugin_rev {
			b.plugin_rev = b.rev
			last := len(b.lines)
			lo, hi := 1, last
			if b.plugin_dirty {
				lo, hi = clamp(b.plugin_lo + 1, 1, last), clamp(b.plugin_hi + 1, 1, last)
			}
			b.plugin_dirty = false
			plugin_queue(editor, {event = .Buf_Changed, buf = b.id, n = i64(b.rev), typed = b.typed_rev == b.rev, lo = lo, hi = hi})
		}
		if b.cursor != b.plugin_cursor {
			b.plugin_cursor = b.cursor
			plugin_queue(editor, {event = .Cursor_Moved, buf = b.id})
		}
	}
}

plugin_flush :: proc(editor: ^Editor) -> (ran: bool) {
	p := &editor.plugins
	if p.L == nil {
		return false
	}
	plugin_views_flush(editor)
	settled := false
	for _ in 0 ..< PLUGIN_FLUSH_ROUNDS {
		plugin_buffers_check(editor)
		if len(p.queue) == 0 {
			settled = true
			break
		}
		batch := p.queue
		p.queue = {}
		for q in batch {
			plugin_emit(editor, q)
			delete(q.a)
			delete(q.b)
			if q.data != 0 {
				lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(q.data))
			}
		}
		delete(batch)
		ran = true
	}
	if !settled {
		changed := 0
		for b in editor.buffers {
			changed += int(b.rev != b.plugin_rev || b.cursor != b.plugin_cursor)
		}
		if len(p.queue) > 0 || changed > 0 do editor_log(editor, .Debug, "plugins", fmt.tprintf("all %d flush rounds used: %d events queued, %d buffers changed again; the rest waits for the next flush", PLUGIN_FLUSH_ROUNDS, len(p.queue), changed), false)
	}
	plugins_keybinds_check(editor)
	editor.jump_lock = false
	return
}

plugin_hook_index :: proc(p: ^Plugins, id: u64) -> int {
	for h, i in p.hooks {
		if h.id == id {
			return i
		}
	}
	return -1
}

plugin_hook_remove :: proc(p: ^Plugins, i: int) {
	h := p.hooks[i]
	lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(h.ref))
	p.subs[h.event] -= 1
	ordered_remove(&p.hooks, i)
}

plugin_timer_index :: proc(p: ^Plugins, id: u64) -> int {
	for t, i in p.timers {
		if t.id == id {
			return i
		}
	}
	return -1
}

plugin_timer_remove :: proc(p: ^Plugins, i: int) {
	lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(p.timers[i].ref))
	ordered_remove(&p.timers, i)
}

plugin_proc_index :: proc(p: ^Plugins, id: u64) -> int {
	for pr, i in p.procs {
		if pr.id == id {
			return i
		}
	}
	return -1
}

plugin_proc_stop :: proc(pr: ^PluginProc) {
	if pr.done {
		return
	}
	pr.done = true
	if pr.fake || !pr.sp.running {
		return
	}
	subprocess_kill_group(&pr.sp)
	subprocess_close_pipes(&pr.sp)
	state, _ := os.process_wait(pr.sp.process, time.Second)
	pr.sp.exit_code = state.exit_code
	pr.sp.running = false
}

plugin_proc_free :: proc(p: ^Plugins, i: int) {
	pr := &p.procs[i]
	pr.killed = true
	plugin_proc_stop(pr)
	if pr.line_ref != 0 {
		lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(pr.line_ref))
	}
	subprocess_destroy(&pr.sp)
	ordered_remove(&p.procs, i)
}

plugin_save_index :: proc(p: ^Plugins, id: u64) -> int {
	for s, i in p.saves {
		if s.id == id {
			return i
		}
	}
	return -1
}

plugin_save_pending :: proc(p: ^Plugins, buf: u64) -> bool {
	if p.presave == buf && buf != 0 {
		return true
	}
	for s in p.saves {
		if s.buf == buf {
			return true
		}
	}
	return false
}

plugin_pre_save :: proc(editor: ^Editor, buf: u64) -> (save: u64) {
	p := &editor.plugins
	if p.L == nil || p.subs[.Buf_Pre_Save] == 0 {
		return 0
	}
	pending := make([dynamic]u64)
	prev := p.presave
	p.presave = buf
	plugin_emit(editor, {event = .Buf_Pre_Save, buf = buf}, &pending)
	p.presave = prev
	if len(pending) == 0 {
		delete(pending)
		return 0
	}
	save = plugin_next_id(p)
	append(&p.saves, PluginSave{id = save, buf = buf, tasks = pending, deadline = plugin_tick_add(time.tick_now(), PLUGIN_HOOK_TIMEOUT_MS)})
	return save
}

plugin_pending_prune :: proc(p: ^Plugins, ids: ^[dynamic]u64) {
	for i := len(ids) - 1; i >= 0; i -= 1 {
		if !plugin_task_alive(p, ids[i]) {
			ordered_remove(ids, i)
		}
	}
}

plugin_pending_owners :: proc(p: ^Plugins, ids: []u64) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for id in ids {
		if i := plugin_task_index(p, id); i >= 0 {
			owner := p.tasks[i].owner
			seen := false
			for n in names {
				seen ||= n == owner
			}
			if !seen {
				append(&names, owner)
			}
		}
	}
	return names[:]
}

plugin_waiters :: proc(p: ^Plugins, kind: PluginWaitKind, id: u64) -> []u64 {
	ids := make([dynamic]u64, context.temp_allocator)
	for t in p.tasks {
		if t.wait.kind == kind && t.wait.id == id {
			append(&ids, t.id)
		}
	}
	return ids[:]
}

plugin_due :: proc(editor: ^Editor) -> bool {
	return editor.plugins.L != nil && plugin_timeout_ms(editor, 1) == 0
}

plugin_lsp_done :: proc(editor: ^Editor, id: u64, ok: bool, reason: string) {
	p := &editor.plugins
	if p.L == nil || id == 0 {
		return
	}
	append(&p.lsp_results, PluginLspResult{id, ok, reason})
}

plugin_lsp_wanted :: proc(editor: ^Editor, id: u64) -> bool {
	return id == 0 || len(plugin_waiters(&editor.plugins, .Lsp, id)) > 0
}

plugin_task_kill :: proc(editor: ^Editor, id: u64) {
	p := &editor.plugins
	i := plugin_task_index(p, id)
	if i < 0 {
		return
	}
	if w := p.tasks[i].wait; w.kind == .Proc {
		if j := plugin_proc_index(p, w.id); j >= 0 && !p.procs[j].bg {
			plugin_proc_free(p, j)
		}
	}
	if i = plugin_task_index(p, id); i < 0 {
		return
	}
	if p.tasks[i].running {
		p.tasks[i].doomed = true
	} else {
		plugin_task_free(editor, i)
	}
}

plugin_lsp_result :: proc(p: ^Plugins, id: u64) -> (PluginLspResult, bool) {
	for r in p.lsp_results {
		if r.id == id {
			return r, true
		}
	}
	return {}, false
}

plugin_busy :: proc(editor: ^Editor) -> bool {
	p := &editor.plugins
	if p.startup_due || len(p.saves) > 0 || len(p.queue) > 0 || len(p.lsp_results) > 0 || len(p.view_events) > 0 || plugin_views_due(editor) {
		return true
	}
	for pr in p.procs {
		if !pr.done {
			return true
		}
	}
	return false
}

plugin_timeout_ms :: proc(editor: ^Editor, cap: int) -> int {
	p := &editor.plugins
	now := time.tick_now()
	best := cap
	consider :: proc(best: ^int, now, t: time.Tick) {
		ms := int(time.duration_milliseconds(time.tick_diff(now, t)))
		best^ = clamp(ms + 1, 0, best^)
	}
	for t in p.timers {
		consider(&best, now, t.due)
	}
	for t in p.tasks {
		if t.wait.kind == .Sleep || t.wait.kind == .Lsp {
			consider(&best, now, t.wait.until)
		}
	}
	for pr in p.procs {
		if pr.fake && !pr.done {
			consider(&best, now, pr.due)
		}
	}
	for s in p.saves {
		consider(&best, now, s.deadline)
	}
	for q in editor.panes {
		if q.ctx.lua && q.query_due {
			consider(&best, now, q.query_at)
		}
	}
	return best
}

plugin_proc_lines :: proc(editor: ^Editor, id: u64, final: bool) {
	p := &editor.plugins
	i := plugin_proc_index(p, id)
	if i < 0 || p.procs[i].line_ref == 0 || p.procs[i].killed {
		return
	}
	pr := &p.procs[i]
	buf := &pr.sp.out.buf
	lines := make([dynamic]string, context.temp_allocator)
	pos := 0
	for {
		rest := string(buf[pos:])
		nl := strings.index_byte(rest, '\n')
		if nl < 0 {
			if final && len(rest) > 0 {
				append(&lines, strings.clone(rest, context.temp_allocator))
				pos = len(buf)
			}
			break
		}
		append(&lines, strings.clone(strings.trim_suffix(rest[:nl], "\r"), context.temp_allocator))
		pos += nl + 1
	}
	copy(buf[:], buf[pos:])
	resize(buf, len(buf) - pos)
	owner, ref := pr.owner, pr.line_ref
	for line in lines {
		if i = plugin_proc_index(p, id); i < 0 || p.procs[i].killed {
			return
		}
		plugin_task_start(editor, owner, .Timer, {ref = ref, args = .Line, line = line})
	}
}

plugin_proc_finish :: proc(editor: ^Editor, id: u64) {
	p := &editor.plugins
	plugin_proc_lines(editor, id, true)
	i := plugin_proc_index(p, id)
	if i < 0 {
		return
	}
	p.procs[i].done = true
	waiters := plugin_waiters(p, .Proc, id)
	for w in waiters {
		plugin_task_resume(editor, w, 0)
	}
	if i = plugin_proc_index(p, id); i >= 0 && len(waiters) == 0 && (!p.procs[i].bg || p.procs[i].orphan) {
		plugin_proc_free(p, i)
	}
}

plugin_pump :: proc(editor: ^Editor) -> (ran: bool) {
	p := &editor.plugins
	if p.L == nil {
		return false
	}
	resumes := p.resumes
	if p.startup_due {
		p.startup_due = false
		plugin_queue(editor, {event = .Startup})
	}
	now := time.tick_now()

	due := make([dynamic]u64, context.temp_allocator)
	for t in p.timers {
		if plugin_tick_due(t.due, now) {
			append(&due, t.id)
		}
	}
	for id in due {
		i := plugin_timer_index(p, id)
		if i < 0 {
			continue
		}
		t := p.timers[i]
		if t.every_ms > 0 {
			p.timers[i].due = plugin_tick_add(now, t.every_ms)
			if plugin_task_alive(p, t.task) {
				continue
			}
		} else {
			ordered_remove(&p.timers, i)
		}
		task, finished := plugin_task_start(editor, t.owner, .Timer, {ref = t.ref, source = t.id if t.every_ms > 0 else 0})
		if t.every_ms == 0 {
			lua.L_unref(p.L, lua.REGISTRYINDEX, c.int(t.ref))
		} else if i = plugin_timer_index(p, id); i >= 0 && !finished {
			p.timers[i].task = task
		}
	}

	clear(&due)
	for t in p.tasks {
		if t.wait.kind == .Sleep && plugin_tick_due(t.wait.until, now) {
			append(&due, t.id)
		}
	}
	for id in due {
		plugin_task_resume(editor, id, 0)
	}

	clear(&due)
	for pr in p.procs {
		if !pr.done {
			append(&due, pr.id)
		}
	}
	for id in due {
		i := plugin_proc_index(p, id)
		if i < 0 {
			continue
		}
		pr := &p.procs[i]
		if pr.fake {
			if plugin_tick_due(pr.due, now) {
				plugin_proc_finish(editor, id)
			}
			continue
		}
		eof := subprocess_drain(&pr.sp, PLUGIN_LINE_READ_MAX if pr.line_ref != 0 else PLUGIN_SPAWN_READ_MAX, PLUGIN_SPAWN_READ_MAX)
		plugin_proc_lines(editor, id, false)
		if i = plugin_proc_index(p, id); i < 0 || p.procs[i].done {
			continue
		}
		if pr = &p.procs[i]; len(pr.sp.out.buf) + len(pr.sp.err.buf) > PLUGIN_SPAWN_OUTPUT_MAX {
			pr.too_big = true
			pr.killed = true
			plugin_proc_stop(pr)
			plugin_proc_finish(editor, id)
			continue
		}
		if eof && subprocess_reap(&pr.sp) {
			plugin_proc_finish(editor, id)
		}
	}

	for i := len(p.procs) - 1; i >= 0; i -= 1 {
		if i < len(p.procs) && p.procs[i].done && p.procs[i].orphan && len(plugin_waiters(p, .Proc, p.procs[i].id)) == 0 {
			plugin_proc_free(p, i)
		}
	}

	for t in p.tasks {
		if t.wait.kind == .Lsp && plugin_tick_due(t.wait.until, now) {
			plugin_lsp_done(editor, t.wait.id, false, "timeout")
		}
	}
	for i := 0; i < len(p.lsp_results); i += 1 {
		for w in plugin_waiters(p, .Lsp, p.lsp_results[i].id) {
			plugin_task_resume(editor, w, 0)
		}
	}
	clear(&p.lsp_results)

	plugin_views_pump(editor)
	plugins_errors_flush(editor)

	clear(&due)
	for s in p.saves {
		append(&due, s.id)
	}
	for id in due {
		i := plugin_save_index(p, id)
		if i < 0 {
			continue
		}
		s := &p.saves[i]
		plugin_pending_prune(p, &s.tasks)
		late := plugin_tick_due(s.deadline, now)
		if len(s.tasks) > 0 && !late {
			continue
		}
		for owner in plugin_pending_owners(p, s.tasks[:]) {
			editor_log(editor, .Warn, plugin_label(&editor.plugins, owner), fmt.tprintf("buf_pre_save handler still running after %d ms, stopped it and saving", PLUGIN_HOOK_TIMEOUT_MS))
		}
		buf, tasks := s.buf, s.tasks
		ordered_remove(&p.saves, i)
		for task in tasks {
			plugin_task_kill(editor, task)
		}
		delete(tasks)
		editor_save_id(editor, buf)
		for w in plugin_waiters(p, .Save, id) {
			plugin_task_resume(editor, w, 0)
		}
	}

	pane_stack_sync(editor)
	if !editor.pasting {
		plugin_flush(editor)
	}
	if p.resumes != resumes {
		editor.jump_lock = false
		ran = true
	}
	plugin_gc_step(editor)
	return
}

plugin_gc_rebase :: proc(p: ^Plugins) {
	p.gc_base, p.gc_active, p.gc_debt = p.mem.used, false, 0
}

// a cycle starts once the heap doubles, as Lua's default pause, or halfway from the last cycle's heap to the cap
plugin_gc_threshold :: proc(p: ^Plugins) -> int {
	at := 2 * p.gc_base
	if p.mem.cap > 0 {
		at = min(at, (p.gc_base + p.mem.cap) / 2)
	}
	return max(at, p.gc_base + PLUGIN_GC_HEADROOM)
}

plugin_gc_due :: proc(p: ^Plugins) -> bool {
	if p.L == nil {
		return false
	}
	// an emergency or a plugin's own collection shrank the heap behind the pacer's back
	if !p.gc_active && p.mem.used < p.gc_base {
		p.gc_base = p.mem.used
		when ODIN_TEST {
			test_gc_shrinks += 1
		}
	}
	return p.gc_active || p.mem.used >= plugin_gc_threshold(p)
}

plugin_gc_step :: proc(editor: ^Editor) {
	p := &editor.plugins
	defer p.gc_seen = p.mem.used
	if !plugin_gc_due(p) {
		return
	}
	if p.gc_active {
		p.gc_debt += max(p.mem.used - p.gc_seen, 0)
	}
	p.gc_active = true
	scale := PLUGIN_GC_NEAR_CAP_SCALE if p.mem.cap > 0 && p.mem.used > p.mem.cap / 2 else 1
	debt_steps := 0
	entry: PluginEntry
	prev := plugin_enter(editor, &entry)
	start := time.tick_now()
	// at least one step per call, so progress never depends on the clock
	for {
		when ODIN_TEST {
			frees := test_alloc_frees
		}
		done := lua.gc(p.L, .STEP, c.int(0)) != 0
		when ODIN_TEST {
			test_gc_steps += 1
			test_gc_cycles += int(done)
			test_gc_step_frees_max = max(test_gc_step_frees_max, test_alloc_frees - frees)
		}
		if done {
			plugin_gc_rebase(p)
			break
		}
		p.gc_debt -= 1 << PLUGIN_GC_STEP_SIZE_LOG2
		elapsed := ms_since(start)
		if elapsed < PLUGIN_GC_STEP_MS {
			continue
		}
		if p.gc_debt <= 0 || elapsed >= f64(PLUGIN_GC_DEBT_MS * scale) || debt_steps >= PLUGIN_GC_DEBT_STEPS * scale {
			break
		}
		debt_steps += 1
	}
	plugin_leave(editor, prev)
	when ODIN_TEST {
		test_gc_debt_steps_max = max(test_gc_debt_steps_max, debt_steps)
		if test_slice_on {
			test_gc_max = max(test_gc_max, ms_since(start))
		}
	}
}

editor_plugins_quit :: proc(editor: ^Editor) {
	p := &editor.plugins
	if p.L == nil || p.subs[.Quit] == 0 {
		return
	}
	if !editor.headless {
		editor_log(editor, .Info, "", "Waiting for plugins...")
		editor_render(editor)
	}
	pending := make([dynamic]u64, context.temp_allocator)
	plugin_emit(editor, {event = .Quit}, &pending)
	deadline := plugin_tick_add(time.tick_now(), PLUGIN_HOOK_TIMEOUT_MS)
	for {
		plugin_pending_prune(p, &pending)
		if len(pending) == 0 {
			return
		}
		if plugin_tick_due(deadline, time.tick_now()) {
			for owner in plugin_pending_owners(p, pending[:]) {
				editor_log(editor, .Warn, plugin_label(&editor.plugins, owner), fmt.tprintf("quit handler still running after %d ms, quitting anyway", PLUGIN_HOOK_TIMEOUT_MS))
			}
			return
		}
		plugin_pump(editor)
		time.sleep(2 * time.Millisecond)
	}
}

plugin_sched_unload :: proc(editor: ^Editor, owner: string) {
	p := &editor.plugins
	for i := len(p.tasks) - 1; i >= 0; i -= 1 {
		if i < len(p.tasks) && p.tasks[i].owner == owner {
			if p.tasks[i].running {
				p.tasks[i].doomed = true
			} else {
				plugin_task_free(editor, i)
			}
		}
	}
	for i := len(p.hooks) - 1; i >= 0; i -= 1 {
		if p.hooks[i].owner == owner {
			plugin_hook_remove(p, i)
		}
	}
	for i := len(p.timers) - 1; i >= 0; i -= 1 {
		if p.timers[i].owner == owner {
			plugin_timer_remove(p, i)
		}
	}
	for i := len(p.procs) - 1; i >= 0; i -= 1 {
		if p.procs[i].owner == owner {
			plugin_proc_free(p, i)
		}
	}
	for i := len(p.pool) - 1; i >= 0; i -= 1 {
		if p.pool[i].owner == owner {
			lua.L_unref(p.L, lua.REGISTRYINDEX, p.pool[i].thread.ref)
			ordered_remove(&p.pool, i)
		}
	}
}

plugin_sched_shutdown :: proc(p: ^Plugins) {
	for &pr in p.procs {
		plugin_proc_stop(&pr)
		subprocess_destroy(&pr.sp)
	}
	delete(p.procs)
	for s in p.saves {
		delete(s.tasks)
	}
	delete(p.saves)
	for q in p.queue {
		delete(q.a)
		delete(q.b)
	}
	delete(p.queue)
	delete(p.tasks)
	delete(p.pool)
	delete(p.hooks)
	delete(p.timers)
	delete(p.fakes)
	delete(p.lsp_results)
}

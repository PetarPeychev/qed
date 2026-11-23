package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "lib:tb2"

@(private = "file")
Churn :: struct {
	dir:  string,
	stop: bool,
}

@(private = "file")
churn_run :: proc(th: ^thread.Thread) {
	churn := (^Churn)(th.data)
	for i := 0; !sync.atomic_load(&churn.stop); i += 1 {
		path := fmt.tprintf("%s/churn_%d", churn.dir, i % 64)
		_ = os.write_entire_file(path, nil)
		os.remove(path)
		free_all(context.temp_allocator)
	}
}

@(test)
e2e_round8_fs_list_survives_entries_vanishing :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	dir := fmt.tprintf("/tmp/qed_r8_churn_%d", posix.getpid())
	os.make_directory(dir)
	defer os.remove_all(dir)
	for i in 0 ..< 200 {
		_ = os.write_entire_file(fmt.tprintf("%s/keep_%03d", dir, i), nil)
	}
	churn := Churn{dir = dir}
	th := thread.create(churn_run)
	th.data = &churn
	thread.start(th)
	got := ft_lua(&e.ed, fmt.tprintf(`
		for i = 1, 400 do
			local names, err = qed.fs.list(%q)
			if not names then return "failed: " .. tostring(err) end
			local kept = 0
			for _, name in ipairs(names) do if name:sub(1, 5) == "keep_" then kept = kept + 1 end end
			if kept ~= 200 then return "lost " .. (200 - kept) end
		end
		return "ok"`, dir))
	sync.atomic_store(&churn.stop, true)
	thread.join(th)
	thread.destroy(th)
	testing.expectf(t, got == "ok", "listing while another process deletes entries: %s", got)
	testing.expect(t, strings.has_prefix(ft_lua(&e.ed, `return select(2, qed.fs.list("/nonexistent_qed"))`), "cannot list"), "a missing dir fails")
}

@(test)
e2e_round8_resize_does_not_leak_to_the_next_test :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)
	posix.write(posix.FD(e2e_master), raw_data(string("ab")), 2)
	ev: tb2.Event
	testing.expect(t, tb2.peek_event(&ev, 1000) == .Ok && ev.ch == 'a', "the first key is read, the second stays buffered")
	e2e_apply_size(E2E_W, E2E_H)
	for tb2.peek_event(&ev, 50) == .Ok {
		testing.expect(t, ev.type != .Resize, "the resize was taken by e2e_apply_size, not left for the next reader")
	}
}

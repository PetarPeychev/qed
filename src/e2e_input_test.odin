package main

import "core:slice"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "lib:tb2"

InputFixture :: struct {
	name:  string,
	bytes: string,
	want:  []tb2.Event,
}

input_key :: proc(key: tb2.Key, mods: ..tb2.Mod) -> tb2.Event {
	m: u8
	for x in mods {
		m |= u8(x)
	}
	return {type = .Key, key = key, mod = tb2.Mod(m)}
}

input_ch :: proc(ch: rune) -> tb2.Event {
	return {type = .Key, ch = ch}
}

input_feed :: proc(bytes: string) -> []tb2.Event {
	posix.write(posix.FD(e2e_master), raw_data(bytes), len(bytes))
	got := make([dynamic]tb2.Event, context.temp_allocator)
	ev: tb2.Event
	for tb2.peek_event(&ev, 50) == .Ok {
		if ev.type != .Resize {
			append(&got, ev)
		}
	}
	return got[:]
}

@(test)
e2e_input_fixtures :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)

	fixtures := []InputFixture {
		{"kitty Ctrl+Shift+z", "\x1b[122;6u", {input_key(.Ctrl_Z, .Ctrl, .Shift)}},
		{"kitty Ctrl+Shift+a", "\x1b[97;6u", {input_key(.Ctrl_A, .Ctrl, .Shift)}},
		{"kitty CSI u event subfield", "\x1b[97;6:1u", {input_key(.Ctrl_A, .Ctrl, .Shift)}},
		{"kitty private-use key", "\x1b[57399u", {}},
		{"foot Ctrl+Enter", "\x1b[27;5;13~", {input_key(.Enter, .Ctrl)}},
		{"foot Shift+Enter", "\x1b[27;2;13~", {input_key(.Enter, .Shift)}},
		{"foot Ctrl+Tab", "\x1b[27;5;9~", {input_key(.Tab, .Ctrl)}},
		{"konsole Shift+Enter", "\x1bOM", {input_key(.Enter)}},
		{"cursor position report", "\x1b[12;40Rq", {input_ch('q')}},
		{"focus in", "\x1b[Iq", {input_ch('q')}},
		{"unknown SS3", "\x1bOzq", {input_ch('q')}},
		{"Shift+Tab", "\x1b[Z", {input_key(.Back_Tab)}},
		{"Alt+Backspace", "\x1b\x7f", {input_key(.Esc), input_key(.Backspace2, .Ctrl)}},
		{"Alt+Enter", "\x1b\r", {input_key(.Esc), input_key(.Enter, .Ctrl)}},
		{"urxvt Alt+Up", "\x1b\x1b[A", {input_key(.Arrow_Up, .Alt)}},
		{"Alt+a", "\x1ba", {input_key(.Esc), input_ch('a')}},
		{"Ctrl+Delete", "\x1b[3;5~", {input_key(.Delete, .Ctrl)}},
		{"Alt+Left", "\x1b[1;3D", {input_key(.Arrow_Left, .Alt)}},
		{"Backspace", "\x7f", {input_key(.Backspace2, .Ctrl)}},
		{"Ctrl+Backspace", "\x08", {input_key(.Ctrl_H, .Ctrl)}},
		{"SGR click", "\x1b[<0;5;3M", {{type = .Mouse, key = .Mouse_Left, x = 4, y = 2}}},
		{"bracketed paste", "\x1b[200~x\x1b[201~", {{type = .Paste_Begin}, input_ch('x'), {type = .Paste_End}}},
		{"paste with SGR codes", "\x1b[200~a\x1b[31mb\x1b[201~", {{type = .Paste_Begin}, input_ch('a'), input_ch('b'), {type = .Paste_End}}},
	}
	for f in fixtures {
		got := input_feed(f.bytes)
		testing.expectf(t, slice.equal(got, f.want), "%s: got %v, want %v", f.name, got, f.want)
	}

	typed_later := [][2]string{{"\x1b[", "12 x"}, {"\x1b[", "x"}, {"\x1bO", "x"}}
	for pair in typed_later {
		got := make([dynamic]tb2.Event, context.temp_allocator)
		append(&got, ..input_feed(pair[0]))
		append(&got, ..input_feed(pair[1]))
		want := make([dynamic]tb2.Event, context.temp_allocator)
		append(&want, input_key(.Esc))
		for r in pair[0][1:] {
			append(&want, input_ch(r))
		}
		for r in pair[1] {
			append(&want, input_ch(r))
		}
		testing.expectf(t, slice.equal(got[:], want[:]), "%q then %q: got %v, want %v", pair[0], pair[1], got[:], want[:])
	}
}

@(test)
e2e_input_esc_joins_keys :: proc(t: ^testing.T) {
	e := e2e_start("one\ntwo")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)

	e2e_key(&e, .Ctrl_F)
	testing.expect(t, (len(e.ed.searches) > 0), "Ctrl+F should open find")
	evs := input_feed("\x1b\x7f")
	testing.expect_value(t, len(evs), 2)
	e2e_step(&e, evs[0], ..evs[1:])
	testing.expect(t, (len(e.ed.searches) > 0), "Alt+Backspace must not reach find as a bare Esc")
	evs = input_feed("\x1b\r")
	e2e_step(&e, evs[0], ..evs[1:])
	testing.expect(t, (len(e.ed.searches) > 0), "Alt+Enter must not reach find as a bare Esc")
	testing.expect_value(t, len(b.lines), 2)
}

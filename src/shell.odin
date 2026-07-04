package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	popen :: proc(command: cstring, type: cstring) -> rawptr ---
	pclose :: proc(stream: rawptr) -> c.int ---
	fwrite :: proc(ptr: rawptr, size: c.size_t, nmemb: c.size_t, stream: rawptr) -> c.size_t ---
	fread :: proc(ptr: rawptr, size: c.size_t, nmemb: c.size_t, stream: rawptr) -> c.size_t ---
}

shell_capture :: proc(cmd: cstring, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	stream := popen(cmd, "r")
	if stream == nil {
		return "", false
	}
	sb := strings.builder_make(allocator)
	buf: [4096]u8
	for {
		n := fread(&buf[0], 1, len(buf), stream)
		if n == 0 {
			break
		}
		strings.write_bytes(&sb, buf[:n])
	}
	pclose(stream)
	return strings.to_string(sb), true
}

shell_feed :: proc(cmd: cstring, input: string) -> (ok: bool) {
	stream := popen(cmd, "w")
	if stream == nil {
		return false
	}
	if len(input) > 0 {
		fwrite(raw_data(input), 1, c.size_t(len(input)), stream)
	}
	pclose(stream)
	return true
}

// Run `cmd` as a stdin→stdout filter over `input`. The input goes through a temp
// file (not a pipe) so writing it can't deadlock against the filter's output; the
// filter's stderr is discarded so it never corrupts the TUI. `ok` is the exit-0 status.
shell_filter :: proc(cmd: string, input: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	tmp := fmt.tprintf("/tmp/qed-fmt-%d.tmp", posix.getpid())
	fd, open_err := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if open_err != nil {
		return "", false
	}
	_, write_err := os.write(fd, transmute([]u8)input)
	os.close(fd)
	if write_err != nil {
		os.remove(tmp)
		return "", false
	}
	defer os.remove(tmp)

	full := fmt.ctprintf("%s < %s 2>/dev/null", cmd, shell_quote(tmp))
	stream := popen(full, "r")
	if stream == nil {
		return "", false
	}
	sb := strings.builder_make(allocator)
	buf: [4096]u8
	for {
		n := fread(&buf[0], 1, len(buf), stream)
		if n == 0 {
			break
		}
		strings.write_bytes(&sb, buf[:n])
	}
	status := pclose(stream)
	return strings.to_string(sb), status == 0
}

shell_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '\'')
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			strings.write_string(&sb, "'\\''")
		} else {
			strings.write_byte(&sb, s[i])
		}
	}
	strings.write_byte(&sb, '\'')
	return strings.to_string(sb)
}

shell_command_exists :: proc(name: string) -> bool {
	cmd := fmt.ctprintf("command -v %s >/dev/null 2>&1", name)
	stream := popen(cmd, "r")
	if stream == nil {
		return false
	}
	return pclose(stream) == 0
}

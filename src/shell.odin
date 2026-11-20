package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

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

shell_has :: proc(name: string) -> bool {
	out, ok := shell_capture(strings.clone_to_cstring(fmt.tprintf("command -v %s 2>/dev/null", name), context.temp_allocator))
	return ok && strings.trim_space(out) != ""
}

url_opener :: proc() -> (string, bool) {
	when ODIN_OS == .Darwin {
		return "open", true
	}
	if rel, err := os.read_entire_file("/proc/sys/kernel/osrelease", context.temp_allocator); err == nil && strings.contains(strings.to_lower(string(rel), context.temp_allocator), "microsoft") {
		for name in ([]string{"wslview", "explorer.exe"}) {
			if shell_has(name) {
				return name, true
			}
		}
		return "", false
	}
	return "xdg-open", shell_has("xdg-open")
}

// backgrounded with output discarded: returns at once and leaves no child to reap
url_open :: proc(cmd: string) -> bool {
	_, ok := shell_capture(strings.clone_to_cstring(fmt.tprintf("%s >/dev/null 2>&1 &", cmd), context.temp_allocator))
	return ok
}

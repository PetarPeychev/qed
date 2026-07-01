package main

import "core:c"
import "core:fmt"
import "core:strings"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	popen :: proc(command: cstring, type: cstring) -> rawptr ---
	pclose :: proc(stream: rawptr) -> c.int ---
	fwrite :: proc(ptr: rawptr, size: c.size_t, nmemb: c.size_t, stream: rawptr) -> c.size_t ---
	fread :: proc(ptr: rawptr, size: c.size_t, nmemb: c.size_t, stream: rawptr) -> c.size_t ---
}

ClipboardTool :: enum {
	Unknown,
	WlClipboard,
	Xclip,
	Pbcopy,
	None,
}

clipboard_tool: ClipboardTool = .Unknown
clipboard_register: string

clipboard_shutdown :: proc() {
	delete(clipboard_register)
}

clipboard_command_exists :: proc(name: string) -> bool {
	cmd := fmt.ctprintf("command -v %s >/dev/null 2>&1", name)
	stream := popen(cmd, "r")
	if stream == nil {
		return false
	}
	return pclose(stream) == 0
}

clipboard_detect :: proc() {
	switch {
	case clipboard_command_exists("wl-copy"):
		clipboard_tool = .WlClipboard
	case clipboard_command_exists("xclip"):
		clipboard_tool = .Xclip
	case clipboard_command_exists("pbcopy"):
		clipboard_tool = .Pbcopy
	case:
		clipboard_tool = .None
	}
}

clipboard_set :: proc(text: string) {
	if clipboard_tool == .Unknown {
		clipboard_detect()
	}

	cmd: cstring
	switch clipboard_tool {
	case .WlClipboard:
		cmd = "wl-copy 2>/dev/null"
	case .Xclip:
		cmd = "xclip -selection clipboard 2>/dev/null"
	case .Pbcopy:
		cmd = "pbcopy 2>/dev/null"
	case .None, .Unknown:
		clipboard_register_set(text)
		return
	}

	stream := popen(cmd, "w")
	if stream == nil {
		clipboard_register_set(text)
		return
	}
	if len(text) > 0 {
		fwrite(raw_data(text), 1, c.size_t(len(text)), stream)
	}
	pclose(stream)
}

clipboard_get :: proc(allocator := context.allocator) -> string {
	if clipboard_tool == .Unknown {
		clipboard_detect()
	}

	cmd: cstring
	switch clipboard_tool {
	case .WlClipboard:
		cmd = "wl-paste --no-newline 2>/dev/null"
	case .Xclip:
		cmd = "xclip -selection clipboard -o 2>/dev/null"
	case .Pbcopy:
		cmd = "pbpaste 2>/dev/null"
	case .None, .Unknown:
		return strings.clone(clipboard_register, allocator)
	}

	stream := popen(cmd, "r")
	if stream == nil {
		return strings.clone(clipboard_register, allocator)
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
	return strings.to_string(sb)
}

clipboard_register_set :: proc(text: string) {
	delete(clipboard_register)
	clipboard_register = strings.clone(text)
}

package main

import "core:strings"

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

clipboard_detect :: proc() {
	switch {
	case shell_command_exists("wl-copy"):
		clipboard_tool = .WlClipboard
	case shell_command_exists("xclip"):
		clipboard_tool = .Xclip
	case shell_command_exists("pbcopy"):
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

	if !shell_feed(cmd, text) {
		clipboard_register_set(text)
	}
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

	if out, ok := shell_capture(cmd, allocator); ok {
		return out
	}
	return strings.clone(clipboard_register, allocator)
}

clipboard_register_set :: proc(text: string) {
	delete(clipboard_register)
	clipboard_register = strings.clone(text)
}

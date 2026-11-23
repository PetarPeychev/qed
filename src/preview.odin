package main

import "core:fmt"
import "core:strings"

// a preview copy (qed.buf.create{from}) reads at most this much; a binary shows as a hexdump of this many rows
PREVIEW_HEX_BYTES :: 16
PREVIEW_MAX_LINES :: 4000
PREVIEW_MAX_BYTES :: 4 * 1024 * 1024

preview_is_binary :: proc(data: []u8) -> bool {
	for b in data {
		if b == 0 {
			return true
		}
	}
	return false
}

hex_dump_line :: proc(data: []u8, offset: int, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "%08x  ", offset)
	for j in 0 ..< PREVIEW_HEX_BYTES {
		if j == PREVIEW_HEX_BYTES / 2 {
			strings.write_byte(&sb, ' ')
		}
		if j < len(data) {
			fmt.sbprintf(&sb, "%02x ", data[j])
		} else {
			strings.write_string(&sb, "   ")
		}
	}
	strings.write_string(&sb, " |")
	for b in data {
		c: u8 = '.'
		if b >= 0x20 && b < 0x7f {
			c = b
		}
		strings.write_byte(&sb, c)
	}
	strings.write_byte(&sb, '|')
	return strings.to_string(sb)
}

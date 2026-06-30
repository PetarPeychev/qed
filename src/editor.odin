package main

import "core:strings"
import "lib:tb2"

Editor :: struct {
    buffer: Buffer
}

editor_init :: proc(path: string = "") -> Editor {
    tb2.init();
    tb2.set_output_mode(.O256)
    editor := Editor {buffer = buffer_new()}
    if path != "" {
        buffer_open(&editor.buffer, path)
    }
    return editor
}

editor_shutdown :: proc(editor: ^Editor) {
    tb2.shutdown()
}

editor_render :: proc(editor: ^Editor) {
    for line, i in editor.buffer.lines {
        cstr := strings.clone_to_cstring(string(line.text[:]), context.temp_allocator)
        tb2.print(0, i32(i), gray(20), .Default, cstr)
    }
    tb2.present()
}

rgb :: proc(r, g, b: u8) -> tb2.Color {
    return tb2.Color(16 + 36*u64(r) + 6*u64(g) + u64(b))
}

gray :: proc(level: u8) -> tb2.Color {
    return tb2.Color(232 + u64(level))
}

style :: proc(c: tb2.Color, attrs: ..tb2.Color) -> tb2.Color {
    v := u64(c)
    for a in attrs do v |= u64(a)
    return tb2.Color(v)
}

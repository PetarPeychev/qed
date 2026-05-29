package main

Editor :: struct {
    buffer: Buffer
}

editor_new :: proc(path: string = "") -> Editor {
    editor := Editor {buffer = buffer_new()}
    if path != "" {
        buffer_open(&editor.buffer, path)
    }
    return editor
}

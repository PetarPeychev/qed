package main

import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "lib:tb2"

print_help :: proc() {
	fmt.println("Usage: qed [FILE]")
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.println("Error: Too many arguments.")
		print_help()
		os.exit(1)
	}

	path := ""
	if len(os.args) == 2 {
		path = os.args[1]
	}
	editor := editor_init(path)
	defer editor_shutdown(&editor)


	ev: tb2.Event
	for !editor.quit {
		editor_render(&editor)
		tb2.poll_event(&ev)
		editor_dispatch(&editor, ev)
		free_all(context.temp_allocator)
	}
}

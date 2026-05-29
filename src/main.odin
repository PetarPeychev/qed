package main

import "core:flags"
import "core:fmt"
import "core:os"

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
	editor := editor_new(path)

	for line in editor.buffer.lines {
		fmt.println(string(line.text[:]))
	}
}

package main

import "core:testing"

@(test)
test_fuzzy_rank_builtin :: proc(t: ^testing.T) {
	items := []string{"Save", "Quit", "Select All", "Save As"}

	f := Fuzzy{items = items}

	ranked := fuzzy_rank(&f, "sa", context.temp_allocator)
	seen: [4]bool
	for idx in ranked {
		testing.expect(t, idx != 1, "Quit should not match 'sa'")
		seen[idx] = true
	}
	testing.expect(t, seen[0], "Save should match 'sa'")
	testing.expect(t, seen[2], "Select All should match 'sa'")
	testing.expect(t, seen[3], "Save As should match 'sa'")

	all := fuzzy_rank(&f, "", context.temp_allocator)
	testing.expect_value(t, len(all), len(items))
}

@(test)
test_fuzzy_rank_fzf :: proc(t: ^testing.T) {
	if !shell_command_exists("fzf") {
		return
	}
	items := []string{"Save", "Quit", "Select All", "Save As"}

	fuzzy_tool = .Fzf
	f := fuzzy_begin(items)
	defer fuzzy_end(&f)
	testing.expect(t, f.has_tmp, "fzf session should have a temp file")

	ranked := fuzzy_rank(&f, "save", context.temp_allocator)
	testing.expect(t, len(ranked) >= 2, "expected 'save' to match Save and Save As")
	for idx in ranked {
		testing.expect(t, idx >= 0 && idx < len(items), "index in range")
		testing.expect(t, idx != 1, "Quit should not match 'save'")
	}

	fuzzy_tool = .Unknown
}

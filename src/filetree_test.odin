package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file")
walk_seq: int

@(private = "file")
WalkWant :: struct {
	rel:    string,
	is_dir: bool,
}

@(private = "file")
WALK_BASE := [?]WalkWant {
	{"a.txt", false},
	{"sub", true},
	{"sub/b.txt", false},
	{"sub/deep", true},
	{"sub/deep/c.txt", false},
	{"link", false},
}

@(private = "file")
walk_fixture :: proc() -> string {
	tmp, _ := os.temp_dir(context.temp_allocator)
	walk_seq += 1
	root := fmt.aprintf("%s/qed_walk_%d_%d", tmp, posix.getpid(), walk_seq)
	os.make_directory_all(fmt.tprintf("%s/sub/deep", root))
	os.make_directory(fmt.tprintf("%s/.hdir", root))
	for rel in ([]string{"a.txt", "sub/b.txt", "sub/deep/c.txt", ".hidden", ".hdir/x.txt"}) {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", root, rel), transmute([]u8)string("x"))
	}
	posix.symlink(
		strings.clone_to_cstring(fmt.tprintf("%s/sub", root), context.temp_allocator),
		strings.clone_to_cstring(fmt.tprintf("%s/link", root), context.temp_allocator),
	)
	return root
}

@(private = "file")
walk_collect :: proc(ft: ^FileTree, root: string) -> (rel: map[string]bool, n: int) {
	out := make([dynamic]FileEntry, context.temp_allocator)
	filetree_collect(ft, root, &out)
	rel = make(map[string]bool, context.temp_allocator)
	n = len(out)
	for e in out {
		r := strings.trim_prefix(strings.trim_prefix(e.path, root), "/")
		rel[strings.clone(r, context.temp_allocator)] = e.is_dir
		delete(e.path)
	}
	return
}

@(private = "file")
walk_expect :: proc(t: ^testing.T, got: map[string]bool, n: int, want: []WalkWant) {
	testing.expectf(t, n == len(got), "duplicates: %d entries, %d unique", n, len(got))
	testing.expectf(t, len(got) == len(want), "got %d entries, want %d: %v", len(got), len(want), got)
	for w in want {
		is_dir, ok := got[w.rel]
		testing.expectf(t, ok, "missing %s", w.rel)
		testing.expectf(t, !ok || is_dir == w.is_dir, "%s: is_dir %v, want %v", w.rel, is_dir, w.is_dir)
	}
}

@(test)
test_filetree_walk_default :: proc(t: ^testing.T) {
	root := walk_fixture()
	defer {os.remove_all(root);delete(root)}
	ft: FileTree
	got, n := walk_collect(&ft, root)
	walk_expect(t, got, n, WALK_BASE[:])
}

@(test)
test_filetree_walk_dotfiles :: proc(t: ^testing.T) {
	root := walk_fixture()
	defer {os.remove_all(root);delete(root)}
	ft: FileTree
	ft.show_dotfiles = true
	got, n := walk_collect(&ft, root)
	want := [?]WalkWant {
		{"a.txt", false},
		{"sub", true},
		{"sub/b.txt", false},
		{"sub/deep", true},
		{"sub/deep/c.txt", false},
		{"link", false},
		{".hidden", false},
		{".hdir", true},
		{".hdir/x.txt", false},
	}
	walk_expect(t, got, n, want[:])
}

@(test)
test_filetree_walk_ignored :: proc(t: ^testing.T) {
	root := walk_fixture()
	defer {os.remove_all(root);delete(root)}
	ft: FileTree
	ft.ignored[strings.clone(fmt.tprintf("%s/sub", root))] = true
	defer {
		for key in ft.ignored {
			delete(key)
		}
		delete(ft.ignored)
	}
	got, n := walk_collect(&ft, root)
	want := [?]WalkWant{{"a.txt", false}, {"link", false}}
	walk_expect(t, got, n, want[:])

	ft.show_ignored = true
	got2, n2 := walk_collect(&ft, root)
	walk_expect(t, got2, n2, WALK_BASE[:])
}

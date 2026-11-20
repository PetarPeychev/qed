package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
e2e_nav_filetree_nested_ignore :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	e := e2e_git_start("committed\n")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(e.dir)

	os.make_directory(fmt.tprintf("%s/pkg", e.dir))
	os.make_directory(fmt.tprintf("%s/pkg/dist", e.dir))
	nav_write(fmt.tprintf("%s/pkg/keep.js", e.dir), "keep")
	nav_write(fmt.tprintf("%s/pkg/dist/bundle.js", e.dir), "x")
	nav_write(fmt.tprintf("%s/.gitignore", e.dir), "pkg/dist/\n")

	nav_alt(&e, 'f')
	nav_scan(&e)
	pane_tree_expand_all(&e.ed, ft_pane(&e.ed), true)

	testing.expect(t, !entry_named(&e.ed, "dist"), "nested ignored dir hidden by default")
	testing.expect(t, !entry_named(&e.ed, "bundle.js"), "file in nested ignored dir hidden")
	testing.expect(t, entry_named(&e.ed, "keep.js"), "sibling kept")

	filetree_toggle_ignored(&e.ed)
	pane_tree_expand_all(&e.ed, ft_pane(&e.ed), true)
	testing.expect(t, entry_named(&e.ed, "dist"), "nested ignored dir visible after toggle")
}

// Working root is a plain directory (not a git repo) holding child repos; each
// child's gitignore must still be applied.
@(test)
e2e_nav_filetree_child_repos :: proc(t: ^testing.T) {
	if !shell_command_exists("git") {
		return
	}
	tmp, _ := os.temp_dir(context.temp_allocator)
	parent := fmt.aprintf("%s/qed_e2e_parent_%d", tmp, posix.getpid())
	defer delete(parent)
	os.make_directory(parent)
	defer e2e_run(fmt.tprintf("rm -rf %s", shell_quote(parent)))

	for repo in ([?]string{"repoA", "repoB"}) {
		dir := fmt.tprintf("%s/%s", parent, repo)
		os.make_directory(dir)
		os.make_directory(fmt.tprintf("%s/node_modules", dir))
		nav_write(fmt.tprintf("%s/node_modules/dep.js", dir), "dep")
		nav_write(fmt.tprintf("%s/app.js", dir), "app")
		nav_write(fmt.tprintf("%s/.gitignore", dir), "**/node_modules\n")
		e2e_run(fmt.tprintf("git -C %s init -q", shell_quote(dir)))
	}

	e := e2e_root_start("body")
	defer e2e_stop(&e)
	delete(e.ed.working_root)
	e.ed.working_root = strings.clone(parent)

	nav_alt(&e, 'f')
	nav_scan(&e)
	pane_tree_expand_all(&e.ed, ft_pane(&e.ed), true)

	testing.expect(t, entry_named(&e.ed, "repoA"), "child repo listed")
	testing.expect(t, entry_named(&e.ed, "app.js"), "child repo file listed")
	testing.expect(t, !entry_named(&e.ed, "node_modules"), "child repo node_modules hidden")
	testing.expect(t, !entry_named(&e.ed, "dep.js"), "file inside child node_modules hidden")

	filetree_toggle_ignored(&e.ed)
	pane_tree_expand_all(&e.ed, ft_pane(&e.ed), true)
	testing.expect(t, entry_named(&e.ed, "node_modules"), "node_modules visible after toggle")
}

entry_named :: proc(ed: ^Editor, name: string) -> bool {
	for entry in ft_entries(ed) {
		if entry.name == name {
			return true
		}
	}
	return false
}

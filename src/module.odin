package main

import "base:runtime"

Module :: enum {
	None,
	Git,
	Lsp,
	Ai,
}

@(init)
module_probe :: proc "contextless" () {
	context = runtime.default_context()
	GIT_BINARY_PRESENT = shell_command_exists("git")
}

module_enabled :: proc(m: Module) -> bool {
	switch m {
	case .Git:
		return GIT_ENABLED && GIT_BINARY_PRESENT
	case .Lsp:
		return LSP_ENABLED
	case .Ai:
		return AI_ENABLED
	case .None:
		return true
	}
	return true
}

// Runs after every config hot-reload: each module reconciles its live state to
// its enabled flag, tearing down when it was just switched off. Idempotent (a
// no-op when the module's state already matches). Per-module sync procs are
// appended here by their subsystem.
editor_modules_sync :: proc(editor: ^Editor) {
	git_module_sync(editor)
	lsp_module_sync(editor)
	ai_module_sync(editor)
}

package main

Module :: enum {
	None,
	Ai,
}

module_enabled :: proc(m: Module) -> bool {
	switch m {
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
	ai_module_sync(editor)
}

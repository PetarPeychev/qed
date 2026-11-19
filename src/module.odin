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

editor_modules_sync :: proc(editor: ^Editor) {
	ai_module_sync(editor)
}

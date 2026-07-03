package tree_sitter

Parser :: struct {}
Tree :: struct {}
Query :: struct {}
QueryCursor :: struct {}
Language :: distinct rawptr

Point :: struct {
	row:    u32,
	column: u32,
}

Node :: struct {
	ctx:  [4]u32,
	id:   rawptr,
	tree: rawptr,
}

QueryCapture :: struct {
	node:  Node,
	index: u32,
}

QueryMatch :: struct {
	id:            u32,
	pattern_index: u16,
	capture_count: u16,
	captures:      [^]QueryCapture,
}

QueryError :: enum u32 {
	None = 0,
	Syntax,
	NodeType,
	Field,
	Capture,
	Structure,
	Language,
}

foreign import ts "libtreesitter.a"

@(default_calling_convention = "c", link_prefix = "ts_")
foreign ts {
	parser_new :: proc() -> ^Parser ---
	parser_delete :: proc(self: ^Parser) ---
	parser_set_language :: proc(self: ^Parser, language: Language) -> bool ---
	parser_parse_string :: proc(self: ^Parser, old_tree: ^Tree, str: [^]u8, length: u32) -> ^Tree ---

	tree_root_node :: proc(self: ^Tree) -> Node ---
	tree_delete :: proc(self: ^Tree) ---

	node_start_byte :: proc(node: Node) -> u32 ---
	node_end_byte :: proc(node: Node) -> u32 ---
	node_start_point :: proc(node: Node) -> Point ---
	node_end_point :: proc(node: Node) -> Point ---

	query_new :: proc(language: Language, source: [^]u8, length: u32, error_offset: ^u32, error_type: ^QueryError) -> ^Query ---
	query_delete :: proc(self: ^Query) ---
	query_capture_count :: proc(self: ^Query) -> u32 ---
	query_capture_name_for_id :: proc(self: ^Query, id: u32, length: ^u32) -> [^]u8 ---

	query_cursor_new :: proc() -> ^QueryCursor ---
	query_cursor_delete :: proc(self: ^QueryCursor) ---
	query_cursor_exec :: proc(self: ^QueryCursor, query: ^Query, node: Node) ---
	query_cursor_next_match :: proc(self: ^QueryCursor, match: ^QueryMatch) -> bool ---
}

@(default_calling_convention = "c")
foreign ts {
	tree_sitter_odin :: proc() -> Language ---
	tree_sitter_json :: proc() -> Language ---
	tree_sitter_python :: proc() -> Language ---
}

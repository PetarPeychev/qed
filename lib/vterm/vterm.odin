package vterm

import "core:c"

VTerm :: struct {}
Screen :: struct {}
State :: struct {}

Pos :: struct {
	row, col: c.int,
}

// Mirrors the 4-byte VTermColor union. `type` bit0 = RGB(0)/Indexed(1); bits
// 0x02/0x04 flag default fg/bg. For an RGB colour v0/v1/v2 are red/green/blue.
Color :: struct {
	type:       u8,
	v0, v1, v2: u8,
}

COLOR_TYPE_MASK :: 0x01
COLOR_DEFAULT_FG :: 0x02
COLOR_DEFAULT_BG :: 0x04

// VTermScreenCellAttrs bitfield packed into one C `unsigned int`.
ATTR_BOLD :: 1 << 0
ATTR_UNDERLINE :: 3 << 1
ATTR_ITALIC :: 1 << 3
ATTR_REVERSE :: 1 << 5

ScreenCell :: struct {
	chars:  [6]u32,
	width:  i8,
	_pad:   [3]u8,
	attrs:  u32,
	fg, bg: Color,
}

Modifier :: distinct c.int
MOD_NONE :: Modifier(0x00)
MOD_SHIFT :: Modifier(0x01)
MOD_ALT :: Modifier(0x02)
MOD_CTRL :: Modifier(0x04)

PROP_ALTSCREEN :: c.int(3)
PROP_MOUSE :: c.int(8)

// Only the leading `int` of the VTermValue union is read here (boolean/number
// share offset 0); the full union is wider but we never touch the other members.
Value :: struct {
	number: c.int,
}

// VTermScreenCallbacks. Fields we don't use are left as rawptr nils — libvterm
// null-checks each before calling.
ScreenCallbacks :: struct {
	damage:       rawptr,
	moverect:     rawptr,
	movecursor:   rawptr,
	settermprop:  proc "c" (prop: c.int, val: ^Value, user: rawptr) -> c.int,
	bell:         rawptr,
	resize:       rawptr,
	sb_pushline:  proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int,
	sb_popline:   proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int,
	sb_clear:     proc "c" (user: rawptr) -> c.int,
	sb_pushline4: rawptr,
}

Key :: enum c.int {
	None = 0,
	Enter,
	Tab,
	Backspace,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Ins,
	Del,
	Home,
	End,
	PageUp,
	PageDown,
}

foreign import lib "libvterm.a"

@(default_calling_convention = "c", link_prefix = "vterm_")
foreign lib {
	new :: proc(rows, cols: c.int) -> ^VTerm ---
	free :: proc(vt: ^VTerm) ---
	set_utf8 :: proc(vt: ^VTerm, is_utf8: c.int) ---
	set_size :: proc(vt: ^VTerm, rows, cols: c.int) ---
	input_write :: proc(vt: ^VTerm, bytes: [^]u8, len: c.size_t) -> c.size_t ---
	output_read :: proc(vt: ^VTerm, buffer: [^]u8, len: c.size_t) -> c.size_t ---
	keyboard_unichar :: proc(vt: ^VTerm, ch: u32, mod: Modifier) ---
	keyboard_key :: proc(vt: ^VTerm, key: Key, mod: Modifier) ---
	keyboard_start_paste :: proc(vt: ^VTerm) ---
	keyboard_end_paste :: proc(vt: ^VTerm) ---
	mouse_move :: proc(vt: ^VTerm, row, col: c.int, mod: Modifier) ---
	mouse_button :: proc(vt: ^VTerm, button: c.int, pressed: bool, mod: Modifier) ---

	obtain_state :: proc(vt: ^VTerm) -> ^State ---
	state_get_cursorpos :: proc(state: ^State, cursorpos: ^Pos) ---
	state_set_palette_color :: proc(state: ^State, index: c.int, col: ^Color) ---

	obtain_screen :: proc(vt: ^VTerm) -> ^Screen ---
	screen_reset :: proc(screen: ^Screen, hard: c.int) ---
	screen_enable_altscreen :: proc(screen: ^Screen, altscreen: c.int) ---
	screen_set_default_colors :: proc(screen: ^Screen, default_fg, default_bg: ^Color) ---
	screen_convert_color_to_rgb :: proc(screen: ^Screen, col: ^Color) ---
	screen_get_cell :: proc(screen: ^Screen, pos: Pos, cell: ^ScreenCell) -> c.int ---
	screen_set_callbacks :: proc(screen: ^Screen, callbacks: ^ScreenCallbacks, user: rawptr) ---
}

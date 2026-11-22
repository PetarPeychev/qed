package lua

import "core:c"

foreign import lib "liblua.a"
foreign import _m "system:m"

MAXSTACK :: 1000000
REGISTRYINDEX :: -MAXSTACK - 1000

RIDX_MAINTHREAD :: 1
RIDX_GLOBALS :: 2
EXTRASPACE :: size_of(rawptr)
LOADED_TABLE :: "_LOADED"
NOREF :: -2
REFNIL :: -1

MULTRET :: -1

Status :: enum c.int {
	OK        = 0,
	YIELD     = 1,
	ERRRUN    = 2,
	ERRSYNTAX = 3,
	ERRMEM    = 4,
	ERRERR    = 5,
	ERRFILE   = 6,
}

Type :: enum c.int {
	NONE          = -1,
	NIL           = 0,
	BOOLEAN       = 1,
	LIGHTUSERDATA = 2,
	NUMBER        = 3,
	STRING        = 4,
	TABLE         = 5,
	FUNCTION      = 6,
	USERDATA      = 7,
	THREAD        = 8,
}

GCWhat :: enum c.int {
	STOP    = 0,
	RESTART = 1,
	COLLECT = 2,
	COUNT   = 3,
	COUNTB  = 4,
	STEP    = 5,
	INC     = 11,
}

Number :: distinct f64
Integer :: distinct i64
KContext :: distinct int

CFunction :: #type proc "c" (L: ^State) -> c.int
KFunction :: #type proc "c" (L: ^State, status: c.int, ctx: KContext) -> c.int
Alloc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr
Hook :: #type proc "c" (L: ^State, ar: rawptr)

MASKCOUNT :: 1 << 3

State :: struct {}

L_Reg :: struct {
	name: cstring,
	func: CFunction,
}

@(link_prefix = "lua_")
@(default_calling_convention = "c")
foreign lib {
	newstate :: proc(f: Alloc, ud: rawptr) -> ^State ---
	close :: proc(L: ^State) ---
	atpanic :: proc(L: ^State, panicf: CFunction) -> CFunction ---

	absindex :: proc(L: ^State, idx: c.int) -> c.int ---
	gettop :: proc(L: ^State) -> c.int ---
	settop :: proc(L: ^State, idx: c.int) ---
	pushvalue :: proc(L: ^State, idx: c.int) ---
	rotate :: proc(L: ^State, idx: c.int, n: c.int) ---
	checkstack :: proc(L: ^State, n: c.int) -> c.int ---

	type :: proc(L: ^State, idx: c.int) -> Type ---
	typename :: proc(L: ^State, tp: Type) -> cstring ---
	toboolean :: proc(L: ^State, idx: c.int) -> b32 ---
	tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> cstring ---
	touserdata :: proc(L: ^State, idx: c.int) -> rawptr ---
	tothread :: proc(L: ^State, idx: c.int) -> ^State ---
	@(link_name = "lua_tointegerx")
	tointeger :: proc(L: ^State, idx: c.int, isnum: ^b32 = nil) -> Integer ---
	tonumberx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> Number ---
	isinteger :: proc(L: ^State, idx: c.int) -> b32 ---
	rawlen :: proc(L: ^State, idx: c.int) -> u64 ---

	pushnil :: proc(L: ^State) ---
	pushnumber :: proc(L: ^State, n: Number) ---
	pushinteger :: proc(L: ^State, n: Integer) ---
	pushlstring :: proc(L: ^State, s: [^]byte, len: c.size_t) -> cstring ---
	pushcclosure :: proc(L: ^State, fn: CFunction, n: c.int) ---
	pushboolean :: proc(L: ^State, b: b32) ---
	pushlightuserdata :: proc(L: ^State, p: rawptr) ---
	pushstring :: proc(L: ^State, s: cstring) -> cstring ---

	getglobal :: proc(L: ^State, name: cstring) -> Type ---
	getfield :: proc(L: ^State, idx: c.int, k: cstring) -> Type ---
	rawget :: proc(L: ^State, idx: c.int) -> Type ---
	rawgeti :: proc(L: ^State, idx: c.int, n: Integer) -> Type ---
	createtable :: proc(L: ^State, narr, nrec: c.int) ---

	setfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	rawset :: proc(L: ^State, idx: c.int) ---
	rawseti :: proc(L: ^State, idx: c.int, n: Integer) ---
	setmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	getmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	rawequal :: proc(L: ^State, idx1, idx2: c.int) -> c.int ---

	@(link_name = "lua_callk")
	call :: proc(L: ^State, nargs, nresults: c.int, ctx: KContext = 0, k: KFunction = nil) ---
	@(link_name = "lua_pcallk")
	pcall :: proc(L: ^State, nargs, nresults: c.int, errfunc: c.int, ctx: KContext = 0, k: KFunction = nil) -> Status ---

	error :: proc(L: ^State) -> c.int ---
	newthread :: proc(L: ^State) -> ^State ---
	xmove :: proc(from, to: ^State, n: c.int) ---
	resume :: proc(L: ^State, from: ^State, narg: c.int, nres: ^c.int) -> Status ---
	closethread :: proc(L: ^State, from: ^State) -> Status ---
	yieldk :: proc(L: ^State, nresults: c.int, ctx: KContext = 0, k: KFunction = nil) -> c.int ---
	isyieldable :: proc(L: ^State) -> b32 ---
	status :: proc(L: ^State) -> Status ---
	sethook :: proc(L: ^State, f: Hook, mask: c.int, count: c.int) ---
	next :: proc(L: ^State, idx: c.int) -> c.int ---
	gc :: proc(L: ^State, what: GCWhat, #c_vararg args: ..c.int) -> c.int ---
	setupvalue :: proc(L: ^State, funcindex: c.int, n: c.int) -> cstring ---
}

@(link_prefix = "lua")
@(default_calling_convention = "c")
foreign lib {
	L_openlibs :: proc(L: ^State) ---
	@(link_name = "luaL_tolstring")
	L_tostring :: proc(L: ^State, idx: c.int, len: ^c.size_t = nil) -> cstring ---
	L_argerror :: proc(L: ^State, arg: c.int, extramsg: cstring) -> c.int ---
	L_checkstack :: proc(L: ^State, sz: c.int, msg: cstring) ---
	L_ref :: proc(L: ^State, t: c.int) -> c.int ---
	L_unref :: proc(L: ^State, t: c.int, ref: c.int) ---
	@(link_name = "luaL_loadbufferx")
	L_loadbuffer :: proc(L: ^State, buff: [^]byte, sz: c.size_t, name: cstring, mode: cstring = nil) -> Status ---
	L_setfuncs :: proc(L: ^State, l: [^]L_Reg, nup: c.int) ---
	L_traceback :: proc(L: ^State, L1: ^State, msg: cstring, level: c.int) ---
}

getextraspace :: #force_inline proc "c" (L: ^State) -> ^rawptr {
	return (^rawptr)(uintptr(L) - EXTRASPACE)
}

pop :: #force_inline proc "c" (L: ^State, n: c.int) {
	settop(L, -n - 1)
}

newtable :: #force_inline proc "c" (L: ^State) {
	createtable(L, 0, 0)
}

pushcfunction :: #force_inline proc "c" (L: ^State, f: CFunction) {
	pushcclosure(L, f, 0)
}

pushglobaltable :: #force_inline proc "c" (L: ^State) {
	rawgeti(L, REGISTRYINDEX, RIDX_GLOBALS)
}

insert :: #force_inline proc "c" (L: ^State, idx: c.int) {
	rotate(L, idx, 1)
}

remove :: #force_inline proc "c" (L: ^State, idx: c.int) {
	rotate(L, idx, -1)
	pop(L, 1)
}

upvalueindex :: #force_inline proc "c" (i: c.int) -> c.int {
	return REGISTRYINDEX - i
}

pushodinstring :: proc "c" (L: ^State, s: string) {
	pushlstring(L, raw_data(s), c.size_t(len(s)))
}

toodinstring_any :: proc "c" (L: ^State, idx: c.int) -> (string, bool) {
	n: c.size_t
	p := L_tostring(L, idx, &n)
	if p == nil {
		return "", false
	}
	return string((cast([^]byte)p)[:n]), true
}

toodinstring :: proc "c" (L: ^State, idx: c.int) -> (string, bool) {
	n: c.size_t
	p := tolstring(L, idx, &n)
	if p == nil {
		return "", false
	}
	return string((cast([^]byte)p)[:n]), true
}

package main

import "core:os"
import "core:text/match"
import "core:text/regex"
import ts "lib:tree_sitter"

PredKind :: enum {
	Eq,
	NotEq,
	AnyEq,
	AnyNotEq,
	Match,
	NotMatch,
	AnyMatch,
	AnyNotMatch,
	AnyOf,
	NotAnyOf,
	LuaMatch,
	NotLuaMatch,
	HasParent,
	NotHasParent,
	HasAncestor,
	NotHasAncestor,
	Set,
	Unknown,
}

PRED_NO_CAP :: max(u32)

Predicate :: struct {
	kind:    PredKind,
	subject: u32,
	operand: u32,
	value:   string,
	values:  []string,
	re:      regex.Regular_Expression,
	re_ok:   bool,
	set_key: string,
	set_val: string,
}

PatternPreds :: struct {
	preds: []Predicate,
}

NodeText :: struct {
	buffer: ^Buffer,
	src:    string,
}

// Whole-query predicate/directive cache, one entry per pattern index, parsed
// once at query-build time (predicate step arrays never change for a query).
// Backed by the OS heap so it survives any per-test allocator.
query_predicates_build :: proc(q: ^ts.Query) -> [dynamic]PatternPreds {
	out := make([dynamic]PatternPreds, os.heap_allocator())
	pattern_count := ts.query_pattern_count(q)
	for pi in 0 ..< pattern_count {
		count: u32
		steps := ts.query_predicates_for_pattern(q, pi, &count)
		preds := make([dynamic]Predicate, os.heap_allocator())
		i := 0
		for i < int(count) {
			// Each predicate is [String(name) arg* Done].
			j := i
			for j < int(count) && steps[j].type != .Done {
				j += 1
			}
			pred_steps := steps[i:j]
			i = j + 1
			if len(pred_steps) == 0 || pred_steps[0].type != .String {
				continue
			}
			append(&preds, predicate_parse(q, pred_steps))
		}
		append(&out, PatternPreds{preds[:]})
	}
	return out
}

@(private = "file")
predicate_parse :: proc(q: ^ts.Query, steps: []ts.QueryPredicateStep) -> (p: Predicate) {
	p.subject = PRED_NO_CAP
	p.operand = PRED_NO_CAP
	name := query_string_value(q, steps[0].value_id)
	p.kind = predicate_kind(name)

	args := steps[1:]

	#partial switch p.kind {
	case .Set:
		strs := make([dynamic]string, os.heap_allocator())
		for s in args {
			if s.type == .String {
				append(&strs, query_string_value(q, s.value_id))
			}
		}
		if len(strs) >= 2 {
			p.set_key = strs[0]
			p.set_val = strs[1]
		}
		delete(strs)
		return
	case .Unknown:
		// Skipped at eval time (kind stays .Unknown, subject unset) — the pattern
		// keeps matching, its known predicates still enforced. See PATCHES.md.
		return
	}

	// First arg is the subject capture for every supported filter.
	if len(args) >= 1 && args[0].type == .Capture {
		p.subject = args[0].value_id
	}
	rest := args[1:] if len(args) >= 1 else args

	#partial switch p.kind {
	case .Eq, .NotEq, .AnyEq, .AnyNotEq:
		if len(rest) >= 1 {
			if rest[0].type == .Capture {
				p.operand = rest[0].value_id
			} else {
				p.value = query_string_value(q, rest[0].value_id)
			}
		}
	case .Match, .NotMatch, .AnyMatch, .AnyNotMatch:
		if len(rest) >= 1 && rest[0].type == .String {
			p.value = query_string_value(q, rest[0].value_id)
			re, err := regex.create(p.value, {}, os.heap_allocator())
			if err == nil {
				p.re = re
				p.re_ok = true
			}
		}
	case .LuaMatch, .NotLuaMatch:
		if len(rest) >= 1 && rest[0].type == .String {
			p.value = query_string_value(q, rest[0].value_id)
		}
	case .AnyOf, .NotAnyOf, .HasParent, .NotHasParent, .HasAncestor, .NotHasAncestor:
		strs := make([dynamic]string, os.heap_allocator())
		for s in rest {
			if s.type == .String {
				append(&strs, query_string_value(q, s.value_id))
			}
		}
		p.values = strs[:]
	}
	return
}

@(private = "file")
query_string_value :: proc(q: ^ts.Query, id: u32) -> string {
	length: u32
	ptr := ts.query_string_value_for_id(q, id, &length)
	return string(ptr[:length])
}

@(private = "file")
predicate_kind :: proc(name: string) -> PredKind {
	switch name {
	case "eq?":
		return .Eq
	case "not-eq?":
		return .NotEq
	case "any-eq?":
		return .AnyEq
	case "any-not-eq?":
		return .AnyNotEq
	case "match?":
		return .Match
	case "not-match?":
		return .NotMatch
	case "any-match?":
		return .AnyMatch
	case "any-not-match?":
		return .AnyNotMatch
	case "any-of?":
		return .AnyOf
	case "not-any-of?":
		return .NotAnyOf
	case "lua-match?":
		return .LuaMatch
	case "not-lua-match?":
		return .NotLuaMatch
	case "has-parent?":
		return .HasParent
	case "not-has-parent?":
		return .NotHasParent
	case "has-ancestor?":
		return .HasAncestor
	case "not-has-ancestor?":
		return .NotHasAncestor
	case "set!":
		return .Set
	}
	return .Unknown
}

// Does the match survive this pattern's filter predicates? Unknown predicates and
// #set! directives are ignored (never reject). A failed-to-compile regex rejects
// (falls back to the pre-evaluator stripped behavior).
predicate_pass :: proc(pp: PatternPreds, m: ^ts.QueryMatch, nt: NodeText) -> bool {
	for p in pp.preds {
		if !predicate_eval(p, m, nt) {
			return false
		}
	}
	return true
}

@(private = "file")
predicate_eval :: proc(p: Predicate, m: ^ts.QueryMatch, nt: NodeText) -> bool {
	#partial switch p.kind {
	case .Set, .Unknown:
		return true
	}
	if p.subject == PRED_NO_CAP {
		return true
	}

	#partial switch p.kind {
	case .Eq, .NotEq, .AnyEq, .AnyNotEq:
		target := p.value
		if p.operand != PRED_NO_CAP {
			on := predicate_first_node(m, p.operand)
			if on == nil {
				return true
			}
			target = pred_node_text(nt, on.?)
		}
		all_eq, any_eq := true, false
		seen := false
		for i in 0 ..< int(m.capture_count) {
			if m.captures[i].index != p.subject {
				continue
			}
			seen = true
			t := pred_node_text(nt, m.captures[i].node)
			eq := t == target
			all_eq = all_eq && eq
			any_eq = any_eq || eq
		}
		if !seen {
			return true
		}
		#partial switch p.kind {
		case .Eq:
			return all_eq
		case .AnyEq:
			return any_eq
		case .NotEq, .AnyNotEq:
			return !all_eq
		}

	case .Match, .NotMatch, .AnyMatch, .AnyNotMatch:
		if !p.re_ok {
			return false
		}
		all_m, any_m := true, false
		seen := false
		for i in 0 ..< int(m.capture_count) {
			if m.captures[i].index != p.subject {
				continue
			}
			seen = true
			ok := regex_matches(p.re, pred_node_text(nt, m.captures[i].node))
			all_m = all_m && ok
			any_m = any_m || ok
		}
		if !seen {
			return true
		}
		#partial switch p.kind {
		case .Match:
			return all_m
		case .AnyMatch:
			return any_m
		case .NotMatch, .AnyNotMatch:
			return !all_m
		}

	case .LuaMatch, .NotLuaMatch:
		all_m := true
		seen := false
		for i in 0 ..< int(m.capture_count) {
			if m.captures[i].index != p.subject {
				continue
			}
			seen = true
			txt := pred_node_text(nt, m.captures[i].node)
			ok := lua_pattern_match(txt, p.value)
			all_m = all_m && ok
		}
		if !seen {
			return true
		}
		return all_m if p.kind == .LuaMatch else !all_m

	case .AnyOf, .NotAnyOf:
		all_in := true
		seen := false
		for i in 0 ..< int(m.capture_count) {
			if m.captures[i].index != p.subject {
				continue
			}
			seen = true
			t := pred_node_text(nt, m.captures[i].node)
			in_set := false
			for v in p.values {
				if v == t {
					in_set = true
					break
				}
			}
			all_in = all_in && in_set
		}
		if !seen {
			return true
		}
		return all_in if p.kind == .AnyOf else !all_in

	case .HasParent, .NotHasParent:
		node := predicate_first_node(m, p.subject)
		if node == nil {
			return true
		}
		parent := ts.node_parent(node.?)
		hit := !ts.node_is_null(parent) && predicate_type_in(string(ts.node_type(parent)), p.values)
		return hit if p.kind == .HasParent else !hit

	case .HasAncestor, .NotHasAncestor:
		node := predicate_first_node(m, p.subject)
		if node == nil {
			return true
		}
		hit := false
		cur := ts.node_parent(node.?)
		for !ts.node_is_null(cur) {
			if predicate_type_in(string(ts.node_type(cur)), p.values) {
				hit = true
				break
			}
			cur = ts.node_parent(cur)
		}
		return hit if p.kind == .HasAncestor else !hit
	}
	return true
}

@(private = "file")
predicate_type_in :: proc(t: string, values: []string) -> bool {
	for v in values {
		if v == t {
			return true
		}
	}
	return false
}

@(private = "file")
predicate_first_node :: proc(m: ^ts.QueryMatch, cap: u32) -> Maybe(ts.Node) {
	for i in 0 ..< int(m.capture_count) {
		if m.captures[i].index == cap {
			return m.captures[i].node
		}
	}
	return nil
}

// Reused across regex checks so #match? evaluation allocates nothing per match.
// Predicate evaluation is main-thread only (paint/preview), so a shared buffer is safe.
@(private = "file")
g_re_capture: regex.Capture
@(private = "file")
g_re_capture_ready: bool

@(private = "file")
regex_matches :: proc(re: regex.Regular_Expression, s: string) -> bool {
	if !g_re_capture_ready {
		g_re_capture = regex.preallocate_capture(os.heap_allocator())
		g_re_capture_ready = true
	}
	_, ok := regex.match_with_preallocated_capture(re, s, &g_re_capture)
	return ok
}

@(private = "file")
lua_pattern_match :: proc(haystack, pattern: string) -> bool {
	matches: [match.MAX_CAPTURES]match.Match
	captures, err := match.find_aux(haystack, pattern, 0, true, &matches)
	return err == .OK && captures > 0
}

pred_node_text :: proc(nt: NodeText, node: ts.Node) -> string {
	if nt.buffer != nil {
		sp := ts.node_start_point(node)
		ep := ts.node_end_point(node)
		return buffer_text_span(nt.buffer, int(sp.row), int(sp.column), int(ep.row), int(ep.column))
	}
	sb := ts.node_start_byte(node)
	eb := ts.node_end_byte(node)
	if int(sb) > len(nt.src) || int(eb) > len(nt.src) || eb < sb {
		return ""
	}
	return nt.src[sb:eb]
}

// The literal `#set! injection.language <name>` for a pattern, if present.
pattern_injection_language :: proc(pp: PatternPreds) -> (string, bool) {
	for p in pp.preds {
		if p.kind == .Set && p.set_key == "injection.language" && p.set_val != "" {
			return p.set_val, true
		}
	}
	return "", false
}

query_predicates_destroy :: proc(list: ^[dynamic]PatternPreds) {
	for pp in list {
		for p in pp.preds {
			if p.re_ok {
				regex.destroy(p.re, os.heap_allocator())
			}
			if p.values != nil {
				delete(p.values, os.heap_allocator())
			}
		}
		delete(pp.preds, os.heap_allocator())
	}
	delete(list^)
}

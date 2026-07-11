package main

import "core:os"
import "core:testing"
import "lib:tb2"

// The capture lookup + resolution is exercised on hermetic local maps (no global
// theme state), so it runs in parallel with the rest of the suite.

@(private = "file")
sty :: proc(key: string, attrs: u64 = 0) -> CaptureStyle {
	return CaptureStyle{color_key = key, attrs = attrs}
}

@(test)
test_capture_prefix_fallback :: proc(t: ^testing.T) {
	caps := make(map[string]CaptureStyle, context.temp_allocator)
	caps["comment"] = sty("syntax_comment")

	// comment.documentation in rust falls back through comment.documentation ->
	// comment (no rust/ override exists at either step).
	s, ok := capture_style_find(caps, "rust", "comment.documentation")
	testing.expect(t, ok, "prefix fallback finds the shorter comment entry")
	testing.expect(t, s.color_key == "syntax_comment", "resolves to the comment color key")

	// A capture with no matching prefix at all stays unmapped.
	_, miss := capture_style_find(caps, "rust", "variable")
	testing.expect(t, !miss, "an unmapped capture is not found")
}

@(test)
test_capture_language_precedence :: proc(t: ^testing.T) {
	caps := make(map[string]CaptureStyle, context.temp_allocator)
	caps["punctuation.special"] = sty("foreground")
	caps["markdown/punctuation.special"] = sty("syntax_keyword")
	caps["comment"] = sty("syntax_comment")
	caps["rust/comment"] = sty("syntax_string")

	// Language-qualified wins over global at the same prefix step.
	s, _ := capture_style_find(caps, "markdown", "punctuation.special")
	testing.expect(t, s.color_key == "syntax_keyword", "markdown override wins over global")
	g, _ := capture_style_find(caps, "python", "punctuation.special")
	testing.expect(t, g.color_key == "foreground", "another language falls back to the global entry")

	// Global at a LONGER prefix beats a language override at a SHORTER prefix:
	// order is rust/comment.documentation, comment.documentation, rust/comment, comment.
	caps["comment.documentation"] = sty("syntax_type")
	d, _ := capture_style_find(caps, "rust", "comment.documentation")
	testing.expect(
		t,
		d.color_key == "syntax_type",
		"global comment.documentation beats rust/comment (longer prefix first)",
	)
}

@(test)
test_capture_resolve :: proc(t: ^testing.T) {
	caps := make(map[string]CaptureStyle, context.temp_allocator)
	caps["number"] = sty("syntax_numbers")
	caps["function"] = sty("foreground")
	caps["title"] = sty("syntax_keyword", u64(tb2.Color.Bold))
	caps["broken"] = sty("nonexistent_key")

	colors := make(map[string]tb2.Color, context.temp_allocator)
	colors["syntax_numbers"] = tb2.Color(0xe067ea)
	colors["syntax_keyword"] = tb2.Color(0xffdd33)
	colors["foreground"] = tb2.Color(0xf4f4ff)

	// Novel (user-defined) color key resolves.
	c, ok := capture_resolve(caps, colors, "python", "number")
	testing.expect(t, ok && c == tb2.Color(0xe067ea), "novel color key resolves")

	// Explicit-plain: function -> foreground paints (ok=true) with the fg color, so
	// it OVERWRITES an earlier paint. An unmapped capture returns ok=false (leaves
	// prior paint alone).
	fc, fok := capture_resolve(caps, colors, "odin", "function")
	testing.expect(t, fok && fc == tb2.Color(0xf4f4ff), "function maps to explicit foreground (paints)")
	_, unmapped := capture_resolve(caps, colors, "odin", "variable")
	testing.expect(t, !unmapped, "an unmapped capture does not paint")

	// Attrs fold into the resolved color.
	tc, tok := capture_resolve(caps, colors, "markdown", "title")
	testing.expect(t, tok && tc == color_attr(tb2.Color(0xffdd33), .Bold), "bold attr folds into the color")

	// A capture pointing at a color key that doesn't resolve is ignored (no paint).
	_, brk := capture_resolve(caps, colors, "python", "broken")
	testing.expect(t, !brk, "capture with an unresolvable color key does not paint")
}

@(test)
test_capture_resolve_verbose :: proc(t: ^testing.T) {
	caps := make(map[string]CaptureStyle, context.temp_allocator)
	caps["comment"] = sty("syntax_comment")
	caps["python/constant"] = sty("syntax_keyword", u64(tb2.Color.Bold))
	caps["broken"] = sty("nonexistent_key")

	colors := make(map[string]tb2.Color, context.temp_allocator)
	colors["syntax_comment"] = tb2.Color(0x808080)
	colors["syntax_keyword"] = tb2.Color(0xffdd33)

	// Prefix fallback records every composite key tried, in order, up to the hit:
	// rust/comment.documentation, comment.documentation, rust/comment, comment.
	tried := make([dynamic]string, context.temp_allocator)
	ck, col, attrs, mapped, resolved := capture_resolve_verbose(caps, colors, "rust", "comment.documentation", &tried)
	testing.expect(t, mapped && resolved, "resolves through prefix fallback")
	testing.expect_value(t, ck, "syntax_comment")
	testing.expect_value(t, col, tb2.Color(0x808080))
	testing.expect_value(t, attrs, u64(0))
	testing.expect_value(t, len(tried), 4)
	testing.expect_value(t, tried[0], "rust/comment.documentation")
	testing.expect_value(t, tried[len(tried) - 1], "comment")

	// Language-qualified hit on the first step, attrs folded in.
	t2 := make([dynamic]string, context.temp_allocator)
	ck2, _, at2, m2, r2 := capture_resolve_verbose(caps, colors, "python", "constant", &t2)
	testing.expect(t, m2 && r2, "language-qualified constant resolves")
	testing.expect_value(t, ck2, "syntax_keyword")
	testing.expect_value(t, at2, u64(tb2.Color.Bold))
	testing.expect_value(t, len(t2), 1)
	testing.expect_value(t, t2[0], "python/constant")

	// Mapped capture whose color key does not resolve: mapped but not resolved.
	t3 := make([dynamic]string, context.temp_allocator)
	ck3, _, _, m3, r3 := capture_resolve_verbose(caps, colors, "python", "broken", &t3)
	testing.expect(t, m3 && !r3, "capture with an unresolvable color key is mapped but unresolved")
	testing.expect_value(t, ck3, "nonexistent_key")

	// A capture with no style entry at all is unmapped.
	t4 := make([dynamic]string, context.temp_allocator)
	_, _, _, m4, _ := capture_resolve_verbose(caps, colors, "python", "variable", &t4)
	testing.expect(t, !m4, "unmapped capture reports mapped=false")
}

@(test)
test_parse_capture_style :: proc(t: ^testing.T) {
	s := parse_capture_style("syntax_keyword bold italic")
	defer delete(s.color_key, os.heap_allocator())
	testing.expect(t, s.color_key == "syntax_keyword", "first field is the color key")
	testing.expect(t, s.attrs == u64(tb2.Color.Bold) | u64(tb2.Color.Italic), "bold+italic attrs parsed")

	plain := parse_capture_style("foreground")
	defer delete(plain.color_key, os.heap_allocator())
	testing.expect(t, plain.color_key == "foreground" && plain.attrs == 0, "no attrs")
}

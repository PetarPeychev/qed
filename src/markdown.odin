package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:unicode"
import "core:unicode/utf8"
import cm "lib:cmark_gfm"
import lh "lib:litehtml"
import "lib:tb2"

// litehtml lays out in pixels: one cell is 8x16, the font is one row tall, so every em is a row and every ch a column
MD_CELL_W :: 8
MD_CELL_H :: 16
MD_DETAILS_ID :: "qed-details-"
MD_PIECE_MARK :: "<!--qed-piece %x "
// litehtml grows faster than linearly, so the document is laid out in pieces; a cut goes after one block in
// MD_CHUNK_ODDS whose source hashes to it, so an edit moves no cut but its own and the pieces after it stay reusable
MD_CHUNK_ODDS :: 8
// repeated blocks hash alike: without a floor they would make a piece each
MD_CHUNK_MIN :: 512
MD_CHUNK_MAX :: 16384
// an unclosed raw HTML tag would keep every later block in one piece
MD_CHUNK_FORCE :: 8 * MD_CHUNK_MAX
// a hostile height (`style="height: 1e8px"`) must not become millions of rows
MD_PIECE_ROWS_MAX :: 20_000

MD_LINE_U :: 1
MD_LINE_D :: 2
MD_LINE_L :: 4
MD_LINE_R :: 8

MdLineStyle :: enum u8 {
	Light,
	Heavy,
	Double,
}

MdCell :: struct {
	text:   string,
	fg, bg: tb2.Color,
	link:   i32,
	lines:  u8,
	style:  MdLineStyle,
	tail:   bool,
}

MdImage :: struct {
	ref:       ImageRef,
	x, y:      int,
	path, alt: string,
}

MdSummary :: struct {
	x, y, w, h: int,
	index:      int,
}

MdAnchor :: struct {
	id:  string,
	row: int,
}

// source rows, details indices and anchor ids are relative to the piece, so a piece reuses across edits above it
MdChunk :: struct {
	arena:     vmem.Arena,
	html:      string,
	style_hash:  u64,
	width:     int,
	rows:      [][]MdCell,
	src:       []int,
	links:     []string,
	anchors:   []MdAnchor,
	images:    []MdImage,
	summaries: []MdSummary,
	cols:      int,
}

MdOpenTag :: struct {
	name, tag: string,
}

MdPiece :: struct {
	html:    string,
	line:    int,
	details: int,
}

MdDoc :: struct {
	rows:      [][]MdCell,
	src:       []int,
	link_base: []i32,
	links:     []string,
	anchors:   map[string]int,
	images:    []MdImage,
	summaries: []MdSummary,
	width:     int,
}

MdImageInfo :: struct {
	path, alt: string,
	w, h:      int,
}

MdInput :: struct {
	source, dir, css: string,
	style_hash:       u64,
	palette_hash:     u64,
	lang:             Language,
	width:            int,
	open:             []int,
	bullet:           tb2.Color,
	images_on:        bool,
	image_cell:       [2]int,
	image_max_rows:   int,
	langs:            map[string]Language,
	queries:          [Language]HighlightQuery,
}

MdJob :: struct {
	input:     MdInput,
	prev:      []^MdChunk,
	pieces:    []MdPiece,
	chunks:    []^MdChunk,
	ready:     int,
	cancel:    bool,
	nonce:     u64,
	images:    map[string]MdImageInfo,
	prev_code: map[string][]string,
	code:      map[string][]string,
	// the code cache outlives the job: the next render reads it
	code_allocator: runtime.Allocator,
	// pieces go here when set, else each gets its own arena (freed one by one as renders replace them)
	allocator: runtime.Allocator,
}

// litehtml's own master sheet costs more to parse than a small document: only what cmark-gfm and README HTML use
MD_MASTER_CSS :: `html, body, div, p, h1, h2, h3, h4, h5, h6, center, section, article, header, footer, nav, details, summary, figure, figcaption, address, main, aside { display: block; }
head, meta, title, link, style, script, template { display: none; }
span, a, b, strong, i, em, cite, code, kbd, samp, tt, var, del, s, strike, ins, u, sup, sub, small, big, mark, abbr, q, label { display: inline; }
b, strong, th { font-weight: bold; }
i, em, cite, var { font-style: italic; }
ins, u { text-decoration: underline; }
del, s, strike { text-decoration: line-through; }
center { text-align: center; }
br { display: inline-block; }
img { display: inline-block; }
img[align="right"] { float: right; }
img[align="left"] { float: left; }
hr { display: block; }
table { display: table; border-collapse: separate; box-sizing: border-box; }
tbody, tfoot, thead { display: table-row-group; vertical-align: middle; }
tr { display: table-row; vertical-align: inherit; }
td, th { display: table-cell; vertical-align: inherit; }
caption { display: table-caption; }
td[nowrap], th[nowrap] { white-space: nowrap; }
tt, code, kbd, samp, pre { font-family: monospace; }
pre { display: block; white-space: pre; }
ul, ol, menu, dir { display: block; }
ul { list-style-type: disc; }
ol { list-style-type: decimal; }
li { display: list-item; }
dl, dt { display: block; }
dd { display: block; margin-left: 4ch; }
blockquote { display: block; }
input { display: inline-block; }
[align="center"] { text-align: center; }
[align="right"] { text-align: right; }
[align="left"] { text-align: left; }
`

MdStyle :: struct {
	fg, heading, code, code_bg, link, bullet, checked, quote, border, dim: tb2.Color,
}

MdAlert :: struct {
	name, title, icon: string,
}

MD_ALERTS := [?]MdAlert {
	{"note", "Note", "ⓘ"},
	{"tip", "Tip", "💡"},
	{"important", "Important", "❗"},
	{"warning", "Warning", "⚠"},
	{"caution", "Caution", "⛔"},
}

@(private = "file")
md_ascii_bytes: [128]u8

@(init, private = "file")
md_ascii_init :: proc "contextless" () {
	for i in 0 ..< 128 {
		md_ascii_bytes[i] = u8(i)
	}
}

md_style :: proc() -> MdStyle {
	capture :: proc(name: string, fallback: tb2.Color) -> tb2.Color {
		color, ok := syntax_capture_color("markdown", name)
		return color if ok else fallback
	}
	style := MdStyle {
		fg = COLOR_PANE_FG,
		heading = capture("text.title", color_attr(COLOR_PANE_PROMPT_FG, .Bold)),
		code = capture("text.literal", COLOR_SYN_CODE),
		code_bg = color_over(COLOR_PANE_BG, COLOR_PANE_SEL_BG, MARKDOWN_CODE_TINT),
		link = capture("text.reference", COLOR_SYN_TYPE),
		bullet = capture("punctuation.special", COLOR_PANE_PROMPT_FG),
		checked = capture("string", COLOR_SYN_STRING),
		quote = COLOR_PANE_BORDER,
		border = COLOR_PANE_BORDER,
		dim = COLOR_PANE_SHORTCUT_FG,
	}
	// light themes pick a faint code color; on the band it must stay readable
	if md_contrast(style.code, style.code_bg) < 3 {
		style.code = tb2.Color(u64(COLOR_PANE_FG) | color_attrs(style.code))
	}
	return style
}

md_contrast :: proc(a, b: tb2.Color) -> f32 {
	luminance :: proc(color: tb2.Color) -> f32 {
		channel :: proc(value: u64) -> f32 {
			level := f32(value & 0xff) / 255
			return level / 12.92 if level <= 0.03928 else math.pow((level + 0.055) / 1.055, 2.4)
		}
		rgb := u64(color)
		return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
	}
	first, second := luminance(a), luminance(b)
	return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

md_hex :: proc(color: tb2.Color) -> string {
	return fmt.tprintf("#%06x", u64(color) & COLOR_RGB_MASK)
}

md_css_color :: proc(color: tb2.Color) -> string {
	attrs := color_attrs(color)
	return fmt.tprintf(
		"color: %s;%s%s%s",
		md_hex(color),
		" font-weight: bold;" if attrs & u64(tb2.Color.Bold) != 0 else "",
		" font-style: italic;" if attrs & u64(tb2.Color.Italic) != 0 else "",
		" text-decoration: underline;" if attrs & u64(tb2.Color.Underline) != 0 else "",
	)
}

md_css :: proc(style: MdStyle) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		`body {{ margin: 0; padding: 0; color: %[0]s; font-family: sans-serif; font-size: 16px; line-height: normal; }}
p, ul, ol, dl, table, pre, blockquote, details, hr, section {{ margin-top: 0; margin-bottom: 1em; }}
body > *:first-child {{ margin-top: 0 !important; }}
body > *:last-child {{ margin-bottom: 0 !important; }}
h1, h2, h3, h4, h5, h6 {{ font-size: 1em; font-weight: bold; margin: 1em 0 1em 0; %[1]s }}
h1 {{ border-bottom: 1em groove %[2]s; }}
h2 {{ border-bottom: 1em solid %[6]s; }}
sup, sub, small, big, code, kbd, samp, tt, pre {{ font-size: 1em; vertical-align: baseline; }}
ul {{ padding-left: 2ch; margin-left: 0; }}
ol {{ padding-left: 3ch; margin-left: 0; }}
ul ul, ul ol, ol ol, ol ul {{ margin-top: 0; margin-bottom: 0; }}
li > p {{ margin-top: 1em; margin-bottom: 0; }}
li:first-child > p:first-child {{ margin-top: 0; }}
ul {{ list-style-type: disc; }}
ul ul {{ list-style-type: circle; }}
ul ul ul {{ list-style-type: square; }}
li:has(> .task), li:has(> p:first-child > .task) {{ list-style-type: none; }}
.task {{ font-family: monospace; color: %[8]s; }}
.task.done {{ color: %[9]s; }}
details > *:not(summary) {{ display: none; }}
details[open] > *:not(summary) {{ display: block; }}
summary::before {{ content: "▶ "; }}
details[open] > summary::before {{ content: "▼ "; }}
summary {{ font-weight: bold; margin-bottom: 1em; }}
code, kbd, samp, tt {{ font-family: monospace; %[3]s background: %[4]s; }}
pre {{ font-family: monospace; background: %[4]s; padding: 0 1ch; white-space: pre-wrap; overflow: hidden; }}
pre code {{ background: transparent; }}
blockquote {{ margin-left: 0; margin-right: 0; padding: 0 0 0 1ch; border-left: 1ch solid %[5]s; color: %[8]s; }}
blockquote.alert {{ color: %[0]s; }}
.alert-title {{ font-weight: bold; margin-bottom: 0; }}
hr {{ border: 0; border-top: 1em solid %[6]s; height: 0; background: transparent; }}
table {{ border-collapse: collapse; border-spacing: 0; }}
th, td {{ padding: 0 1ch; border-left: 1ch solid %[6]s; border-right: 1ch solid %[6]s; border-top: 1em solid %[6]s; border-bottom: 1em solid %[6]s; vertical-align: top; }}
th {{ font-weight: bold; }}
img {{ max-width: 100%%; }}
td img, th img {{ width: 100%%; }}
a {{ %[7]s text-decoration: underline; }}
strong, b {{ font-weight: bold; }}
em, i {{ font-style: italic; }}
del, s {{ text-decoration: line-through; }}
.image-alt {{ color: %[8]s; }}
section.footnotes {{ border-top: 1em solid %[6]s; color: %[8]s; }}
sup.footnote-ref::before {{ content: "["; }}
sup.footnote-ref::after {{ content: "]"; }}
`,
		md_hex(style.fg),
		md_css_color(style.heading),
		md_hex(style.heading),
		md_css_color(style.code),
		md_hex(style.code_bg),
		md_hex(style.quote),
		md_hex(style.border),
		md_css_color(style.link),
		md_hex(style.dim),
		md_hex(style.checked),
	)
	alert_colors := [len(MD_ALERTS)]tb2.Color{COLOR_DIAG_INFO_FG, COLOR_GIT_ADD, COLOR_SYN_KEYWORD, COLOR_DIAG_WARN_FG, COLOR_DIAG_ERROR_FG}
	for alert, i in MD_ALERTS {
		fmt.sbprintf(&sb, ".alert-%s {{ border-left-color: %s; }}\n.alert-%s > .alert-title {{ color: %s; }}\n", alert.name, md_hex(alert_colors[i]), alert.name, md_hex(alert_colors[i]))
	}
	return strings.to_string(sb)
}

md_escape_plain :: proc(text: string) -> string {
	blank :: proc(line: string) -> bool {
		return strings.trim(line, " \t") == ""
	}
	sb := strings.builder_make(context.temp_allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	for raw, k in lines {
		line := strings.trim_right(raw, "\r")
		indent := 0
		for indent < len(line) && line[indent] == ' ' {
			indent += 1
		}
		for _ in 0 ..< indent {
			strings.write_string(&sb, " ")
		}
		for char in transmute([]u8)line[indent:] {
			if md_is_punct(char) {
				strings.write_byte(&sb, '\\')
			}
			strings.write_byte(&sb, char)
		}
		if k < len(lines) - 1 {
			gap := blank(line) || (k + 1 < len(lines) && blank(lines[k + 1]))
			strings.write_string(&sb, "\n" if gap else "\\\n")
		}
	}
	return strings.to_string(sb)
}

md_is_punct :: proc(char: u8) -> bool {
	return (char >= '!' && char <= '/') || (char >= ':' && char <= '@') || (char >= '[' && char <= '`') || (char >= '{' && char <= '~')
}

md_fence_word :: proc(info: string) -> string {
	word := strings.trim_space(info)
	if space := strings.index_any(word, " {,"); space >= 0 {
		word = word[:space]
	}
	return word
}

// the language table, the parsers and the theme belong to the main thread: a render gets copies
md_input_make :: proc(source, dir: string, lang: Language, width: int, open: []int, allocator := context.allocator) -> MdInput {
	cm.init()
	style := md_style()
	css := md_css(style)
	input := MdInput {
		source         = strings.clone(source, allocator),
		dir            = strings.clone(dir, allocator),
		css            = strings.clone(css, allocator),
		lang           = lang,
		width          = width,
		open           = slice.clone(open, allocator),
		bullet         = style.bullet,
		images_on      = image_enabled(),
		image_cell     = g_image_cell,
		image_max_rows = IMAGE_MAX_ROWS,
		langs          = make(map[string]Language, allocator),
	}
	want := [Language]bool{}
	want[lang] = true
	rest := source
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		line := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end + 1:]
		fence := strings.trim_left(line, " >-*+0123456789.\t")
		if !strings.has_prefix(fence, "```") && !strings.has_prefix(fence, "~~~") {
			continue
		}
		word := md_fence_word(strings.trim_left(fence, "`~"))
		if word == "" || word in input.langs {
			continue
		}
		if language := language_of_name(word); language != .Plain {
			input.langs[strings.clone(word, allocator)] = language
			want[language] = true
		}
	}
	fallback := COLOR_FG
	input.palette_hash = hash.fnv64a(slice.bytes_from_ptr(&fallback, size_of(fallback)))
	for on, language in want {
		if on && language != .Plain {
			input.queries[language], _ = highlight_query_clone(language, allocator)
			input.palette_hash = hash.fnv64a(slice.to_bytes(input.queries[language].colors), input.palette_hash)
		}
	}
	geometry := [4]int{input.image_cell.x, input.image_cell.y, input.image_max_rows, int(input.images_on)}
	input.style_hash = hash.fnv64a(slice.to_bytes(geometry[:]), hash.fnv64a(transmute([]u8)css, input.palette_hash))
	return input
}

md_input_free :: proc(input: ^MdInput) {
	for query in input.queries {
		highlight_query_free(query)
	}
}

md_html_escape :: proc(sb: ^strings.Builder, text: string) {
	for i in 0 ..< len(text) {
		switch text[i] {
		case '<':
			strings.write_string(sb, "&lt;")
		case '>':
			strings.write_string(sb, "&gt;")
		case '&':
			strings.write_string(sb, "&amp;")
		case '"':
			strings.write_string(sb, "&quot;")
		case:
			strings.write_byte(sb, text[i])
		}
	}
}

md_html_unescape :: proc(text: string) -> string {
	if strings.index_byte(text, '&') < 0 {
		return text
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); {
		if text[i] == '&' {
			if semi := strings.index_byte(text[i:], ';'); semi > 1 && semi < 10 {
				name := text[i + 1:i + semi]
				out := ""
				switch name {
				case "amp":
					out = "&"
				case "lt":
					out = "<"
				case "gt":
					out = ">"
				case "quot":
					out = "\""
				case "apos":
					out = "'"
				case "nbsp":
					out = " "
				case:
					if name[0] == '#' {
						hex := len(name) > 1 && (name[1] == 'x' || name[1] == 'X')
						code, ok := strconv.parse_int(name[2:] if hex else name[1:], 16 if hex else 10)
						if ok {
							strings.write_rune(&sb, rune(code))
							i += semi + 1
							continue
						}
					}
				}
				if out != "" {
					strings.write_string(&sb, out)
					i += semi + 1
					continue
				}
			}
		}
		strings.write_byte(&sb, text[i])
		i += 1
	}
	return strings.to_string(sb)
}

MdCodeCtx :: struct {
	ctx: runtime.Context,
	job: ^MdJob,
}

md_code_html :: proc "c" (user: rawptr, info, code: cstring, first_line: c.int) -> cstring {
	code_ctx := (^MdCodeCtx)(user)
	context = code_ctx.ctx
	job := code_ctx.job
	lang, found := job.input.langs[md_fence_word(string(info))]
	if !found {
		lang = job.input.lang
	}
	text := strings.trim_suffix(string(code), "\n")
	key := fmt.tprintf("%d:%x:%s", int(lang), job.input.palette_hash, text)
	lines, cached := job.code[key]
	if !cached {
		lines, cached = job.prev_code[key]
	}
	if !cached {
		lines = md_code_lines(job.input.queries[lang], text)
	}
	if key not_in job.code {
		stored := make([]string, len(lines), job.code_allocator)
		for line, k in lines {
			stored[k] = strings.clone(line, job.code_allocator)
		}
		job.code[strings.clone(key, job.code_allocator)] = stored
	}
	sb := strings.builder_make(context.temp_allocator)
	for line, k in lines {
		if k > 0 {
			strings.write_byte(&sb, '\n')
		}
		row := int(first_line) + k
		fmt.sbprintf(&sb, `<span data-sourcepos="%d:1-%d:1">%s</span>`, row, row, line)
	}
	out := strings.to_string(sb)
	buf := ([^]u8)(libc.malloc(uint(len(out) + 1)))
	copy(buf[:len(out)], out)
	buf[len(out)] = 0
	return cstring(buf)
}

md_code_lines :: proc(query: HighlightQuery, text: string) -> []string {
	lines := strings.split(text, "\n", context.temp_allocator)
	colors: [dynamic][dynamic]tb2.Color
	highlight_query_lines(query, lines, &colors)
	defer highlight_lines_destroy(&colors)
	out := make([]string, len(lines), context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	run := strings.builder_make(context.temp_allocator)
	flush :: proc(sb, run: ^strings.Builder, color: tb2.Color) {
		if strings.builder_len(run^) == 0 {
			return
		}
		if color == {} {
			strings.write_string(sb, strings.to_string(run^))
		} else {
			fmt.sbprintf(sb, `<span style="%s">%s</span>`, md_css_color(color), strings.to_string(run^))
		}
		strings.builder_reset(run)
	}
	for line, k in lines {
		strings.builder_reset(&sb)
		row_colors := colors[k][:] if k < len(colors) else nil
		current := tb2.Color(0)
		col := 0
		for i := 0; i < len(line); {
			color := row_colors[i] if i < len(row_colors) else tb2.Color(0)
			if color == query.fallback {
				color = {}
			}
			if color != current {
				flush(&sb, &run, current)
				current = color
			}
			char, size := utf8.decode_rune(line[i:])
			if char == '\t' {
				for next := (col / TAB_WIDTH + 1) * TAB_WIDTH; col < next; col += 1 {
					strings.write_byte(&run, ' ')
				}
			} else {
				md_html_escape(&run, line[i:i + size])
				col += 1
			}
			i += size
		}
		flush(&sb, &run, current)
		// an empty span has no box, so its row would take the source of the row above
		if len(line) == 0 {
			strings.write_byte(&sb, ' ')
		}
		out[k] = strings.clone(strings.to_string(sb), context.temp_allocator)
	}
	return out
}

md_slug :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for char in strings.to_lower(text, context.temp_allocator) {
		switch {
		case char == ' ':
			strings.write_byte(&sb, '-')
		case char == '-' || char == '_' || unicode.is_letter(char) || unicode.is_digit(char):
			strings.write_rune(&sb, char)
		}
	}
	return strings.to_string(sb)
}

md_tag_text :: proc(html: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	in_tag := false
	for i in 0 ..< len(html) {
		switch {
		case html[i] == '<':
			in_tag = true
		case html[i] == '>':
			in_tag = false
		case !in_tag:
			strings.write_byte(&sb, html[i])
		}
	}
	return md_html_unescape(strings.to_string(sb))
}

md_tag_attr :: proc(tag, name: string) -> (value: string, present: bool) {
	i := 0
	for i < len(tag) && tag[i] != ' ' && tag[i] != '\t' && tag[i] != '\n' && tag[i] != '>' && tag[i] != '/' {
		i += 1
	}
	for i < len(tag) {
		for i < len(tag) && (tag[i] == ' ' || tag[i] == '\t' || tag[i] == '\n' || tag[i] == '/') {
			i += 1
		}
		start := i
		for i < len(tag) && tag[i] != '=' && tag[i] != ' ' && tag[i] != '\t' && tag[i] != '\n' && tag[i] != '>' && tag[i] != '/' {
			i += 1
		}
		key := tag[start:i]
		val := ""
		if i < len(tag) && tag[i] == '=' {
			i += 1
			if i < len(tag) && (tag[i] == '"' || tag[i] == '\'') {
				quote := tag[i]
				end := strings.index_byte(tag[i + 1:], quote)
				end = len(tag) if end < 0 else i + 1 + end
				val = tag[i + 1:end]
				i = min(end + 1, len(tag))
			} else {
				from := i
				for i < len(tag) && tag[i] != ' ' && tag[i] != '>' {
					i += 1
				}
				val = tag[from:i]
			}
		}
		if key == "" {
			i += 1
			continue
		}
		if strings.equal_fold(key, name) {
			return val, true
		}
	}
	return "", false
}

md_tag_without :: proc(tag, name: string) -> string {
	val, present := md_tag_attr(tag, name)
	if !present {
		return tag
	}
	lower := strings.to_lower(tag, context.temp_allocator)
	at := strings.index(lower, fmt.tprintf(" %s", name))
	if at < 0 {
		return tag
	}
	end := at + 1 + len(name)
	if end < len(tag) && tag[end] == '=' {
		end += 1
		if end < len(tag) && (tag[end] == '"' || tag[end] == '\'') {
			end += len(val) + 2
		} else {
			end += len(val)
		}
	}
	return strings.concatenate({tag[:at], tag[min(end, len(tag)):]}, context.temp_allocator)
}

// a piece's source rows count from its first line, so its HTML stays the same when lines are added above it
md_tag_relative :: proc(tag: string, base: int) -> string {
	at := strings.index(tag, `data-sourcepos="`)
	if at < 0 {
		return tag
	}
	from := at + len(`data-sourcepos="`)
	end := from
	for end < len(tag) && tag[end] >= '0' && tag[end] <= '9' {
		end += 1
	}
	line, ok := strconv.parse_int(tag[from:end])
	if !ok {
		return tag
	}
	close := strings.index_byte(tag[end:], '"')
	close = len(tag) if close < 0 else end + close
	return fmt.tprintf("%s%d%s", tag[:from], line - base, tag[close:])
}

md_alert_at :: proc(rest: string) -> (alert: int, para_tag: string, skip: int, ok: bool) {
	if !strings.has_prefix(rest, "\n<p") {
		return
	}
	close := strings.index_byte(rest, '>')
	if close < 0 {
		return
	}
	para_tag = rest[1:close + 1]
	body := rest[close + 1:]
	if !strings.has_prefix(body, "[!") {
		return
	}
	end := strings.index_byte(body, ']')
	if end < 0 {
		return
	}
	name := body[2:end]
	for candidate, i in MD_ALERTS {
		if strings.equal_fold(candidate.name, name) {
			after := body[end + 1:]
			trail := 0
			for trail < len(after) && after[trail] == ' ' {
				trail += 1
			}
			switch {
			case strings.has_prefix(after[trail:], "</p>"):
				return i, "", close + 1 + end + 1 + trail + 4, true
			case strings.has_prefix(after[trail:], "\n"):
				return i, para_tag, close + 1 + end + 1 + trail + 1, true
			}
		}
	}
	return
}

md_void_tag :: proc(name: string) -> bool {
	switch name {
	case "br", "img", "hr", "input", "meta", "link", "wbr", "col", "area", "source", "embed", "param", "track", "base":
		return true
	}
	return false
}

md_html :: proc(job: ^MdJob) -> []MdPiece {
	input := &job.input
	text := input.source
	if strings.has_prefix(text, "---\n") || strings.has_prefix(text, "---\r\n") {
		lines := strings.split(text, "\n", context.temp_allocator)
		for k in 1 ..< len(lines) {
			line := strings.trim_right(lines[k], "\r")
			if line == "---" || line == "..." {
				lines[0], lines[k] = "```yaml", "```"
				text = strings.join(lines, "\n", context.temp_allocator)
				break
			}
		}
	}
	code_ctx := MdCodeCtx{context, job}
	raw := cm.to_html(raw_data(text), len(text), 1, job.nonce, md_code_html, &code_ctx)
	html := strings.clone(string(raw), context.temp_allocator)
	cm.free(raw)

	sb := strings.builder_make(0, len(html) + len(html) / 8, context.temp_allocator)
	details := make([dynamic]int, context.temp_allocator)
	open_tags := make([dynamic]MdOpenTag, context.temp_allocator)
	mark := fmt.tprintf(MD_PIECE_MARK, job.nonce)
	pieces := make([dynamic]MdPiece)
	starts := make([dynamic]int, context.temp_allocator)
	append(&starts, 0)
	details_n := 0
	piece := MdPiece{line = 1}
	from, tags, block_line := 0, 0, 1
	line_starts := make([dynamic]int, 0, len(text) / 32 + 1, context.temp_allocator)
	append(&line_starts, 0)
	for char, at in transmute([]u8)text {
		if char == '\n' {
			append(&line_starts, at + 1)
		}
	}
	i := 0
	for i < len(html) {
		lt := strings.index_byte(html[i:], '<')
		if lt < 0 {
			strings.write_string(&sb, html[i:])
			break
		}
		strings.write_string(&sb, html[i:i + lt])
		i += lt
		tags += 1
		if tags % 256 == 0 && sync.atomic_load(&job.cancel) {
			return nil
		}
		if strings.has_prefix(html[i:], "<!--") {
			end := strings.index(html[i:], "-->")
			end = len(html) if end < 0 else i + end + 3
			if strings.has_prefix(html[i:], mark) && end - 3 > i + len(mark) {
				line, _ := strconv.parse_int(strings.trim_space(html[i + len(mark):end - 3]))
				if line <= block_line || line > len(line_starts) {
					i = end
					continue
				}
				size := strings.builder_len(sb) - from
				block := text[line_starts[block_line - 1]:line_starts[line - 1]]
				block_line = line
				boundary := (size >= MD_CHUNK_MIN && hash.fnv32a(transmute([]u8)block) % MD_CHUNK_ODDS == 0) || size >= MD_CHUNK_MAX
				if boundary && (len(open_tags) == 0 || size >= MD_CHUNK_FORCE) {
					// a forced cut closes what is open and reopens it, so each piece is whole HTML
					#reverse for open in open_tags {
						fmt.sbprintf(&sb, "</%s>", open.name)
					}
					append(&pieces, piece)
					from = strings.builder_len(sb)
					append(&starts, from)
					piece = {line = line, details = details_n}
					for open in open_tags {
						strings.write_string(&sb, open.tag)
					}
				}
			} else {
				strings.write_string(&sb, html[i:end])
			}
			i = end
			continue
		}
		gt := strings.index_byte(html[i:], '>')
		if gt < 0 {
			strings.write_string(&sb, html[i:])
			break
		}
		tag := html[i:i + gt + 1]
		i += gt + 1
		k := 1
		closing := k < len(tag) && tag[k] == '/'
		if closing {
			k += 1
		}
		name_end := k
		for name_end < len(tag) && (md_ascii_alnum(tag[name_end])) {
			name_end += 1
		}
		name := strings.to_lower(tag[k:name_end], context.temp_allocator)
		if !closing {
			tag = md_tag_relative(tag, piece.line)
		}
		written := strings.builder_len(sb)
		switch {
		case !closing && len(name) == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6':
			_, has_id := md_tag_attr(tag, "id")
			end := strings.index(html[i:], fmt.tprintf("</%s", name))
			if has_id || end < 0 {
				strings.write_string(&sb, tag)
				break
			}
			fmt.sbprintf(&sb, `%s id="`, tag[:name_end])
			md_html_escape(&sb, md_slug(strings.trim_space(md_tag_text(html[i:i + end]))))
			strings.write_string(&sb, `"`)
			strings.write_string(&sb, tag[name_end:])
		case !closing && name == "blockquote":
			alert_index, para, skip, ok := md_alert_at(html[i:])
			if !ok {
				strings.write_string(&sb, tag)
				break
			}
			alert := MD_ALERTS[alert_index]
			fmt.sbprintf(&sb, `%s class="alert alert-%s"%s`, tag[:name_end], alert.name, tag[name_end:])
			fmt.sbprintf(&sb, "\n<p class=\"alert-title\">%s %s</p>\n%s", alert.icon, alert.title, md_tag_relative(para, piece.line))
			i += skip
			if para != "" {
				append(&open_tags, MdOpenTag{"p", strings.clone(para, context.temp_allocator)})
			}
		case !closing && name == "img":
			src_attr, _ := md_tag_attr(tag, "src")
			alt_attr, _ := md_tag_attr(tag, "alt")
			src_value, alt := md_html_unescape(src_attr), md_html_unescape(alt_attr)
			info, ok := md_image_info(input, src_value, alt)
			if !ok {
				strings.write_string(&sb, `<span class="image-alt">[image`)
				if alt != "" {
					strings.write_string(&sb, ": ")
					md_html_escape(&sb, alt)
				}
				strings.write_string(&sb, "]</span>")
				break
			}
			job.images[strings.clone(src_value)] = info
			strings.write_string(&sb, tag)
		case !closing && name == "details":
			index := details_n
			details_n += 1
			append(&details, index)
			_, was_open := md_tag_attr(tag, "open")
			toggled := slice.contains(input.open, index)
			stripped := md_tag_without(tag, "open")
			strings.write_string(&sb, stripped[:name_end])
			if was_open != toggled {
				strings.write_string(&sb, " open")
			}
			strings.write_string(&sb, stripped[name_end:])
		case closing && name == "details":
			if len(details) > 0 {
				pop(&details)
			}
			strings.write_string(&sb, tag)
		case !closing && name == "summary" && len(details) > 0:
			fmt.sbprintf(&sb, `%s id="%s%d"%s`, tag[:name_end], MD_DETAILS_ID, details[len(details) - 1] - piece.details, tag[name_end:])
		case !closing && name == "input":
			kind, _ := md_tag_attr(tag, "type")
			if !strings.equal_fold(kind, "checkbox") {
				strings.write_string(&sb, tag)
				break
			}
			_, checked := md_tag_attr(tag, "checked")
			strings.write_string(&sb, `<span class="task done">☑</span>` if checked else `<span class="task">☐</span>`)
		case:
			strings.write_string(&sb, tag)
		}
		switch {
		case name == "" || md_void_tag(name) || strings.has_suffix(tag, "/>"):
		case !closing:
			opened := strings.to_string(sb)[written:]
			if close := strings.index_byte(opened, '>'); close >= 0 {
				opened = opened[:close + 1]
			}
			append(&open_tags, MdOpenTag{name, strings.clone(opened, context.temp_allocator)})
		case:
			// a stray closer matches nothing open and is ignored, so it can't let a cut land inside an element
			for depth := len(open_tags) - 1; depth >= 0; depth -= 1 {
				if open_tags[depth].name == name {
					resize(&open_tags, depth)
					break
				}
			}
		}
	}
	append(&pieces, piece)
	append(&starts, strings.builder_len(sb))
	out := strings.to_string(sb)
	for &each, k in pieces {
		each.html = out[starts[k]:starts[k + 1]]
	}
	return pieces[:]
}

md_image_info :: proc(input: ^MdInput, src, alt: string) -> (info: MdImageInfo, ok: bool) {
	if !input.images_on || input.dir == "" {
		return
	}
	path := image_resolve(input.dir, src)
	if path == "" {
		return
	}
	stat, err := os.stat(path, context.temp_allocator)
	if err != nil || stat.size > IMAGE_MAX_FILE_BYTES {
		return
	}
	w, h, valid := image_header_size(image_head(path))
	if !valid || w * h > IMAGE_MAX_PIXELS {
		return
	}
	cols, rows := image_cells(w, h, len(IMAGE_DIACRITICS), input.image_max_rows, input.image_cell.x, input.image_cell.y)
	return {strings.clone(path), strings.clone(alt), cols * MD_CELL_W, rows * MD_CELL_H}, true
}

md_ascii_alnum :: proc(char: u8) -> bool {
	return (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9')
}

md_text_width :: proc(text: string) -> int {
	ascii := true
	for char in transmute([]u8)text {
		ascii &&= char >= 0x20 && char < 0x7f
	}
	if ascii {
		return len(text)
	}
	width := 0
	it := utf8.decode_grapheme_iterator_make(text)
	prev := 0
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if grapheme.byte_index > prev {
			width += cluster_width(transmute([]u8)text[prev:grapheme.byte_index])
			prev = grapheme.byte_index
		}
	}
	if prev < len(text) {
		width += cluster_width(transmute([]u8)text[prev:])
	}
	return width
}

MD_NO_SOURCE :: min(int)

MdPaint :: struct {
	ctx:       runtime.Context,
	job:       ^MdJob,
	cols:      int,
	rows:      [dynamic][]MdCell,
	clips:     [dynamic][4]int,
	links:     [dynamic]string,
	sources:   [dynamic][2]int,
	anchors:   [dynamic]MdAnchor,
	images:    [dynamic]MdImage,
	summaries: [dynamic]MdSummary,
}

@(private = "file")
md_cx :: proc(x: f32) -> int {
	return int(math.round(x / MD_CELL_W))
}

@(private = "file")
md_cy :: proc(y: f32) -> int {
	return clamp(int(math.round(y / MD_CELL_H)), 0, MD_PIECE_ROWS_MAX)
}

@(private = "file")
md_box_cells :: proc(box: lh.Rect) -> (c0, r0, c1, r1: int) {
	return md_cx(box.x), md_cy(box.y), md_cx(box.x + box.w), md_cy(box.y + box.h)
}

@(private = "file")
md_cell :: proc(paint: ^MdPaint, col, row: int) -> ^MdCell {
	if col < 0 || col >= paint.cols || row < 0 || row >= MD_PIECE_ROWS_MAX {
		return nil
	}
	if len(paint.clips) > 0 {
		clip := paint.clips[len(paint.clips) - 1]
		if col < clip[0] || row < clip[1] || col >= clip[2] || row >= clip[3] {
			return nil
		}
	}
	for row >= len(paint.rows) {
		append(&paint.rows, make([]MdCell, paint.cols))
	}
	return &paint.rows[row][col]
}

@(private = "file")
md_color :: proc(rgba: u32) -> tb2.Color {
	return tb2.Color(u64(rgba >> 8))
}

@(private = "file")
md_font_attrs :: proc(font: c.int) -> u64 {
	attrs: u64
	if font & lh.BOLD != 0 {
		attrs |= u64(tb2.Color.Bold)
	}
	if font & lh.ITALIC != 0 {
		attrs |= u64(tb2.Color.Italic)
	}
	if font & lh.UNDERLINE != 0 {
		attrs |= u64(tb2.Color.Underline)
	}
	if font & lh.STRIKE != 0 {
		attrs |= u64(tb2.Color.Strikeout)
	}
	return attrs
}

@(private = "file")
md_cb_text_width :: proc "c" (user: rawptr, text: cstring, font: c.int) -> f32 {
	paint := (^MdPaint)(user)
	context = paint.ctx
	return f32(md_text_width(string(text)) * MD_CELL_W)
}

@(private = "file")
md_put :: proc(paint: ^MdPaint, cluster: string, col: ^int, row: int, fg: tb2.Color) {
	width := 1 if len(cluster) == 1 else cluster_width(transmute([]u8)cluster)
	if cell := md_cell(paint, col^, row); cell != nil {
		cell.text = string(md_ascii_bytes[cluster[0]:cluster[0] + 1]) if len(cluster) == 1 && cluster[0] < 128 else strings.clone(cluster)
		cell.fg = fg
		cell.tail = false
		if width == 2 {
			if tail := md_cell(paint, col^ + 1, row); tail != nil {
				tail^ = {tail = true, bg = tail.bg}
			}
		}
	}
	col^ += width
}

@(private = "file")
md_cb_draw_text :: proc "c" (user: rawptr, text: cstring, font: c.int, color: u32, pos: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	col := md_cx(pos.x)
	row := int(math.floor((pos.y + pos.h / 2) / MD_CELL_H))
	fg := tb2.Color(u64(md_color(color)) | md_font_attrs(font))
	str := string(text)
	simple := true
	for char in transmute([]u8)str {
		simple &&= char < 0x80
	}
	if simple {
		for i in 0 ..< len(str) {
			md_put(paint, str[i:i + 1], &col, row, fg)
		}
		return
	}
	it := utf8.decode_grapheme_iterator_make(str)
	prev := 0
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if grapheme.byte_index > prev {
			md_put(paint, str[prev:grapheme.byte_index], &col, row, fg)
			prev = grapheme.byte_index
		}
	}
	if prev < len(str) {
		md_put(paint, str[prev:], &col, row, fg)
	}
}

@(private = "file")
md_cb_fill :: proc "c" (user: rawptr, color: u32, box: lh.Rect, clip: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	if color & 0xff < 128 {
		return
	}
	c0, r0, c1, r1 := md_box_cells(box)
	k0, q0, k1, q1 := md_box_cells(clip)
	for row in max(r0, q0) ..< min(r1, q1) {
		for col in max(c0, k0) ..< min(c1, k1, paint.cols) {
			if cell := md_cell(paint, col, row); cell != nil {
				cell.bg = md_color(color)
			}
		}
	}
}

@(private = "file")
md_line_add :: proc(paint: ^MdPaint, col, row: int, bits: u8, style: c.int, color: u32) {
	cell := md_cell(paint, col, row)
	if cell == nil {
		return
	}
	cell.lines |= bits
	if cell.text == "" {
		cell.fg = md_color(color)
	}
	switch style {
	case 5:
		cell.style = .Double
	case 6, 7:
		cell.style = .Heavy
	case:
		cell.style = .Light
	}
}

// a border is one cell thick: lines join into box-drawing glyphs where they meet
@(private = "file")
md_cb_borders :: proc "c" (user: rawptr, sides: [^]lh.Border, box: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	c0, r0, c1, r1 := md_box_cells(box)
	c1 = min(c1, paint.cols + 1)
	if c1 <= c0 || r1 <= r0 {
		return
	}
	visible :: proc(border: lh.Border) -> bool {
		return border.width > 0 && border.style > 1
	}
	left, top, right, bottom := sides[0], sides[1], sides[2], sides[3]
	for side, i in ([2]lh.Border{top, bottom}) {
		if !visible(side) {
			continue
		}
		row := r0 if i == 0 else r1 - 1
		for col in c0 ..< c1 {
			bits: u8 = MD_LINE_L | MD_LINE_R
			if col == c0 && visible(left) {
				bits = MD_LINE_R
			}
			if col == c1 - 1 && visible(right) {
				bits = MD_LINE_L
			}
			md_line_add(paint, col, row, bits, side.style, side.color)
		}
	}
	for side, i in ([2]lh.Border{left, right}) {
		if !visible(side) {
			continue
		}
		col := c0 if i == 0 else c1 - 1
		for row in r0 ..< r1 {
			bits: u8 = MD_LINE_U | MD_LINE_D
			if row == r0 && visible(top) {
				bits = MD_LINE_D
			}
			if row == r1 - 1 && visible(bottom) {
				bits = MD_LINE_U
			}
			md_line_add(paint, col, row, bits, side.style, side.color)
		}
	}
}

@(private = "file")
md_cb_marker :: proc "c" (user: rawptr, type: c.int, index: c.int, color: u32, font: c.int, pos: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	glyph := "•"
	switch type {
	case 0:
		return
	case 1:
		glyph = "◦"
	case 3:
		glyph = "▪"
	}
	col := int(math.floor(pos.x / MD_CELL_W))
	row := int(math.floor((pos.y + pos.h / 2) / MD_CELL_H))
	if cell := md_cell(paint, col, row); cell != nil {
		cell.text = glyph
		cell.fg = paint.job.input.bullet
	}
}

@(private = "file")
md_cb_image_size :: proc "c" (user: rawptr, src: cstring, w, h: ^c.int) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	if info, ok := paint.job.images[string(src)]; ok {
		w^, h^ = c.int(info.w), c.int(info.h)
	}
}

@(private = "file")
md_cb_draw_image :: proc "c" (user: rawptr, src: cstring, box: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	info, ok := paint.job.images[string(src)]
	// a box ending mid-cell keeps that cell for the padding or border rounding gives it
	c0, r0 := md_cx(box.x), md_cy(box.y)
	c1, r1 := c0 + int(box.w / MD_CELL_W + 0.001), r0 + int(box.h / MD_CELL_H + 0.001)
	if !ok || c1 <= c0 || r1 <= r0 {
		return
	}
	cols := min(c1 - c0, len(IMAGE_DIACRITICS), paint.cols - c0)
	rows := min(r1 - r0, len(IMAGE_DIACRITICS), MD_PIECE_ROWS_MAX - r0)
	if cols <= 0 || rows <= 0 {
		return
	}
	md_cell(paint, c0, r0 + rows - 1)
	append(&paint.images, MdImage{ref = {0, i32(cols), i32(rows)}, x = c0, y = r0, path = info.path, alt = info.alt})
}

@(private = "file")
md_cb_set_clip :: proc "c" (user: rawptr, box: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	c0, r0, c1, r1 := md_box_cells(box)
	if len(paint.clips) > 0 {
		outer := paint.clips[len(paint.clips) - 1]
		c0, r0, c1, r1 = max(c0, outer[0]), max(r0, outer[1]), min(c1, outer[2]), min(r1, outer[3])
	}
	append(&paint.clips, [4]int{c0, r0, c1, r1})
}

@(private = "file")
md_cb_del_clip :: proc "c" (user: rawptr) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	if len(paint.clips) > 0 {
		pop(&paint.clips)
	}
}

@(private = "file")
md_cb_walk :: proc "c" (user: rawptr, tag, href, sourcepos, alt, id: cstring, box: lh.Rect) {
	paint := (^MdPaint)(user)
	context = paint.ctx
	c0, r0, c1, r1 := md_box_cells(box)
	name := string(tag) if tag != nil else ""
	if href != nil && name == "a" {
		append(&paint.links, strings.clone(string(href)))
		link := i32(len(paint.links))
		for row in r0 ..< max(r1, r0 + 1) {
			for col in max(c0, 0) ..< min(c1, paint.cols) {
				if cell := md_cell(paint, col, row); cell != nil {
					cell.link = link
				}
			}
		}
	}
	// an empty inline sits at the end of the row above
	if sourcepos != nil && box.w > 0 {
		pos := string(sourcepos)
		end := 0
		for end < len(pos) && (pos[end] == '-' || (pos[end] >= '0' && pos[end] <= '9')) {
			end += 1
		}
		if line, ok := strconv.parse_int(pos[:end]); ok {
			append(&paint.sources, [2]int{r0, line})
		}
	}
	if id != nil {
		key := string(id)
		if strings.has_prefix(key, MD_DETAILS_ID) {
			if index, ok := strconv.parse_int(key[len(MD_DETAILS_ID):]); ok {
				append(&paint.summaries, MdSummary{c0, r0, c1 - c0, max(r1 - r0, 1), index})
			}
		} else {
			append(&paint.anchors, MdAnchor{strings.clone(key), r0})
		}
	}
}

md_chunk_free :: proc(chunk: ^MdChunk) {
	vmem.arena_destroy(&chunk.arena)
	free(chunk, runtime.heap_allocator())
}

md_chunk_layout :: proc(job: ^MdJob, html: string) -> ^MdChunk {
	input := &job.input
	scratch: vmem.Arena
	defer vmem.arena_destroy(&scratch)
	paint: MdPaint
	{
		context.allocator = vmem.arena_allocator(&scratch)
		context.temp_allocator = context.allocator
		paint = MdPaint {
			ctx  = context,
			job  = job,
			cols = input.width,
		}
		cbs := lh.Callbacks {
			user       = &paint,
			text_width = md_cb_text_width,
			draw_text  = md_cb_draw_text,
			fill       = md_cb_fill,
			borders    = md_cb_borders,
			marker     = md_cb_marker,
			image_size = md_cb_image_size,
			draw_image = md_cb_draw_image,
			set_clip   = md_cb_set_clip,
			del_clip   = md_cb_del_clip,
		}
		ldoc := lh.create(strings.clone_to_cstring(html), MD_MASTER_CSS, strings.clone_to_cstring(input.css), &cbs, MD_CELL_W, MD_CELL_H)
		width := f32(input.width * MD_CELL_W)
		lh.render(ldoc, width)
		height := min(lh.height(ldoc), f32(MD_PIECE_ROWS_MAX * MD_CELL_H))
		reserve(&paint.rows, int(math.ceil(height / MD_CELL_H)) + 1)
		lh.draw(ldoc, {0, 0, width, height})
		lh.walk(ldoc, md_cb_walk, &paint)
		lh.destroy(ldoc)
	}

	chunk := new(MdChunk, job.allocator if job.allocator.procedure != nil else runtime.heap_allocator())
	context.allocator = job.allocator if job.allocator.procedure != nil else vmem.arena_allocator(&chunk.arena)
	chunk.html, chunk.style_hash, chunk.width = strings.clone(html), input.style_hash, input.width
	used := len(paint.rows)
	for used > 0 && md_row_blank(paint.rows[used - 1]) {
		used -= 1
	}
	for img in paint.images {
		used = max(used, img.y + int(img.ref.rows))
	}
	chunk.rows = make([][]MdCell, used)
	for &row, index in chunk.rows {
		painted := paint.rows[index] if index < len(paint.rows) else nil
		last := len(painted)
		for last > 0 && md_cell_blank(painted[last - 1]) {
			last -= 1
		}
		row = slice.clone(painted[:last])
		for &cell in row {
			if len(cell.text) > 1 {
				cell.text = strings.clone(cell.text)
			}
		}
		// a rule spans whatever width it gets, so it never asks for any
		for last > 0 && (md_cell_text(row[last - 1]) == " " || (row[last - 1].text == "" && row[last - 1].lines & (MD_LINE_U | MD_LINE_D) == 0)) {
			last -= 1
		}
		chunk.cols = max(chunk.cols, last)
	}
	for img in paint.images {
		chunk.cols = max(chunk.cols, img.x + int(img.ref.cols))
	}
	slice.sort_by(paint.sources[:], proc(a, b: [2]int) -> bool {
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1]
	})
	chunk.src = make([]int, used)
	current, next := MD_NO_SOURCE, 0
	for row in 0 ..< used {
		found := false
		best := 0
		for next < len(paint.sources) && paint.sources[next][0] <= row {
			if paint.sources[next][0] == row {
				best = max(best, paint.sources[next][1]) if found else paint.sources[next][1]
				found = true
			}
			next += 1
		}
		if found {
			current = best
		}
		chunk.src[row] = current
	}
	chunk.links = make([]string, len(paint.links))
	for link, k in paint.links {
		chunk.links[k] = strings.clone(link)
	}
	chunk.anchors = make([]MdAnchor, len(paint.anchors))
	for anchor, k in paint.anchors {
		chunk.anchors[k] = {strings.clone(anchor.id), anchor.row}
	}
	chunk.images = slice.clone(paint.images[:])
	for &img in chunk.images {
		img.path, img.alt = strings.clone(img.path), strings.clone(img.alt)
	}
	chunk.summaries = slice.clone(paint.summaries[:])
	return chunk
}

md_layout :: proc(job: ^MdJob) {
	if job.input.width <= 0 {
		return
	}
	job.images = make(map[string]MdImageInfo)
	job.nonce = rand.uint64()
	job.code = make(map[string][]string, 16, job.code_allocator)
	pieces := md_html(job)
	if pieces == nil {
		return
	}
	reuse := make(map[string]^MdChunk, len(job.prev))
	for chunk in job.prev {
		if chunk.width == job.input.width && chunk.style_hash == job.input.style_hash {
			reuse[chunk.html] = chunk
		}
	}
	job.pieces = pieces
	job.chunks = make([]^MdChunk, len(pieces))
	for piece, k in pieces {
		if sync.atomic_load(&job.cancel) {
			return
		}
		chunk, found := reuse[piece.html]
		if found {
			delete_key(&reuse, piece.html)
		} else {
			chunk = md_chunk_layout(job, piece.html)
		}
		job.chunks[k] = chunk
		sync.atomic_store(&job.ready, k + 1)
	}
}

md_doc_assemble :: proc(pieces: []MdPiece, chunks: []^MdChunk) -> ^MdDoc {
	doc := new(MdDoc)
	total := 0
	for chunk in chunks {
		if len(chunk.rows) > 0 {
			total += len(chunk.rows) + (1 if total > 0 else 0)
		}
	}
	doc.rows = make([][]MdCell, total)
	doc.src = make([]int, total)
	doc.link_base = make([]i32, total)
	doc.anchors = make(map[string]int)
	seen := make(map[string]int, context.temp_allocator)
	links := make([dynamic]string)
	images := make([dynamic]MdImage)
	summaries := make([dynamic]MdSummary)
	row, current := 0, 0
	for chunk, k in chunks {
		if len(chunk.rows) == 0 {
			continue
		}
		piece := pieces[k]
		if row > 0 {
			doc.src[row] = current
			row += 1
		}
		base := i32(len(links))
		append(&links, ..chunk.links)
		for at in 0 ..< len(chunk.rows) {
			doc.rows[row + at] = chunk.rows[at]
			if chunk.src[at] != MD_NO_SOURCE {
				current = max(chunk.src[at] + piece.line - 1, 0)
			}
			doc.src[row + at] = current
			doc.link_base[row + at] = base
		}
		for anchor in chunk.anchors {
			repeats := seen[anchor.id]
			seen[anchor.id] = repeats + 1
			key := anchor.id if repeats == 0 else fmt.aprintf("%s-%d", anchor.id, repeats)
			if key not_in doc.anchors {
				doc.anchors[key] = row + anchor.row
			}
		}
		for img in chunk.images {
			placed := img
			placed.y += row
			if image := image_get(img.path); image != nil {
				placed.ref.id = image.id
			}
			append(&images, placed)
		}
		for summary in chunk.summaries {
			placed := summary
			placed.y += row
			placed.index += piece.details
			append(&summaries, placed)
		}
		doc.width = max(doc.width, chunk.cols)
		row += len(chunk.rows)
	}
	doc.links, doc.images, doc.summaries = links[:], images[:], summaries[:]
	return doc
}

md_render :: proc(src: string, width: int, lang: Language, dir := "", open: []int = nil) -> ^MdDoc {
	context.allocator = context.temp_allocator
	job := MdJob{input = md_input_make(src, dir, lang, width, open), allocator = context.temp_allocator, code_allocator = context.temp_allocator}
	md_layout(&job)
	md_input_free(&job.input)
	return md_doc_assemble(job.pieces, job.chunks)
}

md_cell_blank :: proc(cell: MdCell) -> bool {
	return (cell.text == "" || cell.text == " ") && cell.lines == 0 && cell.bg == {} && !cell.tail
}

md_row_blank :: proc(row: []MdCell) -> bool {
	for cell in row {
		if !md_cell_blank(cell) {
			return false
		}
	}
	return true
}

md_line_glyph :: proc(lines: u8, style: MdLineStyle) -> string {
	@(static, rodata) LIGHT := [16]string{" ", "│", "│", "│", "─", "┘", "┐", "┤", "─", "└", "┌", "├", "─", "┴", "┬", "┼"}
	@(static, rodata) HEAVY := [16]string{" ", "┃", "┃", "┃", "━", "┛", "┓", "┫", "━", "┗", "┏", "┣", "━", "┻", "┳", "╋"}
	@(static, rodata) DOUBLE := [16]string{" ", "║", "║", "║", "═", "╝", "╗", "╣", "═", "╚", "╔", "╠", "═", "╩", "╦", "╬"}
	switch style {
	case .Heavy:
		return HEAVY[lines & 15]
	case .Double:
		return DOUBLE[lines & 15]
	case .Light:
	}
	return LIGHT[lines & 15]
}

md_cell_text :: proc(cell: MdCell) -> string {
	switch {
	case cell.tail:
		return ""
	case cell.text != "":
		return cell.text
	case cell.lines != 0:
		return md_line_glyph(cell.lines, cell.style)
	}
	return " "
}

md_row_text :: proc(doc: ^MdDoc, row: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if row >= 0 && row < len(doc.rows) {
		for cell in doc.rows[row] {
			strings.write_string(&sb, md_cell_text(cell))
		}
	}
	return strings.trim_right(strings.to_string(sb), " ")
}

md_link_at :: proc(doc: ^MdDoc, col, row: int) -> string {
	if row < 0 || row >= len(doc.rows) || col < 0 || col >= len(doc.rows[row]) {
		return ""
	}
	link := int(doc.rows[row][col].link)
	if link <= 0 {
		return ""
	}
	at := int(doc.link_base[row]) + link - 1
	return doc.links[at] if at < len(doc.links) else ""
}

md_summary_at :: proc(doc: ^MdDoc, col, row: int) -> (int, bool) {
	for summary in doc.summaries {
		if row >= summary.y && row < summary.y + summary.h && col >= summary.x && col < summary.x + summary.w {
			return summary.index, true
		}
	}
	return 0, false
}

md_draw_row :: proc(doc: ^MdDoc, row, x, y, w: int, bg: tb2.Color) {
	if row < 0 || row >= len(doc.rows) {
		return
	}
	col := 0
	for cell in doc.rows[row] {
		if col >= w {
			break
		}
		if cell.tail {
			col += 1
			continue
		}
		text := md_cell_text(cell)
		cw := 1 if len(text) == 1 else cluster_width(transmute([]u8)text)
		if col + cw > w {
			break
		}
		cbg := cell.bg if cell.bg != {} else bg
		cell_put_cluster(x + col, y, transmute([]u8)text, cell.fg, cbg)
		col += 1
	}
}

md_clusters :: proc(text: string) -> []string {
	out := make([dynamic]string, 0, len(text), context.temp_allocator)
	it := utf8.decode_grapheme_iterator_make(text)
	prev := 0
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if grapheme.byte_index > prev {
			append(&out, text[prev:grapheme.byte_index])
			prev = grapheme.byte_index
		}
	}
	if prev < len(text) {
		append(&out, text[prev:])
	}
	return out[:]
}

md_put_placeholder :: proc(x, y, row, col: int, id: u32, bg: tb2.Color) {
	tb2.set_cell(i32(x), i32(y), IMAGE_PLACEHOLDER, image_color(id), bg)
	tb2.extend_cell(i32(x), i32(y), IMAGE_DIACRITICS[row])
	tb2.extend_cell(i32(x), i32(y), IMAGE_DIACRITICS[col])
}

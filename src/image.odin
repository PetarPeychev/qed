package main

import "core:encoding/base64"
import "core:fmt"
import "core:image"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "lib:pty"
import "lib:tb2"

ImageSetting :: enum {
	Auto,
	Kitty,
	None,
}

ImageRef :: struct {
	id:         u32,
	cols, rows: i32,
}

ImageState :: enum {
	Probed,
	Loading,
	Ready,
	Failed,
}

Image :: struct {
	path:   string,
	stamp:  DiskStamp,
	id:     u32,
	w, h:   int,
	state:  ImageState,
	rgba:   []u8,
	rw, rh: int,
	sent:   bool,
	placed: [2]i32,
	used:   u64,
}

ImageJob :: struct {
	thread: ^thread.Thread,
	id:     u32,
	path:   string,
	box:    [2]int,
	rgba:   []u8,
	w, h:   int,
	ok:     bool,
}

ImageDetect :: struct {
	asked:   bool,
	pending: bool,
	tmux:    bool,
	ok:      bool,
	kitty:   bool,
	replies: int,
	term:    [64]u8,
	term_n:  int,
}

ImageReply :: enum {
	None,
	Kitty_Ok,
	Kitty_Error,
	Version,
	Da1,
}

IMAGE_QUERY_ID :: 31
IMAGE_MAX_FILE_BYTES :: 64 * 1024 * 1024
IMAGE_MAX_PIXELS :: 24_000_000
IMAGE_HEAD_BYTES :: 256 * 1024
IMAGE_CACHE_MAX :: 16
IMAGE_ENTRIES_MAX :: 512
IMAGE_CHUNK :: 4096
IMAGE_PLACEHOLDER :: rune(0x10EEEE)

g_images: [dynamic]Image
g_image_job: ^ImageJob
g_image_next: u32
g_image_tick: u64
g_image_floor: u64
g_image_detect: ImageDetect
g_image_cell := [2]int{0, 0}

image_enabled :: proc() -> bool {
	switch IMAGE_PROTOCOL {
	case .Kitty:
		return true
	case .None:
		return false
	case .Auto:
		return g_image_detect.kitty
	}
	return false
}

image_setting_parse :: proc(s: string) -> (ImageSetting, bool) {
	switch s {
	case "auto":
		return .Auto, true
	case "kitty":
		return .Kitty, true
	case "none":
		return .None, true
	}
	return .Auto, false
}

// inside tmux the outer terminal answers the wrapped DA1 after its other replies, while tmux answers the bare one at once
image_query :: proc(tmux: bool) -> string {
	q := fmt.tprintf("\x1b_Gi=%d,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", IMAGE_QUERY_ID)
	if tmux {
		return fmt.tprintf("%s%s%s\x1b[c", image_tmux_wrap(q), image_tmux_wrap("\x1b[>0q"), image_tmux_wrap("\x1b[c"))
	}
	return fmt.tprintf("%s\x1b[>0q\x1b[c", q)
}

// WezTerm and Konsole accept kitty graphics but draw placeholders as text: only these draw them
image_term_placeholders :: proc(term: string) -> bool {
	return strings.has_prefix(term, "kitty") || strings.has_prefix(strings.to_lower(term, context.temp_allocator), "ghostty")
}

image_tmux_wrap :: proc(seq: string) -> string {
	doubled, _ := strings.replace_all(seq, "\x1b", "\x1b\x1b", context.temp_allocator)
	return fmt.tprintf("\x1bPtmux;%s\x1b\\", doubled)
}

image_reply_parse :: proc(s: string) -> (kind: ImageReply, term: string) {
	if strings.has_prefix(s, "\x1bP>|") && strings.has_suffix(s, "\x1b\\") {
		return .Version, s[4:len(s) - 2]
	}
	if strings.has_prefix(s, "\x1b_G") && strings.has_suffix(s, "\x1b\\") {
		body := s[3:len(s) - 2]
		semi := strings.index_byte(body, ';')
		if semi < 0 {
			return .None, ""
		}
		ours := false
		for kv in strings.split(body[:semi], ",", context.temp_allocator) {
			ours ||= kv == fmt.tprintf("i=%d", IMAGE_QUERY_ID)
		}
		if !ours {
			return .None, ""
		}
		return .Kitty_Ok if body[semi + 1:] == "OK" else .Kitty_Error, ""
	}
	if strings.has_prefix(s, "\x1b[?") && strings.has_suffix(s, "c") {
		return .Da1, ""
	}
	return .None, ""
}

image_cell_query :: proc() -> [2]int {
	tty, resize: i32 = -1, -1
	tb2.get_fds(&tty, &resize)
	w, h := pty.cell_pixels(int(tty))
	return {w, h}
}

image_cell_refresh :: proc(editor: ^Editor) {
	if cell := image_cell_query(); cell != g_image_cell {
		g_image_cell = cell
		image_panes_reset(editor)
	}
}

image_detect_begin :: proc() {
	g_image_cell = image_cell_query()
	g_image_detect = {tmux = os.get_env("TMUX", context.temp_allocator) != ""}
	image_detect_sync()
}

image_detect_sync :: proc() {
	if IMAGE_PROTOCOL != .Auto || g_image_detect.asked {
		return
	}
	g_image_detect.asked, g_image_detect.pending = true, true
	q := image_query(g_image_detect.tmux)
	tb2.send(raw_data(q), uint(len(q)))
}

image_detect_end :: proc(editor: ^Editor) {
	if !g_image_detect.pending {
		return
	}
	g_image_detect.pending = false
	term := string(g_image_detect.term[:g_image_detect.term_n])
	g_image_detect.kitty = g_image_detect.ok && image_term_placeholders(term)
	editor_log(editor, .Debug, "Images", fmt.tprintf("terminal %q, kitty graphics %v, placeholders %v, tmux %v", term, g_image_detect.ok, g_image_detect.kitty, g_image_detect.tmux))
	if g_image_detect.kitty {
		image_panes_reset(editor)
	}
}

image_reply :: proc(editor: ^Editor) {
	if !g_image_detect.pending {
		return
	}
	buf: [^]u8
	n := tb2.reply(&buf)
	kind, term := image_reply_parse(string(buf[:n]))
	switch kind {
	case .Kitty_Ok:
		g_image_detect.ok = true
	case .Version:
		g_image_detect.term_n = copy(g_image_detect.term[:], term)
	case .Kitty_Error, .None:
	case .Da1:
		g_image_detect.replies += 1
		if g_image_detect.replies >= (2 if g_image_detect.tmux else 1) {
			image_detect_end(editor)
		}
	}
}

image_panes_reset :: proc(editor: ^Editor) {
	for &p in editor.panes {
		if p.has_md {
			pane_md_reset(&p)
		}
	}
}

image_cells :: proc(w, h, avail, max_rows, cell_w, cell_h: int) -> (cols, rows: int) {
	if w <= 0 || h <= 0 || avail <= 0 {
		return 0, 0
	}
	cw, ch := image_cell_size(cell_w, cell_h)
	cols = min((w + cw - 1) / cw, avail, len(IMAGE_DIACRITICS))
	rows = max(1, (h * cols * cw + w * ch / 2) / (w * ch))
	if max_rows > 0 && rows > max_rows {
		rows = max_rows
		cols = clamp((w * rows * ch + h * cw / 2) / (h * cw), 1, cols)
	}
	rows = min(rows, len(IMAGE_DIACRITICS))
	return
}

image_cell_size :: proc(cell_w, cell_h: int) -> (int, int) {
	if cell_w <= 0 || cell_h <= 0 {
		return 8, 16
	}
	return cell_w, cell_h
}

image_color :: proc(id: u32) -> tb2.Color {
	return tb2.Color(u64(id & 0xffffff))
}

image_placeholder_row :: proc(row, cols: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in 0 ..< cols {
		strings.write_rune(&sb, IMAGE_PLACEHOLDER)
		strings.write_rune(&sb, IMAGE_DIACRITICS[row])
		strings.write_rune(&sb, IMAGE_DIACRITICS[c])
	}
	return strings.to_string(sb)
}

image_resolve :: proc(dir, src: string) -> string {
	if src == "" || strings.contains(src, "://") || strings.has_prefix(src, "data:") {
		return ""
	}
	p := src
	if q := strings.index_any(p, "?#"); q >= 0 {
		p = p[:q]
	}
	if filepath.is_abs(p) {
		return p
	}
	if dir == "" {
		return ""
	}
	joined, _ := filepath.join({dir, p}, context.temp_allocator)
	return joined
}

image_magic :: proc(data: []u8) -> bool {
	return strings.has_prefix(string(data), "\x89PNG\r\n\x1a\n") || strings.has_prefix(string(data), "\xff\xd8\xff")
}

image_header_size :: proc(data: []u8) -> (w, h: int, ok: bool) {
	be16 :: proc(b: []u8, at: int) -> int {
		return int(b[at]) << 8 | int(b[at + 1])
	}
	if strings.has_prefix(string(data), "\x89PNG\r\n\x1a\n") {
		if len(data) < 24 || string(data[12:16]) != "IHDR" {
			return
		}
		w = be16(data, 16) << 16 | be16(data, 18)
		h = be16(data, 20) << 16 | be16(data, 22)
		return w, h, w > 0 && h > 0
	}
	if !strings.has_prefix(string(data), "\xff\xd8") {
		return
	}
	for i := 2; i + 9 <= len(data); {
		if data[i] != 0xff {
			return
		}
		marker := data[i + 1]
		if marker == 0xff {
			i += 1
			continue
		}
		if marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7) {
			i += 2
			continue
		}
		if marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc {
			h, w = be16(data, i + 5), be16(data, i + 7)
			return w, h, w > 0 && h > 0
		}
		i += 2 + be16(data, i + 2)
	}
	return
}

image_head :: proc(path: string) -> []u8 {
	f, err := os.open(path)
	if err != nil {
		return nil
	}
	defer os.close(f)
	buf := make([]u8, IMAGE_HEAD_BYTES, context.temp_allocator)
	n, _ := os.read(f, buf)
	return buf[:max(n, 0)]
}

image_get :: proc(path: string) -> ^Image {
	g_image_tick += 1
	for &img in g_images {
		if img.path == path {
			// one stat per image per frame: measure and render both ask
			if img.used <= g_image_floor {
				if stamp := buffer_disk_stamp(path); img.stamp != stamp {
					image_forget(&img)
					img.stamp = stamp
					image_probe(&img)
				}
			}
			img.used = g_image_tick
			return nil if img.state == .Failed else &img
		}
	}
	stamp := buffer_disk_stamp(path)
	if g_images.allocator.procedure == nil {
		g_images.allocator = os.heap_allocator()
	}
	if len(g_images) >= IMAGE_ENTRIES_MAX {
		image_drop_oldest()
	}
	append(&g_images, Image{path = strings.clone(path, os.heap_allocator()), stamp = stamp, used = g_image_tick})
	img := &g_images[len(g_images) - 1]
	image_probe(img)
	return nil if img.state == .Failed else img
}

image_probe :: proc(img: ^Image) {
	img.state = .Failed
	if !img.stamp.ok || img.stamp.size > IMAGE_MAX_FILE_BYTES {
		return
	}
	w, h, ok := image_header_size(image_head(img.path))
	if !ok || w * h > IMAGE_MAX_PIXELS {
		return
	}
	g_image_next += 1
	if g_image_next == 1 {
		g_image_next = u32(posix.getpid() % 0x7fff) << 8 | 1
	}
	img.id = g_image_next & 0xffffff
	img.w, img.h, img.state = w, h, .Probed
}

image_frame_begin :: proc() {
	g_image_floor = g_image_tick
}

// entries keep their ids for the lines that drew them; only pixels and terminal copies are bounded
image_heavy :: proc(img: Image) -> bool {
	return img.state == .Loading || img.rgba != nil || img.sent
}

image_unload_oldest :: proc() -> bool {
	heavy, oldest := 0, -1
	for img, i in g_images {
		if !image_heavy(img) {
			continue
		}
		heavy += 1
		if img.used <= g_image_floor && (oldest < 0 || img.used < g_images[oldest].used) {
			oldest = i
		}
	}
	if heavy <= IMAGE_CACHE_MAX || oldest < 0 {
		return false
	}
	image_forget(&g_images[oldest])
	g_images[oldest].state = .Probed
	return true
}

image_drop_oldest :: proc() {
	oldest := 0
	for img, i in g_images {
		if img.used < g_images[oldest].used {
			oldest = i
		}
	}
	image_forget(&g_images[oldest])
	delete(g_images[oldest].path, os.heap_allocator())
	unordered_remove(&g_images, oldest)
}

image_forget :: proc(img: ^Image) {
	if img.sent {
		image_send(fmt.tprintf("\x1b_Ga=d,d=I,i=%d,q=2\x1b\\", img.id))
	}
	delete(img.rgba, os.heap_allocator())
	img.rgba, img.sent, img.placed, img.rw, img.rh = nil, false, {}, 0, 0
}

image_state :: proc(id: u32) -> (ImageState, bool) {
	for img in g_images {
		if img.id == id {
			return img.state, true
		}
	}
	return .Failed, false
}

image_busy :: proc() -> bool {
	if g_image_job != nil {
		return true
	}
	for img in g_images {
		if img.state == .Loading {
			return true
		}
	}
	return false
}

// decodes one image at a time off the main thread, the most recently wanted first
image_pump :: proc(editor: ^Editor) -> (redraw: bool) {
	if job := g_image_job; job != nil {
		if !thread.is_done(job.thread) {
			return false
		}
		thread.destroy(job.thread)
		image_job_adopt(editor, job)
		g_image_job = nil
		redraw = true
	}
	for image_unload_oldest() {
	}
	next := -1
	for img, i in g_images {
		if img.state == .Loading && (next < 0 || img.used > g_images[next].used) {
			next = i
		}
	}
	if next < 0 {
		return
	}
	cw, ch := image_cell_size(g_image_cell.x, g_image_cell.y)
	job := new(ImageJob, os.heap_allocator())
	job.id = g_images[next].id
	job.path = strings.clone(g_images[next].path, os.heap_allocator())
	job.box = {max(1, int(tb2.width())) * cw, max(IMAGE_MAX_ROWS, int(tb2.height())) * ch}
	job.thread = thread.create(image_job_run)
	job.thread.data = job
	g_image_job = job
	thread.start(job.thread)
	return
}

image_job_run :: proc(t: ^thread.Thread) {
	job := cast(^ImageJob)t.data
	defer free_all(context.temp_allocator)
	data, err := os.read_entire_file(job.path, os.heap_allocator())
	if err != nil {
		return
	}
	defer delete(data, os.heap_allocator())
	job.rgba, job.w, job.h, job.ok = image_decode(data, os.heap_allocator())
	for job.ok && (job.w >= 2 * job.box.x || job.h >= 2 * job.box.y) {
		half, hw, hh := image_halve(job.rgba, job.w, job.h, os.heap_allocator())
		delete(job.rgba, os.heap_allocator())
		job.rgba, job.w, job.h = half, hw, hh
	}
}

image_job_adopt :: proc(editor: ^Editor, job: ^ImageJob) {
	defer {
		delete(job.path, os.heap_allocator())
		free(job, os.heap_allocator())
	}
	for &img in g_images {
		if img.id == job.id && img.state == .Loading {
			if job.ok {
				img.rgba, img.rw, img.rh, img.state = job.rgba, job.w, job.h, .Ready
			} else {
				img.state = .Failed
				image_panes_reset(editor)
			}
			return
		}
	}
	delete(job.rgba, os.heap_allocator())
}

image_decode :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, w, h: int, ok: bool) {
	src, err := image.load_from_bytes(data, {}, allocator)
	if err != nil || src == nil {
		return
	}
	defer image.destroy(src, allocator)
	w, h = src.width, src.height
	chans, step := src.channels, src.depth / 8
	if w <= 0 || h <= 0 || chans < 1 || chans > 4 || (step != 1 && step != 2) {
		return
	}
	px := src.pixels.buf[:]
	if len(px) < w * h * chans * step {
		return
	}
	rgba = make([]u8, w * h * 4, allocator)
	for i in 0 ..< w * h {
		at :: proc(px: []u8, i, c, chans, step: int) -> u8 {
			k := (i * chans + c) * step
			// core:image keeps 16-bit samples native-endian
			return px[k] if step == 1 else u8((^u16)(&px[k])^ >> 8)
		}
		o := rgba[i * 4:]
		switch chans {
		case 1, 2:
			g := at(px, i, 0, chans, step)
			o[0], o[1], o[2] = g, g, g
			o[3] = at(px, i, 1, chans, step) if chans == 2 else 255
		case:
			o[0], o[1], o[2] = at(px, i, 0, chans, step), at(px, i, 1, chans, step), at(px, i, 2, chans, step)
			o[3] = at(px, i, 3, chans, step) if chans == 4 else 255
		}
	}
	return rgba, w, h, true
}

image_halve :: proc(rgba: []u8, w, h: int, allocator := context.allocator) -> (out: []u8, ow, oh: int) {
	ow, oh = max(1, w / 2), max(1, h / 2)
	out = make([]u8, ow * oh * 4, allocator)
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			x0, y0 := min(2 * x, w - 1), min(2 * y, h - 1)
			x1, y1 := min(x0 + 1, w - 1), min(y0 + 1, h - 1)
			for c in 0 ..< 4 {
				s := int(rgba[(y0 * w + x0) * 4 + c]) + int(rgba[(y0 * w + x1) * 4 + c]) + int(rgba[(y1 * w + x0) * 4 + c]) + int(rgba[(y1 * w + x1) * 4 + c])
				out[(y * ow + x) * 4 + c] = u8((s + 2) / 4)
			}
		}
	}
	return
}

image_kitty_transmit :: proc(img: ^Image) -> []string {
	b64, _ := base64.encode(img.rgba, allocator = context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for at := 0; at < len(b64) || at == 0; at += IMAGE_CHUNK {
		chunk := b64[at:min(at + IMAGE_CHUNK, len(b64))]
		more := 1 if at + IMAGE_CHUNK < len(b64) else 0
		if at == 0 {
			append(&out, fmt.tprintf("\x1b_Ga=t,f=32,s=%d,v=%d,i=%d,q=2,m=%d;%s\x1b\\", img.rw, img.rh, img.id, more, chunk))
		} else {
			append(&out, fmt.tprintf("\x1b_Gm=%d;%s\x1b\\", more, chunk))
		}
	}
	return out[:]
}

// one fixed placement id: a put with the same image and placement id replaces it, so placeholders never pick a stale size
image_kitty_place :: proc(id: u32, cols, rows: i32) -> string {
	return fmt.tprintf("\x1b_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\x1b\\", id, cols, rows)
}

image_send :: proc(seq: string) {
	s := image_tmux_wrap(seq) if g_image_detect.tmux else seq
	tb2.send(raw_data(s), uint(len(s)))
}

image_show :: proc(ref: ImageRef) {
	if !image_enabled() {
		return
	}
	for &img in g_images {
		if img.id != ref.id {
			continue
		}
		g_image_tick += 1
		img.used = g_image_tick
		if img.state == .Probed {
			img.state = .Loading
		}
		if img.state != .Ready {
			return
		}
		if !img.sent {
			for chunk in image_kitty_transmit(&img) {
				image_send(chunk)
			}
			img.sent = true
			delete(img.rgba, os.heap_allocator())
			img.rgba = nil
		}
		if img.placed != {ref.cols, ref.rows} {
			image_send(image_kitty_place(img.id, ref.cols, ref.rows))
			img.placed = {ref.cols, ref.rows}
		}
		return
	}
}

image_shutdown :: proc() {
	if job := g_image_job; job != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
		delete(job.rgba, os.heap_allocator())
		delete(job.path, os.heap_allocator())
		free(job, os.heap_allocator())
		g_image_job = nil
	}
	for &img in g_images {
		image_forget(&img)
		delete(img.path, os.heap_allocator())
	}
	clear(&g_images)
}

// kitty's rowcolumn-diacritics.txt: the Nth entry encodes row or column N of a placeholder cell
IMAGE_DIACRITICS := [?]rune {
	0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
	0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
	0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
	0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
	0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
	0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
	0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
	0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
	0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
	0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
	0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
	0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
	0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
	0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
	0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
	0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
	0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
	0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
	0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
	0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
	0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
	0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1,
	0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
	0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
}

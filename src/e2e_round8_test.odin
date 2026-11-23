package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "lib:tb2"

@(private = "file")
Churn :: struct {
	dir:  string,
	stop: bool,
}

@(private = "file")
churn_run :: proc(th: ^thread.Thread) {
	churn := (^Churn)(th.data)
	for i := 0; !sync.atomic_load(&churn.stop); i += 1 {
		path := fmt.tprintf("%s/churn_%d", churn.dir, i % 64)
		_ = os.write_entire_file(path, nil)
		os.remove(path)
		free_all(context.temp_allocator)
	}
}

@(test)
e2e_round8_fs_list_survives_entries_vanishing :: proc(t: ^testing.T) {
	e := e2e_start("x")
	defer e2e_stop(&e)
	dir := fmt.tprintf("/tmp/qed_r8_churn_%d", posix.getpid())
	os.make_directory(dir)
	defer os.remove_all(dir)
	for i in 0 ..< 200 {
		_ = os.write_entire_file(fmt.tprintf("%s/keep_%03d", dir, i), nil)
	}
	churn := Churn{dir = dir}
	th := thread.create(churn_run)
	th.data = &churn
	thread.start(th)
	got := ft_lua(&e.ed, fmt.tprintf(`
		for i = 1, 400 do
			local names, err = qed.fs.list(%q)
			if not names then return "failed: " .. tostring(err) end
			local kept = 0
			for _, name in ipairs(names) do if name:sub(1, 5) == "keep_" then kept = kept + 1 end end
			if kept ~= 200 then return "lost " .. (200 - kept) end
		end
		return "ok"`, dir))
	sync.atomic_store(&churn.stop, true)
	thread.join(th)
	thread.destroy(th)
	testing.expectf(t, got == "ok", "listing while another process deletes entries: %s", got)
	testing.expect(t, strings.has_prefix(ft_lua(&e.ed, `return select(2, qed.fs.list("/nonexistent_qed"))`), "cannot list"), "a missing dir fails")
}

@(test)
e2e_round8_resize_does_not_leak_to_the_next_test :: proc(t: ^testing.T) {
	e2e_enter()
	defer sync.mutex_unlock(&e2e_lock)
	posix.write(posix.FD(e2e_master), raw_data(string("ab")), 2)
	ev: tb2.Event
	testing.expect(t, tb2.peek_event(&ev, 1000) == .Ok && ev.ch == 'a', "the first key is read, the second stays buffered")
	e2e_apply_size(E2E_W, E2E_H)
	for tb2.peek_event(&ev, 50) == .Ok {
		testing.expect(t, ev.type != .Resize, "the resize was taken by e2e_apply_size, not left for the next reader")
	}
}

@(private = "file")
r8_popup :: proc(e: ^E2E) -> ^UiNode {
	e2e_render(e)
	e2e_render(e)
	return caret_popup_root(&e.ed)
}

@(test)
e2e_round8_hover_is_a_node_under_the_editor :: proc(t: ^testing.T) {
	e := e2e_start("alpha\nbeta\n")
	defer e2e_stop(&e)
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 60 {
		fmt.sbprintf(&sb, "hover line %d\n\n", i)
	}
	append(&e.ed.hover, ..transmute([]u8)strings.to_string(sb))
	e.ed.hover_active = true
	popup := r8_popup(&e)
	testing.expect(t, popup != nil, "the hover is a core-built node")
	if popup == nil {
		return
	}
	testing.expect_value(t, popup.parent.identity, "#layout/main_editor")
	testing.expect_value(t, popup.anchor, UiAnchor.Cursor)
	caret_x, caret_y, _ := ui_editor_caret_pos(&e.ed, popup.parent)
	testing.expect_value(t, popup.rect.y, caret_y + 1)
	testing.expect_value(t, popup.rect.x, caret_x)
	testing.expect(t, e2e_grid_has(&e, "hover line 1"), "the hover text shows")
	scroll := ui_find_in(popup, "caret_hover_scroll")
	e2e_mouse(&e, popup.rect.x + 2, popup.rect.y + 2, .Mouse_Wheel_Down)
	testing.expect(t, e.ed.hover_active, "the wheel over the hover keeps it open")
	testing.expect(t, ui_node_state_peek(&e.ed.ui, scroll).offset > 0, "the wheel scrolls the hover")
	e2e_mouse(&e, popup.rect.x + popup.rect.w + 5, 0)
	testing.expect(t, r8_popup(&e) == nil, "a click elsewhere closes the hover")
}

@(test)
e2e_round8_diagnostic_popup_is_a_node :: proc(t: ^testing.T) {
	e := e2e_start("int x = y;\nok\n")
	defer e2e_stop(&e)
	b := editor_buffer(&e.ed)
	append(&b.diags, Diagnostic{from = {0, 8}, to = {0, 9}, severity = 1, message = strings.clone("use of undeclared identifier 'y'")})
	b.cursor = {0, 8}
	popup := r8_popup(&e)
	testing.expect(t, popup != nil && popup.id == "caret_diagnostic", "the diagnostic under the caret is a core-built node")
	if popup == nil {
		return
	}
	y := popup.rect.y + 1
	row := e2e_row_text(&e, y)
	testing.expect(t, strings.contains(row, "undeclared identifier"), row)
	x := popup.rect.x + 1
	testing.expect_value(t, e2e_rgb(e2e_cell_fg(&e, x, y)), e2e_rgb(COLOR_DIAG_ERROR_FG))
	b.cursor = {1, 0}
	testing.expect(t, r8_popup(&e) == nil, "it goes with the caret")
}

@(test)
e2e_round8_completion_is_a_node_at_the_word :: proc(t: ^testing.T) {
	if !shell_command_exists("python3") {
		return
	}
	e := e2e_lsp_start("top\n")
	defer e2e_lsp_stop(&e)
	testing.expect(t, e2e_lsp_wait(&e, proc(e: ^E2E) -> bool {return len(editor_buffer(&e.ed).diags) > 0}), "server should be ready")
	b := editor_buffer(&e.ed)
	b.cursor = {1, 0}
	e2e_type(&e, "al")
	testing.expect(t, e2e_lsp_wait(&e, proc(e: ^E2E) -> bool {return e.ed.completion.active}), "completion opens")
	popup := r8_popup(&e)
	testing.expect(t, popup != nil && popup.id == "caret_completion", "the completion menu is a core-built node")
	if popup == nil {
		return
	}
	testing.expect_value(t, popup.parent.identity, "#layout/main_editor")
	editor_node := popup.parent
	text_x := editor_node.rect.x + editor_node.rect.w - ui_editor_text_width(editor_node, b)
	testing.expect_value(t, popup.rect.x, text_x)
	rows := ui_find_in(popup, "caret_completion_rows")
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, rows).highlighted, "0")
	e2e_key(&e, .Arrow_Down)
	popup = r8_popup(&e)
	rows = ui_find_in(popup, "caret_completion_rows")
	testing.expect_value(t, ui_node_state_peek(&e.ed.ui, rows).highlighted, "1")
	testing.expect_value(t, e2e_rgb(e2e_cell_bg(&e, popup.rect.x + 2, popup.rect.y + 2)), e2e_rgb(COLOR_PANE_SEL_BG))
}

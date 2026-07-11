package main

import "core:testing"

@(test)
subprocess_reports_exit_code :: proc(t: ^testing.T) {
	sub, err, ok := subprocess_start("exit 7", nil, "/")
	testing.expect(t, ok, "spawn succeeded")
	testing.expect(t, err == nil, "no spawn error")
	defer subprocess_destroy(&sub)

	for !subprocess_drain(&sub) {}
	_ = subprocess_output(&sub)
	testing.expect_value(t, sub.exit_code, 7)
}

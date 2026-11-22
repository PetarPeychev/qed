package main

import "core:c"

when ODIN_OS == .Linux {
	foreign import glibc "system:c"

	@(default_calling_convention = "c")
	foreign glibc {
		mallopt :: proc(param: c.int, value: c.int) -> c.int ---
	}

	M_MXFAST :: 1

	// a large free makes glibc consolidate every fastbin chunk: an unbounded pause inside one GC step
	malloc_fastbins_disable :: proc() {
		mallopt(M_MXFAST, 0)
	}
} else {
	malloc_fastbins_disable :: proc() {}
}

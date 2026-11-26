# litehtml

Vendored from https://github.com/litehtml/litehtml at 0c469ca0fb216b9769fa7ef9a011aa4bc789b150 (BSD-3-Clause,
LICENSE), with its bundled gumbo 0.14.1 (Apache-2.0, src/gumbo/LICENSE). Only src/ and include/ are kept.

- `src/string_id.cpp`: the id-to-string table is a `std::deque` instead of a `std::vector`, so the reference `_s()`
  returns stays valid while another thread adds an id (qed lays out documents on a worker and the hover on the main
  thread; the table is already mutex-guarded).

`qlh.h`/`qlh.cpp` are qed's extern "C" wrapper: a cell-grid `document_container` forwarding to callbacks, and
`qlh_walk` reporting each element with `href`, `src`, `data-sourcepos` or `id` and its rendering boxes. `litehtml.odin`
binds it.

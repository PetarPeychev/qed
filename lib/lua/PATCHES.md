# Lua (vendored)

Lua 5.4.9 `src/` (no `lua.c`/`luac.c`), built static by `build.sh`. `lua.odin` holds the FFI subset qed uses.

## Patches

- `lgc.c` `entersweep`: the sweep starts at the `allgc` header instead of calling `sweeptolive`. That
  call freed every dead object at the list head in the step that ran the atomic phase, i.e. all garbage
  made during the mark phase (263k frees, ~7 ms with a 10k-row tree rebuilt per key). The incremental
  sweep steps now free it at their normal rate; objects created before the first sweep step are new-white
  and survive it.

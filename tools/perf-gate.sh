#!/bin/sh
# perf-gate.sh [CORPUS_DIR] [default]: generate the stress corpus if needed, then run the
# headless benchmark gate (bench_gate) on an -o:speed build, as build.sh ("default": odin test's -o:minimal).
# QED_GATE_ONLY=files,long,longoff,longon,panes,plugins and QED_GATE_FILES=a.c,b.md narrow it.
# Runs under a 6 GB address-space cap and a 30 min timeout.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
corpus=${1:-${TMPDIR:-/tmp}/qed-corpus}
opt=-o:speed
[ "${2:-}" != default ] || opt=
python3 "$root/tools/gen-corpus.py" "$corpus"
cd "$root"
ulimit -v 6000000
QED_GATE=$corpus timeout 1800 odin test src -collection:lib=lib $opt \
    -define:ODIN_TEST_NAMES=main.bench_gate -define:ODIN_TEST_TRACK_MEMORY=false

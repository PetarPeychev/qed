#!/bin/sh
# perf-gate.sh [CORPUS_DIR] [debug]: generate the stress corpus if needed, then run the
# headless benchmark gate (bench_gate) on an -o:speed build. QED_GATE_ONLY=files,long,panes,plugins
# narrows it. Runs under a 6 GB address-space cap and a 30 min timeout.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
corpus=${1:-${TMPDIR:-/tmp}/qed-corpus}
opt=-o:speed
[ "${2:-}" != debug ] || opt=
python3 "$root/tools/gen-corpus.py" "$corpus"
cd "$root"
ulimit -v 6000000
QED_GATE=$corpus timeout 1800 odin test src -collection:lib=lib $opt \
    -define:ODIN_TEST_NAMES=main.bench_gate -define:ODIN_TEST_TRACK_MEMORY=false

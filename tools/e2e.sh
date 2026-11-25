#!/bin/sh
# e2e.sh: build the out-of-process e2e driver and run it against ./qed.
#   tools/e2e.sh verify [scenario...]     compare against tools/e2e/golden
#   tools/e2e.sh update [scenario...]     rewrite goldens
#   tools/e2e.sh demo --out DIR [--size CxR]  .cast + .html player per scenario
#   tools/e2e.sh matrix [--sizes ..] [--terms ..]
#   tools/e2e.sh show FILE                print a snapshot in color
set -eu
cd "$(dirname "$0")/.."
if [ ! -x qed ] || [ -n "$(find src plugins config lib build.sh -newer qed -type f ! -name '*.o' ! -name '*.a' | head -n 1)" ]; then
    ./build.sh
fi
bin=tools/e2e/qed-e2e
if [ ! -x "$bin" ] || [ -n "$(find tools/e2e lib/vterm lib/pty lib/asciinema-player -newer "$bin" \( -name '*.odin' -o -path 'lib/asciinema-player/*' \))" ]; then
    odin build tools/e2e -collection:lib=lib -out:"$bin"
fi
exec "$bin" "$@"

#!/bin/sh
# test.sh [odin build flags...]: build the test binary once, then run the suite split across
# QED_TEST_SHARDS processes (default: cores / 2, at most 8). Each process has its own termbox
# backend and e2e_lock, so e2e sessions run in parallel across processes.
# Same tests and pass/fail as `odin test src -collection:lib=lib`; prints failing shards in full.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
shards=${QED_TEST_SHARDS:-$((cores / 2))}
[ "$shards" -ge 1 ] || shards=1
[ "$shards" -le 8 ] || [ -n "${QED_TEST_SHARDS:-}" ] || shards=8
out=$(mktemp -d "${TMPDIR:-/tmp}/qed-test.XXXXXX")
trap 'rm -rf "$out"' EXIT INT TERM

odin build src -collection:lib=lib -build-mode:test -out:"$out/qed-test" "$@"

want=$(cat src/*.odin | grep -c '@(test')
cat src/*.odin | grep -A1 '^@(test)$' | sed -n 's/^\([a-z_0-9]*\) :: proc.*/\1/p' | sort > "$out/names"
got=$(wc -l < "$out/names")
if [ "$got" -ne "$want" ]; then
    echo "test.sh: found $got test names for $want @(test lines; keep each plain @(test) on its own line above 'name :: proc'" >&2
    exit 2
fi

i=0
while [ "$i" -lt "$shards" ]; do
    awk -v n="$shards" -v i="$i" 'NR % n == i' "$out/names" | paste -sd, - > "$out/shard$i.list"
    if [ -s "$out/shard$i.list" ]; then
        ( rc=0; "$out/qed-test" "-tests:$(cat "$out/shard$i.list")" > "$out/shard$i.log" 2>&1 || rc=$?; echo "$rc" > "$out/shard$i.rc" ) &
    fi
    i=$((i + 1))
done
wait

status=0
ran=0
i=0
while [ "$i" -lt "$shards" ]; do
    if [ -s "$out/shard$i.list" ]; then
        rc=$(cat "$out/shard$i.rc" 2>/dev/null || echo missing)
        n=$(sed -n 's/^Finished \([0-9]*\) tests* in .*successful\.$/\1/p' "$out/shard$i.log")
        if [ "$rc" != 0 ] || [ -z "$n" ] || grep -q '^No test found' "$out/shard$i.log"; then
            status=1
            echo "=== shard $i failed (exit $rc) ==="
            cat "$out/shard$i.log"
        else
            ran=$((ran + n))
            grep '^Finished' "$out/shard$i.log" | sed "s/^/shard $i: /"
        fi
    fi
    i=$((i + 1))
done
if [ "$status" -eq 0 ] && [ "$ran" -ne "$got" ]; then
    echo "test.sh: shards ran $ran tests, expected $got" >&2
    status=1
fi
[ "$status" -eq 0 ] && echo "All $got tests passed in $shards shards." || echo "Some shards failed."
exit "$status"

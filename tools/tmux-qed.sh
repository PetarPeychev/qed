#!/bin/sh
# tmux-qed.sh: drive the real ./qed in a detached tmux session and read the screen.
#
#   start [--size WxH] [--home DIR] [--config FILE] [--] [qed args...]
#       Runs ./qed from the repo root with an isolated HOME (default: fresh temp
#       dir, removed by stop) and TERM=tmux-256color + COLORTERM=truecolor.
#       --config seeds $HOME/.config/qed/config.json. Prints the session name.
#   keys SESSION <tmux send-keys args...>
#       Sends keys, then waits for the screen to settle. Examples:
#         keys S C-p            Ctrl+P          keys S M-p      Alt+P
#         keys S Escape Enter   named keys      keys S -l 'text'  literal text
#   capture SESSION [--color]
#       Prints the screen; --color keeps escape sequences.
#   stop SESSION
#       Kills the session and removes its temp HOME (if start made it).
set -eu

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
tmp_root=${TMPDIR:-/tmp}

sub=${1:-}
[ $# -eq 0 ] || shift
case $sub in
start)
    size=120x40 home= config=
    while [ $# -gt 0 ]; do
        case $1 in
        --size) size=$2; shift 2 ;;
        --home) home=$2; shift 2 ;;
        --config) config=$2; shift 2 ;;
        --) shift; break ;;
        *) break ;;
        esac
    done
    [ -x "$root/qed" ] || { echo "tmux-qed: $root/qed not built (run ./build.sh)" >&2; exit 1; }
    owned=
    if [ -z "$home" ]; then
        home=$(mktemp -d "$tmp_root/tmux-qed-home.XXXXXX"); owned=1
    fi
    mkdir -p "$home/.config/qed"
    [ -z "$config" ] || cp "$config" "$home/.config/qed/config.json"
    name=qedsmoke-$$-$(date +%s)
    cmd="cd '$root' && exec env HOME='$home' TERM=tmux-256color COLORTERM=truecolor ./qed"
    for a in "$@"; do cmd="$cmd '$a'"; done
    if ! tmux new-session -d -s "$name" -x "${size%x*}" -y "${size#*x}" "$cmd"; then
        [ -z "$owned" ] || rm -rf "$home"
        exit 1
    fi
    [ -z "$owned" ] || echo "$home" > "$tmp_root/$name.home"
    sleep 0.5
    echo "$name"
    ;;
keys)
    [ $# -ge 2 ] || usage
    s=$1; shift
    tmux send-keys -t "$s" "$@"
    prev=$(tmux capture-pane -p -t "$s" 2>/dev/null || true)
    i=0
    while [ $i -lt 30 ]; do
        sleep 0.1
        cur=$(tmux capture-pane -p -t "$s" 2>/dev/null || true)
        [ "$cur" = "$prev" ] && break
        prev=$cur; i=$((i + 1))
    done
    ;;
capture)
    [ $# -ge 1 ] || usage
    s=$1; flag=-p
    [ "${2:-}" != --color ] || flag=-pe
    tmux capture-pane "$flag" -t "$s"
    ;;
stop)
    [ $# -eq 1 ] || usage
    home=$(cat "$tmp_root/$1.home" 2>/dev/null || true)
    tmux kill-session -t "$1" 2>/dev/null || true
    rm -f "$tmp_root/$1.home"
    case $home in "$tmp_root"/tmux-qed-home.*) rm -rf "$home" ;; esac
    ;;
*) usage ;;
esac

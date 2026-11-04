#!/bin/sh
# Stop the Strata server started by the start scripts in this folder (PolyStrata tree).
#
# Matches, in this order: the PID recorded at start, the CLI started with this
# directory's profile, and any engine/server still holding the Strata-v02x tree or the
# PolyStrata tree.  One stop kills either PolyStrata engine (clover / ornith), and another
# box's server is never touched. SIGTERM, wait, SIGKILL as last resort.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="$HERE/coder-dflash2-15.json"
PIDFILE="$HERE/server.pid"
REPO=/home/kareem/Documents/Strata-v02x
POLY=/home/kareem/PolyStrata

collect() {
    {
        [ -f "$PIDFILE" ] && cat "$PIDFILE"
        pgrep -f "serve --profile $HERE/" 2>/dev/null || true
        pgrep -f "engine/strata --serve" 2>/dev/null || true
        pgrep -f "strata-pol[y] --serve" 2>/dev/null || true
        pgrep -f "serve/server\.py" 2>/dev/null || true
    } | while IFS= read -r P; do
        [ -n "$P" ] || continue
        [ -r "/proc/$P/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)
        cwd=$(readlink "/proc/$P/cwd" 2>/dev/null)
        case "$cmd;$cwd" in
            *"$HERE/"*|*"$REPO"*|*"$POLY"*) printf '%s\n' "$P" ;;
        esac
    done | sort -u
}

PIDS=$(collect)
if [ -z "$PIDS" ]; then
    rm -f "$PIDFILE"
    echo "nothing running (strata CLI / Strata-v02x / PolyStrata)"
    exit 0
fi

echo "stopping: $PIDS"
kill -TERM $PIDS 2>/dev/null
for _ in $(seq 1 12); do
    sleep 2
    PIDS=$(collect)
    [ -z "$PIDS" ] && { rm -f "$PIDFILE"; echo "stopped"; exit 0; }
done

echo "forcing: $PIDS"
kill -KILL $PIDS 2>/dev/null
rm -f "$PIDFILE"
echo "stopped (some processes needed SIGKILL)"

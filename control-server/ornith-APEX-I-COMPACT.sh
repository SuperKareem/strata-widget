#!/bin/sh
# Start the Ornith APEX-I-COMPACT server from the PolyStrata tree (CUDA fork of Strata).
#
#   Engine   /home/kareem/PolyStrata/engine-poly/strata-poly
#   Server   /home/kareem/PolyStrata/.venv/bin/python serve/server.py --engine strata
#            --config strata-ornith-apex-i-compact.json --port 8090
#   Config   /home/kareem/PolyStrata/strata-ornith-apex-i-compact.json (the port is read from it)
#   Model    Ornith-1.5-35B-A3B-APEX-I-COMPACT (the stock llama.cpp GGUF)
#   Flags    threads 13, --kv q8_0, --tail-skip 6, --conversation-cache-mib 16384
#   Network  0.0.0.0:8090, no API key
#
# This control tree (port 8092) only stops the previous instance and then launches this
# one; the control port and the engine port are different numbers on this box.
# Detached, survives the launching shell. Waits for /v1/models to report loaded.
# Usage: ./ornith-APEX-I-COMPACT.sh   (or GET http://<host>:8092/ornith-APEX-I-COMPACT)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
POLY=/home/kareem/PolyStrata
CONFIG=strata-ornith-apex-i-compact.json
LOG="$POLY/strata-ornith-apex-i-compact.log"
PIDFILE="$HERE/server.pid"

[ -x "$POLY/.venv/bin/python" ] || { echo "missing venv: $POLY/.venv/bin/python"; exit 1; }
[ -f "$POLY/$CONFIG" ] || { echo "missing config: $POLY/$CONFIG"; exit 1; }
PORT=$( "$POLY/.venv/bin/python" -c "import json; print(json.load(open('$POLY/$CONFIG'))['port'])" ) || exit 1

# Asking for Ornith while Ornith is already up must not restart anything: a restart kills
# whatever is generating. Switching models still goes through the stop below.
if pgrep -f "strata-ornith-apex-i-compact[.]json" >/dev/null 2>&1; then
    echo "already serving ornith APEX-I-COMPACT on :$PORT - left running, nothing to do"
    echo "to restart it anyway: $HERE/stop-strata.sh && $POLY/start-strata-poly.sh"
    exit 0
fi

# one server at a time: stop whatever this tree owns (either PolyStrata engine), never another box's
"$HERE/stop-strata.sh" >/dev/null 2>&1 || true
sleep 2

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT is held by another instance, not starting a duplicate:"
    ss -ltnp 2>/dev/null | grep ":$PORT " || true
    exit 1
fi

echo "Starting Ornith APEX-I-COMPACT (PolyStrata tree, CUDA) ..."
cd "$POLY" || exit 1
setsid nohup .venv/bin/python serve/server.py --engine strata --config "$CONFIG" --port "$PORT" >>"$LOG" 2>&1 </dev/null &
echo $! > "$PIDFILE"
disown 2>/dev/null || true

i=0
while [ "$i" -lt 40 ]; do
    if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" | grep -q '"loaded"'; then
        echo "ready: http://0.0.0.0:$PORT/  (LAN: http://192.168.1.6:$PORT/v1, no key)"
        echo "log:   $LOG"
        exit 0
    fi
    i=$((i + 1))
    sleep 3
done

echo "NOT ready after ~2 minutes - tail of $LOG:"
tail -5 "$LOG" 2>/dev/null
exit 1

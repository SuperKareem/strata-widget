#!/bin/sh
# Start the Clover server from the PolyStrata tree (CUDA fork of Strata).
#
#   Engine   /home/kareem/PolyStrata/engine-poly/strata-poly
#   Server   /home/kareem/PolyStrata/.venv/bin/python serve/server.py --engine strata
#            --config strata-clover-q4_k_m.json --port 8090 --api-key strata
#   Config   /home/kareem/PolyStrata/strata-clover-q4_k_m.json (the port is read from it)
#   Model    Diffuspace-Clover-35B-A3B-Preview-Q4_K_M.gguf (21 GiB, already downloaded)
#   Flags    threads 9, --conversation-cache-mib auto, no --kv
#   Network  0.0.0.0:8090, API key "strata"
#
# This control tree (port 8092) only stops the previous instance and then launches this
# one; the control port and the engine port are different numbers on this box.
# Detached, survives the launching shell. Waits for /v1/models to report loaded.
# Usage: ./clover-Q4_K_M.sh   (or GET http://<host>:8092/clover-Q4_K_M)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
POLY=/home/kareem/PolyStrata
CONFIG=strata-clover-q4_k_m.json
LOG="$POLY/strata-clover-q4_k_m.log"
PIDFILE="$HERE/server.pid"
KEY=strata
# Printed LAN endpoint: the server's own primary address, so no personal address is committed.
LAN=${LAN:-$(hostname -I 2>/dev/null | cut -d' ' -f1)}
LAN=${LAN:-0.0.0.0}

[ -x "$POLY/.venv/bin/python" ] || { echo "missing venv: $POLY/.venv/bin/python"; exit 1; }
[ -f "$POLY/$CONFIG" ] || { echo "missing config: $POLY/$CONFIG"; exit 1; }
PORT=$( "$POLY/.venv/bin/python" -c "import json; print(json.load(open('$POLY/$CONFIG'))['port'])" ) || exit 1

# Asking for Clover while Clover is already up must not restart anything: a restart kills
# whatever is generating. Switching models still goes through the stop below.
if pgrep -f "strata-clover-q4_k_m[.]json" >/dev/null 2>&1; then
    echo "already serving clover-Q4_K_M on :$PORT - left running, nothing to do"
    echo "to restart it anyway: $HERE/stop-strata.sh && $POLY/start-clover-poly.sh"
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

echo "Starting Clover (PolyStrata tree, CUDA) ..."
cd "$POLY" || exit 1
setsid nohup .venv/bin/python serve/server.py --engine strata --config "$CONFIG" --port "$PORT" --api-key "$KEY" >>"$LOG" 2>&1 </dev/null &
echo $! > "$PIDFILE"
disown 2>/dev/null || true

i=0
while [ "$i" -lt 40 ]; do
    if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" | grep -q '"loaded"'; then
        echo "ready: http://0.0.0.0:$PORT/  (LAN: http://$LAN:$PORT/v1, key: $KEY)"
        echo "log:   $LOG"
        exit 0
    fi
    i=$((i + 1))
    sleep 3
done

echo "NOT ready after ~2 minutes - tail of $LOG:"
tail -5 "$LOG" 2>/dev/null
exit 1

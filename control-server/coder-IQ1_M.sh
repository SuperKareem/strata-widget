#!/bin/sh
# Start the Strata Coder server through the `strata` CLI.
#
#   CLI      /home/kareem/.local/bin/strata serve --profile ./coder-dflash2-15.json
#   Engine   Strata-v02x/engine/strata
#   Runtime  ROCm 10.0 system + the hipBLASLt 1.5.0 libraries from the llama bundle
#            (lib_dirs puts that folder first), with the 100500 tuning table calibrated
#            on this RX 9060 XT.
#   Drafter  --draft dflash2 (see the note printed after "ready"; the stock engine refuses
#            DFlash2 under --serve and drafts with MTP instead)
#   Network  0.0.0.0:8080, API key "strata"
#
# Detached, survives the launching shell. Waits for /v1/models to report loaded.
# Usage: ./coder-IQ1_M.sh   (or GET http://<host>:8090/coder-IQ1_M)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="$HERE/coder-dflash2-15.json"
CLI=/home/kareem/.local/bin/strata
PORT=8080
KEY=strata
PIDFILE="$HERE/server.pid"
OUT="$HERE/server.out"
LOG=/home/kareem/Documents/Strata-v02x/strata-coder-iq1_m-dflash2-15.log

[ -f "$PROFILE" ] || { echo "missing profile: $PROFILE"; exit 1; }
[ -x "$CLI" ] || { echo "missing CLI: $CLI"; exit 1; }

# one server at a time: stop this tree's previous instance (ours), but never another tree's
"$HERE/stop-strata.sh" >/dev/null 2>&1 || true
sleep 2

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT is held by another instance, not starting a duplicate:"
    ss -ltnp 2>/dev/null | grep ":$PORT " || true
    exit 1
fi

echo "Starting Strata (CLI + 1.5 runtime + DFlash2 request) ..."
setsid nohup "$CLI" serve --profile "$PROFILE" >"$OUT" 2>&1 </dev/null &
echo $! > "$PIDFILE"
disown 2>/dev/null || true

i=0
while [ "$i" -lt 180 ]; do
    if curl -sf -m 2 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
        echo "ready: http://0.0.0.0:$PORT/  (LAN: http://192.168.1.13:$PORT/v1, key: $KEY)"
        echo "log:   $LOG"
        grep -h "engine started" "$LOG" 2>/dev/null | tail -1 | cut -c1-200
        grep -h "hipBLASLt tuning enabled" "$LOG" 2>/dev/null | tail -1
        grep -h "draft dflash2 is off" "$LOG" 2>/dev/null | tail -1
        exit 0
    fi
    i=$((i + 1))
    sleep 2
done

echo "NOT ready after ~6 minutes - tail of $OUT and $LOG:"
tail -5 "$OUT" 2>/dev/null
tail -5 "$LOG" 2>/dev/null
exit 1

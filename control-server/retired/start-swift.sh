#!/bin/sh
# Start the Swift 1.5 IQ3_XXS server through the `strata` CLI.
#
#   CLI      /home/kareem/.local/bin/strata serve --profile ./swift-15.json
#   Engine   Strata-v02x/engine/strata
#   Runtime  ROCm 10.0 system + the hipBLASLt 1.5.0 libraries from the llama bundle
#            (lib_dirs puts that folder first), with the 100500 tuning table.
#   Drafter  MTP: the DFlash2 drafter is trained for Qwen3.8-Flash-Next / Gyro and
#            the CLI refuses it for this model, so Swift keeps its own MTP.
#   Network  0.0.0.0:8080, API key "strata"
#
# Stops whatever this folder was serving first (coder or Swift), then waits for ready.
# The first start of a fresh expert profile can take many minutes.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="$HERE/swift-15.json"
CLI=/home/kareem/.local/bin/strata
PORT=8080
KEY=strata
# Printed LAN endpoint: the server's own primary address, so no personal address is committed.
LAN=${LAN:-$(hostname -I 2>/dev/null | cut -d' ' -f1)}
LAN=${LAN:-0.0.0.0}
PIDFILE="$HERE/server.pid"
OUT="$HERE/server.out"
LOG=/home/kareem/Documents/Strata-v02x/strata-swift-iq3_xxs-15.log

[ -f "$PROFILE" ] || { echo "missing profile: $PROFILE"; exit 1; }
[ -x "$CLI" ] || { echo "missing CLI: $CLI"; exit 1; }

"$HERE/stop-strata.sh" >/dev/null 2>&1 || true
sleep 2

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT is held by another instance, not starting a duplicate:"
    ss -ltnp 2>/dev/null | grep ":$PORT " || true
    exit 1
fi

echo "Starting Swift 1.5 IQ3_XXS (CLI + 1.5 runtime + MTP) ..."
setsid nohup "$CLI" serve --profile "$PROFILE" >"$OUT" 2>&1 </dev/null &
echo $! > "$PIDFILE"
disown 2>/dev/null || true

i=0
while [ "$i" -lt 240 ]; do
    if curl -sf -m 2 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
        echo "ready: http://0.0.0.0:$PORT/  (LAN: http://$LAN:$PORT/v1, key: $KEY)"
        echo "log:   $LOG"
        grep -h "engine started" "$LOG" 2>/dev/null | tail -1 | cut -c1-200
        grep -h "hipBLASLt tuning enabled" "$LOG" 2>/dev/null | tail -1
        exit 0
    fi
    i=$((i + 1))
    sleep 5
done

echo "NOT ready after ~20 minutes - tail of $OUT and $LOG:"
tail -5 "$OUT" 2>/dev/null
tail -5 "$LOG" 2>/dev/null
exit 1

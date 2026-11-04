#!/bin/sh
# Start the Gyro-M server from the Strata-v02x tree.
#
#   Script     /home/kareem/Documents/Strata-v02x/start-gyro.sh (this folder only stops the
#              previous server and then hands the start over to it)
#   Engine     /home/kareem/Documents/Strata-v02x/engine/strata (0.1.55, built from v0.2.9)
#   Server     serve/server.py --engine strata --config strata-gyro-m.json --port 8080
#   Runtime    ROCm 10.0 system libraries plus the hipBLASLt 1.5.0 transplant in ~/hip15/ld,
#              with its 168-row tuning table tagged 100500.  The repo script checks that the
#              table and the library agree before it launches, and prints the tuning line the
#              engine reported after it is ready; a mismatch would silently drop the dense
#              prompt GEMMs to hipBLAS (about 45% slower), which is why it refuses instead.
#   Flags      --spec 4 drafter chain with MTP, --kv k8v4 --kv-resident 20480,
#              --resident-experts with --resident-budget-gib 10, --max-context 92160
#   Network    0.0.0.0:8080, API key "strata"
#
# Gyro-M is agentionai's trellis-coded Qwen3.8-Flash-Next: 29.9 GiB of experts stream from
# the GGUF, so the first load after a cold start takes minutes, not seconds.
# Usage: ./gyro-Gyro-M.sh   (or GET http://<host>:8090/gyro-Gyro-M)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=/home/kareem/Documents/Strata-v02x
PORT=8080
KEY=strata
LOG="$REPO/strata-gyro-m.log"

[ -x "$REPO/start-gyro.sh" ] || { echo "missing repo script: $REPO/start-gyro.sh"; exit 1; }
[ -f "$REPO/strata-gyro-m.json" ] || { echo "missing config: $REPO/strata-gyro-m.json"; exit 1; }

# Asking for Gyro-M while Gyro-M is already loaded must not restart anything: a restart kills
# whatever is generating.  Switching models still goes through the stop below.
LOADED=$(curl -s -m 3 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)
if printf '%s' "$LOADED" | grep -q '"id": *"gyro-m"' &&
   printf '%s' "$LOADED" | grep -q '"value": *"loaded"'; then
    echo "already serving gyro-m on :$PORT - left running, nothing to do"
    echo "to restart it anyway: $REPO/stop-strata.sh && $REPO/start-gyro.sh"
    exit 0
fi

"$HERE/stop-strata.sh" >/dev/null 2>&1 || true
sleep 2

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT is held by another instance, not starting a duplicate:"
    ss -ltnp 2>/dev/null | grep ":$PORT " || true
    exit 1
fi

echo "Starting Gyro-M (Strata-v02x tree, tuning table 100500) ..."
"$REPO/start-gyro.sh"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "log:   $LOG"
curl -s -m 3 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" |
    grep -o '"id": *"[^"]*"' | head -1
echo "LAN:   http://192.168.1.13:$PORT/v1, key: $KEY"

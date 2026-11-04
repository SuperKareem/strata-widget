#!/bin/sh
# Switch the desk to the PREBUILT engine 0.1.48 (Strata-0.2.3-linux-amd-rx9070.AppImage bundle),
# served via the Strata-v02x server.py with the cloned coder config. Stops the tree's server
# and any previous prebuilt instance first.
set -u
PFX=/home/kareem/Documents/Strata-prebuilt
/home/kareem/Documents/Strata-v02x/stop-strata.sh || true
pkill -f "serve.server --engine strata --config $PFX/strata-prebuilt-iq1_m.json" 2>/dev/null
sleep 8
pkill -f "engine-bundle/0.1.48" 2>/dev/null
sleep 6
exec setsid -f bash -c 'cd "$1" && exec python3 -m serve.server --engine strata --config /home/kareem/Documents/Strata-prebuilt/strata-prebuilt-iq1_m.json --port 8080 > /home/kareem/Documents/Strata-prebuilt/server.out 2>&1' _ /home/kareem/Documents/Strata-v02x

#!/bin/sh
# 5-second samples of the RAM the conversation cache is fighting over, while an arm runs.
# MemAvailable is what the engine's admission test reads, engine_swap is the thing we are
# afraid of (resident experts are NOT page-locked on this driver, VmLck=0), so a rising
# engine_swap with a parked big conversation is the failure this watch exists to catch.
set -u
OUT=${1:?usage: ramwatch.sh <outfile>}
echo "t mem_avail_mib swap_free_mib engine_rss_mib engine_swap_mib" > "$OUT"
while true; do
    ENG=$(pgrep -f 'components/engine/|engine/strata' 2>/dev/null | head -1)
    MA=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    SF=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo)
    if [ -n "$ENG" ] && [ -r "/proc/$ENG/status" ]; then
        RSS=$(awk '/^VmRSS/{print int($2/1024)}' "/proc/$ENG/status")
        SWP=$(awk '/^VmSwap/{print int($2/1024)}' "/proc/$ENG/status")
    else
        RSS=NA
        SWP=NA
    fi
    printf '%s %s %s %s %s\n' "$(date +%H:%M:%S)" "$MA" "$SF" "$RSS" "$SWP" >> "$OUT"
    sleep 5
done

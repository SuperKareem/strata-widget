#!/usr/bin/env python3
"""Stage 9: per-arm reuse, per-round cost, and what the RAM/watch saw during each arm."""
import json
import re
import statistics as st
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
rows = [json.loads(l) for l in open(MTP / "evidence/stage9-cache.jsonl")]
prog = open(MTP / "progress.log", errors="ignore").read().splitlines()

# arm windows from the progress log (it stamps HH:MM:SS on every line)
win = {}
cur = None
for ln in prog:
    m = re.match(r"\[(\d\d):(\d\d):(\d\d)\] stage5x arm (\S+): (starting|stopping)", ln)
    if m and m.group(4).startswith(("base", "floor")):
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        if m.group(5) == "starting":
            cur = m.group(4)
            win.setdefault(cur, [t, None])
        else:
            if cur:
                win[cur][1] = t
print("arm windows (seconds since midnight):", win)

watch = []
for ln in open(MTP / "ramwatch-stage9.tsv").read().splitlines()[1:]:
    p = ln.split()
    if len(p) < 5:
        continue
    h, mi, s = (int(x) for x in p[0].split(":"))
    t = h * 3600 + mi * 60 + s
    watch.append((t, int(p[1]), int(p[2]), p[3], p[4]))
print(f"{len(watch)} RAM samples\n")

for name in ("base", "floor1024", "base-repeat"):
    r = [x for x in rows if x["variant"] == name]
    pre = [x for x in r if x["note"] == "prefill"]
    dec = [x for x in r if x["note"] is None]
    if not r:
        print(f"{name}: no rows")
        continue
    lo, hi = win.get(name, (None, None))
    sel = [w for w in watch if lo and hi and lo <= w[0] <= hi]
    print(f"--- {name} ({len(dec)} rounds) ---")
    print(f"  prompt tokens      {pre[0]['prompt_n'] if pre else '?'}")
    print(f"  reused per round   mean {st.mean(x['cache_n'] or 0 for x in dec):8.0f}  "
          f"({st.mean(x['cache_n'] or 0 for x in dec) / (pre[0]['prompt_n'] or 1) * 100:.2f}% of the prompt)")
    print(f"  prompt_ms per round  mean {st.mean(x['prompt_ms'] or 0 for x in dec):7.1f}  "
          f"(cold prefill {pre[0]['prompt_ms']:.0f} ms)")
    print(f"  decode tok/s       median {st.median(x['predicted_per_second'] for x in dec):5.1f}")
    print(f"  wall per round       mean {st.mean(x['wall_s'] or 0 for x in dec):5.2f} s")
    if sel:
        sw = [w for w in sel if w[4] != "NA"]
        print(f"  RAM: MemAvailable min {min(w[1] for w in sel):5d} MiB, "
              f"engine RSS {max(int(w[3]) for w in sw) if sw else '?'} MiB, "
              f"engine swapped {sw[0][4] if sw else '?'} -> {sw[-1][4] if sw else '?'} MiB, "
              f"SwapFree min {min(w[2] for w in sel):5d} MiB")

# what the engines themselves logged about parking
for name in ("base", "floor1024", "base-repeat"):
    f = MTP / f"serve-stage9-cache-{name}.log"
    if not f.exists():
        print(f"\n{name}: no log")
        continue
    txt = f.read_text(errors="ignore")
    park = re.findall(r"parked (\d+) tokens in [\d.]+ ms; parked=\d+ bytes=\d+ evictions=\d+ snapshot_bytes=(\d+)", txt)
    skip = re.findall(r"skip parking \([^)]*?need (\d+) MiB[^)]*?(\d+) MiB available", txt)
    over = re.findall(r"skip parking \(snapshot (\d+) MiB exceeds", txt)
    ev = len(re.findall(r"evicted \d+ parked conversation", txt))
    print(f"\n{name}: parks={len(park)} refusals={len(skip)} budget-refusals={len(over)} eviction-lines={ev}")
    if park:
        big_t, big_s = max(((int(t), int(s)) for t, s in park), key=lambda x: x[0])
        print(f"   biggest park {big_t} tok = {big_s / 1048576:.0f} MiB "
              f"= {big_s / 1024 / big_t:.1f} KiB/token")
    if skip:
        print(f"   asked {max(int(n) for n, _ in skip)} MiB, RAM seen {min(int(a) for _n, a in skip)}"
              f"-{max(int(a) for _n, a in skip)} MiB")

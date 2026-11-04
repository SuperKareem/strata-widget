#!/usr/bin/env python3
"""Stage 7: time to the first token and the cold-prefill curve (item 7), LIVE server, no restart.

Every earlier stage measured decode. At this profile's window the number the user waits
for on a new long document is the prefill: stage 4 saw 154,545 tokens take ~97 s, about
1,600 tok/s, in five independent processes - on a fixture that turned out to be mostly
ELF bytes, so the curve is measured here on the repository's real text instead.

  A  the shape of the curve - prompt tok/s and TTFT (time to the first streamed token) at
     4k / 16k / 48k / 117k cold prompt sizes;
  B  whether the per-request prefill knob does anything on this single-GPU setup:
     strata_tune {"prefill_pipe": X} reaches the engine as `pipe=` (serve/server.py:1434
     -> generate.cpp's pipe= -> Prefill::set_pipe_request). The docs describe it for a
     two-GPU layer split, so a null here is the expected answer and is worth recording.

Every measurement gets its own disjoint slice of `prefill-pool.txt` (mkdoc.py writes it),
so nothing is a prefix-cache hit - each line prints cache_n, which has to stay 0. Slices
are cut with a running chars/token estimate that the last measurement corrects, because
the ratio depends on the file type (this text ~3.6, plain prose ~5.2); the report prints
the measured prompt_n next to the target, and only the measured number means anything.

usage: runner9.py            # both probes
       runner9.py A          # curve only
       runner9.py B          # pipe knob only
"""
import json
import statistics as st
import sys
import time
import urllib.request
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
EVID = MTP / "evidence"
POOL = MTP / "prefill-pool.txt"
PORT, KEY = 8080, "strata"
MODEL = "qwen3.8-flash-next-coder-iq1_m"
CPT0 = 3.6
CURVE = [(4000, 4), (16000, 3), (48000, 2), (117000, 2)]      # (target tokens, repeats)
PIPE_SIZE = 32000
PIPES = [None, 0.0, 1.0, 4096.0]
PIPE_REPEATS = 3
TAG = "stage7-prefill"
PROG = open(MTP / "progress.log", "a", buffering=1)


def log(m):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage7 {m}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


class Cutter:
    """Disjoint slices of about the wanted token count, learning the chars/token ratio as it goes."""

    def __init__(self, pool, cpt=CPT0):
        self.pool, self.cpt, self.pos = pool, cpt, 0

    def take(self, tokens):
        n = max(64, int(tokens * self.cpt))
        if self.pos + n > len(self.pool):
            raise SystemExit(f"pool ran out at {self.pos}+{n} of {len(self.pool)}")
        s = self.pool[self.pos:self.pos + n]
        self.pos += n
        return s

    def report(self, chars, tokens):
        if tokens and chars:
            self.cpt = 0.5 * self.cpt + 0.5 * (chars / tokens)   # one slice is not proof


def ask_stream(doc, pipe, max_tokens=24):
    """(ms to the first content token, the final chunk's timings, wall s)."""
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": doc},
                         {"role": "user", "content": "Name the first file this document mentions."}],
            "max_tokens": max_tokens, "temperature": 0, "stream": True}
    if pipe is not None:
        body["strata_tune"] = {"prefill_pipe": pipe}
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                               data=json.dumps(body).encode())
    r.add_header("Authorization", f"Bearer {KEY}")
    r.add_header("Content-Type", "application/json")
    t0 = time.time()
    first, final = None, {}
    with urllib.request.urlopen(r, timeout=3600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue                          # SSE comments (keep-alive) and event: lines
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                j = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if first is None:
                for c in j.get("choices") or []:
                    d = c.get("delta") or {}
                    if d.get("content") or d.get("reasoning_content"):
                        first = (time.time() - t0) * 1000.0
                        break
            if j.get("timings"):
                final = j
    return first, final.get("timings", {}), time.time() - t0


def record(cut, kind, target, pipe, first, t, wall, seq, rep, chars):
    row = {"kind": kind, "target_tokens": target, "prefill_pipe": pipe, "seq": seq, "rep": rep,
           "slice_chars": chars, "cpt_at_cut": round(cut.cpt, 3),
           "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
           "prompt_per_second": t.get("prompt_per_second"), "prompt_ms": t.get("prompt_ms"),
           "ttft_ms": round(first, 1) if first else None,
           "predicted_n": t.get("predicted_n"),
           "predicted_per_second": t.get("predicted_per_second"),
           "draft_n": t.get("draft_n"), "wall_s": round(wall, 1),
           "t": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(EVID / f"{TAG}.jsonl", "a") as f:
        f.write(json.dumps(row) + "\n")
    log(f"{kind} target {target} pipe={pipe}: prompt_n {row['prompt_n']} "
        f"cache_n {row['cache_n']} prompt {row['prompt_per_second']} tok/s "
        f"TTFT {row['ttft_ms']} ms wall {wall:.1f} s")
    return row


def curve_plan():
    """One job per (size, rep), interleaved by round so no size runs several times in a row."""
    plan = []
    for r in range(max(n for _s, n in CURVE)):
        for size, n in CURVE:
            if r < n:
                plan.append((size, r))
    return plan


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    which = (sys.argv[1] if len(sys.argv) > 1 else "AB").upper()
    cut = Cutter(POOL.read_text())
    rows = []

    if which in ("A", "AB"):
        plan = curve_plan()
        log(f"=== probe A: {len(plan)} cold prefill measurements, "
            f"{sum(s for s, _ in plan)} target tokens, pool {len(cut.pool)} chars ===")
        for seq, (size, rep) in enumerate(plan):
            doc = cut.take(size)
            first, t, wall = ask_stream(doc, None)
            rows.append(record(cut, "curve", size, None, first, t, wall, seq, rep, len(doc)))
            cut.report(len(doc), t.get("prompt_n") or 0)

    if which in ("B", "AB"):
        log(f"=== probe B: pipe knob at {PIPE_SIZE} tokens, {len(PIPES)} values x {PIPE_REPEATS} ===")
        seq = 0
        for rep in range(PIPE_REPEATS):
            # each value runs on its own slice (an identical prompt would be a cache hit), so
            # rotate which slice each value gets; the reps keep a drift off one value
            for pipe in PIPES[rep % len(PIPES):] + PIPES[:rep % len(PIPES)]:
                doc = cut.take(PIPE_SIZE)
                first, t, wall = ask_stream(doc, pipe)
                rows.append(record(cut, "pipe", PIPE_SIZE, pipe, first, t, wall, seq, rep, len(doc)))
                cut.report(len(doc), t.get("prompt_n") or 0)
                seq += 1

    lines = []
    groups = sorted({(r["kind"], r["target_tokens"], str(r["prefill_pipe"])) for r in rows})
    for kind, target, pipe_s in groups:
        sel = [r for r in rows if r["kind"] == kind and r["target_tokens"] == target
               and str(r["prefill_pipe"]) == pipe_s and r["prompt_per_second"]]
        if not sel:
            continue
        pps = sorted(r["prompt_per_second"] for r in sel)
        tt = sorted(r["ttft_ms"] for r in sel if r["ttft_ms"])
        pn = [r["prompt_n"] or 0 for r in sel]
        line = (f"{kind} target={target:6d} pipe={pipe_s:6s} n={len(sel)} "
                f"prompt_n={min(pn)}-{max(pn)} median {pps[len(pps) // 2]:7.1f} tok/s")
        if len(pps) >= 2:
            line += f" (min {pps[0]:.1f} max {pps[-1]:.1f})"
        if tt:
            line += f", TTFT {tt[len(tt) // 2]:6.0f} ms (min {tt[0]:.0f} max {tt[-1]:.0f})"
        lines.append(line)

    # the pipe values share a rep index but not a slice, so a difference is the knob plus the
    # text it happened to run on - the spread says how much to trust it
    def by_rep(pipe):
        return {r["rep"]: r["prompt_per_second"] for r in rows
                if r["kind"] == "pipe" and r["prefill_pipe"] == pipe and r["prompt_per_second"]}
    d0 = by_rep(None)
    for pipe in PIPES[1:]:
        dp = by_rep(pipe)
        common = sorted(set(d0) & set(dp))
        if len(common) >= 2:
            d = [dp[k] / d0[k] - 1 for k in common]
            m = st.mean(d)
            se = st.stdev(d) / len(d) ** 0.5 if len(d) > 1 else 0.0
            verdict = "BEATS" if m - 2 * se > 0 else ("loses" if m + 2 * se < 0 else "tie")
            lines.append(f"pipe {pipe} vs default: {m * 100:+5.2f}% (se {se * 100:.2f}, "
                         f"n={len(d)}) {verdict}")
    txt = "\n".join(lines)
    log("summary\n" + txt)
    (MTP / f"summary-{TAG}.txt").write_text(txt + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Stage 6: refine --spec-min-p under sampling (item 6), LIVE server, no restart.

Stage 3 found 0.5 beating 0.25 by +4.8% at temperature 0.7 and 0.75 losing, so the
sampled optimum is somewhere in 0.4-0.65 and the greedy plateau said nothing about it.
Same method as stage 3: one process, the same cached document, value order rotated so
each value occupies each slot once per question, and the statistic is the paired
difference against the value currently in the profile (0.5).

usage: runner8.py [doc_key] [temperature] [base] [v1,v2,v3,...]
"""
import hashlib
import json
import statistics as st
import sys
import time
import urllib.request
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
EVID = MTP / "evidence"
PORT, KEY = 8080, "strata"
MODEL = "qwen3.8-flash-next-coder-iq1_m"
MAX_TOKENS = 320
PASSES = 3

QUESTIONS = [
    "Write a Python function that merges two sorted lists into one sorted list, without using sorted().",
    "Explain in five bullet points how a git rebase differs from a merge, and give the command for each.",
    "Write a SQL query that returns the second-highest salary in each department.",
    "Give pseudocode for computing realized profit-and-loss per symbol from a list of stock trades.",
    "Explain the CAP theorem in plain words and what it means for a small web app.",
    "Write a bash one-liner that prints the five largest files under a directory, and explain each flag.",
]

PROG = open(MTP / "progress.log", "a", buffering=1)


def log(m):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage6 {m}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def ask(doc, q, min_p, temperature):
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": doc}, {"role": "user", "content": q}],
            "max_tokens": MAX_TOKENS, "temperature": temperature,
            "strata_tune": {"spec_min_p": min_p}}
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                               data=json.dumps(body).encode())
    r.add_header("Authorization", f"Bearer {KEY}")
    r.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(r, timeout=1800) as resp:
        j = json.load(resp)
    return j, time.time() - t0


def main():
    doc_key = sys.argv[1] if len(sys.argv) > 1 else "doc_160000"
    temperature = float(sys.argv[2]) if len(sys.argv) > 2 else 0.7
    base = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    values = [float(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else \
        [0.40, 0.50, 0.60, 0.65]
    if base not in values:
        values = sorted(values + [base])
    tag = f"stage6-minp-sampled-{str(temperature).replace('.', '')}"
    EVID.mkdir(parents=True, exist_ok=True)
    doc = json.load(open(MTP / "doc.json"))[doc_key]
    log(f"start: doc {doc_key}, temperature {temperature}, values {values}, base {base}")

    rows = []

    def one(name, pas, qi, min_p, j, wall, note=None):
        t = j.get("timings", {})
        ch = (j.get("choices") or [{}])[0].get("message", {})
        txt = (ch.get("content") or "") + (ch.get("reasoning_content") or "")
        dn = t.get("draft_n")
        r = {"variant": name, "tag": tag, "pass": pas, "round": qi, "spec_min_p": min_p,
             "temperature": temperature, "prompt_n": t.get("prompt_n"),
             "cache_n": t.get("cache_n"), "prompt_per_second": t.get("prompt_per_second"),
             "predicted_n": t.get("predicted_n"),
             "predicted_per_second": t.get("predicted_per_second"),
             "draft_n": dn, "draft_n_accepted": t.get("draft_n_accepted"),
             "accept": (t.get("draft_n_accepted") / dn) if dn else None,
             "sha": hashlib.sha256(txt.encode()).hexdigest()[:12],
             "wall_s": round(wall, 1), "note": note,
             "t": time.strftime("%Y-%m-%d %H:%M:%S")}
        with open(EVID / f"{tag}.jsonl", "a") as f:
            f.write(json.dumps(r) + "\n")
        return r

    j, wall = ask(doc, QUESTIONS[0], base, temperature)
    pre = one(f"minp{base}", -1, 0, base, j, wall, note="prefill")
    log(f"prefill round: prompt_n {pre['prompt_n']} cache_n {pre['cache_n']} "
        f"{pre['prompt_per_second']} prompt tok/s, decode {pre['predicted_per_second']}")

    by = {}
    n = PASSES * len(values) * len(QUESTIONS)
    done = 0
    for pas in range(PASSES):
        for qi in range(len(QUESTIONS)):
            start = (pas + qi) % len(values)
            for k in range(len(values)):
                v = values[(start + k) % len(values)]
                try:
                    j, wall = ask(doc, QUESTIONS[qi], v, temperature)
                    by.setdefault(v, []).append(one(f"minp{v}", pas, qi, v, j, wall))
                except Exception as e:
                    log(f"minp{v} pass{pas} q{qi}: ERROR {e}")
                done += 1
                if done % 12 == 0:
                    log(f"{done}/{n} requests done")
        log(f"pass {pas} done")

    base_rows = {f"{r['pass']}-{r['round']}": r for r in by.get(base, [])}
    lines = []
    for v in values:
        rs = by.get(v, [])
        sp = sorted(r["predicted_per_second"] for r in rs if r["predicted_per_second"])
        if len(sp) < 2:
            continue
        ac = st.mean(r["accept"] for r in rs if r["accept"] is not None)
        line = f"minp{v:<5.2f} n={len(sp):3d} median={st.median(sp):6.1f} tok/s accept={ac:.2f}"
        if v != base:
            pairs = [(r["predicted_per_second"], base_rows[f"{r['pass']}-{r['round']}"]["predicted_per_second"])
                     for r in rs if f"{r['pass']}-{r['round']}" in base_rows and r["predicted_per_second"]]
            if len(pairs) >= 3:
                d = sorted(a / b - 1 for a, b in pairs)
                m = st.mean(d)
                se = st.stdev(d) / len(d) ** 0.5
                verdict = "BEATS" if m - 2 * se > 0 else ("loses" if m + 2 * se < 0 else "tie")
                line += f" | paired {m * 100:+5.2f}% (se {se * 100:.2f}, n={len(d)}) {verdict}"
        lines.append(line)
    txt = f"temperature {temperature}, doc {doc_key}, base minp{base}\n" + "\n".join(lines)
    log("summary\n" + txt)
    (MTP / f"summary-{tag}.txt").write_text(txt + "\n")


if __name__ == "__main__":
    main()

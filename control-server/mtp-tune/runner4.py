#!/usr/bin/env python3
"""Stage 3 (Phase A): paired per-request A/B of --spec-min-p on the LIVE 8080 server.

The engine takes spec_min_p per request (`strata_tune: {"spec_min_p": P}`,
serve/server.py:1427 -> generate.cpp:12351), so every value is measured in the
same process, against the same cached document, minutes apart. Greedy output is
identical for every value (speculation only changes how tokens are verified),
which is checked here by hashing each reply.

Design: 3 passes x 5 values x 6 questions, value order rotated so each value
sits in each slot once per question (Latin square) - run-to-run drift then
cancels in the paired difference rather than inflating it.
Evidence: evidence/stage3-<size>.jsonl
"""
import hashlib
import json
import statistics as st
import time
import urllib.error
import urllib.request
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
EVID = MTP / "evidence"
PORT = 8080
KEY = "strata"
MODEL = "qwen3.8-flash-next-coder-iq1_m"
MAX_TOKENS = 320
BASE = 0.25
VALUES = [0.05, 0.15, 0.25, 0.35, 0.50]
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


def log(msg):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage3 {msg}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def ask(doc, q, min_p):
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": doc}, {"role": "user", "content": q}],
            "max_tokens": MAX_TOKENS, "temperature": 0,
            "strata_tune": {"spec_min_p": min_p}}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Authorization", f"Bearer {KEY}")
    req.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as resp:
        j = json.load(resp)
    return j, time.time() - t0


def record(tag, vname, pas, qi, min_p, j, wall, extra=None):
    t = j.get("timings", {})
    ch = (j.get("choices") or [{}])[0].get("message", {})
    txt = (ch.get("content") or "") + (ch.get("reasoning_content") or "")
    dn = t.get("draft_n")
    rec = {"variant": vname, "tag": tag, "pass": pas, "round": qi, "spec_min_p": min_p,
           "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
           "prompt_per_second": t.get("prompt_per_second"),
           "predicted_n": t.get("predicted_n"),
           "predicted_per_second": t.get("predicted_per_second"),
           "draft_n": dn, "draft_n_accepted": t.get("draft_n_accepted"),
           "accept": (t.get("draft_n_accepted") / dn) if dn else None,
           "sha": hashlib.sha256(txt.encode()).hexdigest()[:12],
           "finish": ch.get("finish_reason"), "wall_s": round(wall, 1),
           "t": time.strftime("%Y-%m-%d %H:%M:%S")}
    if extra:
        rec.update(extra)
    with open(EVID / f"{tag}.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    return rec


def run_stage(label, doc_key):
    doc = json.load(open(MTP / "doc.json"))[doc_key]
    tag = f"stage3-{label}"
    log(f"=== {label}: warming the document (pays the prefill) ===")
    try:
        j, wall = ask(doc, QUESTIONS[0], BASE)
        r = record(tag, f"minp{BASE}", -1, 0, BASE, j, wall, {"note": "prefill"})
        log(f"prefill round: prompt_n {r['prompt_n']} cache_n {r['cache_n']} "
            f"{r['prompt_per_second']} prompt tok/s, {wall:.0f} s wall")
    except Exception as e:
        log(f"prefill failed: {e} - is the server up?")
        return {}

    out = {}
    n = PASSES * len(VALUES) * len(QUESTIONS)
    done = 0
    for pas in range(PASSES):
        for qi, q in enumerate(QUESTIONS):
            vi = (pas + qi) % len(VALUES)          # Latin square: rotate the value per slot
            for k in range(len(VALUES)):
                v = VALUES[(vi + k) % len(VALUES)]
                name = f"minp{v}"
                try:
                    j, wall = ask(doc, q, v)
                    r = record(tag, name, pas, qi, v, j, wall)
                    out.setdefault(name, []).append(r)
                except Exception as e:
                    log(f"{name} pass{pas} q{qi}: ERROR {e}")
                done += 1
                if done % 10 == 0:
                    log(f"{label}: {done}/{n} requests done")
    log(f"=== {label}: paired summary vs minp{BASE} (medians, % of base) ===")
    report(tag, out)
    return out


def report(tag, rows_by_value):
    base = {f"{r['pass']}-{r['round']}": r for r in rows_by_value.get(f"minp{BASE}", [])}
    lines = []
    for name, rs in sorted(rows_by_value.items()):
        sp = sorted(r["predicted_per_second"] for r in rs if r["predicted_per_second"])
        if len(sp) < 2:
            continue
        med = st.median(sp)
        acc = st.mean(r["accept"] for r in rs if r["accept"] is not None)
        dn = st.mean(r["draft_n"] for r in rs if r["draft_n"])
        pairs = [(r["predicted_per_second"], base[f"{r['pass']}-{r['round']}"]["predicted_per_second"])
                 for r in rs if f"{r['pass']}-{r['round']}" in base and r["predicted_per_second"]]
        txt = f"{name:10s} n={len(sp):3d} median={med:6.1f} tok/s accept={acc:.2f} draft_n={dn:5.1f}"
        if name != f"minp{BASE}" and len(pairs) >= 3:
            d = sorted(a / b - 1 for a, b in pairs)
            m = st.mean(d)
            se = st.stdev(d) / len(d) ** 0.5 if len(d) > 1 else float("nan")
            txt += (f"  paired {m * 100:+5.2f}% vs base (se {se * 100:.2f}, "
                    f"n={len(d)}, {'BEATS' if m - 2 * se > 0 else 'loses' if m + 2 * se < 0 else 'tie'})")
        lines.append(txt)
    # same-text check: greedy output must not depend on the window width
    shas = {}
    for name, rs in rows_by_value.items():
        for r in rs:
            if r.get("note"):
                continue
            shas.setdefault(f"{r['pass']}-{r['round']}", set()).add(r["sha"])
    diff = sum(1 for v in shas.values() if len(v) > 1)
    log(f"replies whose text changed with spec_min_p: {diff} of {len(shas)} (want 0)")
    txt = "\n".join(lines)
    log("\n" + txt)
    (MTP / f"summary-{tag}.txt").write_text(txt + "\n")


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    log(f"start: values {VALUES} base {BASE} passes {PASSES}")
    run_stage("117k", "doc_32000")
    run_stage("155k", "doc_160000")
    log("stage 3 phase A done")


if __name__ == "__main__":
    main()

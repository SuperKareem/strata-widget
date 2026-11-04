#!/usr/bin/env python3
"""Stage 3 follow-ups, both on the LIVE server (no restart).

5a  determinism probe: the same greedy request twice per spec_min_p, then the
    same request with the flag left out.  Greedy output should not depend on
    how wide the verify window is; stage 3 saw the replies differ between
    min-p values, so this separates "min-p changes the text" from "the engine
    is not deterministic at all".
5b  the winner under sampling: temperature 0.7 (the model card's instruct set,
    what real traffic uses) instead of greedy, min-p 0.25 vs 0.5 vs 0.75.
    Every stage 1/2 claim so far is greedy-only.
"""
import hashlib
import json
import statistics as st
import time
import urllib.request
from pathlib import Path

MTP = Path("/home/kareem/Documents/strata-start-stop-server/mtp-tune")
EVID = MTP / "evidence"
PORT, KEY = 8080, "strata"
MODEL = "qwen3.8-flash-next-coder-iq1_m"
DOC = json.load(open(MTP / "doc.json"))["doc_32000"]
PROG = open(MTP / "progress.log", "a", buffering=1)

QUESTIONS = [
    "Write a Python function that merges two sorted lists into one sorted list, without using sorted().",
    "Explain in five bullet points how a git rebase differs from a merge, and give the command for each.",
    "Write a SQL query that returns the second-highest salary in each department.",
    "Give pseudocode for computing realized profit-and-loss per symbol from a list of stock trades.",
    "Explain the CAP theorem in plain words and what it means for a small web app.",
    "Write a bash one-liner that prints the five largest files under a directory, and explain each flag.",
]


def log(m):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage5 {m}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def ask(q, min_p=None, temperature=0.0, max_tokens=320, seed=None):
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": DOC}, {"role": "user", "content": q}],
            "max_tokens": max_tokens, "temperature": temperature}
    if min_p is not None:
        body["strata_tune"] = {"spec_min_p": min_p}
    if seed is not None:
        body["seed"] = seed
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                               data=json.dumps(body).encode())
    r.add_header("Authorization", f"Bearer {KEY}")
    r.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(r, timeout=900) as resp:
        j = json.load(resp)
    return j, time.time() - t0


def cell(j):
    t = j.get("timings", {})
    ch = (j.get("choices") or [{}])[0].get("message", {})
    txt = (ch.get("content") or "") + (ch.get("reasoning_content") or "")
    return {"pps": t.get("predicted_per_second"), "pred_n": t.get("predicted_n"),
            "draft_n": t.get("draft_n"), "acc_n": t.get("draft_n_accepted"),
            "sha": hashlib.sha256(txt.encode()).hexdigest()[:12], "text": txt[:400]}


def probe_5a():
    log("=== 5a determinism: same greedy question, per min-p, twice ===")
    res = {}
    for v in (None, 0.05, 0.25, 0.5):
        runs = [cell(ask(QUESTIONS[1], min_p=v)[0]) for _ in range(2)]
        key = "off" if v is None else str(v)
        res[key] = runs
        log(f"min-p {key}: sha {[r['sha'] for r in runs]} "
            f"pred_n {[r['pred_n'] for r in runs]} pps {[r['pps'] for r in runs]}")
    same_within = all(len({r['sha'] for r in v}) == 1 for v in res.values())
    across = {v[0]['sha'] for v in res.values()}
    log(f"5a: repeats identical within a min-p: {same_within}; "
        f"distinct replies across min-p values: {len(across)} of {len(res)}")
    json.dump(res, open(EVID / "determinism-5a.json", "w"), indent=1)
    return res


def probe_5b():
    log("=== 5b sampled (temp 0.7, model card instruct set): min-p 0.25 vs 0.5 vs 0.75 ===")
    vals = [0.25, 0.5, 0.75]
    rows = []
    for pas in range(3):
        for qi, q in enumerate(QUESTIONS):
            for k in range(len(vals)):
                v = vals[(pas + qi + k) % len(vals)]
                j, wall = ask(q, min_p=v, temperature=0.7, seed=pas)
                c = cell(j)
                rec = {"variant": f"minp{v}", "tag": "stage5b-temp07", "pass": pas,
                       "round": qi, "spec_min_p": v, "temperature": 0.7, "seed": pas,
                       "predicted_per_second": c["pps"], "predicted_n": c["pred_n"],
                       "draft_n": c["draft_n"], "draft_n_accepted": c["acc_n"],
                       "accept": (c["acc_n"] / c["draft_n"]) if c["draft_n"] else None,
                       "sha": c["sha"], "wall_s": round(wall, 1),
                       "t": time.strftime("%Y-%m-%d %H:%M:%S")}
                with open(EVID / "stage5b-temp07.jsonl", "a") as f:
                    f.write(json.dumps(rec) + "\n")
        log(f"5b pass {pas} done")
    by = {}
    for l in open(EVID / "stage5b-temp07.jsonl"):
        r = json.loads(l)
        by.setdefault(r["variant"], []).append(r)
    base = by.get("minp0.25", [])
    for name, rs in sorted(by.items()):
        sp = sorted(r["predicted_per_second"] for r in rs if r["predicted_per_second"])
        ac = st.mean(r["accept"] for r in rs if r["accept"] is not None)
        line = f"5b {name:9s} n={len(sp)} median={st.median(sp):6.1f} tok/s accept={ac:.2f}"
        if name != "minp0.25" and len(rs) == len(base):
            d = sorted(a["predicted_per_second"] / b["predicted_per_second"] - 1
                       for a, b in zip(rs, base)
                       if a["predicted_per_second"] and b["predicted_per_second"])
            m = st.mean(d)
            se = st.stdev(d) / len(d) ** 0.5
            line += f" paired {m*100:+.2f}% (se {se*100:.2f}, n={len(d)})"
        log(line)


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    probe_5a()
    probe_5b()


if __name__ == "__main__":
    main()

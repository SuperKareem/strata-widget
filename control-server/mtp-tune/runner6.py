#!/usr/bin/env python3
"""Stage 4: --mtp-window on the LIVE-shape workload, at 154k context.

Every arm is a fresh `strata serve` on port 8091 from a variant profile with one
--mtp-window value. Only one engine fits in GPU+RAM, so 8080 must be stopped for
the whole run.

Why 154k and not 32k: the default window is 32,768 cells, so a conversation
shorter than that sees no difference at all (src/core/mtp.cpp:372 - a window >=
the context behaves as 0).

Per arm we record both numbers that move:
  * decode tok/s - the draft layer's attention is O(min(cells, N)) (mtp.cpp:1030
    + verify_kernels.cu:1001) and its KV ring is sized by N (mtp.cpp:373);
  * prompt tok/s on the first request, which is a real prefill (cells older than
    prompt_len - N - 64 get no draft K/V at all, mtp.cpp:1426), so a smaller N
    has something to save there too. One sample, so it is a hint, not a result.

Statistic: paired by (pass, question) against the base arm, same as stage 3, plus
a short base repeat at the end to bound drift between the first and last process.
"""
import json
import os
import signal
import statistics as st
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path("/home/kareem/Documents/strata-start-stop-server")
MTP = HERE / "mtp-tune"
EVID = MTP / "evidence"
PROFILE = HERE / "coder-dflash2-15.json"
CLI = "/home/kareem/.local/bin/strata"
PORT = 8091
KEY = "strata"
MODEL = "qwen3.8-flash-next-coder-iq1_m"
DOC_KEY = "doc_160000"          # 154,545 prompt tokens
PASSES = 3
MAX_TOKENS = 320
TAG = "stage4-mtpwindow"

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
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage4 {m}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def make_variant(name, window):
    p = json.load(open(PROFILE))
    p["port"] = PORT
    p["log"] = str(MTP / f"serve-w{window}-{name}.log")
    args = list(p["args"])
    if "--mtp-window" in args:
        args[args.index("--mtp-window") + 1] = str(window)
    elif window is not None:
        args += ["--mtp-window", str(window)]
    p["args"] = args
    path = MTP / f"variant-w{window}-{name}.json"
    json.dump(p, open(path, "w"), indent=1)
    return path, args


def wait_ready(proc, deadline_s=900):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        if proc.poll() is not None:
            return False
        try:
            r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/models")
            r.add_header("Authorization", f"Bearer {KEY}")
            with urllib.request.urlopen(r, timeout=4):
                return True
        except Exception:
            time.sleep(3)
    return False


def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, NameError):
        pass
    for _ in range(20):
        if proc.poll() is not None:
            break
        time.sleep(1)
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, NameError):
            pass
    time.sleep(6)


def ask(doc, q, max_tokens=MAX_TOKENS):
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": doc}, {"role": "user", "content": q}],
            "max_tokens": max_tokens, "temperature": 0}
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                               data=json.dumps(body).encode())
    r.add_header("Authorization", f"Bearer {KEY}")
    r.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(r, timeout=1800) as resp:
        j = json.load(resp)
    return j, time.time() - t0


def rec(name, window, pas, qi, j, wall, note=None):
    t = j.get("timings", {})
    dn = t.get("draft_n")
    row = {"variant": name, "tag": TAG, "mtp_window": window, "pass": pas, "round": qi,
           "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
           "prompt_per_second": t.get("prompt_per_second"), "prompt_ms": t.get("prompt_ms"),
           "predicted_n": t.get("predicted_n"),
           "predicted_per_second": t.get("predicted_per_second"),
           "draft_n": dn, "draft_n_accepted": t.get("draft_n_accepted"),
           "accept": (t.get("draft_n_accepted") / dn) if dn else None,
           "wall_s": round(wall, 1), "note": note,
           "t": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(EVID / f"{TAG}.jsonl", "a") as f:
        f.write(json.dumps(row) + "\n")
    return row


def run_arm(name, window, doc, passes=PASSES):
    path, args = make_variant(name, window)
    log(f"arm {name} (--mtp-window {window}): starting serve ...")
    outf = open(MTP / f"serve-{name}.out", "ab")
    proc = subprocess.Popen([CLI, "serve", "--profile", str(path)],
                            stdout=outf, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        if not wait_ready(proc):
            log(f"arm {name}: NOT READY - skipped (see serve-{name}.out)")
            return None, []
        rows = []
        j, wall = ask(doc, QUESTIONS[0])
        pre = rec(name, window, -1, 0, j, wall, note="prefill")
        log(f"arm {name}: prefill {pre['prompt_n']} tokens at {pre['prompt_per_second']} tok/s "
            f"({wall:.0f} s wall); decode {pre['predicted_per_second']} tok/s")
        for pas in range(passes):
            for qi, q in enumerate(QUESTIONS):
                try:
                    j, wall = ask(doc, q)
                    r = rec(name, window, pas, qi, j, wall)
                    rows.append(r)
                except Exception as e:
                    log(f"arm {name} pass{pas} q{qi}: ERROR {e}")
            log(f"arm {name}: pass {pas} done, "
                f"last {r['predicted_per_second']} tok/s, accept {r['accept']:.2f}")
        return pre, rows
    finally:
        log(f"arm {name}: stopping")
        stop(proc)


def report(arms):
    """arms: [(name, window, prefill_row, rounds)] compared against a base arm - the
    first one in this run, or the base rows already in the evidence file."""
    ref = next((a for a in arms if a[0].startswith("base-")), None)
    if ref is None:
        rows = [json.loads(l) for l in open(EVID / f"{TAG}.jsonl")]
        pre = next((r for r in rows if r["variant"] == "base-32k" and r.get("note") == "prefill"), None)
        base_rows = [r for r in rows if r["variant"] == "base-32k" and not r.get("note")]
        if pre is None or not base_rows:
            log("no base arm in this run or in the evidence; cannot compare")
            return
        ref = ("base-32k(from evidence)", None, pre, base_rows)
    base_name, _bw, base_pre, base_rows = ref
    if base_pre is None or not base_rows:
        log("no usable base arm; cannot compare")
        return
    base = {f"{r['pass']}-{r['round']}": r for r in base_rows}
    lines = [f"base = {base_name}: median decode "
             f"{st.median([r['predicted_per_second'] for r in base_rows]):.1f} tok/s, "
             f"prefill {base_pre['prompt_per_second']} tok/s at "
             f"{base_pre['prompt_n']} tokens"]
    for name, _w, pre, rows in [a for a in arms if a[0] != base_name]:
        if pre is None or not rows:
            lines.append(f"{name:10s} arm failed (no rounds)")
            continue
        sp = sorted(r["predicted_per_second"] for r in rows if r["predicted_per_second"])
        if len(sp) < 2:
            lines.append(f"{name:10s} too few rounds")
            continue
        ac = st.mean(r["accept"] for r in rows if r["accept"] is not None)
        bac = st.mean(r["accept"] for r in base_rows if r["accept"] is not None)
        bsp = sorted(r["predicted_per_second"] for r in base_rows if r["predicted_per_second"])
        line = (f"{name:10s} n={len(sp):3d} median={st.median(sp):6.1f} tok/s accept={ac:.2f} "
                f"| base median {st.median(bsp):6.1f} accept={bac:.2f} "
                f"| prefill {pre['prompt_per_second']} vs {base_pre['prompt_per_second']} tok/s")
        pairs = [(r["predicted_per_second"], base[f"{r['pass']}-{r['round']}"]["predicted_per_second"])
                 for r in rows if f"{r['pass']}-{r['round']}" in base and r["predicted_per_second"]]
        if len(pairs) >= 3:
            d = sorted(a / b - 1 for a, b in pairs)
            m = st.mean(d)
            se = st.stdev(d) / len(d) ** 0.5
            verdict = "BEATS" if m - 2 * se > 0 else ("loses" if m + 2 * se < 0 else "tie")
            line += f"  paired {m * 100:+5.2f}% vs base (se {se * 100:.2f}, n={len(d)}) {verdict}"
        lines.append(line)
    txt = "\n".join(lines)
    log("summary\n" + txt)
    (MTP / f"summary-{TAG}.txt").write_text(txt + "\n")


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    doc = json.load(open(MTP / "doc.json"))[DOC_KEY]
    arms = [("base-32k", None), ("w16384", 16384), ("w8192", 8192),
            ("w4096", 4096), ("w0-every-cell", 0), ("base2-32k", None)]
    if len(sys.argv) > 1:
        want = sys.argv[1].split(",")
        arms = [a for a in arms if a[0] in want or str(a[1]) in want or
                (a[1] is None and "base" in want)]
        if not arms:
            log(f"no arm matches {sys.argv[1]}")
            return
    out = []
    for name, w in arms:
        pre, rows = run_arm(name, w, doc, passes=1 if name.startswith("base2") else PASSES)
        out.append((name, w, pre, rows))
    report(out)
    log("stage 4 done")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Stage 5: an arbitrary engine-flag A/B, one fresh serve per arm.

Same protocol as stage 4 (paired greedy rounds at 154,545 tokens + that arm's own
cold prefill rate), but the lever is any flag given as a list of extra args, so it
works for --mtp-hnorm, --suffix-draft, --lookup-chain-min, STRATA_IQ_MT_MIN (env)
and friends without a new file each time.

Arms run in the order given; the FIRST is the reference. Give it a short base
repeat at the end to see how far the machine drifted between processes.
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
DOC_KEY = os.environ.get("MTP_DOC_KEY", "doc_160000")   # MTP_DOC_KEY=clean_155k for the text fixture
PASSES = 3
MAX_TOKENS = 320

QUESTIONS = [
    "Write a Python function that merges two sorted lists into one sorted list, without using sorted().",
    "Explain in five bullet points how a git rebase differs from a merge, and give the command for each.",
    "Write a SQL query that returns the second-highest salary in each department.",
    "Give pseudocode for computing realized profit-and-loss per symbol from a list of stock trades.",
    "Explain the CAP theorem in plain words and what it means for a small web app.",
    "Write a bash one-liner that prints the five largest files under a directory, and explain each flag.",
]

PROG = open(MTP / "progress.log", "a", buffering=1)
CACHES = {}   # arm name -> (cache view after its prefill, cache view at its end)


def log(m):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] stage5x {m}\n")
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def make_variant(tag, name, extra_args, extra_env):
    p = json.load(open(PROFILE))
    p["port"] = PORT
    p["log"] = str(MTP / f"serve-{tag}-{name}.log")
    args = list(p["args"])
    for flag, val in extra_args:
        if flag in args:
            args[args.index(flag) + 1] = str(val)
        else:
            args += [flag, str(val)]
    p["args"] = args
    p["env"] = {**(p.get("env") or {}), **(extra_env or {})}
    path = MTP / f"variant-{tag}-{name}.json"
    json.dump(p, open(path, "w"), indent=1)
    return path


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
    except ProcessLookupError:
        pass
    for _ in range(20):
        if proc.poll() is not None:
            break
        time.sleep(1)
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    time.sleep(6)


def ask(doc, q, temperature=0.0):
    body = {"model": MODEL,
            "messages": [{"role": "system", "content": doc}, {"role": "user", "content": q}],
            "max_tokens": MAX_TOKENS, "temperature": temperature}
    r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                               data=json.dumps(body).encode())
    r.add_header("Authorization", f"Bearer {KEY}")
    r.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(r, timeout=1800) as resp:
        j = json.load(resp)
    return j, time.time() - t0


def cache_view():
    """The engine's own conversation-cache counters (serve /metrics), plus the RAM it sees.

    Added for stage 9: whether a big park was admitted at all is a yes/no this harness
    would otherwise have to read out of the arm's log by hand. cache_n on every round
    already says how many prompt tokens came back, so this is about the other side -
    parked bytes, restores, evictions. A server without the route returns an error string.
    """
    try:
        r = urllib.request.Request(f"http://127.0.0.1:{PORT}/metrics")
        r.add_header("Authorization", f"Bearer {KEY}")
        with urllib.request.urlopen(r, timeout=8) as resp:
            j = json.load(resp)
        cc, e = j.get("conversation_cache") or {}, j.get("engine") or {}
        return {"parked": cc.get("parked"), "cache_MiB": round((cc.get("bytes") or 0) / 1048576),
                "parks": cc.get("parks"), "restores": cc.get("restores"),
                "evictions": cc.get("evictions"), "requests_reused": cc.get("requests_reused"),
                "reused_tokens": cc.get("reused_tokens"), "budget_mib": cc.get("budget_mib"),
                "vram_free_mib": e.get("vram_free_mib")}
    except Exception as ex:
        return {"error": str(ex)[:100]}


def rec(tag, name, desc, pas, qi, j, wall, note=None):
    t = j.get("timings", {})
    dn = t.get("draft_n")
    row = {"variant": name, "tag": tag, "arm": desc, "pass": pas, "round": qi,
           "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
           "prompt_per_second": t.get("prompt_per_second"), "prompt_ms": t.get("prompt_ms"),
           "predicted_n": t.get("predicted_n"),
           "predicted_per_second": t.get("predicted_per_second"),
           "draft_n": dn, "draft_n_accepted": t.get("draft_n_accepted"),
           "accept": (t.get("draft_n_accepted") / dn) if dn else None,
           "wall_s": round(wall, 1), "note": note,
           "t": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(EVID / f"{tag}.jsonl", "a") as f:
        f.write(json.dumps(row) + "\n")
    return row


def run_arm(tag, name, desc, extra_args, extra_env, doc, passes=PASSES):
    path = make_variant(tag, name, extra_args, extra_env)
    log(f"arm {name} ({desc}): starting serve from {path.name} ...")
    outf = open(MTP / f"serve-{tag}-{name}.out", "ab")
    proc = subprocess.Popen([CLI, "serve", "--profile", str(path)],
                            stdout=outf, stderr=subprocess.STDOUT, start_new_session=True)
    pre, rows = None, []
    try:
        if not wait_ready(proc):
            log(f"arm {name}: NOT READY - see serve-{tag}-{name}.out")
            return None, []
        j, wall = ask(doc, QUESTIONS[0])
        pre = rec(tag, name, desc, -1, 0, j, wall, note="prefill")
        log(f"arm {name}: prefill {pre['prompt_n']} tok at {pre['prompt_per_second']} tok/s "
            f"({wall:.0f} s wall), decode {pre['predicted_per_second']}")
        c0 = cache_view()
        for pas in range(passes):
            for qi, q in enumerate(QUESTIONS):
                try:
                    j, wall = ask(doc, q)
                    rows.append(rec(tag, name, desc, pas, qi, j, wall))
                except Exception as e:
                    log(f"arm {name} pass{pas} q{qi}: ERROR {e}")
            last = rows[-1] if rows else None
            if last:
                log(f"arm {name}: pass {pas} done, last {last['predicted_per_second']} tok/s, "
                    f"accept {last['accept']:.2f}")
        CACHES[name] = (c0, cache_view())
        log(f"arm {name}: cache after prefill {c0}")
        log(f"arm {name}: cache at the end {CACHES[name][1]}")
        return pre, rows
    finally:
        log(f"arm {name}: stopping")
        stop(proc)


def report(tag, arms):
    base_name, _d, base_pre, base_rows = arms[0]
    if base_pre is None or not base_rows:
        log("no base arm; cannot compare")
        return
    bsp = sorted(r["predicted_per_second"] for r in base_rows if r["predicted_per_second"])
    base = {f"{r['pass']}-{r['round']}": r for r in base_rows}
    lines = [f"base = {base_name}: median {st.median(bsp):.1f} tok/s "
             f"(n={len(bsp)}), prefill {base_pre['prompt_per_second']} tok/s"]
    for name, desc, pre, rows in arms[1:]:
        if pre is None or not rows:
            lines.append(f"{name:14s} arm failed")
            continue
        sp = sorted(r["predicted_per_second"] for r in rows if r["predicted_per_second"])
        ac = st.mean(r["accept"] for r in rows if r["accept"] is not None)
        bac = st.mean(r["accept"] for r in base_rows if r["accept"] is not None)
        line = (f"{name:14s} n={len(sp):3d} median={st.median(sp):6.1f} tok/s accept={ac:.2f} "
                f"| base {st.median(bsp):6.1f} accept={bac:.2f} "
                f"| prefill {pre['prompt_per_second']} vs {base_pre['prompt_per_second']}")
        # the cache's payoff is not tokens/s, it is the prompt read that never happens:
        # cache_n per round and the arm's total wall clock, against the base arm's same cells
        reused = st.mean(r["cache_n"] or 0 for r in rows)
        breused = st.mean(base[k]["cache_n"] or 0 for k in base)
        wsum = sum(r["wall_s"] or 0 for r in rows)
        bwsum = sum(base[f"{r['pass']}-{r['round']}"]["wall_s"] or 0 for r in rows
                    if f"{r['pass']}-{r['round']}" in base)
        line += (f" | reused {reused:6.0f} vs {breused:6.0f} tok/round, "
                 f"wall {wsum:5.0f} vs {bwsum:5.0f} s")
        if name in CACHES:
            a, b = CACHES[name]
            ba, bb = CACHES.get(base_name, (None, None))
            line += f"\n{'':14s} cache end: {b}"
            if bb:
                line += f"\n{'':14s} base  end: {bb}"
        pairs = [(r["predicted_per_second"], base[f"{r['pass']}-{r['round']}"]["predicted_per_second"])
                 for r in rows if f"{r['pass']}-{r['round']}" in base and r["predicted_per_second"]]
        if len(pairs) >= 3:
            d = sorted(a / b - 1 for a, b in pairs)
            m = st.mean(d)
            se = st.stdev(d) / len(d) ** 0.5
            verdict = "BEATS" if m - 2 * se > 0 else ("loses" if m + 2 * se < 0 else "tie")
            line += f" | paired {m * 100:+5.2f}% (se {se * 100:.2f}, n={len(d)}) {verdict}"
        lines.append(line)
    txt = "\n".join(lines)
    log(f"{tag} summary\n" + txt)
    (MTP / f"summary-{tag}.txt").write_text(txt + "\n")


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    if len(sys.argv) < 3:
        print(__doc__)
        print("usage: runner7.py TAG 'name:FLAG=VAL[,ENV:KEY=VAL]' 'name2:...' ...")
        print("  the first arm is the reference; name a one-pass drift check 'base-repeat'")
        sys.exit(2)
    tag = sys.argv[1]
    specs = sys.argv[2:]
    doc = json.load(open(MTP / "doc.json"))[DOC_KEY]
    arms = []
    for i, s in enumerate(specs):
        name, _, rest = s.partition(":")
        extra = []
        env = {}
        for pair in filter(None, rest.split(",")) if rest else []:
            if pair.startswith("ENV:"):
                k, v = pair[4:].split("=", 1)
                env[k] = v
            else:
                k, v = pair.split("=", 1)
                extra.append((k, v))
        passes = 1 if i and name.startswith("base") and "repeat" in name else PASSES
        pre, rows = run_arm(tag, name, rest or "(profile as-is)", extra, env, doc, passes=passes)
        arms.append((name, rest, pre, rows))
    report(tag, arms)
    log(f"{tag} done")


if __name__ == "__main__":
    main()

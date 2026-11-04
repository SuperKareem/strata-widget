#!/usr/bin/env python3
# MTP tuning sweep for the coder IQ1_M profile on this machine (engine 0.1.52, hip, gfx1200).
# Method: every arm is a fresh `strata serve` process on port 8091 with one changed MTP
# argument, then six identical fixed questions over a fixed long document, greedy,
# 320 tokens. The base arm is repeated during the sweep to bound run-to-run drift.
# Evidence goes to mtp-tune/evidence/*.jsonl and mtp-tune/summary.txt.
import json, os, subprocess, sys, time, urllib.request, signal, glob
from pathlib import Path

HERE    = Path("/home/kareem/Documents/strata-start-stop-server")
MTP     = HERE / "mtp-tune"
EVID    = MTP / "evidence"
PROFILE = HERE / "coder-dflash2-15.json"
CLI     = "/home/kareem/.local/bin/strata"
PORT    = 8091
KEY     = "strata"
ROOT    = "/home/kareem/Documents/Strata-v02x"
ENGINE  = Path.home() / ".local/share/strata/components/engine/0.1.52-linux-x86_64-hip-rx9070/strata"

(EVID).mkdir(parents=True, exist_ok=True)
PROG = open(MTP / "progress.log", "a", buffering=1)

def log(msg):
    PROG.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")

QUESTIONS = [
    "Write a Python function that merges two sorted lists into one sorted list, without using sorted().",
    "Explain in five bullet points how a git rebase differs from a merge, and give the command for each.",
    "Write a SQL query that returns the second-highest salary in each department.",
    "Give pseudocode for computing realized profit-and-loss per symbol from a list of stock trades.",
    "Explain the CAP theorem in plain words and what it means for a small web app.",
    "Write a bash one-liner that prints the five largest files under a directory, and explain each flag.",
]

def build_doc(target_tokens):
    # One deterministic pass over the repository's own text, no repetition
    # (repeated text could inflate prompt-lookup acceptance).
    headers = [str(ENGINE)] + \
        sorted(glob.glob(os.path.join(ROOT, "docs", "*.md"))) + \
        sorted(glob.glob(os.path.join(ROOT, "src", "*.py"))) + \
        sorted(glob.glob(os.path.join(ROOT, "src", "*.cpp"))) + \
        sorted(glob.glob(os.path.join(ROOT, "include", "*.h"))) + \
        sorted(glob.glob(os.path.join(ROOT, "serve", "*.py")))
    parts, total = [], 0
    for f in headers:
        try:
            t = open(f, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        parts.append(f"## {os.path.relpath(f, ROOT)}\n\n{t}")
        total += len(t)
        if total >= target_tokens * 4:
            break
    doc = "\n\n".join(parts)[: target_tokens * 4]
    return doc

DOC_FILE = MTP / "doc.json"
def doc_for(stage):
    # stage 1: ~32k tokens; stage 2: ~160k tokens (near the profile's 179k cap)
    tok = 32000 if stage == 1 else 160000
    key = f"doc_{tok}"
    if DOC_FILE.exists():
        d = json.load(open(DOC_FILE))
        if key in d:
            return d[key]
    d = json.load(open(DOC_FILE)) if DOC_FILE.exists() else {}
    log(f"building {key} (~{tok} tokens) from {len(glob.glob(os.path.join(ROOT,'docs','*.md')))}+ files ...")
    d[key] = build_doc(tok)
    json.dump(d, open(DOC_FILE, "w"))
    return d[key]

def set_arg(args, flag, val):
    i = args.index(flag)
    args[i + 1] = str(val)
    return args

def make_variant(name, transform):
    p = json.load(open(PROFILE))
    p["port"] = PORT
    p["log"] = str(MTP / f"serve-{name}.log")
    p["args"] = transform(list(p["args"]))
    path = MTP / f"variant-{name}.json"
    json.dump(p, open(path, "w"), indent=1)
    return path

ID = lambda a: a

VARIANTS_STAGE1 = [
    ("base-1",    ID),                                            # spec 4, min-p 0.5 (current)
    ("spec2",     lambda a: set_arg(a, "--spec", 2)),
    ("spec3",     lambda a: set_arg(a, "--spec", 3)),
    ("spec5",     lambda a: set_arg(a, "--spec", 5)),
    ("base-2",    ID),
    ("minp025",   lambda a: set_arg(a, "--spec-min-p", 0.25)),
    ("minp075",   lambda a: set_arg(a, "--spec-min-p", 0.75)),
    ("lookup4",   lambda a: a + ["--lookup-chain", "4"]),
    ("batchmtp",  lambda a: a + ["--batch-mtp"]),
    ("spec6",     lambda a: set_arg(a, "--spec", 6)),
    ("base-3",    ID),
]

def wait_ready(deadline_s=420):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        try:
            r = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/models")
            r.add_header("Authorization", f"Bearer {KEY}")
            with urllib.request.urlopen(r, timeout=4) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    return False

def ask(messages, max_tokens=320, timeout=600):
    body = json.dumps({"model": "qwen3.8-flash-next-coder-iq1_m",
                       "messages": messages, "max_tokens": max_tokens,
                       "temperature": 0}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                 data=body, method="POST")
    req.add_header("Authorization", f"Bearer {KEY}")
    req.add_header("Content-Type", "application/json")
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        j = json.load(resp)
    return j, time.time() - t0

def stop_arm(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(15):
        if proc.poll() is not None:
            break
        time.sleep(1)
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=30)
    time.sleep(5)

def run_arm(name, path, doc, tag):
    log(f"arm {name}: starting serve ...")
    logf = open(MTP / f"serve-{tag}-{name}.out", "ab")
    proc = subprocess.Popen([CLI, "serve", "--profile", str(path)],
                            stdout=logf, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        if not wait_ready():
            log(f"arm {name}: NOT READY, skipping")
            return
        log(f"arm {name}: ready, doc prefill inside round 1")
        for qi, q in enumerate(QUESTIONS):
            messages = [{"role": "system", "content": doc},
                        {"role": "user", "content": q}]
            try:
                j, wall = ask(messages)
            except Exception as e:
                log(f"arm {name} round {qi}: error {e}")
                continue
            t = j.get("timings", {})
            ch = (j.get("choices") or [{}])[0].get("message", {})
            rec = {"variant": name, "tag": tag, "round": qi,
                   "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
                   "prompt_per_second": t.get("prompt_per_second"),
                   "predicted_n": t.get("predicted_n"),
                   "predicted_per_second": t.get("predicted_per_second"),
                   "draft_n": t.get("draft_n"), "draft_n_accepted": t.get("draft_n_accepted"),
                   "accept": (t.get("draft_n_accepted") / t["draft_n"])
                              if t.get("draft_n") else None,
                   "finish": ch.get("finish_reason"), "wall_s": round(wall, 1),
                   "t": time.strftime("%Y-%m-%d %H:%M:%S")}
            with open(EVID / f"{tag}.jsonl", "a") as ef:
                ef.write(json.dumps(rec) + "\n")
            log(f"arm {name} round {qi}: {rec['predicted_per_second']} tok/s, "
                f"accept {rec['accept']}, predicted_n {rec['predicted_n']}")
    finally:
        log(f"arm {name}: stopping")
        stop_arm(proc)

def summarize(tag):
    rows = [json.loads(l) for l in open(EVID / f"{tag}.jsonl")]
    arms = {}
    for r in rows:
        arms.setdefault(r["variant"], []).append(r)
    lines = [f"== {tag} =="]
    for name, rs in arms.items():
        sp = sorted(r["predicted_per_second"] for r in rs if r["predicted_per_second"])
        ac = [r["accept"] for r in rs if r["accept"]]
        if len(sp) >= 2:
            med = sp[len(sp) // 2]
            acc = sum(ac) / len(ac) if ac else 0
            lines.append(f"{name:10s} n={len(sp)} median={med:8.1f} tok/s "
                         f"min={sp[0]:7.1f} max={sp[-1]:7.1f} accept={acc:.2f}")
    txt = "\n".join(lines)
    log("summary\n" + txt)
    open(MTP / f"summary-{tag}.txt", "w").write(txt + "\n")
    return {n: sorted(r["predicted_per_second"] for r in rs if r["predicted_per_second"])
            for n, rs in arms.items()}

def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    log("=== stage 1 (32k context) ===")
    doc1 = doc_for(1)
    variants = []
    for name, tr in VARIANTS_STAGE1:
        if only and name.split("-")[0] not in only.split(","):
            continue
        variants.append((name, tr, make_variant(name, tr)))
    for name, _tr, path in variants:
        tag = "stage1"
        # allow re-running the same arm later without overwriting evidence
        ef = EVID / f"{tag}.jsonl"
        run_arm(name, path, doc1, tag if not ef.exists() else tag)
    s1 = summarize("stage1")

    # stage 2: the winner (excluding the base repeats) against base at ~160k context
    if only:
        log("single-variant run; skipping stage 2")
        return
    scores = {n: (v[len(v)//2] if len(v) >= 3 else (v[0] if v else 0))
              for n, v in s1.items() if n and not n.startswith("base")}
    base_scores = [sum(v)/len(v) for n, v in s1.items() if n.startswith("base") and v]
    base_med = sorted(base_scores)[len(base_scores)//2] if base_scores else 0
    winner = max(scores, key=scores.get) if scores else None
    log(f"stage 1 winner: {winner} ({scores.get(winner)} tok/s vs base {base_med:.1f})")
    if winner and scores.get(winner, 0) > base_med * 1.03:
        log("=== stage 2 (160k context) ===")
        doc2 = doc_for(2)
        run_arm("base", make_variant("base", ID), doc2, "stage2")
        run_arm(winner, make_variant(f"stage2-{winner}",
                                     dict(VARIANTS_STAGE1)[winner] if winner in dict(VARIANTS_STAGE1) else (lambda a: a + ["--lookup-chain", "4"])),
                doc2, "stage2")
        summarize("stage2")
    else:
        log("no variant beat base by >3%; keeping the current configuration")

if __name__ == "__main__":
    main()

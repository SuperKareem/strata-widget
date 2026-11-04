#!/usr/bin/env python3
# Combo arm: min-p 0.25 + --lookup-chain 4, measured against base at stage-1 size (~117k).
import harness

harness.log("=== combo check (minp025 + lookup4, ~117k) ===")
doc = json_load = harness.doc_for(1)
p_base = harness.make_variant("base", harness.ID)
p_combo = harness.make_variant("combo",
    lambda a: harness.set_arg(harness.set_arg(a, "--spec-min-p", 0.25), "--spec-min-p", 0.25) if False
    else (lambda a2: a2 + ["--lookup-chain", "4"])(harness.set_arg(list(a), "--spec-min-p", 0.25)))
for name, path in (("base-4", p_base), ("combo", p_combo)):
    harness.run_arm(name, path, doc, "stage1")
harness.summarize("stage1")

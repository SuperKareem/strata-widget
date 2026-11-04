#!/usr/bin/env python3
# Re-run stage 2 only: winner (min-p 0.25) against base at ~160k real tokens,
# doc sized with the measured 1.09 chars/token ratio from stage 1.
import json
import harness

harness.log("=== stage 2 rerun (160k tokens) ===")
MINP = 1.091  # chars per token measured on the stage-1 doc
RAW = harness.build_doc(160000)  # sized at tok*4 chars; plenty of raw material
doc = RAW[: int(160000 * MINP)]
json.dump({"doc_32000": json.load(open(harness.DOC_FILE))["doc_32000"],
           "doc_160000": doc}, open(harness.DOC_FILE, "w"))

p_base = harness.make_variant("base", harness.ID)
p_win  = harness.make_variant("stage2-minp025",
                              lambda a: harness.set_arg(a, "--spec-min-p", 0.25))
for name, path in (("base", p_base), ("minp025", p_win)):
    harness.run_arm(name, path, doc, "stage2")
harness.summarize("stage2")

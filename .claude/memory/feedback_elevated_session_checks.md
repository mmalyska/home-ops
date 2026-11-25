---
name: feedback-elevated-session-checks
description: Node files, exec and LLM requests need the owner's elevated Claude session; hand them a ready read-only prompt and record the report
metadata:
  type: feedback
---

The dev workspace cannot read node sysfs/debugfs (`talosctl read` denied), `exec` into pods, port-forward (`kubectl auth can-i create pods --subresource=portforward` is `no`), reach `llama-server` (the `llm` NetworkPolicies drop it) or read secrets (so no LiteLLM key). The owner runs such checks from a separate Claude session with more access and pastes the report back.

**Why:** On 2026-11-25 (nv1 iGPU metrics, #6466/#6467) the r39 sysfs/debugfs formats, the hwmon pairing and the load-under-request check all came from that route; guessing from jetson-stats source would have been wrong (EMC activity is not a percent, the GPU state files hold words). A local Docker Hub fetch to test busybox was also denied by the permission check.

**How to apply:** When a design or a live check depends on node files or a request through `llama-server`, write a paste-ready, read-only prompt (exact commands, what to report, "change nothing"), put it in the spec, and save the report as evidence before writing code against it. Check the reported numbers yourself in Prometheus where possible: an owner-side query (`[5m:]` subquery) once missed a 13 s peak. Related: [[feedback_cluster_access_rules]].

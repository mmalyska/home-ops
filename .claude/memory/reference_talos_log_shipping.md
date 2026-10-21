---
name: reference_talos_log_shipping
description: Talos service and kernel logs go to Loki over UDP (Alloy loki.source.syslog raw), why not TCP, Alloy gotchas hit while building it
metadata:
  type: reference
---

All four nodes send Talos service logs and the kernel log to the Alloy receiver `monitoring/alloy-talos-logs` (LB IP 192.168.48.32, UDP 5180 service, 5181-5184 kernel mc1..nv1). Design and query labels: `provision/talos/README.md`, section "Log shipping to Loki". Loki labels: `source=talos-service|talos-kernel`, `node`, `service`, `level`.

- **UDP, not TCP.** A TCP connection stays pinned to the receiver pod that accepted it (Cilium `bpf-lb-sock` is off, so it is the datapath conntrack). After the pod was replaced, nv1 hung in CLOSE_WAIT about 6 minutes and lost the queued ~3 minutes on reconnect; mc1 and mc2 stayed silent over 1.5 minutes. With UDP, nv1 lost about 10 seconds when the pod was deleted. A tuppr rollout that moves the pod would stall TCP senders on every node.
- **Alloy has no `otelcol.receiver.udplog`.** UDP is `loki.source.syslog` with `protocol = "udp"` and `syslog_format = "raw"` (experimental, needs `stabilityLevel: experimental`). `alloy fmt` only checks syntax; use `kubectl exec -i deploy/alloy-talos-logs -c alloy -- sh -c 'cat > /tmp/t.alloy && alloy validate --stability.level=experimental /tmp/t.alloy'` to check component names too.
- **Alloy object fields need commas** (`expressions = { a = "x", b = "y" }`), block attributes do not. A config that fails to parse on reload leaves the old pipeline running with only an info line, so check the pod logs for `config reloaded` and the live output, not just ArgoCD.
- **A Service or container port list cannot repeat a port number** (TCP 5170 and UDP 5170): the ArgoCD client-side dry run fails with "order in patch list doesn't match $setElementOrder". Use distinct numbers.
- `otelcol.exporter.loki` wraps each line as `{"body": "<line>"}`; the old TCP pipeline needed an unwrap stage. The raw syslog path has no wrapper.
- `KmsgLogConfig` has no `extraTags` before Talos v1.15, hence one port per node. The service-log destination (`machine.logging`) does take `extraTags`, which carries the node name. Talos also puts kernel lines into the service stream (`service=kernel`).
- Kernel lines are rare; an empty kernel stream for a node does not mean the port is broken (check `talosctl netstat` for the UDP flow).

**Why:** the nv1 boot-entry investigation had no logs from the failed boots, and the tuppr rollout moves pods.
**How to apply:** query `{source=~"talos-.*", node="nv1"}` after a reboot or upgrade; capture the next nv1 upgrade this way (see the boot-entry item in `.plans/TODO.md`). Related: [[reference_tuppr_upgrades]].

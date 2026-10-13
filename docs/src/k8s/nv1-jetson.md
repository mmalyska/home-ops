# nv1 — Jetson Orin NX (GPU node)

nv1 (`192.168.48.5`) is a Jetson Orin NX 16 GB running Talos with a custom nvgpu stack (JetPack 7 / r39.2 since 2026-10-08, see below). CPU and GPU share the 16 GB (about 12.8 GiB usable for models).

## JetPack 7 (r39) image

nv1 runs the JetPack 7 build of the custom installer (`ghcr.io/mmalyska/custom-installer:v1.14.2-6.18.54-nvgpu39.2.1-jp7`, Jetson Linux r39.2, CUDA 13 driver, modules from NVIDIA's r39.2.1 sources). The board firmware (QSPI) was flashed to r39.2.0 on 2026-10-08 with Seeed's `recomputer-orin-j401` package, QSPI only (`l4t_initrd_flash.sh --qspi-only`; without `--qspi-only` the tool also rebuilds and flashes the NVMe). The module list is `provision/talos/patches/node/nv1/28` to `38`: `ivc_ext`, `tegra_hv` and `nvhwpm` are new, and `host1x_nvhost` loads before `host1x_fence`.

- Libraries: the `restore-libs` init container of `nvidia-cdi-setup` downloads `libcuda` and what it loads from NVIDIA's apt repository (component `som`, dist `r39.2`: `nvidia-l4t-core`, `-cuda-nvgpu` and `-cuda`, about 26 MB, plus `libnvidia-ptxjitcompiler` out of the `cuda-compat-13-2` package of the `common` component, about 88 MB to download and 32 MB kept; versions and SHA-256 pinned in the manifest) into `/var/lib/nvidia-tegra-libs/tegra` once per version, and the CDI spec mounts that directory into GPU containers, together with the `host1x-*`/`nvhost-*` device nodes. The set includes `libnvcucompat.so`, which `libcuda` dlopen()s at `cuInit` (without it `cuInit` returns 999). The node image carries no userspace libraries, only the GA10B firmware (extension `nvidia-firmware-ext`). nv1 moved to this image (the `nvidia-tegra-userspace` extension gone from the node, libraries from the init container) on 2026-10-10: the init container filled 14 files on the old image first, then the node was upgraded by digest and booted with `nvidia.com/gpu` 1 and `llama-server` at 25.8 tok/s generation. The node needs access to `repo.download.nvidia.com` the first time (and after a version bump of the manifest); once the marker file `.l4t-<version>` exists it works offline.
- Firmware: `nvidia-cdi-setup` copies the firmware from the node image to `/var/fw-fresh/ga10b` and sets `firmware_class.path` there, and it re-syncs on every start. `/var` survives upgrades: a one-time copy left JetPack 6 firmware in front of the JetPack 7 files and the r39 `nvgpu` reset the node on GPU power-on (PMU never booted, then a NULL dereference in the `nvgpu` interrupt thread, hard reset with no pstore record).
- Measured 2026-10-08: `llama-server` (LFM2.5-8B-A1B Q6_K_XL) 25.7 tok/s generation, 66 tok/s prompt processing, GPU load about 95% during a request; the CPU fallback is about 6 tok/s.
- Comparison with the upstream author's JetPack 6 numbers (2026-10-10; the upstream README measures Ollama 0.20.5 decode with the prompt `Hello!` on an Orin NX 16 GB at MAXN). Same Q4_K_M files from the Ollama registry, `llama-bench` of our `llama-cpp-jetson` v0.6.0 (native sm_87, CUDA 13.2 driver), `-ngl 99`, pp8 and tg128, 5 runs, MAXN, llama-server scaled to 0 for the test:

  | Model               | JetPack 7.2 here (llama.cpp) | Talos JetPack 6 (upstream, Ollama) | JetPack 6.2 native (upstream, Ollama) |
  | ------------------- | ---------------------------: | ---------------------------------: | ------------------------------------: |
  | qwen2.5:0.5b Q4_K_M |             89.7 ± 2.7 tok/s |                         64.6 tok/s |                            66.5 tok/s |
  | qwen3:4b Q4_K_M     |             16.7 ± 0.0 tok/s |                         16.4 tok/s |                            19.5 tok/s |

  The 4B model is memory-bandwidth bound and lands at the same speed on both JetPack lines. The 0.5B gap is mostly engine and version (llama.cpp directly against Ollama's HTTP path), not JetPack 7; this is not a like-for-like JetPack comparison. Prefill (pp8) was 447 and 133 tok/s.

- **Stock Ollama runs once `libnvidia-ptxjitcompiler` is in the library set** (v0.40.2, `cuda_v13`, 2026-10-10). Without it the first kernel aborts with `CUDA error: PTX JIT compiler library not found`: Ollama's CUDA 13 build has no native sm_87 code and falls back to PTX JIT, and the library is not in the `som` debs (`nvidia-l4t-core`, `-cuda`, `-cuda-nvgpu`, `-cuda-utils`). The restore-libs step takes it from `cuda-compat-13-2` (`libnvidia-ptxjitcompiler.so.595.71.05`, the newest 595.x in the `common` component while the node driver is 595.78; the version gap caused no problem). The same applies to any image without native sm_87 SASS (stock PyTorch and vLLM wheels carry sm_80 code and PTX). Result with the library, Ollama v0.40.2, all layers on the GPU, MAXN, `Hello!` prompt (median of 5) and a 256-token generation:

  | Model               | `Hello!` decode | 256-token decode | Talos JP6 (upstream, Ollama 0.20.5) | JP 6.2 native (upstream) |
  | ------------------- | --------------: | ---------------: | ----------------------------------: | -----------------------: |
  | qwen2.5:0.5b Q4_K_M |      77.0 tok/s |       89.3 tok/s |                          64.6 tok/s |               66.5 tok/s |
  | qwen3:4b Q4_K_M     |      17.6 tok/s |       17.6 tok/s |                          16.4 tok/s |               19.5 tok/s |

  The `Hello!` prompt generates only about 10 tokens on the 0.5B model, so warm-up overhead lowers its rate; the 256-token column is the steady decode rate. Like for like (Ollama against Ollama), JetPack 7.2 is about 19% faster than Talos JetPack 6 on the 0.5B and about 7% on the 4B, and still about 10% below JetPack 6.2 native on the 4B. Ollama and `llama-bench` agree within a few percent, so Ollama adds little overhead here. The pod test needs the single GPU: `llama-server` has to be paused through git (`server.replicaCount: 0`), as the app self-heals a scale-down.

- Soak 2026-10-09 (2 hours, 2 workers matching the 2 slots, random prompts of 40 to 4,500 words, 100 to 300 generated tokens): 1,398 requests, 0 errors, 265k generated tokens, generation median 21.8 to 22.0 tok/s in every 30-minute window (no slowdown), slowest request 25 s, 24 prompts above 4,000 tokens. The GPU sat at 92 to 100% load. Memory filled while the prompt cache and context checkpoints warmed up and then levelled off: node `MemAvailable` fell from 3.9 GB to about 1.7 GB within 40 minutes and stayed there, the pod at about 11.4 GiB (below its 13Gi limit). No restarts, no OOM kills, no `nvgpu` errors or Oops in the kernel log, node uptime unbroken. A first attempt was cut short after 17 minutes by a site power outage; nv1 cold-booted cleanly afterwards.
- One `nvme nvme0: I/O tag ... timeout, completion polled` warning appeared about a day after the soak (a missed completion that the driver recovered). Not seen during the load; watch for repeats.
- `cuInit` returning 999 or a node reset when a GPU pod starts: stream `talosctl dmesg --follow` and `strace -f` over the network (a hard reset loses unsynced files, so do not write the trace to local disk), see the fork's `docs/jetpack7.md`.
- Upgrading the image needs three things beyond `talos:upgrade`: (1) a **new tag or the digest**: the node reuses a cached image for a tag it already pulled, so a rebuilt installer under the same tag is not fetched (`talosctl upgrade --image ...@sha256:<digest>`); (2) **free ESP space** first: each UKI is about 565 MB and the ESP is 2.0 GB, so keep at most two (delete the `*.bak` files with a privileged pod that mounts `/dev/nvme0n1p1`; the pod needs a namespace that allows privileged pods, for example `nvidia-system`); (3) the **stale default boot entry**: the Jetson UEFI keeps booting the old UKI (it did again on 2026-10-10), so rename it to `.bak` (see `provision/talos/README.md`, "nv1 boots the wrong UKI after an upgrade") and reboot. `task talos:upgrade` cannot tell the old and new image apart when the Talos version is the same, so check the extensions with `talosctl get extensions`.
- Rollback: the previous image was `ghcr.io/mmalyska/custom-installer:v1.14.2-6.18.54-nvgpu5.13.0-drm-noshim`. The r39 firmware also ran the JetPack 6 modules (seen on 2026-10-08).

## How GPU access works

- `nvidia-cdi-setup` DaemonSet writes a CDI spec (device nodes + JetPack libs).
- `nvidia-device-plugin` advertises **exactly one** `nvidia.com/gpu` (hard-coded, no config). Only one pod at a time can hold it.
- A `kubelet-watchdog` sidecar restarts the plugin whenever the kubelet re-creates `kubelet.sock`. Without it, any kubelet restart leaves the node at `nvidia.com/gpu: 0` because the plugin never re-registers.
- Alert `NodeGpuUnavailable` fires when allocatable GPU is 0 for 5 minutes.

## Rules for GPU images

- The JetPack 7 driver (CUDA 13.2) runs CUDA 13 images. Pin images by digest.
- On the **JetPack 6 image** (rollback) use CUDA **12.6** images only (for llama.cpp: `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04`) and never `latest*` tags: they moved to CUDA 13, which the JetPack 6 driver cannot initialize. llama.cpp then falls back to CPU **silently** (log line `ggml_cuda_init: failed to initialize CUDA: CUDA driver version is insufficient for CUDA runtime version`, ~6 tok/s).

## Symptoms and recovery

| Symptom                                                                                          | Cause                                                | Fix                                                                                                                 |
| ------------------------------------------------------------------------------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| GPU pod `Pending`, `Insufficient nvidia.com/gpu`; node allocatable `nvidia.com/gpu: 0`           | Kubelet restarted; plugin lost registration          | Watchdog fixes it in about a minute; manual: `kubectl rollout restart ds/nvidia-device-plugin -n nvidia-system`     |
| Kubelet restarts every 10–20 min                                                                 | Extra DHCP address on the NIC flapping the static IP | See below                                                                                                           |
| `cilium-envoy`/`node-exporter` CrashLoopBackOff, DNS timeouts, llama-server slows to a few tok/s | Node-wide OOM (see memory budget below)              | Check `talosctl -n 192.168.48.5 dmesg \| grep -i oom` and `read /proc/meminfo`; keep llama-server within its budget |

## Talos: platform DHCP left in META (fixed 2026-09-25)

nv1 had a leftover platform network config in the Talos META partition (key `0x0a`) with `operators: [dhcp4 enP8p1s0]`. It leased `192.168.48.210` beside the static `192.168.48.5`; lease churn flapped `.5`, and Talos restarted the kubelet. Machine-config `dhcp: false` does **not** remove a platform-layer operator.

- Check: `talosctl -n 192.168.48.5 get operatorspecs` must be empty and `get addresses` must show only `192.168.48.5/24` on `enP8p1s0`.
- Fix: `talosctl -n 192.168.48.5 meta delete 0x0a` (no reboot needed).
- After a reinstall or reflash, re-check this: the key is not in git.

## Memory budget (llama-server)

nv1 has 15.6 GiB of unified memory. The system (Talos, kubelet, Cilium, DaemonSets) uses about 3.4 GiB, and the llama-server pod sits at **about 11.9 GiB right after warm-up** (weights 10.0 GiB, KV cache 0.76 GiB, compute buffers 0.6 GiB, CUDA context). That leaves roughly 1.3 GiB of node headroom, and the pod can grow to about 13.4 GiB before the node starves.

- Settings that fit (`cluster/apps/ai/llm/server/values.yaml`): memory limit `13Gi`, request `11Gi`, `--cache-ram 256`, `--ctx-checkpoints 2`, `-ub 256`. Measured steady state: 11.8–12.2 GiB, node `MemAvailable` about 1.3 GiB, 15–16 tok/s, no restarts across a sustained multi-prompt test.
- llama-server defaults do **not** fit: the host-RAM prompt cache defaults to 8192 MiB (about 88 MiB per 1k tokens) and each context checkpoint is 100–120 MiB (32 per slot). Left at defaults they starve the node, Talos' OOM controller kills besteffort system pods, and generation decays from about 14 to about 3 tok/s. It is not thermal.
- A pod limit of `12Gi` is too low (OOM-killed at about 12.5 GB); a limit above about 13.4 GiB gives no protection because the node runs out first.
- Gemma 4 thinks by default and reasoning consumes `max_tokens`, so small-budget calls return empty content. The server defaults to thinking off (`--chat-template-kwargs`); a request can opt in with `chat_template_kwargs.enable_thinking=true`.
- Before changing the model, quantization, context, slots or any of the flags above, re-run a sustained test with many different prompts and watch pod memory and node `MemAvailable` (`talosctl -n 192.168.48.5 read /proc/meminfo`).
- Smaller quants of the same model save little (IQ2_XXS is 9.24 GiB vs 9.82 GiB for the running Q2_K_XL); Gemma 4 E4B frees about 5 GiB but scored much lower on agentic tasks.
- **Hermes needs at least 64,000 tokens of context per slot for its main model** (`ctx / parallel >= 64000`, plus `model.context_length` set to the same value). With the running `-c 65536 -np 2` each slot has 32768, so Hermes' main model and compression stay on the cloud. Getting to 64K per slot means either one slot (`-np 1`, Hermes and Honcho then share it and evict each other's cached prompt) or `-c 131072 -np 2` (about +0.5 GiB KV on a node with about 1 GiB spare); either needs a new sustained memory test.

## Qwen3.6-35B-A3B benchmark (2026-10-13)

Plan: `docs/superpowers/plans/2026-10-13-qwen3.6-benchmark.md`. Image `llama-cpp-jetson` v0.6.0 (same digest as production), `llama-server` paused through git for about 25 minutes, throwaway pods on the `llama-server-models` PVC, production flags (`-c 131072 -np 2 -fa on -ctk q8_0 -ctv q4_0 -ub 256`, `--cache-ram 512 --ctx-checkpoints 2` for the Qwen arms).

| Arm                                   | pp512 (tok/s) | tg128 (tok/s) | Result                                                        |
| ------------------------------------- | ------------: | ------------: | ------------------------------------------------------------- |
| Qwen3.6-35B-A3B UD-IQ2_XXS (10.0 GiB) |           183 |          15.9 | loads, 15.1 tok/s single stream in server mode, quality 19/20 |
| Qwen3.6-35B-A3B UD-IQ2_M (10.7 GiB)   |           n/a |           n/a | fails to load: `cudaMalloc` OOM on the 10.4 GiB weight buffer |
| LFM2.5-8B-A1B UD-Q6_K_XL (baseline)   |           632 |          26.6 | production model                                              |

- **Verdict: does not fit.** With IQ2_XXS loaded and idle the pod sat at 10.7-11 GiB and node `MemAvailable` at **0.40-0.47 GB** (gate: 0.8 GB; LFM2.5 leaves 1.7-4 GB). The concurrent 45K-token load test was stopped after a minute instead of risking the node-wide OOM described above; no round completed.
- The corruption rate (hybrid-state bug class, #29002) was **not measured**: the memory result made it moot. It is still unknown whether Qwen3.6's Gated-DeltaNet hybrid shares LFM2.5's bug.
- Quality with thinking off: known answers 4/5 (missed reversing a word letter by letter), JSON 5/5, single tool calls 5/5, small-budget titles 5/5. With `enable_thinking=true` a 32-token title call returns empty content (finish `length`), so thinking stays off server-side as for Gemma 4.
- `llama-bench` and the server both ran on the GPU with no CUDA 13.2 gibberish, so Unsloth's warning does not apply to our build.
- Qwen3.6-35B-A3B at 2-bit is about the ceiling nv1 can load at all (IQ2_M is already out). A 3-bit file or `UD-Q2_K_XL` (11.45 GiB) cannot work. A usable Qwen3.6 or Qwen3.8-27B needs a 24 GB-class GPU.

---
name: nvgpu patch safety audit — run after every change
description: 5-step audit required after every change to nvgpu-kernel-compat.patch
type: feedback
---

Run after EVERY change to `nvgpu-kernel-compat.patch`:

1. Restore clean OE4T source: `rm -rf /tmp/nvgpu-src && tar -xzf /tmp/nvgpu.tar.gz -C /tmp/nvgpu-src --strip-components=1`
2. Verify applies cleanly: `git -C /tmp/nvgpu-src apply --check <patch>`
3. For every stubbed file audit symbols — list exported symbols, grep callers, check Makefile guards
4. Verify platform struct mandatory callbacks: `ga10b_tegra_platform` needs non-NULL `.probe` and `.is_railgated` (called unconditionally)
5. Verify hunk line counts in `@@` headers

**Why:** Stub changes can cause modpost undefined-symbol errors or NULL dereference crashes that only surface after multi-hour ARM CI.

**How to apply:** Never skip this audit even for small patch changes.

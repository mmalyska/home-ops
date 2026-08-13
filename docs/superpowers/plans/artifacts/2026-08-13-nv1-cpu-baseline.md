# nv1 CPU Inference Baseline (2026-08-13)

CPU-only figures, recorded before any GPU enablement work, from a throwaway
`ollama/ollama:0.20.5` pod (`ollama-cpu-baseline`) scheduled on nv1 via
`nodeSelector: kubernetes.io/hostname: nv1`, no GPU resources requested. Prompt
for both models: "Write a haiku about storage." These are CPU-only numbers —
the Jetson Orin NX's 8 A78AE cores, no GPU/CUDA involved.

## qwen2.5:0.5b

| Metric            | Value           |
| ----------------- | --------------- |
| eval rate         | 33.56 tokens/s  |
| prompt eval rate  | 105.61 tokens/s |
| eval count        | 18 tokens       |
| prompt eval count | 36 tokens       |

## qwen3.5:9b

The default run (thinking mode enabled, the model's default) did not
complete within 35+ minutes — `ollama ps` showed the runner pinned at
100% CPU the entire time with no response yet. This is consistent with
`qwen3.5` being a hybrid reasoning model that, left at its default
settings, spends most of its token budget on internal "thinking" tokens
before producing a final answer; at CPU speeds that made even a one-line
haiku prompt impractically slow. The run was killed and repeated with
`--think=false`:

| Metric            | Value         |
| ----------------- | ------------- |
| eval rate         | 3.21 tokens/s |
| prompt eval rate  | 6.00 tokens/s |
| eval count        | 19 tokens     |
| prompt eval count | 19 tokens     |

**Note:** the default (thinking-enabled) case has no usable tok/s figure —
it simply did not finish in a reasonable time on CPU. The `--think=false`
numbers above are the only completed data point for this model, and even
those are roughly an order of magnitude slower than qwen2.5:0.5b's rate, as
expected for a model ~18x larger. Whichever mode Phase 1's GPU comparison
ultimately uses (Task 13 pins `JETSON_JETPACK=6` but does not disable
thinking), the CPU baseline for thinking-enabled generation should be
treated as "impractically slow / effectively unusable," not as a specific
number to beat.

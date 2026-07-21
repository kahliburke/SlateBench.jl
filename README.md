# SlateBench.jl

A streaming-transport **benchmark widget** for [Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl). Drop it in a cell and it renders a live dashboard that stress-tests the `slate_emit` hub→browser path — the measuring stick for the binary-WS numeric-frame work.

```julia
using SlateBench
bench_stream(n = 64, frames = 2000)   # returns a StreamBench → Slate renders the live dashboard
```

Press ▶ Run and it streams `frames` frames of an `n×n` Float32 field over `slate_emit` as fast as it can, then charts **throughput (MB/s), delivered fps, drop rate, and latency drift** (p50/p95/p99) — with a field canvas, a throughput timeline, and latency/inter-arrival histograms.

## What it demonstrates

A complete Slate extension depending only on `SlateExtensionsBase` — a returned `StreamBench` renders as a `slate_render` component, the emitter's `run` action is registered through the `slate_on` context accessor, and the dashboard front-end ships once via `__slate_frontend`. Each frame carries a run id + hi-res send time so the receiver measures **delivered** frames (not just what landed before the call returned) and **latency drift** (does the pipeline keep up, or back up?).

## Baseline (JSON `slate_emit`, before the binary frame)

| frame | delivered | drops | latency p50/p95/p99 |
|---|---|---|---|
| 64² (16 KB) | ~50 MB/s · 3000 fps | 0% | 61 / 75 / 79 ms |
| 128² (64 KB) | ~56 MB/s · 858 fps | 0% | 755 / 1306 / 1384 ms |

The path tops out around **~56 MB/s**; offer more and nothing drops but the queue backs up and latency balloons to ~1 s. The binary WebSocket numeric frame has to beat that.

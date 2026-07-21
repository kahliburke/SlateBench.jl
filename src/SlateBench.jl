"""
    SlateBench

A streaming-transport **benchmark widget** for Kaimon Slate: drop `bench_stream()` in a cell and it renders
a live dashboard that stress-tests the `slate_emit` hub→browser path — pushing an `n×n` Float32 field as
fast as it can and charting **throughput, dropped frames, and latency drift**. It's the measuring stick for
the binary-WS numeric-frame work: run it on today's JSON path, then again after, on the same dashboard.

A complete Slate extension depending only on `SlateExtensionsBase`: a returned `StreamBench` renders via
`slate_render`, the emitter's `run:` action is registered through the `slate_on` context accessor, and the
front-end dashboard ships once via `__slate_frontend`.
"""
module SlateBench

using SlateExtensionsBase

export StreamBench, bench_stream

# ── The emitter under test ────────────────────────────────────────────────────
# Stream `frames` frames of an n×n Float32 plasma field over `slate_emit` — the exact worker→hub→browser
# path we're optimizing. Each frame carries {i: index, t: hi-res send time, d: the flat field}, so the
# receiver can measure drops (index gaps) and latency drift (recv − send).
#
# The plasma field is PRECOMPUTED into a small cycle of variants OUTSIDE the emit loop, so the O(n²)
# sin/cos generation cost stays OUT of the measured throughput — this benchmarks the TRANSPORT (the
# per-frame SlateBinary collect + encode + publish + wire + browser decode), not field synthesis, which
# otherwise grows with frame size and dilutes exactly the large-frame numbers the transport work targets.
# Cycling a handful of variants (not one static buffer) keeps the payload changing frame-to-frame so
# nothing downstream can dedup it, while costing only `NVARIANTS` field-gens total regardless of `frames`.
function run_stress(channel::AbstractString, n::Int, frames::Int, delayMs::Float64, run::Int, bin::Bool)
    NVARIANTS = 8
    variants = map(1:NVARIANTS) do v
        ph = v * 0.15
        fld = Vector{Float32}(undef, n * n)
        @inbounds for y in 0:n-1, x in 0:n-1
            fld[y*n + x + 1] = sin(x*0.18f0 + ph) * cos(y*0.18f0 - ph) + 0.5f0*sin((x+y)*0.09f0 + 0.7f0*ph)
        end
        fld
    end
    t0 = time()
    for i in 1:frames
        fld = variants[mod1(i, NVARIANTS)]
        # `r` tags the run so the receiver ignores frames still draining from a PRIOR run (else recv > sent).
        # BINARY: raw f32 bytes over the WS (SlateBinary copies via `collect`); JSON: the legacy 3-pass path.
        if bin
            slate_emit(channel, SlateBinary(fld; i = i, t = time(), r = run))
        else
            slate_emit(channel, (i = i, t = time(), r = run, d = copy(fld)))
        end
        delayMs > 0 && sleep(delayMs / 1000)
        yield()                                     # let the PUB flush + keep the worker responsive
    end
    return (; sent = frames, dur_ms = (time() - t0) * 1000, bytes_per_frame = n * n * 4)
end

# ── The widget ────────────────────────────────────────────────────────────────
"""
    StreamBench

A returnable streaming-benchmark dashboard (build it with [`bench_stream`](@ref)); Slate mounts the live
throughput/latency viz via `slate_render`.
"""
struct StreamBench
    props::Dict{String,Any}
end

SlateExtensionsBase.slate_render(b::StreamBench) = component("SlateBench.StreamBench", b.props)

"""
    bench_stream(; n=64, frames=2000, delayMs=0, name="bench") -> StreamBench

Return a live streaming-benchmark dashboard. Press ▶ Run and it streams `frames` frames of an `n×n` Float32
field over `slate_emit` (throttled by `delayMs`, `0` = as fast as possible), charting throughput, drops, and
latency drift. `name` is the `slate_emit`/RPC channel. The `run` handler is wired automatically through
SlateExtensionsBase's `slate_on` accessor — the notebook just returns the value.
"""
# Register the `<name>:run` RPC handler that ▶ Run invokes. Factored out so BOTH `bench_stream` (for a
# custom `name`) and `__slate_frontend` (for the default channel) install it. `slate_on` replaces by
# channel, so calling it twice is idempotent.
_register_run_handler!(slate_on, name::AbstractString) =
    slate_on("$name:run", a -> run_stress(String(name), Int(a.n), Int(a.frames), Float64(a.delayMs),
                                          Int(hasproperty(a, :run) ? a.run : 0),
                                          hasproperty(a, :bin) && a.bin == true))

function bench_stream(; n::Integer = 64, frames::Integer = 2000, delayMs::Real = 0, name::AbstractString = "bench")
    _register_run_handler!(slate_on, String(name))
    return StreamBench(Dict{String,Any}(
        "channel" => String(name), "n" => Int(n), "frames" => Int(frames), "delayMs" => Float64(delayMs)))
end

# Package-global front-end + handler wiring, re-fired per namespace generation from `using SlateBench` —
# so the dashboard JS and the default `bench:run` handler are BOTH present on a fresh worker even when the
# dash cell's output is memo-restored rather than re-executed (registering the handler only inside
# `bench_stream` left it missing after a restore → "no slate_on handler registered for channel 'bench:run'").
function __slate_frontend(slate_on)
    provide_frontend!(@pkg_asset("assets/bench.js"); id = "SlateBench.bench")
    _register_run_handler!(slate_on, "bench")
end

end # module

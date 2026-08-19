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

# ── Pacing ────────────────────────────────────────────────────────────────────
# Wait `ms` milliseconds between frames, accurately. `sleep` is a libuv timer on a busy event loop, so
# it is useless as a pacer at benchmark scale: it has a ~1ms floor AND overshoots its argument by a
# growing margin (a sub-millisecond request still costs milliseconds). Left unhandled that silently
# clamps the frame rate to a few hundred fps — a pacer artifact that masquerades as a transport ceiling
# on small frames, where a frame costs microseconds.
#
# So pace against a DEADLINE instead of trusting any single sleep. While more than `SPIN_MS` remains we
# sleep a conservative fraction of the remaining time — `SLEEP_DIVISOR` exceeds the worst observed
# overshoot ratio, so a chunk cannot overrun the deadline — and the last stretch is spun on the
# monotonic clock. That yields microsecond accuracy at any delay while only the final `SPIN_MS` burns
# CPU. `yield()` throughout keeps the PUB flushing and the worker responsive.
const SPIN_MS = 4.0
const SLEEP_DIVISOR = 5.0

function pace(ms::Float64)
    tend = time_ns() + round(UInt64, ms * 1e6)
    while true
        remaining_ms = (signed(tend) - signed(time_ns())) / 1e6
        remaining_ms <= 0 && break
        remaining_ms > SPIN_MS ? sleep(remaining_ms / SLEEP_DIVISOR / 1000) : yield()
    end
    return nothing
end

# ── The emitter under test ────────────────────────────────────────────────────
# Stream `frames` frames of an n×n Float32 plasma field over `slate_emit` — the exact worker→hub→browser
# path we're optimizing. Each frame carries {i: index, t: hi-res send time, d: the flat field}, so the
# receiver can measure drops (index gaps) and latency drift (recv − send).
#
# The plasma field is PRECOMPUTED into a small cycle of variants OUTSIDE the emit loop, so the O(n²)
# sin/cos generation cost stays OUT of the measured throughput — this benchmarks the TRANSPORT (per-frame
# encode + publish + wire + browser decode), not field synthesis, which otherwise grows with frame size
# and dilutes exactly the large-frame numbers the transport work targets. Cycling a handful of variants
# (not one static buffer) keeps the payload changing frame-to-frame so nothing downstream can dedup it,
# while costing only `NVARIANTS` field-gens total regardless of `frames`.
#
# `snapshot` picks what the binary path does with the payload: by reference (the default — the frame
# reads the variant in place) or copied per frame. That copy is what a sender pays when it holds a
# frame rather than emitting it, and it is the whole difference between the two on large fields, so
# both belong on one dashboard. The JSON path always copies, which is worth remembering when reading
# the two against each other: only `snapshot` on makes them like-for-like on that count.
function run_stress(channel::AbstractString, n::Int, frames::Int, delayMs::Float64, run::Int,
                    bin::Bool, snapshot::Bool)
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
    sent = 0
    for i in 1:frames
        CURRENT_RUN[] == run || break     # a newer run superseded this one — abandon the old stream
        fld = variants[mod1(i, NVARIANTS)]
        # `r` tags the run so the receiver ignores frames still draining from a PRIOR run (else recv > sent).
        # BINARY: raw f32 bytes over the WS; JSON: the 3-pass serialize/base64/parse path.
        if bin
            slate_emit(channel, SlateBinary(fld; snapshot = snapshot, i = i, t = time(), r = run))
        else
            slate_emit(channel, (i = i, t = time(), r = run, d = copy(fld)))
        end
        sent = i
        delayMs > 0 && pace(delayMs)
        yield()                                     # let the PUB flush + keep the worker responsive
    end
    # `sent` is what actually went out, which is NOT `frames` when a newer run cut this one short —
    # reporting the request instead would show those abandoned frames as drops.
    return (; sent = sent, dur_ms = (time() - t0) * 1000, bytes_per_frame = n * n * 4)
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

# ── Run control ───────────────────────────────────────────────────────────────
# Streaming thousands of frames takes far longer than the browser's 30s RPC timeout, so the ▶ Run
# call ALWAYS fails on a long run — and especially on a backed-up one, exactly the case the benchmark
# exists to measure. Awaiting it therefore discarded a completed run's statistics: the reply was late,
# not the work wrong.
#
# The stream CANNOT be moved off the handler's own task. `slate_emit` delivers only from a live run:
# frames emitted from a detached task — spawned inside the handler OR from a cell whose run has since
# finished — are accepted and then dropped silently, so the dashboard sees an accepted run deliver
# nothing. Streaming therefore stays inline, and the RPC necessarily outlives the browser's timeout.
#
# So the browser is decoupled from the RPC's RETURN instead: the tally is also published as a
# `<channel>:done` event, emitted inline while the run is still live, and the dashboard finalizes on
# that. The reply is then pure redundancy — if it makes it back, fine; if it times out, the summary
# has already been delivered by the event.
const CURRENT_RUN = Ref(0)

function start_run(channel::AbstractString, n::Int, frames::Int, delayMs::Float64, run::Int,
                   bin::Bool, snapshot::Bool)
    CURRENT_RUN[] = run                  # supersedes any stream still running; it sees this and stops
    tally = try
        merge(run_stress(channel, n, frames, delayMs, run, bin, snapshot), (; ok = true, error = ""))
    catch e
        # Report a failure on the SAME path as success — a silently dead stream would otherwise leave
        # the dashboard waiting on frames that are never coming.
        (; sent = 0, dur_ms = 0.0, bytes_per_frame = n * n * 4, ok = false, error = sprint(showerror, e))
    end
    slate_emit("$channel:done", merge(tally, (; r = run)))
    return tally
end

# Register the `<name>:run` RPC handler that ▶ Run invokes. Factored out so BOTH `bench_stream` (for a
# custom `name`) and `__slate_frontend` (for the default channel) install it. `slate_on` replaces by
# channel, so calling it twice is idempotent.
_register_run_handler!(slate_on, name::AbstractString) =
    slate_on("$name:run", a -> start_run(String(name), Int(a.n), Int(a.frames), Float64(a.delayMs),
                                         Int(hasproperty(a, :run) ? a.run : 0),
                                         hasproperty(a, :bin) && a.bin == true,
                                         hasproperty(a, :snapshot) && a.snapshot == true))

"""
    bench_stream(; n=64, frames=2000, delayMs=0, name="bench") -> StreamBench

Return a live streaming-benchmark dashboard. Press ▶ Run and it streams `frames` frames of an `n×n` Float32
field over `slate_emit` (throttled by `delayMs`, `0` = as fast as possible), charting throughput, drops, and
latency drift. `name` is the `slate_emit`/RPC channel. The `run` handler is wired automatically through
SlateExtensionsBase's `slate_on` accessor — the notebook just returns the value.
"""
function bench_stream(; n::Integer = 64, frames::Integer = 2000, delayMs::Real = 0, name::AbstractString = "bench")
    _register_run_handler!(slate_on, String(name))
    return StreamBench(Dict{String,Any}(
        "channel" => String(name), "n" => Int(n), "frames" => Int(frames), "delayMs" => Float64(delayMs)))
end

# Package-global front-end + handler wiring, re-fired per namespace generation from `using SlateBench` —
# so the dashboard JS and the default `bench:run` handler are BOTH present on a fresh worker even when the
# dash cell's output is memo-restored rather than re-executed (registering the handler only inside
# `bench_stream` left it missing after a restore → "no slate_on handler registered for channel 'bench:run'").
#
# NOTE when editing the dashboard JS: `@pkg_asset` is a MACRO, so the file's contents are baked in when
# this method is compiled. Re-running the cell re-serves the BAKED copy, not what is on disk — editing
# `assets/bench.js` alone changes nothing in the browser. Restart the worker (or touch this method to
# make Revise re-expand the macro), then reload the page.
function __slate_frontend(slate_on)
    provide_frontend!(@pkg_asset("assets/bench.js"); id = "SlateBench.bench")
    _register_run_handler!(slate_on, "bench")
end

end # module

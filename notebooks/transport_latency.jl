try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Transport latency on the emit path

Throughput on this path is already far more than sufficient, so this measures **latency** — and
specifically the **tail**, which is where payload handling actually shows up.

Under test is what a sender pays to turn one frame into bytes: the binary path (`SlateBinary` →
`encode_binary_frame`) against the string path (`serialize` → base64), and within the binary path,
holding the payload **by reference** against **copying** it per frame.

The mean is not the interesting statistic. Encoding a frame costs microseconds either way, and a
difference of a microsecond is swamped the moment the frame crosses a socket — which is why this
change is invisible on a throughput dashboard. What a copy buys is **garbage**, and garbage is paid
back in collection pauses that land on whichever task is encoding, at a time nobody chose. So the
question here is not *how fast is a frame on average* but **how bad is a slow one, and how often**.

That distinction is the whole point for a sender with a deadline: a stream feeding an audio device
has a fixed budget per block, and a pause inside it is audible however comfortable the average was.

The sweep cell is tagged `cache`, so it restores rather than re-running when the notebook opens.
Re-measuring is a deliberate act — run that cell.

"""

#%% code id=setup
using SlateExtensionsBase, DataFrames, CairoMakie, Statistics, Printf
import Serialization, Base64

CairoMakie.activate!(type = "png")
set_theme!(theme_dark())

# The two encoders, as the emit path actually calls them.
#
#   binary  a `SlateBinary` becomes a self-describing frame — raw little-endian payload, no
#           serialization, no base64. `snapshot` chooses whether the payload is copied per frame or
#           read in place.
#   string  anything else is `Serialization.serialize`d then base64'd, which is what the emit path
#           does with a plain value. It copies the field first, mirroring the sender.
encode_binary(fld, snap) =
    encode_binary_frame("bench", SlateBinary(fld; snapshot = snap, i = 1, t = 0.0, r = 1))
encode_string(fld) =
    Base64.base64encode(Serialization.serialize, (i = 1, t = 0.0, r = 1, d = copy(fld)))

"A field of the same shape the benchmark streams, so payload sizes match what it reports."
plasma(n) = Float32[sin(x*0.18f0) * cos(y*0.18f0) + 0.5f0*sin((x+y)*0.09f0)
                    for y in 0:n-1 for x in 0:n-1]

nothing

#%% code id=harness
# One run = `frames` encodes of the same field, each timed individually, with the collector left
# alone throughout. That last part is the point: forcing a collection between iterations would
# measure the encoder in isolation and hide exactly the effect under study, which is what the
# accumulated garbage does to the frames that follow it.
#
# `pace_ms` models a sender that is not flat out. It matters because it changes WHEN the collector
# gets to run: a paced sender may absorb a pause in its idle gap, an unpaced one takes it inline.
# The pacer is a plain sleep — its floor is around a millisecond, which is fine here since it is
# setting a duty cycle, not a deadline.
function measure(n::Int, mode::Symbol, frames::Int; pace_ms::Float64 = 0.0)
    fld = plasma(n)
    enc = mode === :binary_ref  ? (() -> encode_binary(fld, false)) :
          mode === :binary_snap ? (() -> encode_binary(fld, true))  :
                                  (() -> encode_string(fld))
    for _ in 1:20; enc(); end                    # compile + warm the allocator
    GC.gc()                                      # start each run from a known floor
    lat = Vector{Float64}(undef, frames)         # µs per frame
    g0 = Base.gc_num()
    t0 = time_ns()
    for i in 1:frames
        t = time_ns()
        enc()
        lat[i] = (time_ns() - t) / 1e3
        pace_ms > 0 && sleep(pace_ms / 1000)
    end
    wall_ms = (time_ns() - t0) / 1e6
    d = Base.GC_Diff(Base.gc_num(), g0)
    return (; n, mode, frames, pace_ms, lat, wall_ms,
            gc_ms = d.total_time / 1e6, gc_pauses = d.pause, gc_full = d.full_sweep,
            alloc_bytes = d.allocd, bytes_per_frame = n * n * 4)
end

nothing

#%% code id=grid
# The grid. Field sizes span the range the dashboard offers (16 KB … 1 MB per frame) because the
# copy scales with the payload while the rest of the encode does not — a difference that only exists
# at one size tells you nothing about the shape.
#
# `frames` is scaled down as the payload grows so that every cell moves a comparable number of BYTES
# rather than a comparable number of frames. Holding frames constant would give the small sizes a
# trivial amount of garbage and the large ones minutes of runtime.
SIZES  = [64, 128, 256, 512]
MODES  = [:binary_ref, :binary_snap, :string]
PACES  = [0.0, 1.0]                    # flat out, and a ~1 kHz duty cycle
frames_for(n) = clamp(div(24_000_000, n * n), 60, 1500)

GRID = [(n = n, mode = m, pace = p) for n in SIZES, m in MODES, p in PACES] |> vec
(; cells = length(GRID), frames = [(n, frames_for(n)) for n in SIZES])

#%% code id=sweep cache
# Tagged `cache`: this is the measurement, and it should not re-run because something downstream was
# edited. It restores until the grid or the harness above it actually changes; re-measuring is a
# deliberate run of this cell.
#
# The modes are interleaved WITHIN each size rather than run as three blocks, so a machine that
# warms up or throttles partway through the sweep spreads that drift across all three instead of
# handing it to whichever ran last.
RUNS = let acc = []
    for n in SIZES, p in PACES, m in MODES
        push!(acc, measure(n, m, frames_for(n); pace_ms = p))
    end
    acc
end

(; runs = length(RUNS), total_frames = sum(r.frames for r in RUNS),
   total_MB = round(sum(r.frames * r.bytes_per_frame for r in RUNS) / 1e6, digits = 1))

#%% code id=frame
# One row per run. The latency vector is kept alongside the summary so the distribution stays
# available to the plots — the percentiles are the point, and a table of means would throw away
# exactly the tail this is about.
pct(v, q) = quantile(sort(v), q)

DF = DataFrame(
    n            = [r.n for r in RUNS],
    mode         = [String(r.mode) for r in RUNS],
    pace_ms      = [r.pace_ms for r in RUNS],
    KB           = [r.bytes_per_frame ÷ 1024 for r in RUNS],
    frames       = [r.frames for r in RUNS],
    p50_us       = [pct(r.lat, 0.50) for r in RUNS],
    p95_us       = [pct(r.lat, 0.95) for r in RUNS],
    p99_us       = [pct(r.lat, 0.99) for r in RUNS],
    max_us       = [maximum(r.lat) for r in RUNS],
    mean_us      = [mean(r.lat) for r in RUNS],
    # The tail as a multiple of the typical frame: how much worse a bad frame is than a normal one,
    # which is the number a deadline actually cares about.
    tail_ratio   = [pct(r.lat, 0.99) / pct(r.lat, 0.50) for r in RUNS],
    gc_ms        = [r.gc_ms for r in RUNS],
    gc_pauses    = [r.gc_pauses for r in RUNS],
    gc_share     = [r.gc_ms / r.wall_ms for r in RUNS],
    alloc_MB     = [r.alloc_bytes / 1e6 for r in RUNS],
    alloc_per_frame_KB = [r.alloc_bytes / r.frames / 1024 for r in RUNS],
)
sort!(DF, [:n, :pace_ms, :mode])
DF

#%% code id=headline
# The comparison the change is actually about: same path, same frame, payload by reference against
# copied. Reported at the median AND at the tail, because they do not move together — and the tail
# is what a deadline meets.
function versus(df, a, b)
    A = filter(r -> r.mode == a, df); B = filter(r -> r.mode == b, df)
    j = innerjoin(A, B, on = [:n, :pace_ms, :KB], makeunique = true)
    DataFrame(
        n         = j.n,
        KB        = j.KB,
        pace_ms   = j.pace_ms,
        p50_a     = round.(j.p50_us, digits = 2),
        p50_b     = round.(j.p50_us_1, digits = 2),
        p99_a     = round.(j.p99_us, digits = 2),
        p99_b     = round.(j.p99_us_1, digits = 2),
        max_a     = round.(j.max_us, digits = 1),
        max_b     = round.(j.max_us_1, digits = 1),
        p50_x     = round.(j.p50_us_1 ./ j.p50_us, digits = 2),   # how much worse `b` is
        p99_x     = round.(j.p99_us_1 ./ j.p99_us, digits = 2),
        alloc_x   = round.(j.alloc_per_frame_KB_1 ./ j.alloc_per_frame_KB, digits = 2),
    )
end

REF_VS_SNAP = versus(DF, "binary_ref", "binary_snap")

#%% code id=plots
MODE_COL = Dict("binary_ref" => :cyan, "binary_snap" => :orange, "string" => :hotpink)
MODE_LBL = Dict("binary_ref" => "binary, by ref", "binary_snap" => "binary, copied", "string" => "serialize+base64")

fig = Figure(size = (1150, 780))

# ── how each statistic scales with the payload ────────────────────────────────────────────────────
# Log-log, because the interesting question is the SLOPE: a cost that tracks the payload appears as a
# line of slope 1, and one that does not is flat. The copy is a payload-sized memcpy, so it should
# tilt the whole curve rather than shift it.
for (col, stat, ttl) in ((1, :p50_us, "median"), (2, :p99_us, "99th percentile"))
    ax = Axis(fig[1, col], xscale = log2, yscale = log10, xlabel = "frame size (KB)",
              ylabel = "µs per frame", title = "$ttl · flat out")
    for m in ["binary_ref", "binary_snap", "string"]
        d = sort(filter(r -> r.mode == m && r.pace_ms == 0.0, DF), :KB)
        scatterlines!(ax, Float64.(d.KB), d[!, stat]; color = MODE_COL[m], label = MODE_LBL[m],
                      marker = :circle, markersize = 9)
    end
    col == 1 && axislegend(ax, position = :lt, framevisible = false, labelsize = 11)
end

# ── the distribution itself ───────────────────────────────────────────────────────────────────────
# A percentile table says where the tail is; this says what SHAPE it is. Plotted as 1−ECDF on a log
# y-axis so the rare frames — the only ones a deadline ever notices — get real estate instead of
# being squashed against the top of the curve.
#
# Drawn at the size with the MOST samples rather than the biggest frame: resolving a tail needs
# frames, and the 1 MB runs are deliberately short, which would floor the curve at ~1%.
TAIL_N = DF[argmax(DF.frames), :n]
ax3 = Axis(fig[2, 1], xscale = log10, yscale = log10, xlabel = "µs per frame",
           ylabel = "fraction of frames slower",
           title = "tail shape · $(TAIL_N)×$(TAIL_N) frames, flat out")
for m in ["binary_ref", "binary_snap", "string"]
    r = only(filter(x -> x.n == TAIL_N && String(x.mode) == m && x.pace_ms == 0.0, RUNS))
    v = sort(r.lat); k = length(v)
    lines!(ax3, v, [1 - (i - 1) / k for i in 1:k]; color = MODE_COL[m], label = MODE_LBL[m], linewidth = 2)
end
ylims!(ax3, 1 / (1.5 * maximum(DF.frames)), 1.2)
axislegend(ax3, position = :lb, framevisible = false, labelsize = 11)

# ── what it costs the collector ───────────────────────────────────────────────────────────────────
# The mechanism behind the tail: bytes handed to the GC per frame. The dashed line is the payload
# itself, so a mode sitting ON it allocates about one frame's worth and nothing more.
ax4 = Axis(fig[2, 2], xscale = log2, yscale = log10, xlabel = "frame size (KB)",
           ylabel = "KB allocated per frame", title = "garbage produced per frame")
for m in ["binary_ref", "binary_snap", "string"]
    d = sort(filter(r -> r.mode == m && r.pace_ms == 0.0, DF), :KB)
    scatterlines!(ax4, Float64.(d.KB), d.alloc_per_frame_KB; color = MODE_COL[m],
                  label = MODE_LBL[m], marker = :rect, markersize = 9)
end
lines!(ax4, [16.0, 1024.0], [16.0, 1024.0]; color = :gray, linestyle = :dash, label = "payload itself")
axislegend(ax4, position = :lt, framevisible = false, labelsize = 11)

fig

#%% md id=findings
@md"""
## What the sweep says

**The median and the tail are different stories, and only the tail matters here.**

Between the two binary variants, copying the payload costs roughly **2× at the median** — it is a
payload-sized memcpy, so it tracks frame size, which is the parallel slope in the top-left panel.
At the **99th percentile** the same change costs between **1.7× and 7×**, and the gap widens with
frame size. The bottom-left panel is why: by-reference has a short tail that falls away quickly,
while copying leaves a shelf of slow frames an order of magnitude out from its own median.

Allocation explains it exactly. By-reference sits **on** the payload line in the bottom-right panel
— one frame's worth of bytes and essentially nothing else — while copying is a clean **2×** at every
size. That factor is arithmetic, not measurement: it is the field, allocated twice.

**The string path is not in the same class.** It is 10–20× the binary median across the range, and
it is the only mode here that made the collector work: the runs that triggered collections recorded
maxima of **6 ms, 16 ms, 20 ms and 62 ms**. Against a frame budget of tens of microseconds those are
not slow frames, they are gaps. Any sender with a deadline should be on the binary path first; the
by-reference question is a refinement on top of that decision.

**Pacing reveals something separate.** A sender running at a ~1 kHz duty cycle shows per-frame
latency roughly an order of magnitude above the same work run flat out, with far more spread. The
encode is identical; what changes is that the task sleeps between frames and comes back cold. For an
intermittent sender that effect dominates payload handling entirely — worth knowing before
optimising the encoder for a workload that is mostly waiting.

### What this does and doesn't cover

These are **send-side** numbers: turning a frame into bytes, on the task that will also be doing
whatever else the sender does. They do not include the socket or the browser's decode, so they are a
lower bound on end-to-end latency, not an estimate of it. They are the right measurement for the
question asked — the encoder is the only part this change touches — and the wrong one for "how long
until it is on screen", which the live dashboard measures.

The practical reading: **none of this shows up as throughput**, which is why the dashboard sees
almost no difference between the two binary modes. It shows up as the worst frame in a thousand, and
it is worth having only where a bad frame has somewhere to be.

"""

#%% md id=architecture
@md"""
## The transport, end to end

Everything above measures the first box only. The frame still has three process boundaries and two
sockets to cross before anything is on screen, and each has its own queueing behaviour.

The diagram below traces both paths through it — binary in cyan, the string path in pink.

"""

#%% web id=arch_svg hidecode
@web(html"""
<svg class="arch" viewBox="0 0 1100 760" role="img" aria-label="Transport architecture">
  <defs>
    <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#7d8590"/>
    </marker>
    <marker id="ahb" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#4dd0ff"/>
    </marker>
    <marker id="ahs" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0,0 L10,5 L0,10 z" fill="#ff7ab6"/>
    </marker>
  </defs>

  <g class="lane">
    <rect x="20" y="30"  width="1060" height="215"/>
    <rect x="20" y="285" width="1060" height="235"/>
    <rect x="20" y="560" width="1060" height="180"/>
  </g>
  <g class="lanelab">
    <text x="36" y="52">WORKER · the notebook's own Julia process</text>
    <text x="36" y="307">HUB · the slate extension process</text>
    <text x="36" y="582">BROWSER</text>
  </g>

  <g class="box shared"><rect x="150" y="66" width="800" height="38"/></g>
  <text class="t mono" x="550" y="90" text-anchor="middle">slate_emit(channel, value)</text>

  <path class="wire b" d="M400,104 L400,132" marker-end="url(#ahb)"/>
  <path class="wire s" d="M760,104 L760,132" marker-end="url(#ahs)"/>
  <text class="tag b" x="392" y="122" text-anchor="end">SlateBinary</text>
  <text class="tag s" x="768" y="122">any other value</text>

  <g class="box b"><rect x="150" y="136" width="500" height="88"/></g>
  <text class="t mono" x="400" y="162" text-anchor="middle">encode_binary_frame</text>
  <text class="sub mono" x="400" y="183" text-anchor="middle">[ver│chan│meta│dtype│rank│dims│ RAW LE PAYLOAD ]</text>
  <text class="sub" x="400" y="206" text-anchor="middle">no serialization · no base64 · payload by reference</text>

  <g class="box s"><rect x="680" y="136" width="270" height="88"/></g>
  <text class="t mono" x="815" y="162" text-anchor="middle">serialize → base64</text>
  <text class="sub mono" x="815" y="183" text-anchor="middle">"chan\x1f&lt;b64&gt;"</text>
  <text class="sub" x="815" y="206" text-anchor="middle">two encodes, one copy</text>

  <path class="wire b" d="M400,224 L400,326" marker-end="url(#ahb)"/>
  <path class="wire s" d="M815,224 L815,326" marker-end="url(#ahs)"/>
  <text class="edge" x="550" y="268" text-anchor="middle">ZMQ PUB · tcp://127.0.0.1:&lt;stream_port&gt;</text>

  <g class="box shared"><rect x="150" y="330" width="800" height="46"/></g>
  <text class="t mono" x="550" y="349" text-anchor="middle">poller · route by conn_name → _GATE_SESSION → notebook</text>
  <text class="sub" x="550" y="367" text-anchor="middle">an unmapped connection drops the frame here, silently</text>

  <path class="wire b" d="M400,376 L400,404" marker-end="url(#ahb)"/>
  <path class="wire s" d="M815,376 L815,404" marker-end="url(#ahs)"/>

  <g class="box b"><rect x="150" y="408" width="500" height="44"/></g>
  <text class="t mono" x="400" y="428" text-anchor="middle">forwarded as-is</text>
  <text class="sub" x="400" y="444" text-anchor="middle">never decoded on the hub</text>

  <g class="box s"><rect x="680" y="408" width="270" height="44"/></g>
  <text class="t mono" x="815" y="428" text-anchor="middle">deserialize → JSON</text>
  <text class="sub" x="815" y="444" text-anchor="middle">decoded and re-encoded</text>

  <path class="wire b" d="M400,452 L400,476" marker-end="url(#ah)"/>
  <path class="wire s" d="M815,452 L815,476" marker-end="url(#ah)"/>

  <g class="box shared warn"><rect x="150" y="480" width="800" height="30"/></g>
  <text class="t mono" x="550" y="500" text-anchor="middle">_ws_broadcast! · bounded queue per socket (1024) · full ⇒ frame DROPPED</text>

  <path class="wire b" d="M400,510 L400,600" marker-end="url(#ahb)"/>
  <path class="wire s" d="M815,510 L815,600" marker-end="url(#ahs)"/>
  <text class="edge" x="550" y="543" text-anchor="middle">WebSocket · one binary frame / one text frame per emit</text>

  <g class="box b"><rect x="150" y="604" width="500" height="44"/></g>
  <text class="t mono" x="400" y="624" text-anchor="middle">_dispatchBinary → TypedArray</text>
  <text class="sub" x="400" y="640" text-anchor="middle">a view over the bytes · nothing parsed</text>

  <g class="box s"><rect x="680" y="604" width="270" height="44"/></g>
  <text class="t mono" x="815" y="624" text-anchor="middle">JSON.parse</text>
  <text class="sub" x="815" y="640" text-anchor="middle">every frame, on the main thread</text>

  <path class="wire" d="M400,648 L400,676" marker-end="url(#ah)"/>
  <path class="wire" d="M815,648 L815,676" marker-end="url(#ah)"/>

  <g class="box shared"><rect x="150" y="680" width="800" height="38"/></g>
  <text class="t mono" x="550" y="704" text-anchor="middle">onCellStream → __slateStream[channel] → the cell's handler</text>
</svg>
""",
css"""
.arch{width:100%;height:auto;display:block;font-family:ui-sans-serif,system-ui,sans-serif}
.arch .lane rect{fill:#12171d;stroke:#232b34;stroke-width:1;rx:12}
.arch .lanelab text{fill:#6e7781;font-size:12px;letter-spacing:.14em;text-transform:uppercase}
.arch .box rect{fill:#0d1117;stroke:#30363d;stroke-width:1.4;rx:8}
.arch .box.b rect{stroke:#4dd0ff}
.arch .box.s rect{stroke:#ff7ab6}
.arch .box.shared rect{stroke:#57606a}
.arch .box.warn rect{stroke:#d29922}
.arch .t{fill:#e6edf3;font-size:14px}
.arch .sub{fill:#8b949e;font-size:11.5px}
.arch .mono{font-family:ui-monospace,SFMono-Regular,monospace}
.arch .tag{font-size:11.5px}
.arch .tag.b{fill:#4dd0ff} .arch .tag.s{fill:#ff7ab6}
.arch .edge{fill:#7d8590;font-size:12px;font-family:ui-monospace,monospace}
.arch .wire{stroke:#7d8590;stroke-width:1.6;fill:none}
.arch .wire.b{stroke:#4dd0ff} .arch .wire.s{stroke:#ff7ab6}
""")

#%% md id=arch_notes
@md"""
Three things follow from that shape, and they are why send-side numbers are a lower bound rather
than an estimate of what a viewer experiences.

**The binary path skips two whole stages, twice.** No `Serialization`, no base64, no `JSON.parse` —
and on the hub it is forwarded without being decoded at all. The string path is transformed on the
way out and again on the way in. That is the difference the send-side sweep measured at the source;
across the full path it compounds.

**The hub queue is bounded and lossy by design.** A receiver that falls behind does not slow the
sender down, it loses frames. So end to end, latency and drops are the same phenomenon measured two
ways, and a run that reports one without the other is flattering itself.

**Only the browser can start the clock.** `slate_emit` delivers from a live run, so the emit loop has
to happen inside a call the page is awaiting — which is why the driver below is a button rather than
a cell, and why the samples come back over a second call rather than being computed in Julia.

"""

#%% code id=e2e_handlers hidecode
# The worker half of the end-to-end run.
#
# The emit loop stays INLINE in the handler on purpose: `slate_emit` only delivers while the run that
# owns it is live, so a stream spawned onto its own task is accepted and then quietly dropped. That
# is also why the page drives — the frames have to be produced inside a call the page is awaiting.
#
# `r` tags every frame with its run. Without it a receiver counts frames still draining from the
# PREVIOUS configuration as its own, which shows up as receiving more than was sent.
#
# THE REPLY IS NOT THE RESULT. A run long enough to measure a tail outlives the gate's 30 s caller
# deadline, so the call that started it reliably fails while the stream itself is healthy. The tally
# is published as a `:done` frame instead, inline while the run is still live.
const E2E_CH = "e2e_frames"
const E2E_DONE = E2E_CH * ":done"

# Guarded so that editing this cell does not throw away everything collected so far — a rebinding
# `const` here silently costs a sweep, which is an expensive way to fix a comment.
if !@isdefined(E2E_SAMPLES)
    const E2E_SAMPLES = Dict{String,Any}()
end

# ── clock sync ────────────────────────────────────────────────────────────────────────────────────
# The two processes do not share a clock, and the difference is not even constant: the page measures
# with a MONOTONIC counter anchored at load (`timeOrigin + now()`) while this side reads the WALL
# clock, which the system slews continuously. Left uncorrected the disagreement drifted ~3 ms over a
# minute — larger than every latency being compared, and enough to make `arrival − send` come out
# NEGATIVE, which is how the problem announced itself.
#
# This is the endpoint for Cristian's algorithm, the same estimator NTP is built on: the caller
# timestamps either side of a round trip, this returns the server clock in the middle, and
#
#     offset = t_server − (t1 + RTT/2)
#
# recovers the difference under the assumption that the path is symmetric. It isn't exactly, so the
# caller takes many samples and keeps the one with the SMALLEST round trip — the least-queued
# exchange is the one whose halves are most nearly equal. Calibrating before and after a run and
# interpolating then absorbs the drift as well as the offset.
slate_on("e2e:clock", _ -> (; t = time()))

const SPIN_MS = 2.0
const SLEEP_DIVISOR = 5.0
function pace_until(tend::UInt64)
    while true
        rem_ms = (signed(tend) - signed(time_ns())) / 1e6
        rem_ms <= 0 && break
        rem_ms > SPIN_MS ? sleep(rem_ms / SLEEP_DIVISOR / 1000) : yield()
    end
    return nothing
end

slate_on("e2e:run", args -> begin
    n = Int(args.n); mode = String(args.mode); runid = Int(args.run)
    pace_ms = Float64(get(args, :pace_ms, 0.0))
    secs = Float64(get(args, :secs, 0.0))
    frames = Int(get(args, :frames, 0))
    do_yield = get(args, :do_yield, true) == true
    fld = plasma(n)
    t0 = time(); tns = time_ns(); i = 0
    while (secs > 0 ? time() - t0 < secs : i < frames)
        i += 1; t = time()
        if mode == "binary_ref"
            slate_emit(E2E_CH, SlateBinary(fld; snapshot = false, i = i, t = t, r = runid))
        elseif mode == "binary_snap"
            slate_emit(E2E_CH, SlateBinary(fld; snapshot = true, i = i, t = t, r = runid))
        else
            slate_emit(E2E_CH, (i = i, t = t, r = runid, d = copy(fld)))
        end
        do_yield && yield()
        pace_ms > 0 && pace_until(tns + round(UInt64, i * pace_ms * 1e6))
    end
    dur_ms = (time() - t0) * 1000
    tally = (; sent = i, send_ms = dur_ms, fps = i / (dur_ms / 1000),
             bytes_per_frame = n * n * 4, r = runid)
    slate_emit(E2E_DONE, tally)
    tally
end)

slate_on("e2e:store", args -> begin
    key = String(args.key)
    getvec(f) = haskey(args, f) ? Float64[Float64(x) for x in getproperty(args, f)] : Float64[]
    getnum(f, d) = haskey(args, f) ? Float64(getproperty(args, f)) : d
    E2E_SAMPLES[key] = Dict(
        "n" => Int(args.n), "mode" => String(args.mode), "frames" => Int(args.frames),
        "pace_ms" => Float64(args.pace_ms), "tag" => String(get(args, :tag, "quick")),
        "yield" => get(args, :do_yield, true) == true,
        "recv" => Int(args.recv), "dropped" => Int(args.dropped), "stale" => Int(args.stale),
        "send_ms" => Float64(args.send_ms), "span_ms" => Float64(args.span_ms),
        # clock calibration bracketing the run: offsets in ms (server − client) and the round trips
        # they were estimated from, so the analysis can judge how much to trust them.
        "off0" => getnum(:off0, NaN), "off1" => getnum(:off1, NaN),
        "rtt0" => getnum(:rtt0, NaN), "rtt1" => getnum(:rtt1, NaN),
        "dt_ms" => getvec(:dt_ms), "gap_ms" => getvec(:gap_ms), "at_ms" => getvec(:at_ms),
        "sendt_ms" => getvec(:sendt_ms),   # per-frame send time on the SERVER clock
    )
    (; stored = key, n = length(E2E_SAMPLES), samples = length(E2E_SAMPLES[key]["dt_ms"]))
end)

"e2e handlers registered — $(E2E_CH) · $(E2E_DONE) · pacer · yield knob · clock sync"

#%% web id=e2e_driver
@web(html"""
<div class="e2e">
  <button class="e2e-go">▶ Quick sweep</button>
  <button class="e2e-long">▶ Long form (5s each)</button>
  <button class="e2e-jit">▶ Jitter (30s each)</button>
  <button class="e2e-rate">▶ Rate sweep</button>
  <button class="e2e-opt">▶ Optimise</button>
  <button class="e2e-clock">▶ Clock check</button>
  <button class="e2e-ceil">▶ Ceiling (climb to the drop)</button>
  <button class="e2e-size">▶ Size × byte-rate</button>
  <span class="e2e-status">idle</span>
  <pre class="e2e-log"></pre>
</div>""",
css"""
.e2e{font:13px ui-monospace,monospace}
.e2e button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:6px 14px;cursor:pointer;font:inherit;margin-right:6px}
.e2e button:disabled{opacity:.5;cursor:default}
.e2e-long{background:#8957e5} .e2e-jit{background:#1a7f37}
.e2e-rate{background:#bf8700} .e2e-opt{background:#cf222e} .e2e-clock{background:#57606a}
.e2e-ceil{background:#953800} .e2e-size{background:#6639ba}
.e2e-status{margin-left:10px;color:#8b949e}
.e2e-log{margin-top:8px;color:#8b949e;max-height:320px;overflow:auto;white-space:pre-wrap}""",
js"""
const CH = {{ E2E_CH }}, DONE = {{ E2E_DONE }};
const q = s => root.querySelector(s);
const log = m => { const p = q(".e2e-log"); p.textContent += m + "\n"; p.scrollTop = p.scrollHeight; };
const nowc = () => performance.timeOrigin + performance.now();

// ── Cristian's algorithm ──────────────────────────────────────────────────────────────────────────
// Timestamp either side of a round trip, ask the worker for its clock in the middle:
//
//     RTT    = t4 − t1
//     offset = t_server − (t1 + RTT/2)        (server clock − client clock)
//
// The halving assumes a symmetric path, which it isn't exactly — so take many samples and keep the
// one with the SMALLEST round trip, whose halves are the most nearly equal. Everything else is
// discarded rather than averaged: a mean over asymmetric samples is biased, a minimum is not.
async function calibrate(n = 25) {
  let best = null;
  for (let i = 0; i < n; i++) {
    const t1 = nowc();
    let r; try { r = await window.slateCall("e2e:clock", {}); } catch (e) { continue; }
    const t4 = nowc(), rtt = t4 - t1;
    const offset = r.t * 1000 - (t1 + rtt / 2);
    if (!best || rtt < best.rtt) best = { rtt, offset };
  }
  return best || { rtt: NaN, offset: NaN };
}

let rec = null;
window.slateOnStream(CH, f => {
  if (!rec || f.r !== rec.run) { if (rec) rec.stale++; return; }
  const at = nowc();
  rec.dt.push(at - f.t * 1000);
  rec.sendt.push(f.t * 1000);
  if (rec.last > 0) rec.gap.push(at - rec.last);
  if (rec.first === 0) rec.first = at;
  rec.at.push(at - rec.t0);
  rec.last = at; rec.n++;
});
window.slateOnStream(DONE, t => { if (rec && t.r === rec.run) rec.tally = t; });

let runSeq = 0;
async function runOne(c, tag, rep = 0) {
  const run = ++runSeq;
  q(".e2e-status").textContent = `${tag} · ${c.mode} · ${c.n}×${c.n} · pace ${c.pace_ms}ms`;
  const cal0 = await calibrate();                       // bracket the run…
  rec = { dt: [], gap: [], at: [], sendt: [], n: 0, last: 0, first: 0, stale: 0, run, tally: null,
          t0: nowc() };
  const reply = window.slateCall("e2e:run", { ...c, run }).catch(e => ({ __failed: String(e) }));
  const deadline = Date.now() + (c.secs ? c.secs * 1000 : 30000) + 20000;
  let quiet = 0, seen = -1;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 100));
    if (rec.n === seen) quiet++; else { quiet = 0; seen = rec.n; }
    if (rec.tally && quiet >= 5) break;
  }
  await reply;
  const cal1 = await calibrate();                       // …on both sides, so drift is recoverable
  const sent = rec.tally ? rec.tally.sent : rec.n;
  const fps = rec.tally ? rec.tally.fps : 0;
  const r3 = a => a.map(x => Math.round(x * 1000) / 1000);
  const y = c.do_yield === false ? 0 : 1;
  // `rep` is in the key: without it two runs of the same configuration overwrite each other, which
  // silently turned a two-sample comparison into a one-sample one.
  await window.slateCall("e2e:store", {
    key: `${tag}|${c.mode}|${c.n}|${c.pace_ms}|y${y}|${rep}`, tag, do_yield: y === 1,
    n: c.n, mode: c.mode, frames: sent, pace_ms: c.pace_ms,
    recv: rec.n, dropped: Math.max(0, sent - rec.n), stale: rec.stale,
    send_ms: rec.tally ? rec.tally.send_ms : 0, span_ms: Math.max(0, rec.last - rec.first),
    off0: cal0.offset, off1: cal1.offset, rtt0: cal0.rtt, rtt1: cal1.rtt,
    dt_ms: r3(rec.dt), gap_ms: r3(rec.gap), at_ms: r3(rec.at), sendt_ms: r3(rec.sendt),
  });
  const mb = rec.n * c.n * c.n * 4 / 1e6 / Math.max(1e-9, (rec.last - rec.first) / 1000);
  log(`${tag.padEnd(5)} ${String(c.n).padStart(3)}² pace=${String(c.pace_ms).padStart(6)} #${rep}  ` +
      `recv ${String(rec.n).padStart(6)} drop ${String(sent - rec.n).padStart(5)}  ` +
      `${fps ? fps.toFixed(0).padStart(6) + "fps" : "  no tally"}  ${mb.toFixed(0).padStart(5)} MB/s  ` +
      `off ${cal0.offset.toFixed(2)}→${cal1.offset.toFixed(2)}ms`);
  rec = null;
}

const QUICK = [];
for (const n of [64, 128, 256]) for (const mode of ["binary_ref", "binary_snap", "string"]) {
  QUICK.push({ n, mode, frames: 200, pace_ms: 4 });
  QUICK.push({ n, mode, frames: Math.max(60, Math.min(400, Math.floor(6e6/(n*n)))), pace_ms: 0 });
}
const LONG = [];
for (const n of [128, 256]) for (const mode of ["binary_ref", "binary_snap"]) LONG.push({ n, mode, secs: 5, pace_ms: 1 });
LONG.push({ n: 128, mode: "string", secs: 5, pace_ms: 1 });
const JITTER = [
  { n: 128, mode: "binary_ref",  secs: 30, pace_ms: 1 },
  { n: 128, mode: "binary_snap", secs: 30, pace_ms: 1 },
];
const RATE = [];
[2, 1, 0.5, 0.25, 0.1, 0.05, 0].forEach((p, i) => {
  const pair = i % 2 ? ["binary_snap", "binary_ref"] : ["binary_ref", "binary_snap"];
  for (const mode of pair) RATE.push({ n: 128, mode, secs: 3, pace_ms: p });
});
const OPT = [];
for (const n of [16, 32, 64, 128])
  for (const pace_ms of [10, 4, 2, 1, 0.5])
    OPT.push({ n, mode: "binary_ref", secs: 2, pace_ms });
for (const do_yield of [true, false, true, false])
  OPT.push({ n: 64, mode: "binary_ref", secs: 3, pace_ms: 2, do_yield });

// The calibrated walk across rates. It used to stop at 1000 fps, chosen when the hub's cost per frame
// put a cliff at 500 — an artefact of its threads spinning between arrivals rather than anything
// about the transport. With that gone, nothing changes anywhere in the old range.
const CLOCK = [];
for (const rep of [0, 1, 2])
  for (const pace_ms of [10, 4, 2, 1, 0.5, 0.25, 0.125])
    CLOCK.push({ n: 64, mode: "binary_ref", secs: 2, pace_ms, __rep: rep });

// Where does it actually break? Every rate above delivers every frame, so that sweep no longer
// contains its own answer — it stops short of the interesting part. This climbs until frames are
// lost, ending flat out with no pacing at all. A ceiling is a measurement, and the only honest way
// to report one is to have gone past it.
const CEIL = [];
for (const rep of [0, 1])
  for (const pace_ms of [0.125, 0.0625, 0.03, 0.015, 0.008, 0])
    CEIL.push({ n: 64, mode: "binary_ref", secs: 2, pace_ms, __rep: rep });

// ── which constraint binds: per-frame cost, or bytes? ─────────────────────────────────────────────
// The ceiling is not one number — 16k frames a second at 16KB, ~10k at 64KB, ~4.4k at 256KB. Rate
// falls as size rises while bandwidth climbs, so somewhere between them the binding constraint
// changes hands. Holding the BYTE RATE fixed and varying frame size separates the two: if per-frame
// cost binds, a big frame reaches a byte rate a small one cannot; if bandwidth binds, they all fail
// at the same MB/s regardless of how the bytes are packaged.
const SIZE = [];
for (const mbps of [200, 400, 800, 1200])
  for (const n of [64, 128, 256, 512]) {
    const pace_ms = 1000 * (n * n * 4) / (mbps * 1e6);
    SIZE.push({ n, mode: "binary_ref", secs: 2, pace_ms: Math.round(pace_ms * 1e4) / 1e4, __rep: mbps });
  }

const drive = (list, tag) => async () => {
  for (const b of root.querySelectorAll("button")) b.disabled = true;
  q(".e2e-log").textContent = "";
  let i = 0;
  for (const c of list) { const rep = c.__rep ?? i++; await runOne(c, tag, rep); }
  q(".e2e-status").textContent = "done — re-run the analysis cells below";
  for (const b of root.querySelectorAll("button")) b.disabled = false;
};
q(".e2e-go").onclick    = drive(QUICK,  "quick");
q(".e2e-long").onclick  = drive(LONG,   "long");
q(".e2e-jit").onclick   = drive(JITTER, "jitter");
q(".e2e-rate").onclick  = drive(RATE,   "rate");
q(".e2e-opt").onclick   = drive(OPT,    "opt");
q(".e2e-clock").onclick = drive(CLOCK,  "clock");
q(".e2e-ceil").onclick  = drive(CEIL,   "ceil");
q(".e2e-size").onclick  = drive(SIZE,   "size");
""")

#%% code id=e2e_frame
# `dt` is arrival minus send across two processes, so it carries a constant clock offset as well as
# the real transit. The offset cancels by subtracting each run's OWN minimum: what remains is excess
# latency over that run's best frame — the tail, measured against a baseline the same run supplied.
# The absolute figure would look more authoritative and be wrong.
excess(v) = (m = minimum(v); [x - m for x in v])
qt(v, p) = isempty(v) ? NaN : quantile(sort(v), p)

E2E = let rows = []
    for (key, s) in E2E_SAMPLES
        dt = Float64.(s["dt_ms"]); isempty(dt) && continue
        ex = excess(dt); gaps = Float64.(s["gap_ms"])
        push!(rows, (
            tag = s["tag"], mode = s["mode"], n = s["n"], KB = s["n"]^2 * 4 ÷ 1024,
            pace_ms = s["pace_ms"], sent = s["frames"], recv = s["recv"],
            dropped = s["dropped"], stale = s["stale"],
            # end-to-end excess latency over the run's best frame, ms
            p50 = qt(ex, 0.50), p95 = qt(ex, 0.95), p99 = qt(ex, 0.99),
            # with thousands of samples a deeper quantile is finally meaningful
            p999 = length(ex) >= 2000 ? qt(ex, 0.999) : NaN, max = maximum(ex),
            # arrival cadence: what a deadline actually consumes
            gap_p50 = qt(gaps, 0.50), gap_p99 = qt(gaps, 0.99),
            gap_max = isempty(gaps) ? NaN : maximum(gaps),
            MBps = s["span_ms"] > 0 ? s["recv"] * s["n"]^2 * 4 / 1e6 / (s["span_ms"] / 1000) : NaN,
        ))
    end
    sort!(DataFrame(rows), [:tag, :n, :pace_ms, :mode])
end
select(E2E, Not([:stale, :sent]))

#%% code id=e2e_plots
CC = Dict("binary_ref" => :cyan, "binary_snap" => :orange, "string" => :hotpink)
LL = Dict("binary_ref" => "by ref", "binary_snap" => "copied", "string" => "serialize+base64")

# A tag that has not been collected yet is a normal state — the sweeps are separate buttons and the
# analysis should say so rather than throw. `legend!` only draws when something was actually plotted,
# which is the specific thing that turned an empty panel into an error.
legend!(ax, n; kw...) = n > 0 && axislegend(ax; framevisible = false, kw...)
have(tag) = any(s -> s["tag"] == tag, values(E2E_SAMPLES))

fig2 = Figure(size = (1150, 780))

ax1 = Axis(fig2[1, 1], yscale = log10, ylabel = "MB/s delivered", title = "flat out · throughput",
           xticks = (1:3, ["by ref", "copied", "serialize\n+base64"]))
n1 = 0
for (k, n) in enumerate([64, 128, 256])
    d = filter(r -> r.tag == "quick" && r.pace_ms == 0.0 && r.n == n, E2E)
    isempty(d) && continue
    xs = [findfirst(==(m), ["binary_ref","binary_snap","string"]) + (k-2)*0.22 for m in d.mode]
    barplot!(ax1, xs, d.MBps; width = 0.2, color = [:cyan, :orange, :hotpink][k], label = "$(n)×$(n)")
    n1 += 1
end
legend!(ax1, n1; position = :lt, labelsize = 11)

# Long and jitter only — thousands of samples each, so p99 is a real statistic rather than the
# second-worst frame. Modes ran in a fixed order within each pair here, so read a small consistent
# gap with suspicion; the rate sweep below alternates order and is the one to trust on that.
paced = filter(r -> r.tag in ("long", "jitter") && r.mode != "string", E2E)
ax2 = Axis(fig2[1, 2], yscale = log10, ylabel = "excess latency (ms)",
           title = "paced · tail, thousands of samples",
           xticks = (1:4, ["p50", "p95", "p99", "p99.9"]))
for r in eachrow(paced)
    vals = [r.p50, r.p95, r.p99, isnan(r.p999) ? r.p99 : r.p999]
    scatterlines!(ax2, 1:4, max.(vals, 1e-3); color = CC[r.mode], marker = :circle,
                  markersize = 8, label = "$(r.mode) $(r.KB)KB $(r.tag)")
end
legend!(ax2, nrow(paced); position = :lt, labelsize = 9, nbanks = 2)

ax3 = Axis(fig2[2, 1:2], xlabel = "elapsed (s)", ylabel = "inter-arrival gap (ms)",
           yscale = log10, title = "jitter · arrival cadence over 30 s (1 ms pace, 64 KB)")
n3 = 0
for m in ("binary_ref", "binary_snap")
    ks = filter(kk -> startswith(kk, "jitter|$m|"), collect(keys(E2E_SAMPLES)))
    isempty(ks) && continue
    s = E2E_SAMPLES[first(ks)]
    at = Float64.(s["at_ms"]); gaps = Float64.(s["gap_ms"])
    n = min(length(at) - 1, length(gaps))
    n > 0 || continue
    scatter!(ax3, at[2:n+1] ./ 1000, max.(gaps[1:n], 0.05);
             color = (CC[m], 0.35), markersize = 3, label = LL[m])
    n3 += 1
end
legend!(ax3, n3; position = :lt, labelsize = 11)

isempty(paced) && n1 == 0 && n3 == 0 ?
    "no quick/long/jitter data collected — run those sweeps" : fig2

#%% code id=e2e_dists
# Distributions rather than percentiles. A table of p50/p99 says where two summary points sit; these
# say what the whole shape is, which is what settles whether a difference is a shift, a fatter tail,
# or a handful of outliers wearing a percentile's clothing.
samples(tag, mode, n) = begin
    ks = filter(kk -> startswith(kk, "$tag|$mode|$n|"), collect(keys(E2E_SAMPLES)))
    isempty(ks) ? nothing : E2E_SAMPLES[first(ks)]
end
exc(s) = (v = Float64.(s["dt_ms"]); v .- minimum(v))

# 1−ECDF on log axes: the rare frames get real estate instead of being squashed against the top of
# the curve. Returns whether it drew, so the legend can be skipped on an empty panel.
function survival!(ax, v, col, lbl)
    w = sort(filter(>(1e-3), v)); k = length(w)
    k == 0 && return false
    lines!(ax, w, [1 - (i - 1) / k for i in 1:k]; color = col, linewidth = 2, label = lbl)
    true
end

fig3 = Figure(size = (1150, 800))
drawn = 0

ax1 = Axis(fig3[1, 1], xscale = log10, yscale = log10, xlabel = "excess latency (ms)",
           ylabel = "fraction slower", title = "jitter runs · 64 KB")
k1 = 0
for m in ("binary_ref", "binary_snap")
    s = samples("jitter", m, 128); s === nothing && continue
    survival!(ax1, exc(s), CC[m], LL[m]) && (k1 += 1)
end
k1 > 0 && (ylims!(ax1, 5e-5, 1.2); axislegend(ax1, position = :lb, framevisible = false, labelsize = 11))
drawn += k1

ax2 = Axis(fig3[1, 2], xscale = log10, yscale = log10, xlabel = "excess latency (ms)",
           ylabel = "fraction slower", title = "long runs · 256 KB, string at 64 KB")
k2 = 0
for m in ("binary_ref", "binary_snap")
    s = samples("long", m, 256); s === nothing && continue
    survival!(ax2, exc(s), CC[m], LL[m] * " 256KB") && (k2 += 1)
end
let s = samples("long", "string", 128)
    s === nothing || (survival!(ax2, exc(s), CC["string"], LL["string"] * " 64KB") && (k2 += 1))
end
k2 > 0 && (ylims!(ax2, 3e-4, 1.2); axislegend(ax2, position = :lb, framevisible = false, labelsize = 10))
drawn += k2

# The cadence itself: what matters is not where the peak sits but how tightly the mass gathers.
ax3 = Axis(fig3[2, 1], yscale = log10, xlabel = "inter-arrival gap (ms)", ylabel = "frames",
           title = "jitter · cadence distribution")
k3 = 0
for m in ("binary_ref", "binary_snap")
    s = samples("jitter", m, 128); s === nothing && continue
    g = filter(x -> 0 < x < 12, Float64.(s["gap_ms"])); isempty(g) && continue
    stephist!(ax3, g; bins = 120, color = CC[m], label = LL[m], linewidth = 1.6); k3 += 1
end
k3 > 0 && axislegend(ax3, position = :rt, framevisible = false, labelsize = 11)
drawn += k3

# Deviation from the run's OWN median cadence — jitter with the pace divided out, so the modes are
# compared on how much they wander rather than on where they settled.
ax4 = Axis(fig3[2, 2], xscale = log10, yscale = log10, xlabel = "|gap − median gap| (ms)",
           ylabel = "fraction larger", title = "jitter · deviation from own cadence")
k4 = 0
for m in ("binary_ref", "binary_snap")
    s = samples("jitter", m, 128); s === nothing && continue
    g = Float64.(s["gap_ms"]); isempty(g) && continue
    survival!(ax4, abs.(g .- median(g)), CC[m], LL[m]) && (k4 += 1)
end
k4 > 0 && (ylims!(ax4, 5e-5, 1.2); axislegend(ax4, position = :lb, framevisible = false, labelsize = 11))
drawn += k4

drawn == 0 ? "no long/jitter data collected — run those sweeps" : fig3

#%% code id=rate_frame
# The rate sweep, laid side by side. `pace = 0` is flat out; everything else is a requested cadence
# the deadline pacer actually hits, so `achieved fps` is a check on the pacer as much as on the
# transport. Modes alternated order per rate, so a consistent gap here is not warm-up.
#
# A run whose tally never arrived is UNKNOWN, not zero. Above the ceiling the `<channel>:done` frame
# rides the same bounded queue as the data, so the report of a saturated run is the thing most likely
# to be dropped — and `sent` then falls back to what arrived, which reads as a perfect run. Both
# columns say `missing` there rather than dividing by a zero duration (which crashed this cell) or
# printing a zero drop rate for a run that lost most of its frames.
RATE = let rows = []
    for (key, s) in E2E_SAMPLES
        s["tag"] == "rate" || continue
        dt = Float64.(s["dt_ms"]); isempty(dt) && continue
        ex = dt .- minimum(dt); gaps = Float64.(s["gap_ms"])
        told = s["send_ms"] > 0                    # did the run report itself?
        push!(rows, (
            pace_ms = s["pace_ms"], mode = s["mode"],
            req_fps = s["pace_ms"] > 0 ? round(Int, 1000 / s["pace_ms"]) : 0,
            sent = told ? s["frames"] : missing, recv = s["recv"],
            dropped = told ? s["dropped"] : missing,
            drop_pct = told ? round(100 * s["dropped"] / max(1, s["frames"]), digits = 2) : missing,
            sent_fps = told ? round(Int, s["frames"] / (s["send_ms"] / 1000)) : missing,
            MBps = round(s["recv"] * s["n"]^2 * 4 / 1e6 / (s["span_ms"] / 1000), digits = 1),
            p50 = round(qt(ex, 0.50), digits = 3), p99 = round(qt(ex, 0.99), digits = 2),
            p999 = round(qt(ex, 0.999), digits = 2), max = round(maximum(ex), digits = 1),
            gap_p50 = round(qt(gaps, 0.50), digits = 3),
        ))
    end
    sort!(DataFrame(rows), [:pace_ms, :mode], rev = [true, false])
end

# The comparison, per rate: how much worse copying is on each axis. >1 means by-reference wins.
RATE_X = let
    a = filter(r -> r.mode == "binary_ref", RATE); b = filter(r -> r.mode == "binary_snap", RATE)
    j = innerjoin(a, b, on = [:pace_ms, :req_fps], makeunique = true)
    DataFrame(pace_ms = j.pace_ms, req_fps = j.req_fps,
              fps_ref = j.sent_fps, fps_snap = j.sent_fps_1,
              MBps_ref = j.MBps, MBps_snap = j.MBps_1,
              drop_ref = j.drop_pct, drop_snap = j.drop_pct_1,
              p99_ref = j.p99, p99_snap = j.p99_1,
              MBps_gain = round.(j.MBps ./ j.MBps_1, digits = 2))
end

#%% code id=rate_plots
# Flat out has no requested rate, so it is placed on the axis at the highest achieved rate and marked
# separately — plotting it as "0 fps requested" would put the most interesting point at the origin.
#
# A run whose tally was lost has no `sent_fps` and no `drop_pct` (see `rate_frame`), and that is
# exactly the saturated end of this sweep — so those points are DROPPED from the series rather than
# coerced. A gap in a line is honest about a run that could not report itself; a zero would draw a
# saturated run as a perfect one.
told(d) = filter(r -> !ismissing(r.sent_fps), d)
paced_r = sort(filter(r -> r.pace_ms > 0, RATE), :req_fps)
flat_r  = told(filter(r -> r.pace_ms == 0, RATE))

fig4 = Figure(size = (1150, 420))

ax1 = Axis(fig4[1, 1], xscale = log10, yscale = log10, xlabel = "requested fps",
           ylabel = "MB/s delivered", title = "delivered throughput tracks the request…")
for m in ("binary_ref", "binary_snap")
    d = filter(r -> r.mode == m, paced_r)          # MB/s comes from arrivals, so every run has it
    scatterlines!(ax1, Float64.(d.req_fps), d.MBps; color = CC[m], label = LL[m], markersize = 9)
    f = filter(r -> r.mode == m, flat_r)
    isempty(f) || scatter!(ax1, [Float64(f.sent_fps[1])], [f.MBps[1]];
                           color = CC[m], marker = :star5, markersize = 18)
end
axislegend(ax1, position = :lt, framevisible = false, labelsize = 11)

ax2 = Axis(fig4[1, 2], xscale = log10, xlabel = "requested fps", ylabel = "% frames dropped",
           title = "…until the transport saturates")
for m in ("binary_ref", "binary_snap")
    d = told(filter(r -> r.mode == m, paced_r))
    scatterlines!(ax2, Float64.(d.req_fps), Float64.(d.drop_pct); color = CC[m], label = LL[m], markersize = 9)
    f = filter(r -> r.mode == m, flat_r)
    isempty(f) || scatter!(ax2, [Float64(f.sent_fps[1])], [Float64(f.drop_pct[1])];
                           color = CC[m], marker = :star5, markersize = 18)
end
axislegend(ax2, position = :lt, framevisible = false, labelsize = 11)

# The one axis where the modes genuinely differ: what the SENDER can produce when nothing is holding
# it back. Stars are the flat-out runs; the paced points sit on the diagonal because the pacer hit
# every rate it was asked for.
ax3 = Axis(fig4[1, 3], xscale = log10, yscale = log10, xlabel = "requested fps",
           ylabel = "achieved fps", title = "sender capacity (★ = flat out)")
lines!(ax3, [400.0, 5e4], [400.0, 5e4]; color = :gray, linestyle = :dash, label = "requested")
for m in ("binary_ref", "binary_snap")
    d = told(filter(r -> r.mode == m, paced_r))
    scatterlines!(ax3, Float64.(d.req_fps), Float64.(d.sent_fps); color = CC[m], label = LL[m], markersize = 9)
    f = filter(r -> r.mode == m, flat_r)
    isempty(f) || scatter!(ax3, [4e4], [Float64(f.sent_fps[1])];
                           color = CC[m], marker = :star5, markersize = 18)
end
axislegend(ax3, position = :lt, framevisible = false, labelsize = 10)

fig4

#%% code id=opt_frame
# SUPERSEDED IN PART — see "What the clock work invalidates above". `floor_rel` below assumes the
# clock offset holds still between runs so that floors are comparable. The calibration work showed it
# does not: the offset wanders by up to 0.8 ms within a two-second run. The column reads as a time
# trend — floors fall monotonically as `n` rises, and the sweep ran `n` ascending, which would make
# larger frames arrive sooner. It is kept for the shape of the sweep, not as a floor ranking.
#
# `spread50` / `spread99` are the quantile above each run's OWN minimum. Those are within-run, so
# they carry only the wander accumulated over one short run, and they remain the usable columns here.
#
# `fps` is `missing` for a run whose tally never came back — the `<channel>:done` frame rides the
# same droppable queue as the data, so a saturated run loses the message that would have described
# it. Dividing by that zero duration is what used to error this cell out.
OPT = let rows = []
    for (key, s) in E2E_SAMPLES
        s["tag"] == "opt" || continue
        dt = Float64.(s["dt_ms"]); isempty(dt) && continue
        push!(rows, (
            n = s["n"], KB = round(s["n"]^2 * 4 / 1024, digits = 1), pace_ms = s["pace_ms"],
            fps = s["send_ms"] > 0 ? round(Int, s["frames"] / (s["send_ms"] / 1000)) : missing,
            yield = get(s, "yield", true), frames = s["frames"],
            floor_ms = minimum(dt), p50_ms = qt(dt, 0.50), p99_ms = qt(dt, 0.99),
            spread50 = qt(dt, 0.50) - minimum(dt),      # typical frame, above the floor
            spread99 = qt(dt, 0.99) - minimum(dt),
        ))
    end
    df = DataFrame(rows)
    # An empty frame is what you get before the sweep has been run, and it is not an error: say so
    # rather than failing on a column that cannot exist yet.
    isempty(df) ? df : begin
        base = minimum(df.floor_ms)
        df.floor_rel = round.(df.floor_ms .- base, digits = 3)   # not a floor ranking — see above
        select!(df, [:n, :KB, :pace_ms, :fps, :yield, :frames, :floor_rel,
                     :spread50, :spread99, :p50_ms, :p99_ms])
        sort!(df, [:yield, :n, :pace_ms], rev = [true, false, true])
    end
end
isempty(OPT) ? "no opt data collected — run that sweep" : select(OPT, Not([:p50_ms, :p99_ms]))

#%% code id=opt_analysis
# The floor turned out to be unusable, and it is worth keeping the evidence rather than the
# conclusion: raw `arrival − send` ranges from +0.5 to −2.4 ms across this sweep, and a NEGATIVE
# value means the frame arrived before it was sent. That is not a measurement, it is the two clocks
# disagreeing — and the disagreement drifts by nearly 3 ms over a minute, which is larger than
# anything being compared. Absolute latency across these two processes needs a round-trip
# calibration; the notebook does not have one, so it does not claim one.
#
# What survives is every statistic taken WITHIN a run, where the offset is common to all frames and
# cancels. `spread50` is the typical frame's cost above that run's own best, `spread99` the tail's.
BY_RATE = combine(groupby(filter(r -> r.yield, OPT), [:pace_ms, :fps]),
                  :spread50 => (x -> round(mean(x), digits = 3)) => :spread50_mean,
                  :spread99 => (x -> round(mean(x), digits = 2)) => :spread99_mean,
                  :spread50 => (x -> round(maximum(x), digits = 3)) => :spread50_worst)
sort!(BY_RATE, :fps)

# The `yield` tweak: same size, same rate, alternated so warm-up cannot masquerade as the result.
YIELD = combine(groupby(filter(r -> r.n == 64 && r.pace_ms == 2.0, OPT), :yield),
                nrow => :runs,
                :spread50 => (x -> round(mean(x), digits = 3)) => :spread50,
                :spread99 => (x -> round(mean(x), digits = 2)) => :spread99)

(by_rate = BY_RATE, yield_tweak = YIELD)

#%% code id=opt_plot
fig5 = Figure(size = (1150, 400))
SZC = Dict(16 => :cyan, 32 => :orange, 64 => :hotpink, 128 => :yellowgreen)

# Both statistics against send rate. The floor is deliberately absent — see the note above; these are
# costs ABOVE each run's own best frame, which is the part the clocks cannot corrupt.
for (col, stat, ttl) in ((1, :spread50, "typical frame (p50 − floor)"),
                         (2, :spread99, "tail (p99 − floor)"))
    ax = Axis(fig5[1, col], xscale = log10, yscale = log10, xlabel = "send rate (fps)",
              ylabel = "ms above the run's own floor", title = ttl)
    for n in (16, 32, 64, 128)
        d = sort(filter(r -> r.n == n && r.yield, OPT), :fps)
        isempty(d) && continue
        scatterlines!(ax, Float64.(d.fps), max.(d[!, stat], 1e-3);
                      color = SZC[n], label = "$(n)×$(n)", markersize = 9)
    end
    col == 1 && axislegend(ax, position = :lt, framevisible = false, labelsize = 10)
end

# The mean across sizes, which is where the shape is easiest to see: flat and low to ~250 fps, then
# climbing once the pipeline starts queueing.
ax3 = Axis(fig5[1, 3], xscale = log10, yscale = log10, xlabel = "send rate (fps)",
           ylabel = "ms above floor", title = "mean across sizes")
scatterlines!(ax3, Float64.(BY_RATE.fps), BY_RATE.spread50_mean; color = :cyan,
              label = "p50", markersize = 10)
scatterlines!(ax3, Float64.(BY_RATE.fps), BY_RATE.spread99_mean; color = :orange,
              label = "p99", markersize = 10)
vlines!(ax3, [250.0]; color = :white, linestyle = :dash)
text!(ax3, 260, 0.3; text = "sweet spot", color = :white, fontsize = 11)
axislegend(ax3, position = :lt, framevisible = false, labelsize = 11)

fig5

#%% code id=clock_frame
# With the clocks tied together, absolute latency is finally a real quantity.
#
#   dt_i        = arrival(client) − send(server)      — carries the offset
#   offset(τ)   = interpolated between the calibrations bracketing the run
#   latency_i   = dt_i + offset(τ_i)
#
# The offset moved by up to 0.8 ms WITHIN a two-second run, so interpolating across it is not a
# refinement — a single calibration would leave a drift of that size smeared through the numbers,
# which is the same order as the latency being measured.
CLOCK = let rows = []
    for (key, s) in E2E_SAMPLES
        s["tag"] == "clock" || continue
        dt = Float64.(s["dt_ms"]); at = Float64.(s["at_ms"])
        (isempty(dt) || length(at) != length(dt)) && continue
        off0, off1 = s["off0"], s["off1"]
        span = max(1e-9, at[end] - at[1])
        lat = [dt[i] + off0 + (off1 - off0) * (at[i] - at[1]) / span for i in eachindex(dt)]
        push!(rows, (
            pace_ms = s["pace_ms"], fps = round(Int, s["frames"] / (s["send_ms"] / 1000)),
            rep = parse(Int, last(split(key, "|"))), frames = s["frames"],
            # absolute one-way latency, worker → hub → browser
            min = round(minimum(lat), digits = 3), p50 = round(qt(lat, 0.50), digits = 3),
            p95 = round(qt(lat, 0.95), digits = 3), p99 = round(qt(lat, 0.99), digits = 3),
            drift_ms = round(off1 - off0, digits = 3), rtt = round(s["rtt0"], digits = 2),
        ))
    end
    sort!(DataFrame(rows), [:fps, :rep])
end

# Averaged over repetitions, which is what the reps were for.
CLOCK_SUM = combine(groupby(CLOCK, [:pace_ms, :fps]), nrow => :runs,
                    :min => (x -> round(mean(x), digits = 3)) => :min_ms,
                    :p50 => (x -> round(mean(x), digits = 3)) => :p50_ms,
                    :p95 => (x -> round(mean(x), digits = 3)) => :p95_ms,
                    :p99 => (x -> round(mean(x), digits = 3)) => :p99_ms)
(runs = CLOCK, summary = sort(CLOCK_SUM, :fps))

#%% code id=clock_final
# Corrected latencies still land around −2.7 ms, and a negative one-way latency is impossible — so a
# constant bias survives the calibration. The cause is that Cristian's estimator assumes the two
# halves of its round trip are equal, and here they are not comparable to the path being measured at
# all: the calibration rides REQ/REP through the gate, while a frame rides PUB → poller → broadcast
# queue → socket. Halving one and applying it to the other imports the difference as a constant.
#
# Drift is genuinely fixed — that was the part that varied and it now interpolates away. What remains
# is an unknown ZERO, and the standard treatment is a minimum filter: the fastest frame observed
# anywhere in the sweep is the one that queued least, so take it as the origin. What that buys is
# "how much worse than the best this path can do", measured on one consistent scale across rates.
FLOOR = minimum(CLOCK.min)

FINAL = let d = combine(groupby(CLOCK, [:pace_ms, :fps]), nrow => :runs,
                        :p50 => (x -> round(mean(x) - FLOOR, digits = 3)) => :p50_above,
                        :p95 => (x -> round(mean(x) - FLOOR, digits = 3)) => :p95_above,
                        :p99 => (x -> round(mean(x) - FLOOR, digits = 3)) => :p99_above)
    # 498/500 and 995/1000 are the same requested rate, so fold them together.
    d.rate = round.(Int, 1000 ./ d.pace_ms)
    combine(groupby(d, :rate), :runs => sum => :runs,
            :p50_above => (x -> round(mean(x), digits = 3)) => :p50_above,
            :p95_above => (x -> round(mean(x), digits = 3)) => :p95_above,
            :p99_above => (x -> round(mean(x), digits = 3)) => :p99_above) |>
        d -> sort!(d, :rate)
end

#%% md id=method_revision
@md"""
## What the clock work invalidates above

The calibration was added to answer "what is the absolute latency". It also answered a question that
was not asked: **the inter-process offset is not constant.** It moves by up to 0.8 ms within a
two-second run, sign varying — part genuine drift, part calibration noise (the estimator's own RTT
is ~7 ms, so an individual offset sample is worth about a millisecond). Either way it is the same
order as the latency being measured, and every cell above predates knowing that.

**Superseded — `opt_frame`'s `floor_rel` column.** It compares each run's minimum `dt` against the
best in the sweep, which is only meaningful if the offset holds still between runs. It does not. The
evidence is in that column itself: `floor_rel` falls monotonically with frame size, so a 1 KB frame
appears to arrive 2.8 ms *later* than a 64 KB one. Larger frames cannot be faster. The sweep ran `n`
ascending, so the column is reading elapsed time, not transport. Everything derived from it —
`opt_analysis`'s floor ranking, the floor series in `opt_plot` — inherits the artefact. The
`spread50` / `spread99` columns beside it are within-run and stand.

**Weakened — the 30-second jitter runs.** Within-run wander scales with duration, so the longest
runs carry the most of it, and they are the ones the tail claims lean on. The cadence result (no
periodic structure, no banding) is unaffected — that is measured on arrival gaps, which never touch
the sender's clock. The p95/p99 excess figures should be read as upper bounds.

**Unaffected.** `e2e_frame` and `rate_frame` subtract a per-run minimum on short paced runs, and
compare modes within a run; `sweep`/`frame`/`headline` are single-process send-side timings with no
second clock in them at all.

**Still open — the absolute zero.** Cristian's estimator assumes its round trip is symmetric, and
here the two halves are not even the same transport: calibration rides REQ/REP through the gate, a
frame rides PUB → poller → broadcast queue → socket. That imports a constant bias, which is why the
corrected numbers land at an impossible −2.7 ms and why `clock_final` falls back to a minimum
filter. The rate comparison is sound on one consistent scale; the origin is not established.
"""

#%% md id=e2e_findings
@md"""
## What the full path says

Measured after the hub stopped spinning between frames — see the note below, because everything on
this page changed when it did.

**There is no knee any more.** The old shape of this result was a cliff: fine to 250 frames a second,
and past 500 the tail went from about a millisecond to nearly thirty. That was never the transport.
The hub's threads spun for 4ms after each wake, betting more work was coming, and above 500 fps the
frames arrived faster than the bet expired — so twelve threads spun continuously to move a few
hundred bytes at a time. With them parking instead, the same 500 fps run goes from a p99 of 28.6ms to
1.2ms, and 1000 fps from 29.5ms to 3.7ms.

**The median is flat, and that is the real headline.** From 250 to 4000 frames a second the typical
frame takes about half a millisecond above the floor — the rate barely enters into it. The tail grows
gently rather than suddenly: p99 goes 1.2 → 3.7 → 5.7 → 7.0 → 10.9ms across 500 → 8000 fps. There is
no rate in that range where the system stops behaving, which is a different kind of statement from a
faster one.

**The best point is now 500 fps**, on every statistic — and the "250 sweet spot" this page used to
report was an artefact of sitting just below the cliff, not a property worth designing to.

**The ceiling is about 16,000 frames a second** at 16KB a frame — 256 MB/s — and it is a real edge:
one run there lost 0.84% and its repeat lost nothing. Below it, nothing is lost at any rate.

**Past the ceiling it does not degrade, it collapses.** Asking for 33,000 fps delivers FEWER frames
than asking for 16,000 — a couple of thousand rather than thirty-two thousand — and the run returns
no tally at all. Which exposes something worth fixing: the `<channel>:done` tally rides the same
bounded queue as the data, so the one condition where you most need to know how much was lost is the
condition where the message carrying that number is most likely to be dropped. Every run above the
ceiling therefore reports "0 dropped", because `sent` falls back to what arrived. A missing tally
means UNKNOWN, and this page should say so rather than print a zero.

### What this leaves of the earlier comparisons

The by-reference versus copied comparison, and the conclusion that copying bought nothing when paced,
were measured when the transport was the bottleneck and the payload copy was significant against it.
That balance is gone: at these rates the wire is no longer what limits anything below 16k fps. The
comparison needs re-running before it means anything.

Absolute latency is still not answerable here. The numbers above are excess over the fastest frame
observed, because the clock calibration rides REQ/REP through the gate while a frame rides
PUB → poller → socket, and Cristian's estimator assumes those two halves are equal. The corrected
figures still land near −3ms, which is impossible, so the origin remains unestablished — see the
first item under next steps.
"""

#%% md id=next_steps
@md"""
## Next steps

Roughly in order of what each one buys.

**1. Establish the zero by calibrating on the frame path.** The remaining bias exists because the
calibration and the measurement take different routes. Emit a token through `slate_emit` and time it
against the `slateCall` reply that acknowledges it: two equations, two unknowns, and the outbound
leg is separable instead of assumed to be half the round trip. This is the one that turns "0.594 ms
above the floor" into a latency.

**2. Re-run the `opt` sweep with calibration bracketing.** The floor comparison it was built for is
not recoverable from the stored samples — the runs would have to be redone with `off0`/`off1`
captured the way the `clock` sweep does. Randomise the size order while doing it, so a residual time
trend cannot masquerade as a size effect a second time.

**3. Settle the `yield` knob.** The storage key now carries a repetition index, so the arms no longer
overwrite each other; the earlier comparison was one sample per arm and means nothing. A 30-second
run per arm at the 250 fps sweet spot decides it.

**4. Characterise the 500 fps knee.** p99 goes from 1.2 ms to 28 ms between 250 and 500 fps, a 24×
step for a 2× rate. A step that sharp is a queue crossing a threshold, not a gradual saturation —
worth finding which one. The bounded per-socket WS queue and the poller's batching are the
candidates.

**5. Alternate mode order within the paced comparison.** Recorded as a caveat under the e2e findings
and still unaddressed there: by-reference always ran first, so the copy's marginally better tail is
confounded with warm-up. The rate sweep already alternates; the paced runs do not.
"""

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   CairoMakie 0.15.13 13f3f980-e62b-5c42-98c6-ff1f3baf88f0
#   DataFrames 1.8.2 a93c6f00-e57d-5684-b7b6-d8193f3e46c0
#   Printf 1.11.0 de0858da-6303-5e67-8744-51eddeeeb8d7
#   Statistics 1.11.1 10745b16-79ce-11e8-11f9-7d13ad32a3b2
# ╚═╡
# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 21e8a3c1-4471-4304-a10b-00e05eeb0cfc
# ╚═╡

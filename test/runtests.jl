using SlateBench
using Test

# Time `f` `n` times, returning the median elapsed milliseconds. Median, not mean: these run on a
# shared machine where GC and scheduler preemption produce occasional multi-millisecond outliers that
# a mean would absorb into a false failure.
function median_ms(f, n)
    samples = map(1:n) do _
        t = time_ns()
        f()
        (time_ns() - t) / 1e6
    end
    sort!(samples)
    isodd(n) ? samples[(n + 1) ÷ 2] : (samples[n ÷ 2] + samples[n ÷ 2 + 1]) / 2
end

@testset "SlateBench" begin
    @testset "pace" begin
        SlateBench.pace(1.0)   # warm up: keep compilation out of the first measured sample

        # The regression this guards: `sleep` has a ~1ms floor, so a naive pacer turns ANY non-zero
        # delay into milliseconds and clamps the benchmark to a few hundred fps regardless of the
        # requested rate. Bounds are deliberately loose — an order of magnitude above the observed
        # accuracy — so they catch a return to sleep-floor behaviour without going flaky on timing
        # jitter. The point is the floor is gone, not that any particular precision is hit.
        @test median_ms(() -> SlateBench.pace(0.01), 200) < 0.5
        @test median_ms(() -> SlateBench.pace(0.1), 200) < 1.0

        # Sub-spin-threshold delays are spun, so they should track the request closely.
        @test 1.0 <= median_ms(() -> SlateBench.pace(1.0), 100) < 2.0

        # Above the spin threshold the deadline loop sleeps in chunks, then spins the remainder;
        # it must still not undershoot, and must not overshoot the way a bare `sleep` does.
        @test 10.0 <= median_ms(() -> SlateBench.pace(10.0), 20) < 13.0

        # A pacer must never return early — the deadline is a floor, whichever path is taken.
        for ms in (0.01, 0.5, 5.0)
            t = time_ns()
            SlateBench.pace(ms)
            @test (time_ns() - t) / 1e6 >= ms
        end

        @test SlateBench.pace(0.0) === nothing   # degenerate delay returns immediately
    end

    @testset "run supersede" begin
        # A stream reports what it ACTUALLY sent, not what was requested. When a newer run takes over,
        # the old loop must stop rather than keep flooding the receiver — and its abandoned frames must
        # not be counted as sent, or they would show up as drops.
        SlateBench.CURRENT_RUN[] = 2
        r = SlateBench.run_stress("test_probe", 4, 10_000, 0.0, 1, true)   # run 1 is already stale
        @test r.sent == 0
        @test r.bytes_per_frame == 4 * 4 * 4
    end
end

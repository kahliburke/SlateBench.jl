try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% code id=5151b2
using SlateBench

#%% code id=dash
bench_stream(n = 64, frames = 3000)

#%% code id=c11d94 hidecode
using Base64, Dates
let ffmpeg = "/opt/homebrew/bin/ffmpeg", ffprobe = "/opt/homebrew/bin/ffprobe"
    dur(p) = try; parse(Float64, strip(read(`$ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p`, String))); catch; -1.0; end
    bufs = Dict{String,IOBuffer}()
    slate_on("clip_begin", a -> (bufs[String(a.id)] = IOBuffer(); (ok = true)))
    slate_on("clip_chunk", a -> (write(get!(bufs, String(a.id), IOBuffer()), String(a.data)); (ok = true)))
    slate_on("clip_end", a -> begin
        id = String(a.id); mime = String(get(a, :mime, "video/webm"))
        buf = get(bufs, id, nothing); buf === nothing && return (ok = false, error = "no buffer")
        b64 = String(take!(buf)); delete!(bufs, id)
        ext = occursin("mp4", mime) ? "mp4" : "webm"; bytes = base64decode(b64)
        ts = Dates.format(now(), "yyyymmdd-HHMMSS"); dir = expanduser("~/Downloads")
        raw = joinpath(dir, "slate-rec-$ts-raw.$ext"); out = joinpath(dir, "slate-rec-$ts.mp4")
        write(raw, bytes); dr = dur(raw)
        ok = try; run(`$ffmpeg -y -loglevel error -fflags +genpts -i $raw -c:v libx264 -pix_fmt yuv420p -crf 23 -fps_mode cfr -r 30 -movflags +faststart $out`); true; catch e; @warn e; false; end
        dout = ok ? dur(out) : -1.0; ok && rm(raw; force = true)
        (ok = ok, path = (ok ? out : raw), mb = round(length(bytes)/1e6, digits = 1), raw_dur = round(dr, digits = 2), out_dur = round(dout, digits = 2))
    end)
end
"screen-record handlers registered (bookmarklet)"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 28370534-b4e4-4f58-808f-8223f3dfb604
# ╚═╡

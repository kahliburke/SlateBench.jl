try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% code id=5151b2
using SlateBench

#%% code id=dash
bench_stream(n = 64, frames = 3000)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 28370534-b4e4-4f58-808f-8223f3dfb604
# ╚═╡

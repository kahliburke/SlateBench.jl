// SlateBench dashboard — a live streaming-transport benchmark for a `StreamBench` output value. Registered
// as a `slateRegisterWidget` component (it owns canvases). `wire(el, api)`: `api.params` carries the config
// (channel/n/frames/delayMs); ▶ Run calls `api.call(channel+":run", …)` while `slateOnStream(channel)`
// receives the frames. Stream processing (counting, stats) is decoupled from rendering (a rAF loop draws
// the field + charts), so render cost never skews the transport throughput number.
(() => {
  const C = {                                       // palette — cohesive on near-black
    bg: "#0a0d14", panel: "#0d1117", grid: "#20283a",
    dim: "#8a93b0", text: "#cdd3e6",
    thru: "#7ee787", fps: "#56d4dd", lat: "#e3b341", drop: "#f85149",
  };
  const fmt = (v, d = 1) => (v == null || !isFinite(v)) ? "—" : v.toFixed(d);
  const pctile = (sorted, p) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : NaN;

  // ── canvas chart primitives ──────────────────────────────────────────────
  function clear(cx, w, h) { cx.fillStyle = C.panel; cx.fillRect(0, 0, w, h); }
  function label(cx, s, x, y, col) { cx.fillStyle = col || C.dim; cx.font = "10px ui-monospace,monospace"; cx.fillText(s, x, y); }

  // filled area sparkline (autoscaled), for the throughput timeline
  function area(cx, w, h, data, col, title) {
    clear(cx, w, h);
    const pad = 16, x0 = 4, x1 = w - 4, y0 = h - 12, y1 = 4;
    const max = Math.max(1e-9, ...data);
    label(cx, title, 4, 10, C.dim);
    label(cx, fmt(max, max < 10 ? 1 : 0), w - 34, 10, col);
    if (data.length < 2) return;
    const X = i => x0 + (x1 - x0) * i / (data.length - 1);
    const Y = v => y0 - (y0 - y1) * Math.max(0, v) / max;
    cx.beginPath(); cx.moveTo(X(0), y0);
    data.forEach((v, i) => cx.lineTo(X(i), Y(v)));
    cx.lineTo(X(data.length - 1), y0); cx.closePath();
    const g = cx.createLinearGradient(0, y1, 0, y0);
    g.addColorStop(0, col + "55"); g.addColorStop(1, col + "08"); cx.fillStyle = g; cx.fill();
    cx.beginPath(); data.forEach((v, i) => i ? cx.lineTo(X(i), Y(v)) : cx.moveTo(X(i), Y(v)));
    cx.strokeStyle = col; cx.lineWidth = 1.5; cx.stroke();
  }

  // histogram with p50/p95 markers, for a distribution (latency drift, jitter)
  function hist(cx, w, h, samples, col, title, unit) {
    clear(cx, w, h);
    label(cx, title, 4, 10, C.dim);
    if (samples.length < 4) return;
    const s = samples.slice().sort((a, b) => a - b);
    const lo = s[0], hi = Math.max(s[s.length - 1], lo + 1e-9);
    const NB = 26, bins = new Array(NB).fill(0);
    for (const v of s) bins[Math.min(NB - 1, Math.floor((v - lo) / (hi - lo) * NB))]++;
    const bmax = Math.max(...bins);
    const x0 = 4, x1 = w - 4, y0 = h - 12, y1 = 16, bw = (x1 - x0) / NB;
    bins.forEach((b, i) => {
      const bh = (y0 - y1) * b / bmax;
      cx.fillStyle = col + "cc"; cx.fillRect(x0 + i * bw + 0.5, y0 - bh, bw - 1, bh);
    });
    const p50 = pctile(s, 0.5), p95 = pctile(s, 0.95);
    const mark = (v, c, lab) => {
      const x = x0 + (x1 - x0) * (v - lo) / (hi - lo);
      cx.strokeStyle = c; cx.lineWidth = 1; cx.beginPath(); cx.moveTo(x, y1); cx.lineTo(x, y0); cx.stroke();
      label(cx, lab, Math.min(w - 26, x + 2), y1 + 8, c);
    };
    mark(p50, C.text, "p50"); mark(p95, C.drop, "p95");
    label(cx, fmt(lo) + unit, 4, y0 + 10, C.dim);
    label(cx, fmt(hi) + unit, w - 40, y0 + 10, C.dim);
  }

  const colorize = v => { const t = Math.max(0, Math.min(1, (v + 1.6) / 3.2));
    return [Math.round(30 + t * t * 220), Math.round(50 + t * 190), Math.round(110 + (1 - t) * 110)]; };

  // ── the widget ────────────────────────────────────────────────────────────
  function mount(el, api) {
    const p = (api && api.params) || {}, channel = p.channel || "bench";
    el.innerHTML = `
      <div class="sb">
        <div class="sb-row">
          <label>grid n</label><input class="sb-n" type="number" value="${p.n||64}" min="16" max="512" step="16">
          <label>frames</label><input class="sb-f" type="number" value="${p.frames||2000}" min="100" step="100">
          <label>delay ms</label><input class="sb-d" type="number" value="${p.delayMs||0}" min="0" step="1">
          <label class="sb-binlab"><input class="sb-bin" type="checkbox" checked> binary</label>
          <label class="sb-binlab sb-snaplab" title="copy the field per frame instead of sending it by reference — only the binary path has the choice; JSON always copies"><input class="sb-snap" type="checkbox"> snapshot</label>
          <button class="sb-go">▶ Run</button>
          <span class="sb-path">path: binary · by ref</span>
        </div>
        <div class="sb-main">
          <canvas class="sb-field" width="64" height="64" title="the streamed field"></canvas>
          <div class="sb-kpis">
            <div class="sb-tile"><span>recv fps</span><b class="k_fps" style="color:${C.fps}">—</b></div>
            <div class="sb-tile"><span>float MB/s</span><b class="k_mbs" style="color:${C.thru}">—</b></div>
            <div class="sb-tile"><span>drop rate</span><b class="k_drop" style="color:${C.drop}">—</b></div>
            <div class="sb-tile"><span>p95 latency</span><b class="k_p95" style="color:${C.lat}">—</b></div>
          </div>
        </div>
        <div class="sb-charts">
          <canvas class="sb-thru" width="330" height="76"></canvas>
          <canvas class="sb-lat"  width="220" height="76"></canvas>
          <canvas class="sb-iat"  width="220" height="76"></canvas>
        </div>
        <div class="sb-foot"><span class="sb-sum"></span></div>
      </div>`;
    _injectCSS();
    const q = s => el.querySelector(s);
    const field = q(".sb-field"), fcx = field.getContext("2d");
    const thruCx = q(".sb-thru").getContext("2d"), latCx = q(".sb-lat").getContext("2d"), iatCx = q(".sb-iat").getContext("2d");
    let img = fcx.createImageData(64, 64), gridN = 64, latest = null, dirty = false;

    let S = null, runSeq = 0;
    const resetStats = n => {
      gridN = n; field.width = n; field.height = n; img = fcx.createImageData(n, n);
      S = { recv: 0, first: null, last: null, lastIdx: 0, gaps: 0, offset: null, latMax: 0,
            lat: [], iat: [], thru: [], bucket: null, bucketBytes: 0, prev: null,
            emitDone: false, finalized: false, lastFrame: 0, final: null, ack: null, error: null };
    };

    // stream handler — CHEAP: count + collect, no render (keeps transport measurement clean)
    const WARMUP = 10;   // first frames carry JIT/connection/buffer warm-up — excluded from latency + jitter
    window.slateOnStream && window.slateOnStream(channel, msg => {
      if (!S || S.finalized || msg.r !== S.runId) return;   // ignore frames draining from a prior run
      S.lastFrame = performance.now();
      const now = performance.now() / 1000, d = msg.d, i = msg.i;
      latest = d; dirty = true;
      if (S.first === null) { S.first = now; S.bucket = now; }
      if (i > S.lastIdx + 1) S.gaps += i - S.lastIdx - 1;
      S.lastIdx = i; S.recv++;
      const warm = S.recv > WARMUP;
      if (S.prev !== null && warm) S.iat.push((now - S.prev) * 1000);
      S.prev = now; S.last = now;
      warm && S.lat.push((now - msg.t) * 1000);   // raw one-way delta (ms), post-warmup; min-anchored at display
      // throughput bucket (100ms): float bytes/sec
      S.bucketBytes += d.length * 4;
      if (now - S.bucket >= 0.1) { S.thru.push(S.bucketBytes / (now - S.bucket) / 1e6); S.bucket = now; S.bucketBytes = 0; }
    });

    // Emission finished — the tally arrives as an EVENT, not as the ▶ Run RPC's return value, so a run
    // that outlasts the RPC timeout still reports its statistics instead of failing (see `start_run`).
    window.slateOnStream && window.slateOnStream(channel + ":done", msg => {
      if (!S || S.finalized || msg.r !== S.runId) return;   // a superseded run's tally is not ours
      S.emitDone = true;
      S.final = msg.ok === false ? null : msg;
      if (msg.ok === false) S.error = msg.error;
      if (S.lastFrame === 0) S.lastFrame = performance.now();   // arm the drain watchdog even if nothing arrived
    });

    // Latency ABOVE THE FLOOR: each frame's one-way delta minus the smallest observed (which absorbs the
    // unknown send/recv clock offset + the minimum transit). 0 = the fastest frame; growth = the pipeline
    // backing up. Never negative — the fix for the earlier "negative drift".
    const relLat = () => {
      if (!S.lat.length) return [];
      let mn = S.lat[0]; for (const x of S.lat) if (x < mn) mn = x;
      return S.lat.map(x => x - mn);
    };

    // Finalize a run once emission is done AND delivery has drained (async delivery lags a burst) — freeze
    // stats + write the summary. `recv/sent` is the true drop rate; `MB/s delivered` uses the receive window.
    const finalize = () => {
      if (!S || S.finalized) return;
      S.finalized = true;
      const go = q(".sb-go"); go.disabled = false; go.textContent = "▶ Run";
      // Fall back to the ACK's shape if the tally never arrived (worker gone, event lost). The frames
      // we DID receive are still worth reporting — treating a missing tally as a failed run would
      // throw away a whole stream's statistics over a lost final message.
      const r = S.final || (S.ack && S.lastIdx > 0
        ? { sent: S.lastIdx, dur_ms: (S.last && S.first) ? (S.last - S.first) * 1000 : 0,
            bytes_per_frame: S.ack.bytes_per_frame, partial: true }
        : null);
      if (!r) {
        q(".sb-sum").textContent = S.error ? "run failed: " + S.error : "no frames delivered";
        return;
      }
      const elapsed = (S.last && S.first) ? (S.last - S.first) : 0;               // seconds
      const recvMBs = elapsed > 0 ? S.recv * r.bytes_per_frame / elapsed / 1e6 : 0;
      const sorted = relLat().sort((a, b) => a - b);
      q(".sb-sum").innerHTML =
        (r.partial ? `<span style="color:${C.lat}">partial (no final tally)</span> · ` : "") +
        `sent <b>${r.sent}</b> @ ${fmt(r.sent / (r.dur_ms/1000), 0)} fps · recv <b>${S.recv}</b> ` +
        `(<b style="color:${C.drop}">${fmt(100*(1 - S.recv/r.sent),1)}%</b> dropped) · ` +
        `<b style="color:${C.thru}">${fmt(recvMBs,1)} MB/s delivered</b> · ` +
        `lat p50/p95/p99 <b>${fmt(pctile(sorted,.5),0)}/${fmt(pctile(sorted,.95),0)}/${fmt(pctile(sorted,.99),0)} ms</b> · ` +
        `${fmt(r.bytes_per_frame/1024,1)} KB/frame`;
    };

    // render loop — decoupled from stream processing; draws field + charts at ~display rate
    let lastChart = 0;
    const draw = () => {
      if (dirty && latest) {
        const px = img.data;
        for (let k = 0; k < gridN * gridN; k++) { const c = colorize(latest[k]), o = k * 4; px[o]=c[0]; px[o+1]=c[1]; px[o+2]=c[2]; px[o+3]=255; }
        fcx.putImageData(img, 0, 0); dirty = false;
      }
      const t = performance.now();
      if (S && S.emitDone && !S.finalized && t - S.lastFrame > 500) finalize();     // delivery drained
      // Stall watchdog: the tally never came and frames stopped long ago. Without this the button
      // stays disabled forever on a dead worker; finalize() reports what was received.
      if (S && !S.emitDone && !S.finalized && S.lastFrame > 0 && t - S.lastFrame > 5000) finalize();
      if (S && !S.finalized && t - lastChart > 120) {
        lastChart = t;
        area(thruCx, 330, 76, S.thru.slice(-160), C.thru, "throughput  MB/s");
        hist(latCx, 220, 76, relLat(), C.lat, "latency (above floor)", "ms");
        hist(iatCx, 220, 76, S.iat, C.fps, "inter-arrival", "ms");
        const elapsed = (S.last && S.first) ? S.last - S.first : 0, fps = elapsed > 0 ? S.recv / elapsed : 0;
        q(".k_fps").textContent = fmt(fps, 0);
        q(".k_mbs").textContent = fmt(fps * gridN * gridN * 4 / 1e6, 1);
        const sent = S.final ? S.final.sent : S.lastIdx;
        q(".k_drop").textContent = sent > 0 ? fmt(100 * (1 - S.recv / sent), 1) + "%" : "—";
        const sorted = relLat().sort((a, b) => a - b);
        q(".k_p95").textContent = fmt(pctile(sorted, 0.95), 0) + "ms";
      }
      raf = requestAnimationFrame(draw);
    };
    let raf = requestAnimationFrame(draw);
    el._sbStop = () => cancelAnimationFrame(raf);

    // Snapshot is a binary-path choice: JSON copies either way, so the control is disabled there
    // rather than sitting enabled and doing nothing.
    const syncSnap = () => { q(".sb-snap").disabled = !q(".sb-bin").checked; };
    q(".sb-bin").onchange = syncSnap; syncSnap();

    q(".sb-go").onclick = async () => {
      const n = +q(".sb-n").value, frames = +q(".sb-f").value, delayMs = +q(".sb-d").value;
      const bin = q(".sb-bin").checked, snapshot = q(".sb-snap").checked;
      resetStats(n); S.runId = ++runSeq;
      // Name what actually ran: on the binary path the payload handling is half the comparison, and
      // "binary" alone would label two runs with very different costs identically.
      q(".sb-path").textContent = "path: " + (bin ? "binary · " + (snapshot ? "snapshot" : "by ref") : "JSON");
      const go = q(".sb-go"); go.disabled = true; go.textContent = "streaming…"; q(".sb-sum").textContent = "";
      S.ack = { bytes_per_frame: n * n * 4, frames };
      // This RPC spans the WHOLE stream, so on a long or backed-up run it times out in the browser
      // even though the run succeeded. It is therefore only a redundant path: the tally that matters
      // arrives on `<channel>:done` (see `start_run`). A late reply is accepted if the event beat it
      // here; a rejection is recorded but NOT surfaced, since the event carries the real outcome and
      // the drain/stall watchdogs finalize regardless. Only a run that produced nothing at all — no
      // frames, no tally — reports the error, because then it is the only evidence we have.
      const runId = S.runId;
      api.call(channel + ":run", { n, frames, delayMs, run: runId, bin, snapshot }).then(r => {
        if (!S || S.runId !== runId || S.finalized || S.final) return;
        S.emitDone = true; S.final = r;
        if (S.lastFrame === 0) S.lastFrame = performance.now();
      }).catch(e => {
        if (!S || S.runId !== runId) return;
        S.error = (e && e.message) || String(e);
        if (S.lastFrame === 0) S.lastFrame = performance.now();   // arm the stall watchdog
      });
    };
  }

  function _injectCSS() {
    if (document.getElementById("sb-css")) return;
    const s = document.createElement("style"); s.id = "sb-css";
    s.textContent = `
      .sb{font:13px ui-monospace,monospace;color:${C.text}}
      .sb-row{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
      .sb label{color:${C.dim}} .sb-path{color:${C.dim};margin-left:auto;font-size:11px}
      .sb input{width:66px;background:${C.bg};color:${C.text};border:1px solid #30363d;border-radius:5px;padding:3px 6px;font:inherit}
      .sb-go{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:6px 16px;cursor:pointer;font:inherit}
      .sb-go:disabled{opacity:.5;cursor:default}
      .sb-binlab{display:flex;align-items:center;gap:5px} .sb-binlab input{width:auto}
      .sb-binlab:has(input:disabled){opacity:.45}
      .sb-main{display:flex;gap:14px;align-items:stretch;margin-bottom:10px}
      .sb-field{width:150px;height:150px;image-rendering:pixelated;border-radius:8px;border:1px solid #21262d;background:${C.bg}}
      .sb-kpis{flex:1;display:grid;grid-template-columns:1fr 1fr;gap:8px}
      .sb-tile{background:${C.panel};border:1px solid #21262d;border-radius:8px;padding:8px 12px;display:flex;flex-direction:column;justify-content:center}
      .sb-tile span{color:${C.dim};font-size:11px} .sb-tile b{font-size:1.5rem;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.1}
      .sb-charts{display:flex;gap:10px;flex-wrap:wrap} .sb-charts canvas{border-radius:8px;border:1px solid #21262d}
      .sb-foot{margin-top:9px;color:${C.dim};font-size:12px} .sb-foot b{color:${C.text};font-variant-numeric:tabular-nums}`;
    document.head.appendChild(s);
  }

  if (window.slateRegisterWidget) {
    window.slateRegisterWidget("SlateBench.StreamBench", {
      wire(el, api) { try { mount(el, api); } catch (e) { el.textContent = "SlateBench error: " + ((e&&e.message)||e); console.error(e); } },
      destroy(el) { if (el._sbStop) el._sbStop(); },
    });
  }
})();

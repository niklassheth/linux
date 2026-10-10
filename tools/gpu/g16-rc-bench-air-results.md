# rc_bench on the M4 Air: the render→compute edge (2026-10-09)

**Tool:** `render-burst/rc_bench.c`. Each frame has N edges. Each edge is a 256×256 one-draw render pass, then an R→C
barrier, then a compute dispatch (`spin.comp`), then a C→R barrier.
- `--mode barrier`: one submit per frame.
- `--mode semaphore`: a separate submit per pass, chained by a timeline semaphore.

The R→C and C→R gaps come from GPU timestamps; the CPU frame time and frames/s are also reported.

**Runners:**
- `render-burst/rc-bench-air.sh`: host cross-build, pinned ICD `/opt/mesa-apple9-air-ed7603d/…`, `LOAD=cpu|mixed`, `HKP=batch`. It uses journal-cursor kernel-log deltas.
- `render-burst/rc-bench-air-busy.sh`: adds a second GPU client.
- `fwtrace-arm.sh`, `h121-arm.sh`.

All runs were in asahi-03's RO boots, kernels #119 (= #92 + diag) and #121 (+ host-priority knobs).

## Results (p50, µs)

| boot / arm | barrier16 R→C | semaphore16 R→C | notes |
|---|---|---|---|
| #119 idle | 47 | 278 | C→R 27 / 330; render pass ~314 |
| #119 all cores busy | 53 | **3008** (p99 4013) | barrier CPU frame 7.5 → 19.0 ms; ms-quantized |
| #119 half load (mixed) | 45 | 263 | no effect |
| #119 busy GPU (render_burst) | 45–48 | — | |
| #119 + fw_trace=4096, unbatched | 51 | 274 | **barrier: 400 `rc release` lines**, held p50 392, notification p50 62 before release, i.e. kernel-held under compute_deps=1 |
| #119 fw_trace, `--r2c-src fragment` / `--event` | 50 / 56 | — | |
| #119 fw_trace, HK_PERFTEST=batch | 46 | 311 | batch doesn't change the edge |
| #119 fw_trace, batch + all cores busy | 54 | — | |
| #121 def, all cores busy, batch / nobatch | 54 / 54 | 1052 / 2093 | |
| #121 def, big-pass busy GPU (71 × 14 ms passes/s), ± all-core load | 52 / 53 | — | the render pass stretches to 0.9 ms, the edge doesn't |
| #121 irq_notify=1, all cores busy, batch / nobatch | 54 / 54 | 1053 / 2285 | no help |
| #121 pump_prio=2, all cores busy, batch / nobatch | 54 / 47 | 2686 / **272** | barrier fps 50 → 90+; the nobatch semaphore is back to the idle level, batch is not (1 run each) |
| #121 sched_highpri=1, all three | — | — | not run (the Air went dark at the 23:15 reset) |

## Reading

- **The in-submission edge** (render → barrier → compute; hk gives each command "barrier on all previous", so under compute_deps=1 the kernel holds the compute until the render's completion notification) costs ~50 µs on the Air. It's immune to CPU load, GPU load, batching and the barrier shape.
- **The separate-submit edge** goes through drm_sched (fence → scheduler worker → publish). It costs ~280 µs idle and becomes whole-millisecond (jiffy-quantized) under all-core CPU load. irq_notify doesn't help; pump_prio=2 helped the unbatched case in one run.
- **Lethal on the mini** has ~23 in-submission R→C edges per frame at 0.44 ms mean under cd1 (0.07 ms under cd0/cd2). Its trace shows the notification ~23 µs before release but holds of ~1 ms, so there the firmware's completion notification itself is late.
- Nothing on the Air reproduces a late notification. **Open:** Lethal on the Air (claude-driver's harness port) decides whether it's mini-specific or Lethal-specific.

## Next, when the Air is back (claude-kernel's priority)

1. #121 `asahi_m4.pump_prio=2 asahi_m4.sched_highpri=1`, all cores busy: `h121-arm.sh pumphp` (batch + nobatch).
   - **Why:** the batched semaphore hop is a drm_sched run_job hop that pump_prio can't reach.
2. A pump_prio=2 repeat (noise check on the 272 µs vs 2.7 ms split).
3. If both semaphore hops collapse to idle level, `pump_prio=2 sched_highpri=1` is a cheap production candidate (scheduling priority only).
4. Lethal on the Air (claude-driver) for the in-submission edge: is it mini-specific or Lethal-specific?

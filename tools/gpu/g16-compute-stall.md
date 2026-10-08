# Dota compute stall / G16 compute time-slicing — Codex (2026-10-07)

Owner: `codex-dota`. No hardware lease held at the 22:18 checkpoint.
The op-0x1b recovery runner is queued behind claude-driver; no device access
has begun. Earlier blocks restored the then-current production kernel (#19
at the last release). Kernel/driver/air mini users may interleave.
Private topic branch and worktree:
`bits/213-g16-compute-timeslice` in `tmp/g16-compute-timeslice`, independent of
claude-driver's integration and recovery work. Never push.

## Current checkpoint (22:36 local)

- Capture 6 audit is complete: [capture6-verified.md](capture6-verified.md),
  `capture6-audit.json`, and `capture6-initial-context.json`. No destroy names H
  during the observed 147 s after SIGTERM; C/R destroys do match their objects.
  H retains changing state while C/R progress. Lane switching fits the evidence;
  firmware write sites and the guest process's final exit are not observed.
- Control82's op20 VA maps to C's operand-table physical page through ASID7.
  It is not a registration for H. H's support/operand/save mappings are private,
  despite identical virtual addresses. A per-process op20 is not established
  as a prerequisite for H's coexistence with C/R.
- H's initial queue-context first 64 bytes exactly match our initializer. Its
  static native-priority queue profile also matches. No missing quantum or
  lane-enable field has been identified in those initial bytes.
- Capture 6 also proves separate support objects/FList slots (C3/H0) and
  private physical pool backing. Ours shares slot2 and its pool. Default-off
  `compute_private_pool=1` WIP b9d449 allocates private backing/exclusive leases;
  separate production17+213 build is running, with no hardware result.
- Six historical op1b records are present before the arm cursor; none is newly
  published by these clients. The default-off six-record Linux experiment is
  queued using frozen #6, RO production17+213, native priority, policy3 and
  valid zeroed Work-record storage. This is a combined setup test, not a fix.
- Dota300-304 has 2049 executed buffer copies; Honeykrisp lowers buffer copies
  to libagx compute kernels. Largest recorded copy is 2249100 bytes. No explicit
  dispatch does not imply no firmware compute. Image uploads may use graphics
  for compressed G16G layouts, so they cannot all be classified as compute.
  Ranking/dependencies: `dota-transfer-ranking.json`; size is not GPU duration.
- Next fresh Dota lease stages explicit frames 1800-1804, a 300 s deadline and
  scene console logs, retaining original Steam-unit liveness as a validity gate.
  The op1b runner must finish restoration/release before that runner is queued.

## Prior status / manager handoff (21:56 local; historical)

- Valid read-only production #17 + rebased 213 recovery retry is **negative**:
  teardown policy 3 plus native compute priority does not recover other clients.
  Logs: `observe-20261007_211348/`, `retry-production17-console.log`. Firmware
  consumes teardown publications; companion loses device, all three fresh
  vkcubes time out, and KWin later aborts after a distinct late firmware fault.
- First exact-path probe slot is **INVALID for capture/FEX**. It booted the
  expected private #4 image RO, but the Sniper entry point was unavailable.
  Native AArch64 baseline completes on c0828f3fac Honeykrisp; the two nominal
  layer runs have no layer mapping or capture and must not count as passes.
  `probe-service.log` also records muvm launch EPERM, and the verdict file is
  empty. Logs are `observe-20261007_211820/`. Production #17 and all three
  desktop/input units were verified, then lease released.
- Corrected probe has **all six guest verdicts rc0**, full checkpoints and
  four valid/convertible captures (native and FEX, unassisted and page_guard).
  FEX is the exact muvm → shared Steam VM → FEX → Sniper → Vulkan thunks path,
  Apple M4 / Honeykrisp c0828f3fac, layer 1.0.5/header1.4.363. Logs
  `observe-20261007_213656/`; summary `probe-exact-path-summary.json`.
  Host returned rc1 because of early asynchronous muvm EPERM and verdict race;
  all six finished during clean shutdown and were copied completely. Individual
  probe results are valid; harness outcome and GPU-work recovery are separate.
- Probe cleanup restored newly promoted production **#19**, verified all three
  desktop/input services and released the lease at ~21:44. The kscreen-doctor
  setup command blocked on both candidate and restore boots without G16 errors;
  terminating that command let post-boot complete. Own observer now bounds it.
- Dota unassisted capture **completed and converted**, actual staged frames
  **300-304**, 967866872bytes, five presents. The staged script preceded the
  local frame1 change; actual capture-inputs/logs take precedence. Artifacts
  `observe-20261007_214416/`, `dota-unassisted-300-304.jsonl` (80MiB),
  `dota-compute-summary.json`, `dota-frames-vs-state.json`.
  Six application submits execute2554 transfers; no vkCmdDispatch, indirect
  dispatch, or query-copy calls in either reconstructed state or five frames.
  State reconstructs93 compute-pipeline creation calls. This is a usable trace
  and shows unassisted + deferred tracking can work through FEX. It is not a
  reproducing hang or proof of page_guard as queue32's crash cause.
- Launch-path limitation: original g16-steam service exited after30s, before
  the75s Dota launch. App logs later include SteamAPI failures/default Steam ID;
  this is not the same living Steam VM condition as queue32 and must not count
  as a matched clean Dota run. Native libvulkan_asahi is mapped, trace renderer
  is Apple M4, and five successful presents establish Vulkan initialization.
  Capture ended normally at304; host150s deadline stopped the remaining game.
  No G16 timeout/fault lines, all desktop/input services active after capture.
- Restored current production#19 and all three services; lease released21:53.
  No codex runner remains. Compiler now owns mini for requested capture6.
  Next: investigate Steam lifetime/exact-scene validity, capture later live
  gameplay with unassisted, and test default-off global control1b in a fresh
  RO lease. Correlate capture6's actual roots/backing with op20 registration.
- Own branch is rebased onto current bit211 a6e385; diagnostic and default-off
  global control-1b experiment fixes were folded back from the private test
  assembly. The control-1b build passed (#6, 21:29:19), **not booted**. Current
  queued probe still uses the previous frozen #4 and does not enable it.
- Code basis of tested #4 is production f6ba235 plus rebased 213 e3882f12,
  assembly 69be865. Frozen inputs: `artifacts/m4-linux/bits-7.3-213-prod17-69be865`.
  It retains system_dfl() and current debug_ctx gates. Nine inherited 212
  recovery commits remain a test dependency and are not production changes.
  Release/requeue between all experiments; never push.

Capture5 is available and independently parsed (6348records). Verification:
[capture5-verified.md](capture5-verified.md), with lifetime/root separation in
capture5-lifetimes.json. Manager answer **yes** to a teardown rerun, with exact
additions in [capture6-request.md](capture6-request.md). Current capture ends
when a retired C record read disables the monitor at80.2s, so H's destruction
is not established. Zero initial records are normal; first-success op20 ASID
translation still does not establish mapping ownership.
Queue32 Dota gfxr crashes before its late loader guard. No Apple binaries inspected.

The exact capture-5 request is [capture5-request.md](capture5-request.md), ready
for the manager to relay. It includes finite Metal controls and submit-time
record reads, full 256-entry rings, control registration backing, Work ASID
correlation, and read-error coverage. Queue32's captured and clean fb0-v1 logs
have the same set of 60 unknown Vulkan-function warnings. The captured run
exits 139 before its log reaches the clean run's host-X11 initialization, with
no useful crash stack. Missing RenderDoc warnings occur in both arms and are
not evidence of the crash's cause. Comparison: queue32-crash-comparison.json.

The no-submit probe now builds for x86-64 and AArch64 and records mapped Vulkan,
layer and FEX libraries after instance/device creation. New launch scripts use
the Sniper entry point inside the same muvm Steam VM, preserving the Dota FEX
thunk configuration. Target execution remains pending; host-native success
does not validate the FEX path. FEX's local AGENTS.md forbids AI-generated code
contributions to that project; this work uses external probes, not FEX edits.

**Additional control audit (20:57):** capture 4's first control dump has state
cursors `{82,82}`, producer `83`, and slots 79–82. The op-0x1b `{2,2}` is
slot 79, already behind both cursors; the initial tracer reads `(end-4)..end`
without a prior baseline. Its dump timestamp is therefore **not** a publication
timestamp. This does not establish whether op-0x1b is boot/global setup or
per-client setup. Slot 80's op-0x20 is likewise historical; only slot 82 is
ahead of those observed cursors. Capture 5's arm snapshot is essential for
separating historical content from new publications. Raw cursor extract:
capture4-control-cursors.json. Prepared-tracer coverage review for manager:
[capture5-preflight-review.md](capture5-preflight-review.md).

**Request through manager to claude-compiler for capture 5:** capture op-0x20's
firmware descriptor at +0x14 and user mappings at +0x1c/+0x24, plus the Work
+0x883 record **before firmware consumes each Work**. Follow the user-space
address written at record +0 through that Work's context. Our source calls this
an FList directory / operand pool, shared by all client roots, rather than a
known preemption buffer. Need to distinguish those roles before duplicating it.
Log op-0x20 context and descriptor addresses against every compute Work's ASID,
not just process start times. A nonzero slot word such as 0x70_0000_1016 may be a
packed pointer/status value; low bits must be retained in the capture.

## Verified source facts

- `g16_fw::opening_control()` sends op 0x20 once, with context 1, descriptor
  CONTROL_DATA and user directory OPERAND_TABLE; `opening_flist()` refers to
  0x70_0000_0000. `g16_runtime::map_compute_work()` maps that same backing into
  every client VM (comment: device-owned FList directory and spill pool).
- The negative `compute_save_slot=1` experiment supplies initially zeroed
  records in each queue's shared pointers allocation. It does **not** provide
  separate client FList registration. This excludes a null record as the sole
  issue; it does not exclude missing per-client backing / registration.
- Capture 4's +0x883 interpretation as a preemption-progress record remains a
  hypothesis, not an established ABI. The full raw trace contradicts the earlier 16-entry-ring summary (see below);
  the slot contents' role needs data from behind the referenced address.

## Experiments / results

| ID | Action | Result |
| --- | --- | --- |
| C0 | Read source and published experiment summaries | Per-client op-0x20 remains untested; no hardware run yet |
| C1 | Summarize captures 1–4 from raw JSONL | Captures 3/4 both use 256 distinct slots; process-registration correlation unproven |
| C2 | Recheck cslice-184641 logs and cmdline | Combined tail/slot/register/native-priority fields negative; no rerun |
| C3 | Prepare matched Metal spin with finite output controls | CPU LCG checks pass; Objective-C build unavailable on controller; mini execution pending capture-owner lease |
| C4 | GCC build of integrated diagnostics + quarantined-lane follow-up | Pass; Image.gz/dtbs; no boot yet |
| C5 | Streaming gfxr parser lifecycle fixture + local converter build | Pass; Dota capture pending |
| C6 | Policy 3 + native-priority teardown test with detailed lane/control diagnostics | First boot invalid; valid RO #17+213 retry negative: companion DEVICE_LOST, three fresh cubes time out; restored #17 |
| C7 | Native host no-submit probe: no layer, unassisted, page_guard + convert both captures | All pass; no FEX/mini result yet |
| C8 | Capture5 full raw audit plus finite logs / root lifetimes | Valid concurrent C/R progress; zero host records normal; teardown and registration ownership coverage gaps |
| C9 | RO #17+213 exact-path no-submit probe, first slot | INVALID FEX/capture: external Sniper path unavailable, layer absent in nominal native layer modes; production restored |
| C10 | Explicit-layer probe, external volume RO + tmpfs overlay | All six native/FEX modes rc0; four captures converted, one 64 KiB fill each, zero submissions |
| C11 | Six captured global control-1b records, default-off kernel experiment | Build passed; no hardware result |
| C12 | Dota unassisted deferred trim300-304 under FEX/Sniper, RO17+213 | 924MiB complete trace converts; five presents, no explicit compute; original Steam exited before launch, so not matched clean/hang control |
| C13 | Parser on actual Dota trace, singleton objects + trim reconstruction | Pass: six frame submits,2554 transfers, no unobserved CBs; setup submits counted separately |
| C14 | Capture 6 raw audit: control attribution, snapshots, initial context | 8901 records parse; no H destroy in observed 147 s; H context prefix matches ours; op20 belongs C |
| C15 | Dota transfer ranking and Honeykrisp source association | 2049 executed buffer copies use libagx compute; largest 2249100 bytes; no duration/hang attribution |
| C16 | Default-off per-VM compute pool/support/slot experiment | WIP b9d449; separate GCC build running; no hardware result |

## Valid recovery retry (#17 source + 213, 21:13–21:17)

Exact UTS/cmdline guard passed; root and home are Btrfs **ro**, desktop writes
use tmpfs overlays. Mesa reports c0828f3fac/Honeykrisp, Apple M4 G16G B1.
Baseline cube120frames passes. Companion completes6141frames before H and
only5 more in the next10s, then reports DEVICE_LOST. H reports DEVICE_LOST at
20s; both second submit and wait-idle also report device loss. Fresh cubes
during15, after35 and after-client-exit all return124 (20s timeout).

Queue descriptors verify native priorities2/2. Control cursors4/4/4 initially,
then5/5/5 after first destroy and6/6/6 after the next; eventually10/10/10.
Thus the new debug information establishes consumption of those publications,
without demonstrating eviction of the non-finishing Work. At135.821s uptime,
after all observed bans, firmware reports kind4 timeout and event service fails
EIO globally; fault registers decode0x10000858000, vm_slot3. This later failure
must be distinguished from the initial engine stall; causal attribution is
not established. KWin later aborts. Production#17 and all three desktop/input
services verified after restoration.

Diagnostic limitation/fix: Work pointers+86a/+883 are packed, but my reader
called FirmwareSpace::read_u64, whose read_u32 rejects unaligned addresses.
Their deadbeef sentinels therefore do **not** indicate unmapped pointers.
Aligned-word assembly is committed on the private test branch and building;
folded the tooling/kernel fixes back into213 after its first probe runner
finishes. The immutable recovery/probe image remains the verified #4 artifact.

## Next

Analyze capture 4's slot words / control descriptors; prepare an isolated,
default-off kernel experiment only when allocation and lifetime can be explained.
Use forced compute hang plus a pre-existing second client before any Dota soak.
Test kernels must use read-only root with overlays, and each hardware slot ends
with production boot + m4-post-boot. Success criteria remain user-specified:
Dota 3 × 5 min with reproducing control and forced hang isolating DEVICE_LOST to
its client while KWin and a fresh vkcube continue.

## Raw capture recheck (captures 1–4)

`capture-summary.json` was generated by the new
`tmp/g16-compute-timeslice/tools/gpu/g16-capture-summary.py`.
It parses command-stream data only, without interpreting any code.

- Capture 3: C lane 671 observed Works, context 8; **256 distinct slots**, span
  0x4000, stride 0x40, first address reused after 256 Works. H context 10.
- Capture 4: C lane 782 observed Works, context 7; same 256 slots / 16 KiB /
  stride / reuse. H context 9. Thus the 16-entry-ring claim is incorrect for
  the full address sequence; the monitor reads only a 1 KiB window at once.
- Capture 4 captured op-0x20 +4 values 1 and 8, while these compute Works use
  ASIDs 7 and 9. They cannot be correlated by equating those fields. Some
  registration can precede tracer arming; absence in this trace is inconclusive.
- Capture 4 contains no submit-time slot contents (`slot_at_doorbell`) or
  op-0x20 backing (`fw_object`, `user_regions`). Current tracer source has been
  extended since this capture. Firmware-vs-host ownership of initial contents
  is therefore unknown, despite snapshots showing memory changes.
- Recovery run cslice-184641 confirms the combined Metal-field configuration
  was tried: compute_preempt=1, compute_save_slot=1, compute_tail=15,
  compute_regs=1, compute_identity=1. Its second client stops after 6127 frames
  and reports its 10 s wait timeout. The tried table now reflects this.

## Capture-5 workload validation / prepared tool

`tools/gpu/g16-metal-spin.m` on the private kernel branch derives from our
`xhang.m`, using public Metal API calls. The original MSL only stores when
`k == 7`; the GLSL forced-hang workload uses the **final** LCG value. That is a
semantic difference and gives an optimizer room to discard later iterations.
This is a validation concern, **not proof** that the original was optimized or
that the observed macOS non-retiring Work was idle.

The prepared variant starts `x = i ^ 1`, uses the same LCG as GLSL and always
stores its final value. Defaults: UINT32_MAX iterations, 65536 threads,
64 threads per group (matching the Linux workload). `H_ITERS`, `H_THREADS`,
`H_TG` let the capture owner run finite controls. After a completed H dispatch,
the CPU verifies **all** thread outputs with an independently implemented
logarithmic affine-recurrence calculation; no binary inspection is involved.

**Additional manager request to claude-compiler:** use this variant for finite
H_ITERS=1000 and H_ITERS=1000000 controls, then the long H case with R/C. Record
H config, completion status and output verification, plus C/R continuity.
Capture compute support/FList records at Work +0x86a and microsequence +0x160,
CDM launch bytes (command data only), and save-area mappings at Work +0x798.
These distinguish registration/pool setup from dispatch-level scheduling.
The controller Mac is used only to compile the source; no GPU test is run there.

## Validation and availability

- Capture summarizer completed on all four JSONL captures with no trace-error
  records. Captures 3 and 4 independently confirm the 256-Work address reuse.
- Extracted the exact CPU recurrence checker and compiled it with GCC C11,
  `-Wall -Wextra -Werror`. All 40000 comparisons against direct iteration pass,
  plus recurrence-composition checks at UINT32_MAX. Log: `lcg-validation.log`.
- Controller compile attempt could not start: no Xcode command-line developer
  tools are installed (`metal-build.log`). No installation was requested by
  us and no program was run. Objective-C/MSL compilation must use the capture
  owner's existing macOS build environment; this is not yet validated.
- Mini remains with claude-driver for queue32, with claude-kernel waiting.
  No lease, SSH session to the mini, reset or change to its live state by Codex.

## Linux diagnostic WIP

Tools/report committed locally as `2362984ee2396` on
`bits/213-g16-compute-timeslice` (based on 212 at `cb8f8582a8823`).
`g16_runtime.rs` now adds timeout-only diagnostics for each compute flight:
queue runtime +0x9c, priority fields, firmware context words, support/FList
identity/slot/directory/cursors, save-area VA, optional record contents, and
register/value pairs including any firmware-added resume state. The hang report
also records control read/done/write cursors. This makes the next recovery test
able to distinguish a submitted teardown from a consumed teardown. There is no
scheduling or recovery-policy change, and no UAPI change.

Reads of optional firmware pointers tolerate unmapped addresses and use
saturating offset additions. GPU user addresses are printed without following
them through the firmware mapping. Register dumps use fixed stack storage.
A GCC in-tree `Image.gz dtbs` build is running in the private worktree with the
212 test configuration (`kernel-config.log`, `kernel-build.log`). No boot yet.

Source audit also eliminates the alleged microsequence +0x2c8/+0x2d0 byte
difference: our encoder writes firmware Work pointers at +0x2c1/+0x2c9. Their
high bytes at +0x2c8/+0x2d0 are already 0xff, matching Metal. Do not spend a
hardware slot changing those bytes independently of their containing pointers.

Build note (19:39): building the bit branch alone fails before the driver with
missing `bindings::apple_rtkit_set_early_crashlog`: 212's base lacks the matching
C header addition carried by the integration. Preserved initial build output
as `kernel-build-bit-only.log`. Created `test/m4-7.3-213` in the same private
worktree, based on the exact 212 test integration `1e2a1cd7c92c6`, then merged
`bits/213-g16-compute-timeslice` (diagnostics commit `341adb26aed30`). Header
now contains the required declaration; the in-tree GCC build is restarted.
No changes to any other agent's branch or checkout.

## Prepared Linux observation (not run)

Prior `kwin-1744-timeout_policy=3` cmdline has **compute_preempt=0** (default).
The native-priority tests use policy 1 (log-only), so the combination of
native priority with actual context teardown is not covered by those negatives.
Prepared `tools/gpu/g16-recovery-slot.sh` and `g16-recovery-observe.sh` for one
new observation: policy 3 + compute_preempt=1, with the new diagnostics. This
asks whether native priority enables teardown even if it does not enable
compute time-slicing. No other Metal-field knobs are changed.

Host wrapper requires the candidate Image/DTB, takes and renews the mini lease,
verifies the booted UTS version and both boot argument tokens, stages source only
into tmpfs, and restores production + m4-post-boot + service verification on
exit. Remote wrapper rejects writable root/home, creates desktop tmpfs overlays,
records renderer and KWin mappings, starts a companion before the existing
forced-hang reproducer, and checks a new vkcube before/during/after teardown.
Results remain **pending**; shell syntax checks pass. The supplied command is:

    G16_KERNEL_ARTIFACT=$PWD/artifacts/m4-linux/bits-7.3-213-fcf0513 bash tmp/g16-compute-timeslice/tools/gpu/g16-recovery-slot.sh

Do not run this while another owner holds the mini except through its lease
wait; do not claim KWin is compositing just because its systemd unit is active.
Fresh vkcube completion and continuing companion frames are required evidence.

## Gfxrecon analysis path (prepared; Dota file pending)

Built native x86-64 `gfxrecon-convert` from the existing source/build under
`artifacts/mixed-pages/gfxrecon-muvm-build/` (6 build steps, success; help and
build output saved here). The parser `tools/gpu/g16-gfxr-compute-summary.py`
reads JSONL as a stream, follows command-buffer recordings and secondary
execution into actual queue submissions, groups repeated dispatch patterns,
and records first/last submit waits/fences. It reports direct dispatches by
workgroup count, indirect dispatches with unknown dimensions, image-to-buffer
copies and query resolves. Compute pipeline creation metadata links explicit
compute operations to module handles / specialization. Image/query copies can
be driver-internal compute, so they are included even without vkCmdDispatch.

Validation fixture exercises secondary execution, command-buffer pool reset,
Submit and Submit2 timeline waits, explicit/indirect dispatches, and a WAIT
query resolve. Expected six submitted operations and two executions of the
128-workgroup dispatch are checked. Fixture and result saved here. This is
parser validation, **not Dota evidence**. `artifacts/dota-gfxrecon-20261007/`
is empty as of 19:46; queue32 has not reached the capture step.

Example once the Dota file arrives (streaming avoids a large intermediate JSON
file; preserve pipefail and constrain host memory):

    set -o pipefail
    artifacts/mixed-pages/gfxrecon-muvm-build/tools/convert/gfxrecon-convert --format jsonl --output stdout artifacts/dota-gfxrecon-20261007/dota.gfxr | systemd-run --user --scope -p MemoryMax=2G python tmp/g16-compute-timeslice/tools/gpu/g16-gfxr-compute-summary.py > artifacts/dota-compute-stall-20261007/dota-compute-summary.json

Workgroup count is **not duration**; indirect buffer contents and shader cost
remain unresolved. Only four preceding sync commands are retained per operation;
the summary cannot prove a wait was satisfied or identify the GPU hang alone.

## Build success / final diagnostic addition (19:49)

Private test integration `dbab7b4e3b541` completed GCC `Image.gz dtbs` with
exit 0, including `RUSTC drivers/gpu/drm/asahi/asahi_m4.o`. Artifact initially
staged at `artifacts/m4-linux/bits-7.3-213-341adb/`, UTS #1. No boot yet.
Adding one follow-up diagnostic before the hardware observation: also sample
up to four quarantined compute flights on subsequent hang reports. That lets
us compare the **same** lane's runtime/context after a destroy has been
published, alongside the control-ring acknowledgement cursors. Quarantine
already retains all backing, so these reads do not alter lifetimes.

Additional untested capture observation: capture 4 has one control op 0x1b,
64-byte record `{u32 opcode=0x1b, +4=2, +8=2, remaining=0}`, ring index 79,
before the first observed op-0x20 records. Capture 3's monitored window does
not contain it. Our G16 source sends no op 0x1b. **Meaning unknown**; no kernel
command injection planned from this single sample. Please include it and any
other global setup commands when capturing process/pool registration in capture 5.
The capture summarizer now preserves all observed control slots, not just op 0x20.

## Latest state (19:56)

Final diagnostic addition compiled and linked with exit 0, including Asahi
Rust compilation: `kernel-build-quarantine.log`. Final image/DTB:
`artifacts/m4-linux/bits-7.3-213-fcf0513/` (UTS #3, source integration
`4e3176459a4ce`, diagnostic topic `fcf05134b5c35`). The initial `341adb` artifact
lacks the quarantined-lane follow-up; use the **fcf0513** artifact for tests.
Shell guards have been corrected for Rust module parameters' `perm: 0` (these
parameters do not appear in sysfs); they verify cmdline tokens, while the kernel
diagnostic verifies actual lane-priority data. Remote setup requires the Apple
M4/Honeykrisp renderer and records the version. Restoration has bounded boot
attempts and retries. No hardware result or recovery fix is claimed yet.


The prepared slot uses the immutable artifact (Image/DTB/UTS header), records
input hashes before waiting, and requests a 15-minute lease. It cannot silently
boot a later rebuild of the worktree while queued.

## Queued hardware run (20:00)

Live host runner is waiting for the `codex-dota` lease (no lease held yet):
`linux-slot.log`, observation directory `observe-20261007_200029/`.
Exec session ID: 28302. Wrapper copied beside the immutable kernel artifact;
it will boot only after lease acquisition, observe policy 3 + native compute
priority, collect per-run logs, restore production with service verification,
and release. Other owners remain uninterrupted. Results are **pending**.

Local topic tip: `a8268feb5ddb3` (tools/docs guard follow-up); GPU diagnostic tip
`fcf05134b5c35`. Test assembly tip `ce6c0d18f08dc` contains the same GPU code as
the built `4e3176459a4ce` assembly; later differences are tools/docs only.
No push. Capture-5 requests remain above; Dota's actual trigger and successful
compute time-slicing / client-isolated recovery remain unresolved.


## Record interpretation / parser check (20:09)

Reconstructed capture-4 slot snapshots with `tools/gpu/g16-slot-windows.py`,
checking each delta against its recorded prior bytes. Output:
`slot-window-summary.json`. This confirms the existing capture README's H
record observation; it is **not a new hardware experiment**.

- C's sampled first record is either all zero or `{u32 0x1016, 0x70, remaining=0}`.
  Reading that pair as u64 gives `0x70_0000_1016`, but that alone does not prove
  that this field is a host/GPU virtual address.
- H's record starts `{u32 0x1a70, 0xb74, 0x1a70, 0xb02}` and settles at
  `{0x1a70, 0xbed, 0x1a70, 0xb77}` by ~1.94 seconds after its doorbell.
  The remaining words are zero. A pointer interpretation of its first u64
  would give `0xb74_0000_1a70`, rather than the apparent C address form.
- Thus keep **both u32/u64 views and the unmodified bytes** in capture 5.
  Following the C value as a user VA is a useful probe, not an established ABI.
  H's changing words could describe progress or allocator state; their meaning
  and relationship to op-0x20 remain unknown. The snapshot window moves for C,
  so change counts must not be presented as writes to a single slot address.

The real gfxrecon `triangle.gfxr` sample also passed converter-to-parser
streaming: 11 queue submits, zero compute/transfer operations, no unknown
command buffers. This validates actual converter JSON shape beyond the
synthetic lifecycle fixture (`gfxr-triangle-summary.json`), but gives no Dota
trigger evidence. Dota capture and our leased mini observation remain pending.


## Lease handoff collision / invalidated boot (20:10)

**Manager coordination:** our lease history records codex-dota acquisition at
20:08:59 after queue32 released at 20:08:46. Queue32's shared log then records
`20:09:17 inst-v3 left G16 errors (): rebooting to default`, after its release.
Our candidate boot returned but the exact UTS guard reported **wrong kernel
booted**. No forced-hang workload was launched. The runner is restoring
production under our lease; it will verify services and release.

This is an **invalid boot attempt, not a negative compute/recovery result**.
Please ensure all queue exit/trim restore paths hold the lease before resetting;
another owner's later restore must not race a new candidate. Our wrapper's UTS
and cmdline guards prevented testing on the wrong kernel. Driver gfxr-v1 also
failed its EXPECT_DRIVER guard (rc=3); no completed capture is available.
The streaming capture worker (session 88653) is waiting for a successful copy
marker, so it cannot analyze a partial/missing file.

Our completed offline tools/doc WIP is local topic `1078edd4f4a4e`; test assembly
`d0041a28a83b4` has the same GPU diagnostic code as the immutable fcf0513 image.


## Restore verified / retry queued (20:12)

First runner completed with exit 1 after its wrong-kernel guard. Restoration
succeeded on attempt 1: `observe-20261007_200029/production-services-1.log`
records production #10 and all three services active. Lease released 20:10:26;
claude-kernel acquired at 20:10:39 for 7.3-rc6 RO gates. No workloads or GPU
state changes were made by our first attempt.

Retry runner is now lease-waiting: session **90431**, `linux-slot-retry.log`,
using the same fcf0513 diagnostic image. The guard now persists both expected
and actual UTS/cmdline **before** comparing them, so a future invalid boot will
retain that evidence. These are host-script changes only; no kernel rebuild
needed. Please keep all other restore paths inside their own lease. This retry
will also restore production and verify services before release.


## Dota capture ownership / local smoke (20:20)

Manager confirms the watcher reset caused the first invalid boot; watcher fixed.
The recovery retry remains lease-waiting behind claude-kernel (now until 21:09).
I also own fixing the Dota capture path from this point onward.

New verified queue32 results on production #10, render_barrier=2, correct
`driver-fb-a64`: fb0 3/3 clean ~301 s; fb1 1/3 hang at 39 s (127 G16 errors),
2/3 clean. **No causal A/B conclusion**: measured fb0 control rate here is 0/3,
so more reproducing controls are needed. This does not meet the success criteria.

The gfxr run's true failure is an application SIGSEGV (exit 139) at 3.2 s,
before the +45 s loaded-driver probe. WRONG-DRIVER is a follow-on guard result,
not evidence that the wrong driver ran. Layer initialization is recorded at
1.0.5/header 1.4.363. Unknown Vulkan-function warnings also occur in clean runs.
Logs are now locally readable in `artifacts/dota-hang-20261006/queue32/gfxr-v1/`;
no `.gfxr` file was produced. The prior converter worker will time out if no
successful capture appears; it performs no device access.

Prepared `tools/gpu/g16-capture-probe.c`, an own workload with flushed markers
around instance/device/buffer/map setup and a 64 KiB memory write. **No shaders
or queue submissions**. It builds x86-64 with GCC C11 -Wall -Wextra -Werror.
Three local native-host runs pass: no layer, gfxrecon `unassisted`, gfxrecon
`page_guard`. Both layer runs emit convertible small traces (5008/4927 bytes),
with one vkMapMemory and zero submits. Logs/captures:
`host-capture-probe/`. These use the host NVIDIA renderer; they validate the
probe/capture tool, not FEX, Honeykrisp, or the mini's recovery.

Next capture isolation within a lease: same probe under native aarch64 and
x86 FEX Vulkan thunks, with no layer / aarch64 gfxrecon unassisted / page_guard.
Use the existing FEX config and driver paths, verify loaded architecture, and
collect first failing marker. This tests a specific hypothesis: default
page_guard uses a native SIGSEGV handler and guarded mapped memory, which can
conflict with emulation/crash handling. Source/usage documentation establishes
that mechanism, **not that it caused this Dota crash**. If unassisted boots the
real game, use a short trimmed frame window to bound memory/disk capture cost.
Header matching and the no-thunks x86 layer path remain alternatives after
this isolation, rather than changes to combine blindly.

I read the local FEX source as reference; its AGENTS.md forbids AI-generated
contributions to that project. No FEX source edits are being made. Our standalone
probe and launch/capture fixes live on our own topic, not in FEX's checkout.


## Prepared capture launchers (20:24; not deployed)

`tools/gpu/g16-dota-capture-inner.sh` and `g16-dota-capture-guest.sh` derive from
our lab launcher and retain the FEX Vulkan-thunk/native ICD path. They isolate
unassisted vs page_guard capture memory modes, keep compression normal, clear
other shader-diagnostic overrides, and default to frames **300-304** (five),
rather than the failed run's 300-900. Frame override is limited to ten frames.
This bounds frame count, **not bytes**; the leased host harness must also enforce
memory/free-space/maximum-file-size limits, particularly for unassisted mode.

A live maps poll starts immediately after game launch, retaining native driver
and gfxrecon mappings during a fast crash. It replaces the old +45 s-only probe
in these private launchers; the host still must verify expected driver, Vulkan
init, application exit status and capture contents. Failed capture runs must not
be called clean Dota runs. Scripts pass bash syntax checks and reject a label
outside their dedicated `dota-gfxr-codex-*` namespace. They are **not yet run
on the mini**, and do not modify the existing shared harness.

The no-submit probe's x86 binary needs GLIBC_2.34 or older-version symbols only,
as checked with readelf. Native-host smoke outputs are described above. Next
hardware slot will first preserve the prepared recovery experiment, then use
these tools for capture setup in a bounded leased slot; no simultaneous runners
with the same lease owner will be started. Production restoration remains
mandatory. Capture 5 should also report finite-H GPU-time scaling (the prepared
Metal tool prints GPU start/end times) to check the workload's executed cost.


## Checkpoint for manager (20:24)

- Local WIP tip **ef25ec310a61b** on `bits/213-g16-compute-timeslice`; no pushes.
  Immutable diagnostic GPU code remains fcf05134b5c35, no new kernel rebuild.
- Recovery retry still running as a lease waiter (session 90431), output
  `linux-slot-retry.log`. It will boot RO, test policy3/native compute priority,
  restore production and verify services before releasing. Do not start another
  codex-dota runner concurrently. Kernel owner currently has rc6 RO gates.
- Obsolete queue32 capture-copy watcher stopped locally (exit 143), since the
  confirmed failed capture means its success marker will not arrive. No device
  access by that watcher. We will analyze our own successful capture explicitly.
- Capture isolation tools/launchers are built/committed, native-host smoke passes,
  FEX and real Dota capture remain pending. No DEVICE_LOST isolation/time-slicing
  fix or valid Dota A/B improvement demonstrated.


## First probe slot and correction (21:30–21:38)

`observe-20261007_211820` passed UTS/RO guards. Native baseline reached
vkCreateInstance/device/buffer/allocate/map/write/flush and teardown without
submitting GPU work, on Apple M4 / Honeykrisp c0828f3fac. Nominal unassisted
and page_guard executions also reached teardown, but maps contain no
libVkLayer_gfxreconstruct and no gfxr/log files exist: **layer absence, not a
layer compatibility pass**. FEX log in every mode contains only missing
`SteamLinuxRuntime_sniper/_v2-entry-point`; there is no Vulkan checkpoint.
The host service reports `could not request launch to server: EPERM`, so
joining and synchronous stdio validity must also be verified in the retry.
The empty verdict file gives no valid success marker. No FEX crash conclusion.

The RO observer had not explicitly mounted the external game volume; corrected
observer mounts USB4-TEST read-only and overlays the volume in tmpfs before
muvm starts, requires the actual Sniper path, and records backing mount state.
The C probe now explicitly enables VK_LAYER_LUNARG_gfxreconstruct for layer
modes and prints capture/loader environment at entry. Missing layer now fails
instance creation rather than appearing to pass through environment omission.
Direct verdict-file writes avoid dependence on launch stdout plumbing. Both
probe architectures build with -Wall -Wextra -Werror; shell syntax passes.
These are own external workloads/launchers; no FEX project modifications.


## Exact-path probe result (21:42–21:46)

All six modes in the completed guest verdict file pass. Both FEX layer modes
initialize the same native aarch64 gfxrecon version1.0.5/header1.4.363 seen in
queue32; maps contain native libvulkan_asahi and libVkLayer_gfxreconstruct.
The converted file's executable metadata names FEXInterpreter, renderer is
Apple M4, and the probe completes map/write/flush/unmap/device/instance teardown.
Each of four traces has25 records, one65536-byte FillMemoryCommand, one map,
and zero GPU submissions; sizes4826–4908bytes. Conversion succeeds for all4.
This excludes basic no-submit setup and a single mapped write as sufficient
causes. It does **not** exclude Dota's API/extension/threading behavior, command
submissions, or deferred-trim state tracking.

The host-side EPERM is consistent with muvm run_io_host adding stdin fd0 to
an epoll instance when systemd supplies /dev/null. Guest execution had already
begun. Own launchers now use a pipe for stdin and wait for a final guest marker,
so they avoid premature cleanup. Source reference: tmp/muvm-src/crates/muvm/src/
tty.rs run_io_host; no changes to muvm or FEX. Despite the rc1 orchestration race,
all six copied results and four complete converted traces are available.

Dota's new first-frame capture changes capture startup mode intentionally.
Gfxrecon CommonCaptureManager starts frame1; a single range beginning1 opens
its file immediately and writes setup calls. A future300-304 run will exercise
the separate pre-range tracking path used by queue32. First-frame startup can
therefore provide evidence even if the game crashes before its first present.


## Dota unassisted capture and first analysis (21:48–21:56)

Raw file: `observe-20261007_214416/codex-dota-20261007_214416/dota-results/`
`dota_frames_300_through_304.gfxr`. Actual size/hash are in
`dota-capture-manifest.json`; conversion exit0,153666JSONL records, five frame
end markers300–304, no truncated-file warnings. Native driver mapping is
`/usr/lib64/libvulkan_asahi.so`, renderer Apple M4, gfxrecon1.0.5/header1.4.363.
The same installed native path was verified by the preceding probe as c0828f3fac.
The trace's deferred-state setup does not preserve driverInfo, so driver commit
comes from that adjacent probe rather than an independent trace string.

Six **frame** queue submits (plus one synthesized trim-setup submit) execute
2554 executed transfers:500 buffer-to-image,2049 buffer copies and five blits.
Five of those uploads were recorded in reconstructed CBs and submitted again
in the captured frames; frame API recording itself has495 upload commands. There are1180 CmdDraw and five CmdDrawIndexed calls
in the five frames. State reconstructs93 compute-pipeline creations but no
explicit compute dispatch appears anywhere. Neither query-copy nor query-reset
calls appear. Application-level dispatch duration and dependency analysis thus
has no compute dispatch to rank in this window. Transfers and graphics setup
may still create internal driver compute; a later gameplay window and driver
Work-to-command association are needed. Gfxrecon state reconstruction must not
be counted as live frame executions.

The streaming parser previously assumed structure arrays were always lists;
real pSubmits with count1 is a dict. Normalization now handles singleton structs
and handles consistently. It retains reconstructed CB definitions but excludes
trim setup submissions from frame execution counts, and records transfers that
may invoke driver compute. The real trace passes with zero unobserved CBs.
Analysis outputs: `dota-compute-summary.json`, `dota-frames-vs-state.json`,
`dota-trace-validation.json`. Largest transfer does not mean longest GPU time.

Steam lifetime is a real validity limitation: its initial service deactivated
at21:47:08 after30.3s. Dota starts21:47:53 and can render/capture through the
fresh VM, but the original authenticated Steam VM is no longer alive and later
Steam API failures are present. Do not score this as a matching five-minute
control or claim unassisted caused the change from queue32. The preserved
capture input is300-304 despite the later local default1-5 change. Observer
captured completed gfxr within its2GiB limit and stopped at150s deadline.

No firmware failure is visible in this run. Production restore booted#19;
kscreen-doctor blocked again and was terminated so post-boot finished normally.
Desktop/headless/input units all active before lease release. The next capture
must preserve Steam launch/shutdown logs and assert original Steam VM liveness
before claiming the exact authenticated path. Requested capture6 is currently
with compiler; do not contend for its UART or memory monitor.

Static source check: current libagx_copy_query has no shader-side availability
spin; only the CPU GetQueryPoolResults wait path spins with a timeout. The old
helper.cl threadgroup-allocation TODO is not evidence of the Apple9 issue:
current G16G scratch reservation explicitly skips that older helper protocol.
No changes or hardware tests were made for those discarded hypotheses.


## Final checkpoint (21:58)

All three authorized mini blocks are finished; no codex hardware waiter or
runner remains. Each released the lease after verifying production restoration.
Current main development tip is on own bit213; diagnostic, global-control1b and
harness/parser changes are committed WIP, with no pushes or production merges.
The tried table records the valid recovery negative. Global-control1b remains
**unbooted**. The frozen #6 artifact is
`artifacts/m4-linux/bits-7.3-213-prod17-e6f72e2/`; future boot must use its exact
UTS and explicit parameter, RO backing and a fresh lease.

Next Dota runner now requires the original Steam unit still active at launch,
and preserves startup/service/guest-shutdown logs. This guard was added after
the successful API capture; do not retroactively claim that run passed it.
Capture5 teardown rerun: yes; capture6-request.md is the exact pending scope.
Compiler holds the lease for it now. Follow-ups are Steam lifetime/exact gameplay,
then later capture with actual compute/driver-meta association, and the new
op1b forced-stall experiment after release/requeue. Neither time-slicing nor
isolated DEVICE_LOST recovery is fixed; no 3x5-minute success claim.


## Waiting checkpoint (22:26)

The queued op1b runner79319 has not acquired the mini. It remains a single
waiter, behind claude-driver's Lethal block; no concurrent Codex runner/reset.
Independent parser extension now reproducibly ranks executed transfers with
recording/submit indices, preceding synchronization and submission waits.
`dota-sized-transfer-summary.json` reproduces all six frame submits,2049
buffer copies,500 uploads and five blits with zero unobserved CBs; largest
buffer transfer2249100 bytes at recording143886 / submit146063. WIP ea16e65.
Source association is `hk_cmd_copy` → libagx copy kernels →
`hk_dispatch_precomp` → `hk_apple9_dispatch`; no application dispatch needed.

Next Dota observer now also gives the **initial Steam host launcher** epollable
stdin using a pipe held open for the bounded observer. The previous fix only
covered joining probe/Dota launchers. The original g16-steam unit was started
with systemd's /dev/null, a plausible EPERM/early-exit source. This is a
hypothesis until the preserved initial Steam journal confirms it, not a proven
explanation of the30s prior exit. Installed Steam/FEX scripts are unchanged;
the original Steam host script is copied into artifacts for exact review.
Bash syntax passes; WIP f9c2e37. Dota retains liveness gate and frames1800-1804.
Conditional initialization request after a negative op1b:
`capture7-initialization-request.md`; no request to displace the current lease.

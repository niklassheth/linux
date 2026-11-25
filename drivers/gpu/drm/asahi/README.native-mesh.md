# Native object/mesh support on T8132

Native Apple9 object/mesh shader renders on T8132 are gated behind the
`asahi_m4.native_mesh` module parameter (default `0`, off) and runtime debugfs
knob `/sys/kernel/debug/asahi_m4/native_mesh`.

## UAPI contract (downstream G16 extension bit 28)

Native object/mesh support uses two downstream G16 UAPI bits in
`include/uapi/drm/asahi_drm.h` (kept byte-identical with Mesa's
`include/drm-uapi/asahi_drm.h`):

- **`DRM_ASAHI_FEATURE_NATIVE_MESH` (`(1UL) << 28`):** advertised in
  `drm_asahi_params_global::features` from `DRM_IOCTL_ASAHI_GET_PARAMS` when
  the DRM file descriptor was opened with `asahi_m4.native_mesh` enabled.
- **`DRM_ASAHI_RENDER_NATIVE_MESH` (`(1U << 28)`):** per-render flag in
  `drm_asahi_cmd_render::flags` telling the kernel that the render's VDM
  control stream may contain native Apple9 object/mesh shader dispatches.

The kernel treats the VDM control stream as completely opaque: it performs **no
CPU command-stream reads or parsing** and **no CPU producer-stamp waits**.
Producer ordering uses the normal firmware dependency items. The kernel imposes
no native-specific command-stream admission restrictions under
`DRM_ASAHI_RENDER_NATIVE_MESH` (ordinary-only, native-only, mixed
ordinary/native sequences, chained `VDM_STREAM_LINK`, indirect draws,
multi-layer `layers > 1`, MSAA `samples` 2 or 4, occlusion queries, and memory
writes are all accepted by submission). Kernel acceptance is separate from
hardware qualification: device qualification for individual workloads remains
tracked separately, and a TVB growth refusal during an in-flight native mesh
render still warns once per boot (`native_tvb_refused`) because a full pool can
leave output incomplete.

### Discovery latching and `SUBMIT` validation

- **Per-DRM-open latching:** `File::open()` latches `asahi_m4.native_mesh` once
  for the lifetime of that open DRM file descriptor. Both `GET_PARAMS` and
  `VM_CREATE` on that file descriptor read the same latch, eliminating any
  discovery-to-creation race across concurrent runtime debugfs toggles.
- `DRM_ASAHI_RENDER_NATIVE_MESH` requires a VM created on a DRM file descriptor
  that latched native mesh enabled; submitting it on a non-native VM is rejected
  with `EINVAL`.
- `DRM_ASAHI_RENDER_NATIVE_MESH` is mutually exclusive with
  `DRM_ASAHI_RENDER_FEW_PRIMITIVES`; combining them is rejected with `EINVAL`.

## Hardware state and memory management

- **Render operand pool and support object:** A VM created with native mesh
  enabled latches `native_mesh = true`. At its first render (or first compute
  when `compute_shares_render_pool=1`), the VM allocates the full 24-buffer
  operand pool (`48 MiB`) and initializes the support header in native mode
  (`+0x10 = 2`, `+0x40 = 4`) before first publication. That support object
  serves both ordinary and native renders for the lifetime of the VM.
- **Extended TA register state:** For a render with
  `DRM_ASAHI_RENDER_NATIVE_MESH`, the kernel programs:
  - `0x0a5a1` = `Profile::GATE` (`0xec_0040_0020`)
  - `0x1ca48` = `0x0200_0000_0000_0000 | payload` (inserted after `0x10799`,
    omitting the duplicate `0x10209` stamp entry)
  - TA register count `0x42` (`0x318` bytes), TA work `+0x86c = 1`, and TA size
    `+0x908 = Profile::TA_SIZE` (`0x13300`, preserving layer bit 62)
  - Fragment (3D) registers and Work encoding remain identical to ordinary
    renders.
- **Per-render `0x1ca48` payload aperture (`512 KiB`):** TA register `0x1ca48`
  backs a per-cluster hardware free-list DRAM aperture of
  `CLUSTER_PAYLOAD_BYTES` (`0x40000`, `256 KiB`) per geometry cluster across
  `NUM_CLUSTERS = 2` on T8132 (`Profile::PAYLOAD_BYTES = 0x80000`, `512 KiB`).
  Each native render exclusively leases this 16 KiB-aligned aperture inside its
  render scratch lease (bounded inside 40-bit VA space) through both TA and
  fragment retirement.
- **Zero-allocation & partial-clear reuse:** Render scratch pages are allocated
  with `__GFP_ZERO` once per VM (`alloc_low`), preserving cross-VM isolation.
  On same-VM scratch reuse, `lease_scratch` re-zeroes only the 5 render
  metadata pages (`80 KiB`) and skips re-zeroing the hardware-written `512 KiB`
  payload pages. If a released native lease is later split and reused by an
  ordinary render whose metadata lands on former payload pages, those metadata
  pages are still freshly zeroed.

## Boot parameter, runtime debugfs, and counters

`asahi_m4.native_mesh` defaults to `0` (disabled). Accepted values for both the
module parameter and `/sys/kernel/debug/asahi_m4/native_mesh` are:

- `0`: disabled (default)
- `1` (or legacy alias `4`): enabled
- Any other value: rejected with `EINVAL`

```sh
cat /sys/kernel/debug/asahi_m4/native_mesh       # 0 or 1
echo 1 > /sys/kernel/debug/asahi_m4/native_mesh  # enable for newly opened DRM fds
echo 0 > /sys/kernel/debug/asahi_m4/native_mesh  # disable for newly opened DRM fds
```

Flipping the knob at runtime is safe at any time:

- **Each DRM file open latches the current state** and propagates it to every
  `GET_PARAMS` and `VM_CREATE` on that file descriptor. Existing clients keep
  their latched state regardless of later toggles.
- **Open a fresh DRM file descriptor (e.g. start a new process)** after
  toggling to observe the new state.

Debugfs `/sys/kernel/debug/asahi_m4/dep_stats` tracks:

- `native_mesh_renders`: published renders submitted with
  `DRM_ASAHI_RENDER_NATIVE_MESH` (counted once on publication, not on `EBUSY`
  retries).
- `native_tvb_refused`: refused TVB growth requests on pools with an in-flight
  native mesh render (also warned once per boot).

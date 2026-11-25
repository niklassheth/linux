// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2026 The Asahi Linux Contributors

//! Native object/mesh render state for Apple9 (T8132).
//!
//! Gated by `asahi_m4.native_mesh` (default `0`, runtime debugfs
//! `asahi_m4/native_mesh`). Each DRM file open latches the current gate so
//! `GET_PARAMS` (`DRM_ASAHI_FEATURE_NATIVE_MESH`, bit 28) and `VM_CREATE` on
//! that file always agree. VMs created with native mesh enabled allocate the
//! full 24-buffer operand pool with a native support header and accept
//! `DRM_ASAHI_RENDER_NATIVE_MESH` (bit 28) on opaque VDM control streams
//! without CPU command-stream parsing.

/// Runtime enable gate (`asahi_m4.native_mesh`, writable from debugfs
/// `asahi_m4/native_mesh` without a reboot). Latched per DRM file open so
/// `GET_PARAMS` and `VM_CREATE` on a file descriptor always agree.
static ENABLED: core::sync::atomic::AtomicBool = core::sync::atomic::AtomicBool::new(false);

/// Hardware `0x1ca48` per-cluster free-list DRAM aperture size (256 KiB per
/// geometry cluster: Cluster 0 `[base+0x00000..+0x40000)`, Cluster 1
/// `[base+0x40000..+0x80000)`).
pub(crate) const CLUSTER_PAYLOAD_BYTES: usize = 0x40000;

/// Number of geometry clusters on T8132 (G16G: 10 cores across 2 clusters).
pub(crate) const NUM_CLUSTERS: usize = 2;

/// Parse an `asahi_m4.native_mesh` boot parameter or debugfs write:
/// `0` disables native mesh; `1` or `4` (legacy qualified alias) enables it.
/// Any other value is rejected with `EINVAL`.
pub(crate) fn parse_parameter(value: u32) -> Option<bool> {
    match value {
        0 => Some(false),
        1 | 4 => Some(true),
        _ => None,
    }
}

/// Whether native object/mesh support is currently enabled for newly opened
/// DRM file descriptors.
pub(crate) fn enabled() -> bool {
    ENABLED.load(core::sync::atomic::Ordering::Acquire)
}

/// Set the runtime native mesh enable gate.
pub(crate) fn set_enabled(enable: bool) {
    ENABLED.store(enable, core::sync::atomic::Ordering::Release);
}

/// Classification of non-accepted bits in `drm_asahi_cmd_render::flags`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RenderFlagsReject {
    /// At least one unrecognized/reserved bit is set (`EINVAL`).
    Unknown,
    /// Only recognized-but-unimplemented UAPI bits are set (`EOPNOTSUPP`).
    Unsupported,
}

/// Classify non-zero rejected render flag bits (`c.flags & !accepted`) into
/// unknown bits (`EINVAL`) vs recognized-but-unimplemented bits (`EOPNOTSUPP`).
pub(crate) fn classify_rejected_render_flags(
    rejected_flags: u32,
    known_unsupported: u32,
) -> RenderFlagsReject {
    if rejected_flags & !known_unsupported != 0 {
        RenderFlagsReject::Unknown
    } else {
        RenderFlagsReject::Unsupported
    }
}

/// Frontend `SUBMIT` rejection reasons for `DRM_ASAHI_RENDER_NATIVE_MESH`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RenderReject {
    /// The VM was created without native mesh enabled.
    VmDisabled,
    /// `DRM_ASAHI_RENDER_NATIVE_MESH` cannot be combined with
    /// `DRM_ASAHI_RENDER_FEW_PRIMITIVES`.
    FewPrimitivesConflict,
}

/// Validate `DRM_ASAHI_RENDER_NATIVE_MESH` against the VM's latched native
/// mesh capability and mutually exclusive `DRM_ASAHI_RENDER_FEW_PRIMITIVES`.
pub(crate) fn render_profile(
    vm_native_mesh: bool,
    native_mesh: bool,
    few_primitives: bool,
) -> Result<Option<Profile>, RenderReject> {
    if !native_mesh {
        return Ok(None);
    }
    if !vm_native_mesh {
        return Err(RenderReject::VmDisabled);
    }
    if few_primitives {
        return Err(RenderReject::FewPrimitivesConflict);
    }
    Ok(Some(Profile::default()))
}

/// Whether a refused TVB growth on `selected_root` affects a pool with at
/// least one in-flight native render: either the selected render itself is
/// native, or another live render flight on the same VM root is native.
pub(crate) fn pool_has_native_flight<I>(
    selected_native: bool,
    selected_root: u64,
    other_renders: I,
) -> bool
where
    I: IntoIterator<Item = (bool, u64)>,
{
    selected_native
        || other_renders
            .into_iter()
            .any(|(native, root)| native && root == selected_root)
}

/// Count a staged native mesh render exactly once (never on `EBUSY`
/// retries or failed submissions).
pub(crate) fn note_render_published(
    published: bool,
    is_mesh: bool,
    counter: &core::sync::atomic::AtomicU64,
) {
    if published && is_mesh {
        counter.fetch_add(1, core::sync::atomic::Ordering::Relaxed);
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Profile {
    /// Exclusive per-render storage, filled by `prepare_render`, never userspace.
    pub(crate) payload: u64,
}

impl Profile {
    /// Total exclusive per-render `0x1ca48` UAT backing aperture across all
    /// geometry clusters (`NUM_CLUSTERS * CLUSTER_PAYLOAD_BYTES` = 512 KiB on
    /// 2-cluster T8132). Mapping less leaves Cluster 0 slots >= 16 and all of
    /// Cluster 1 unmapped, silently corrupting to zero when evicted from L2.
    pub(crate) const PAYLOAD_BYTES: usize = NUM_CLUSTERS * CLUSTER_PAYLOAD_BYTES;
    pub(crate) const TA_SIZE: u64 = 0x13300;
    pub(crate) const GATE: u64 = 0xec_0040_0020;

    pub(crate) fn payload_register(self) -> Option<u64> {
        // Absolute-address interpretation: 16 KiB-aligned base VA whose full
        // multi-cluster aperture `[payload, payload + PAYLOAD_BYTES)` stays
        // within the 40-bit VA bound.
        let end = self.payload.checked_add(Self::PAYLOAD_BYTES as u64)?;
        (self.payload != 0 && self.payload & 0x3fff == 0 && end <= (1 << 40))
            .then_some(0x0200_0000_0000_0000 | self.payload)
    }
}

// SPDX-License-Identifier: GPL-2.0-only
// Included by test-native-mesh.py, together with the actual production methods.
use g16_mesh::{Profile, RenderReject};

#[test]
fn parameter_parsing_accepts_zero_one_and_legacy_four_only() {
    assert_eq!(g16_mesh::parse_parameter(0), Some(false));
    assert_eq!(g16_mesh::parse_parameter(1), Some(true));
    assert_eq!(g16_mesh::parse_parameter(4), Some(true));
    for invalid in [2, 3, 5, 6, 16, 255, u32::MAX] {
        assert_eq!(g16_mesh::parse_parameter(invalid), None, "value {invalid}");
    }
}

#[test]
fn a_runtime_enable_gate_starts_off_and_file_latch_prevents_aba_discovery_race() {
    // Runs first under --test-threads=1: verifies the static AtomicBool starts false.
    assert!(!g16_mesh::enabled(), "native_mesh gate must default to disabled");

    // Client A opens DRM fd while gate is off; later runtime enable does not
    // mutate Client A's GET_PARAMS or VM_CREATE latch.
    let file_a = g16_mesh::enabled();
    assert!(!file_a);
    g16_mesh::set_enabled(true);
    assert!(g16_mesh::enabled());
    let vm_a = file_a;
    assert_eq!(
        g16_mesh::render_profile(vm_a, true, false),
        Err(RenderReject::VmDisabled)
    );
    assert_eq!(g16_mesh::render_profile(vm_a, false, false), Ok(None));
    assert_eq!(g16_mesh::render_profile(vm_a, false, true), Ok(None));

    // Client B opens DRM fd while gate is on. Even if root toggles 1 -> 0 -> 1
    // between open(), GET_PARAMS, and VM_CREATE (the ABA race), Client B's
    // file latch keeps GET_PARAMS and VM_CREATE identical.
    let file_b = g16_mesh::enabled();
    assert!(file_b);
    let get_params_before = file_b;
    g16_mesh::set_enabled(false);
    assert!(!g16_mesh::enabled());
    let vm_b = file_b;
    g16_mesh::set_enabled(true);
    let get_params_after = file_b;
    assert!(get_params_before && vm_b && get_params_after);
    assert_eq!(
        g16_mesh::render_profile(vm_b, true, false),
        Ok(Some(Profile::default()))
    );
    assert_eq!(
        g16_mesh::render_profile(vm_b, true, true),
        Err(RenderReject::FewPrimitivesConflict)
    );

    // Restore default-off state for any subsequent tests.
    g16_mesh::set_enabled(false);
    assert!(!g16_mesh::enabled());
}

#[test]
fn render_profile_enforces_vm_latch_and_few_primitives_mutual_exclusion() {
    let cases = [
        // (vm_native_mesh, native_mesh_flag, few_primitives_flag, expected)
        (false, false, false, Ok(None)),
        (false, false, true, Ok(None)),
        (false, true, false, Err(RenderReject::VmDisabled)),
        (false, true, true, Err(RenderReject::VmDisabled)),
        (true, false, false, Ok(None)),
        (true, false, true, Ok(None)),
        (true, true, false, Ok(Some(Profile::default()))),
        (true, true, true, Err(RenderReject::FewPrimitivesConflict)),
    ];
    for (vm_native, flag_native, flag_few, expected) in cases {
        assert_eq!(
            g16_mesh::render_profile(vm_native, flag_native, flag_few),
            expected,
            "vm={vm_native} native={flag_native} few={flag_few}"
        );
    }
}

#[test]
fn rejected_render_flags_separate_unknown_einval_from_recognized_eopnotsupp() {
    use g16_mesh::{classify_rejected_render_flags, RenderFlagsReject};
    const ACCEPTED: u32 = (1 << 1) | (1 << 18) | (1 << 28) | (1 << 29) | (1 << 30);
    const KNOWN_UNSUPPORTED: u32 = (1 << 0) | (1 << 2);
    const EOPNOTSUPP: i32 = 95;
    const ENOTSUPP_INTERNAL: i32 = 524;

    let to_errno = |rejected: u32| match classify_rejected_render_flags(rejected, KNOWN_UNSUPPORTED) {
        RenderFlagsReject::Unknown => EINVAL,
        RenderFlagsReject::Unsupported => EOPNOTSUPP,
    };

    // Recognized unimplemented upstream flags -> EOPNOTSUPP (95), never 524.
    for flags in [1u32 << 0, 1u32 << 2, (1u32 << 0) | (1u32 << 2)] {
        let rejected = flags & !ACCEPTED;
        assert_ne!(rejected, 0);
        assert_eq!(
            classify_rejected_render_flags(rejected, KNOWN_UNSUPPORTED),
            RenderFlagsReject::Unsupported
        );
        assert_eq!(to_errno(rejected), EOPNOTSUPP);
        assert_ne!(to_errno(rejected), ENOTSUPP_INTERNAL);
    }

    // Every single unknown bit (including legacy downstream bit 3 and bit 31)
    // and any mix of unknown + recognized-unsupported -> EINVAL (22).
    for bit in 0..32u32 {
        let flag = 1u32 << bit;
        if flag & (ACCEPTED | KNOWN_UNSUPPORTED) != 0 {
            continue;
        }
        assert_eq!(
            classify_rejected_render_flags(flag, KNOWN_UNSUPPORTED),
            RenderFlagsReject::Unknown,
            "bit {bit} must be Unknown (EINVAL)"
        );
        assert_eq!(to_errno(flag), EINVAL);
        assert_eq!(
            classify_rejected_render_flags(flag | KNOWN_UNSUPPORTED, KNOWN_UNSUPPORTED),
            RenderFlagsReject::Unknown,
            "bit {bit} combined with recognized-unsupported must still be Unknown (EINVAL)"
        );
    }
}

#[test]
fn pool_has_native_flight_attributes_tvb_refusal_strictly_by_vm_root() {
    use g16_mesh::pool_has_native_flight;
    const ROOT_A: u64 = 0x10_0000_0000;
    const ROOT_B: u64 = 0x20_0000_0000;

    // 1. Selected render itself is native (already taken out of self.flights).
    assert!(pool_has_native_flight(true, ROOT_A, []));
    assert!(pool_has_native_flight(true, ROOT_A, [(false, ROOT_B)]));

    // 2. Selected render is ordinary, but a peer render on the SAME root is native.
    assert!(pool_has_native_flight(
        false,
        ROOT_A,
        [(false, ROOT_A), (true, ROOT_A), (false, ROOT_B)]
    ));

    // 3. Selected render is ordinary, and native peers exist ONLY on OTHER roots:
    //    must NOT charge ROOT_A's ordinary pool for another VM's native render.
    assert!(!pool_has_native_flight(
        false,
        ROOT_A,
        [(false, ROOT_A), (true, ROOT_B)]
    ));

    // 4. All ordinary renders -> false.
    assert!(!pool_has_native_flight(false, ROOT_A, [(false, ROOT_A)]));
}

#[test]
fn native_mesh_render_counter_increments_once_on_publish_not_ebusy_retries() {
    use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
    let counter = AtomicU64::new(0);
    // Ordinary renders never increment, whether deferred or published.
    g16_mesh::note_render_published(false, false, &counter);
    g16_mesh::note_render_published(true, false, &counter);
    assert_eq!(counter.load(Relaxed), 0);
    // Native mesh render deferred twice (EBUSY) before publishing increments once.
    g16_mesh::note_render_published(false, true, &counter);
    g16_mesh::note_render_published(false, true, &counter);
    assert_eq!(counter.load(Relaxed), 0);
    g16_mesh::note_render_published(true, true, &counter);
    assert_eq!(counter.load(Relaxed), 1);
    // Second published native mesh render increments to 2.
    g16_mesh::note_render_published(true, true, &counter);
    assert_eq!(counter.load(Relaxed), 2);
}

#[test]
fn profile_constants_and_payload_register_bounds_are_exact() {
    assert_eq!(Profile::default(), Profile { payload: 0 });
    assert_eq!(g16_mesh::CLUSTER_PAYLOAD_BYTES, 0x40000);
    assert_eq!(g16_mesh::NUM_CLUSTERS, 2);
    assert_eq!(Profile::PAYLOAD_BYTES, 0x80000);
    assert_eq!(
        Profile::PAYLOAD_BYTES,
        g16_mesh::NUM_CLUSTERS * g16_mesh::CLUSTER_PAYLOAD_BYTES
    );
    assert_eq!(Profile::TA_SIZE, 0x13300);
    assert_eq!(Profile::GATE, 0xec_0040_0020);
    for bad_payload in [
        0u64,
        1,
        0x3fff,
        0x10e4000004,
        (1 << 40) - Profile::PAYLOAD_BYTES as u64 + 0x4000,
        (1 << 40) - 0x4000,
        1 << 40,
        u64::MAX,
    ] {
        assert_eq!(Profile { payload: bad_payload }.payload_register(), None);
    }
    for ok_payload in [
        0x4000u64,
        0x10e6ad4000, // 16 KiB-aligned, non-256 KiB-aligned base
        0x10e4040000, // 256 KiB-aligned base
        (1 << 40) - Profile::PAYLOAD_BYTES as u64,
    ] {
        assert_eq!(
            Profile { payload: ok_payload }.payload_register(),
            Some(0x0200_0000_0000_0000 | ok_payload)
        );
    }
}

fn read32(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(buf[off..off + 4].try_into().unwrap())
}
fn read64(buf: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(buf[off..off + 8].try_into().unwrap())
}

#[test]
fn initialized_pool_covers_all_advertised_native_pages() {
    for start in [0x1080000000, 0x10e0000000] {
        let pool = g16_render::OperandPool::new(start, start + 0x20000000).unwrap();
        let header = pool.support(7, 0xfffffc2002810000);
        assert_eq!(read32(&header, 0x20), 0);
        assert_eq!(read32(&header, 0x24), 24 * 512);
        assert_eq!(read32(&header, 0x2c), 24 * 512);
        assert_eq!(read32(&header, 0x48), 24 * 8);
        let aliases = g16_render::private_aliases(&pool);
        assert_eq!(read64(&header, 0x14), aliases[3].0);
        assert_eq!(read64(&header, 0x30), aliases[4].0);
        let mut descriptors = [0; 0x4000];
        g16_render::private_page(&pool, 0x440000, &mut descriptors).unwrap();
        for buffer in 0..24 {
            let (va, backing, size) = aliases[16 + buffer];
            assert_eq!(read64(&descriptors, buffer * 0x40), va | (1 << 61));
            assert_eq!(size, 0x200000);
            assert!(backing + size as u64 <= g16_render::PRIVATE_SIZE as u64);
            if buffer != 0 {
                let previous = aliases[15 + buffer];
                assert!(va >= previous.0 + previous.2 as u64 + 0x8000);
            }
        }
        for offset in (0x40000..0x58000).step_by(0x4000) {
            let mut page = [0; 0x4000];
            g16_render::private_page(&pool, offset, &mut page).unwrap();
            for index in 0..0x800 {
                let entry = (offset - 0x40000) / 8 + index;
                let (va, _, size) = aliases[16 + entry / 512];
                let address = read64(&page, index * 8);
                assert_eq!(address, va + (entry % 512) as u64 * 0x1000);
                assert!(address + 0x1000 <= va + size as u64);
            }
        }
    }
}

macro_rules! parameters {
    ($module:ident, $scene:expr, $layers:expr, $samples:expr) => {{
        let mut p = $module::Parameters::default();
        p.set_private(0x10e0000000, 0x1100000000).unwrap();
        p.width = 640 + $scene;
        p.height = 480;
        p.layers = $layers;
        p.samples = $samples;
        p.utile_width = 32;
        p.utile_height = 16;
        p.tib_blocks = 64;
        p.encoder = p.context_base + 0x10000;
        p.scene_slot = $scene;
        p.cycle = 0x240000 + $scene * 0x30;
        p.tiling_gate = 0xa900400020;
        p.fragment_gate = 0xd500400020;
        p.tiling_work_stamp = 0x12345678;
        p.fragment_work_stamp = 0x76543210;
        p.request_tvb_growth = true;
        p.completion_control = 1;
        p
    }};
}

#[test]
fn ordinary_work_is_byte_identical_to_214() {
    for scene in 0..80 {
        for layers in [1, 2, 16] {
            for samples in [1, 2, 4] {
                let old = parameters!(baseline, scene, layers, samples);
                let new = parameters!(g16_render, scene, layers, samples);
                assert_eq!(old.tiling_registers(), new.tiling_registers());
                assert_eq!(old.fragment_registers(), new.fragment_registers());
                let old_a = baseline::Addresses::bootstrap();
                let new_a = g16_render::Addresses::bootstrap();
                let mut old_ta = [0; 0x940];
                let mut new_ta = [0; 0x940];
                let mut old_frag = [0; 0xcc0];
                let mut new_frag = [0; 0xcc0];
                old.tiling_work(&old_a, &mut old_ta).unwrap();
                new.tiling_work(&new_a, &mut new_ta).unwrap();
                old.fragment_work(&old_a, &mut old_frag).unwrap();
                new.fragment_work(&new_a, &mut new_frag).unwrap();
                assert_eq!(old_ta, new_ta);
                assert_eq!(old_frag, new_frag);
            }
        }
    }
}

#[test]
fn mesh_ta_has_ordered_extension_and_preserves_scene_selection() {
    for scene in 0..80 {
        let mut p = parameters!(g16_render, scene, 1, 1);
        let ordinary = p.tiling_registers().unwrap();
        let fragment = p.fragment_registers().unwrap();
        let payload = 0x10e4000000 + scene * 0x4000;
        p.mesh = Some(Profile { payload });
        let registers = p.tiling_registers().unwrap();
        assert_eq!(registers[55].0, 0x10799);
        assert_eq!(registers[56], (0x1ca48, 0x0200000000000000 | payload));
        assert!(!registers.iter().any(|r| r.0 == 0x10209));
        for &(reg, value) in &ordinary {
            if reg != 0x10209 && reg != 0xa5a1 {
                assert!(registers.contains(&(reg, value)));
            }
        }
        assert_eq!(p.fragment_registers().unwrap(), fragment);
        assert_eq!(
            registers.iter().find(|r| r.0 == 0xa5a1).unwrap().1,
            Profile::GATE
        );
        let mut work = [0; 0x940];
        p.tiling_work(&g16_render::Addresses::bootstrap(), &mut work)
            .unwrap();
        assert_eq!(&work[0x748..0x74c], &[0x42, 0, 0x18, 3]);
        assert_eq!(read32(&work, 0x86c), 1);
        assert_eq!(read64(&work, 0x908), 0x13300);
    }
}

#[test]
fn mesh_ta_and_fragment_preserve_multilayer_and_msaa_encoding() {
    let a = g16_render::Addresses::bootstrap();
    for layers in [1u64, 2, 4, 16, 2048] {
        for samples in [1u64, 2, 4] {
            let mut p = parameters!(g16_render, 7, layers, samples);
            if samples == 4 {
                p.utile_width = 32;
                p.utile_height = 16;
            } else {
                p.utile_width = 32;
                p.utile_height = 32;
            }
            p.sample_size = 16;
            p.tib_blocks = (p.sample_size * p.utile_width * p.utile_height * samples).div_ceil(2048);
            p.utile_config = (p.utile_width / 16) << 12
                | (p.utile_height / 16) << 14
                | match samples {
                    1 => 0,
                    2 => 1,
                    4 => 2,
                    _ => unreachable!(),
                };
            p.tile_config = 0x280 | u64::from(layers > 1);
            p.multisample_control = match samples {
                1 => 0x88,
                2 => 0x4c_c4,
                4 => 0x26_e2_6e_a6,
                _ => unreachable!(),
            };
            p.layermeta = p.heapmeta;
            if layers > 1 {
                p.heapmeta += 0x100;
            }

            let ordinary_ta_regs = p.tiling_registers().unwrap();
            let ordinary_frag_regs = p.fragment_registers().unwrap();
            let mut ordinary_ta = [0; 0x940];
            let mut ordinary_frag = [0; 0xcc0];
            p.tiling_work(&a, &mut ordinary_ta).unwrap();
            p.fragment_work(&a, &mut ordinary_frag).unwrap();

            let payload = 0x10e4010000;
            p.mesh = Some(Profile { payload });
            let mesh_ta_regs = p.tiling_registers().unwrap();
            let mesh_frag_regs = p.fragment_registers().unwrap();
            let mut mesh_ta = [0; 0x940];
            let mut mesh_frag = [0; 0xcc0];
            p.tiling_work(&a, &mut mesh_ta).unwrap();
            p.fragment_work(&a, &mut mesh_frag).unwrap();

            // 3D stage is identical between ordinary and native mesh renders.
            assert_eq!(mesh_frag_regs, ordinary_frag_regs);
            assert_eq!(mesh_frag, ordinary_frag);
            assert_eq!(read32(&mesh_frag, 0x50), samples as u32);
            assert_eq!(read32(&mesh_frag, 0xbac), u32::from(samples > 1));
            assert_eq!(read64(&mesh_frag, 0xbe8), layers - 1);
            assert_eq!(
                read64(&mesh_frag, 0xc50),
                0x113a0 | if layers > 1 { 1 << 62 } else { 0 }
            );

            // TA register list preserves every layer and MSAA register.
            assert_eq!(mesh_ta_regs[55].0, 0x10799);
            assert_eq!(mesh_ta_regs[56], (0x1ca48, 0x0200000000000000 | payload));
            assert!(!mesh_ta_regs.iter().any(|r| r.0 == 0x10209));
            for &(reg, value) in &ordinary_ta_regs {
                if reg != 0x10209 && reg != 0xa5a1 {
                    assert!(
                        mesh_ta_regs.contains(&(reg, value)),
                        "missing TA reg {reg:#x}={value:#x} for layers={layers} samples={samples}"
                    );
                }
            }
            let target_layers = if layers > 1 { 0xe000 | (layers - 1) } else { 0x8000 };
            assert_eq!(mesh_ta_regs.iter().find(|r| r.0 == 0x10149).unwrap().1, p.utile_config);
            assert_eq!(mesh_ta_regs.iter().find(|r| r.0 == 0x10139).unwrap().1, p.multisample_control);
            assert_eq!(mesh_ta_regs.iter().find(|r| r.0 == 0x10169).unwrap().1, target_layers);
            assert_eq!(mesh_ta_regs.iter().find(|r| r.0 == 0x1c9e8).unwrap().1, target_layers & 0x4fff);
            assert_eq!(mesh_ta_regs.iter().find(|r| r.0 == 0x0a5a1).unwrap().1, Profile::GATE);

            // TA Work preserves layer TPC scaling, layer count, and bit 62 alongside mesh TA_SIZE.
            assert_eq!(&mesh_ta[0x748..0x74c], &[0x42, 0, 0x18, 3]);
            assert_eq!(read64(&mesh_ta, 0x768), read64(&ordinary_ta, 0x768));
            assert_eq!(read32(&mesh_ta, 0x86c), 1);
            assert_eq!(read64(&mesh_ta, 0x8a0), layers - 1);
            assert_eq!(
                read64(&mesh_ta, 0x908),
                Profile::TA_SIZE | if layers > 1 { 1 << 62 } else { 0 }
            );
        }
    }
}

// Small I/O double for the production scratch allocation, reuse, and release methods.
type Error = i32;
type Result<T = ()> = std::result::Result<T, Error>;
const EINVAL: Error = 22;
const ENOMEM: Error = 12;
const EIO: Error = 5;
const EBUSY: Error = 16;
const EEXIST: Error = 17;
const GFP_NOWAIT: u32 = 1;
const __GFP_NOWARN: u32 = 2;
const __GFP_ZERO: u32 = 4;
mod prot {
    pub const PROT_GPU_SHARED_RW: () = ();
}
mod g16_timeline {
    pub struct Timer;
    pub static P_PREPARE_RENDER: () = ();
    impl Timer {
        pub fn start(_: &()) -> Self {
            Self
        }
    }
}
const UAT_PGSZ: usize = 0x4000;
#[derive(Debug, PartialEq)]
struct Scratch {
    range: std::ops::Range<u64>,
    render: bool,
}
struct KVec<T>(Vec<T>);
impl<T> KVec<T> {
    fn new() -> Self {
        Self(Vec::new())
    }
    fn capacity(&self) -> usize {
        self.0.capacity()
    }
    fn reserve(&mut self, additional: usize, _: u32) -> Result {
        self.0.reserve(additional);
        Ok(())
    }
    fn iter(&self) -> std::slice::Iter<'_, T> {
        self.0.iter()
    }
    fn len(&self) -> usize {
        self.0.len()
    }
    fn remove(&mut self, index: usize) -> Result<T> {
        Ok(self.0.remove(index))
    }
    fn push_within_capacity(&mut self, value: T) -> std::result::Result<(), T> {
        if self.0.len() == self.0.capacity() {
            return Err(value);
        }
        self.0.push(value);
        Ok(())
    }
}
impl<T> IntoIterator for KVec<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}
impl<T> std::ops::Index<usize> for KVec<T> {
    type Output = T;
    fn index(&self, index: usize) -> &Self::Output {
        &self.0[index]
    }
}
impl<T> std::ops::IndexMut<usize> for KVec<T> {
    fn index_mut(&mut self, index: usize) -> &mut Self::Output {
        &mut self.0[index]
    }
}
#[derive(Clone)]
struct TestArena {
    next: u64,
    end: u64,
}
impl TestArena {
    fn new(range: std::ops::Range<u64>) -> Self {
        Self {
            next: range.start,
            end: range.end,
        }
    }
    fn alloc(&mut self, size: u64, align: u64) -> Option<std::ops::Range<u64>> {
        let start = (self.next + align - 1) & !(align - 1);
        let end = start.checked_add(size)?;
        if end > self.end {
            return None;
        }
        self.next = end;
        Some(start..end)
    }
}
struct GpuPage {
    bytes: std::cell::RefCell<Box<[u8; UAT_PGSZ]>>,
    clears: std::cell::Cell<usize>,
    phys_addr: u64,
}
impl GpuPage {
    fn alloc(gfp: u32) -> Result<Self> {
        assert_ne!(gfp & __GFP_ZERO, 0, "scratch backing must be __GFP_ZERO");
        static NEXT_PHYS: std::sync::atomic::AtomicU64 =
            std::sync::atomic::AtomicU64::new(0x8_0000_0000);
        let phys_addr = NEXT_PHYS.fetch_add(UAT_PGSZ as u64, std::sync::atomic::Ordering::Relaxed);
        Ok(Self {
            bytes: std::cell::RefCell::new(Box::new([0u8; UAT_PGSZ])),
            clears: std::cell::Cell::new(0),
            phys_addr,
        })
    }
    fn phys(&self) -> u64 {
        self.phys_addr
    }
    fn with_page_mapped(&self, f: impl FnOnce(*mut u8)) {
        self.clears.set(self.clears.get() + 1);
        f(self.bytes.borrow_mut().as_mut_ptr());
    }
}
struct RBTreeNode(u64, GpuPage);
impl RBTreeNode {
    fn new(va: u64, page: GpuPage, _: u32) -> Result<Self> {
        Ok(Self(va, page))
    }
}
struct TestPages(std::collections::BTreeMap<u64, GpuPage>);
impl TestPages {
    fn new() -> Self {
        Self(std::collections::BTreeMap::new())
    }
    fn get(&self, va: &u64) -> Option<&GpuPage> {
        self.0.get(va)
    }
    fn insert(&mut self, node: RBTreeNode) {
        assert!(self.0.insert(node.0, node.1).is_none());
    }
}
struct TestLowPt {
    mapped: std::collections::BTreeMap<u64, u64>,
    allocs: Vec<std::ops::Range<u64>>,
}
impl TestLowPt {
    fn new() -> Self {
        Self {
            mapped: std::collections::BTreeMap::new(),
            allocs: Vec::new(),
        }
    }
    fn translate(&self, va: u64) -> Result<Option<u64>> {
        Ok(self.mapped.get(&va).copied())
    }
    fn prepare_map_gfp(&mut self, range: std::ops::Range<u64>, _: u32) -> Result {
        self.allocs.push(range);
        Ok(())
    }
    fn map_pages_gfp(
        &mut self,
        range: std::ops::Range<u64>,
        phys: u64,
        _: (),
        _: bool,
        _: u32,
    ) -> Result {
        assert_eq!(range.end - range.start, UAT_PGSZ as u64);
        assert!(self.mapped.insert(range.start, phys).is_none());
        Ok(())
    }
}
struct ScratchVm {
    low: TestLowPt,
    pages: TestPages,
    owned_bytes: usize,
    compute_arena: TestArena,
    render_arena: TestArena,
    scratch_free: [KVec<std::ops::Range<u64>>; 2],
    scratch_users: [usize; 2],
    scratch_max_block: [usize; 2],
    writes: Vec<(u64, Vec<u8>)>,
    fail_write: bool,
}
impl ScratchVm {
    fn new(render_start: u64) -> Self {
        Self {
            low: TestLowPt::new(),
            pages: TestPages::new(),
            owned_bytes: 0,
            compute_arena: TestArena::new(0x10a0000000..0x10c0000000),
            render_arena: TestArena::new(render_start..0x1100000000),
            scratch_free: [KVec::new(), KVec::new()],
            scratch_users: [0; 2],
            scratch_max_block: [0; 2],
            writes: Vec::new(),
            fail_write: false,
        }
    }
    fn fill_range(&self, range: std::ops::Range<u64>, byte: u8) {
        for va in range.step_by(UAT_PGSZ) {
            self.pages.get(&va).unwrap().bytes.borrow_mut().fill(byte);
        }
    }
    fn page_byte(&self, va: u64) -> u8 {
        self.pages.get(&va).unwrap().bytes.borrow()[0]
    }
    fn clear_count(&self, va: u64) -> usize {
        self.pages.get(&va).unwrap().clears.get()
    }
    fn write_low(&mut self, va: u64, data: &[u8]) -> Result {
        if self.fail_write {
            return Err(EIO);
        }
        self.writes.push((va, data.to_vec()));
        Ok(())
    }
    fn has_pending_tables(&self) -> bool {
        false
    }
    fn sync(&self) {}
    /* PREPARE_RENDER */
    /* LEASE_SCRATCH */
    /* RELEASE_SCRATCH */
}

#[test]
fn payload_has_a_distinct_zeroed_aperture_in_each_render_lease() {
    assert_eq!(Profile::PAYLOAD_BYTES, 0x80000);
    let mut vm = ScratchVm::new(0x10e4000000);
    let mut ordinary = parameters!(g16_render, 0, 1, 1);
    let ordinary_lease = vm.prepare_render(&mut ordinary).unwrap();
    assert_eq!(vm.writes.len(), 1);
    let mut previous = ordinary_lease.range;
    for _ in 0..8 {
        let mut mesh = parameters!(g16_render, 0, 1, 1);
        mesh.mesh = Some(Profile::default());
        vm.writes.clear();
        let lease = vm.prepare_render(&mut mesh).unwrap();
        let address = mesh.mesh.unwrap().payload;
        assert_eq!(address & 0x3fff, 0);
        assert_eq!(lease.range.end - address, Profile::PAYLOAD_BYTES as u64);
        assert_eq!(lease.range.end - address, 0x80000);
        assert_eq!(
            mesh.mesh.unwrap().payload_register(),
            Some(0x0200_0000_0000_0000 | address)
        );
        assert!(address >= mesh.aux_fb + 0x4000);
        assert!(lease.range.start >= previous.end);
        // Fresh allocation zero-initializes the full [start..end) lease via
        // __GFP_ZERO in alloc_low, covering Cluster 0 [0..256 KiB) and Cluster 1
        // [256 KiB..512 KiB) without any reuse write_bytes pass.
        for va in (address..address + Profile::PAYLOAD_BYTES as u64).step_by(UAT_PGSZ) {
            assert_eq!(vm.page_byte(va), 0);
            assert_eq!(vm.clear_count(va), 0);
        }
        assert_eq!(vm.writes.len(), 1);
        assert_eq!(vm.writes[0].0, mesh.aux_fb + 0x600);
        previous = lease.range;
    }
    assert_eq!(
        (vm.low.allocs[1].end - vm.low.allocs[1].start)
            - (vm.low.allocs[0].end - vm.low.allocs[0].start),
        Profile::PAYLOAD_BYTES as u64
    );
}

#[test]
fn prepare_render_places_layermeta_heapmeta_and_payload_for_multilayer_and_msaa() {
    let mut vm = ScratchVm::new(0x10e4000000);
    let a = g16_render::Addresses::bootstrap();
    let mut previous_end = 0x10e4000000;
    for layers in [1u64, 2, 4, 16] {
        for samples in [1u64, 2, 4] {
            let mut mesh = parameters!(g16_render, 3, layers, samples);
            if samples == 4 {
                mesh.utile_width = 32;
                mesh.utile_height = 16;
            } else {
                mesh.utile_width = 32;
                mesh.utile_height = 32;
            }
            mesh.mesh = Some(Profile::default());
            vm.writes.clear();
            let (tilemap, tpc) = mesh.scratch_sizes().unwrap();
            let lease = vm.prepare_render(&mut mesh).unwrap();
            let meta = lease.range.start + (tilemap + tpc) as u64;
            let payload = mesh.mesh.unwrap().payload;
            assert!(lease.range.start >= previous_end);
            assert_eq!(mesh.tilemap, lease.range.start);
            assert_eq!(mesh.tpc, lease.range.start + tilemap as u64);
            assert_eq!(mesh.layermeta, meta);
            assert_eq!(mesh.heapmeta, meta + if layers > 1 { 0x100 } else { 0 });
            assert_eq!(mesh.aux_fb, meta + 0x10000);
            assert_eq!(payload, meta + 0x14000);
            assert_eq!(payload & 0x3fff, 0);
            assert_eq!(lease.range.end - payload, Profile::PAYLOAD_BYTES as u64);
            for va in (meta..lease.range.end).step_by(UAT_PGSZ) {
                assert_eq!(vm.page_byte(va), 0);
            }
            assert_eq!(vm.writes.len(), 1);
            assert_eq!(vm.writes[0].0, mesh.aux_fb + 0x600);
            let mut ta = [0; 0x940];
            let mut frag = [0; 0xcc0];
            mesh.tiling_work(&a, &mut ta).unwrap();
            mesh.fragment_work(&a, &mut frag).unwrap();
            assert_eq!(read32(&ta, 0x86c), 1);
            assert_eq!(read64(&ta, 0x8a0), layers - 1);
            assert_eq!(
                read64(&ta, 0x908),
                Profile::TA_SIZE | if layers > 1 { 1 << 62 } else { 0 }
            );
            assert_eq!(read32(&frag, 0x50), samples as u32);
            assert_eq!(read32(&frag, 0xbac), u32::from(samples > 1));
            previous_end = lease.range.end;
        }
    }
}

#[test]
fn lease_scratch_partial_clear_skips_mesh_payload_on_reuse_and_clears_reused_metadata() {
    let mut vm = ScratchVm::new(0x10e4000000);
    // 1. Fresh native render: allocates __GFP_ZERO pages for the entire range.
    let mut mesh1 = parameters!(g16_render, 0, 1, 1);
    mesh1.mesh = Some(Profile::default());
    let (tilemap, tpc) = mesh1.scratch_sizes().unwrap();
    let lease1 = vm.prepare_render(&mut mesh1).unwrap();
    let base = lease1.range.start;
    let meta = base + (tilemap + tpc) as u64;
    let payload = mesh1.mesh.unwrap().payload;
    assert_eq!(payload, meta + 5 * UAT_PGSZ as u64);
    assert_eq!(lease1.range.end, payload + Profile::PAYLOAD_BYTES as u64);
    // Simulate GPU writing to every page in the lease, then retire & release.
    vm.fill_range(lease1.range.clone(), 0x5a);
    vm.release_scratch(lease1).unwrap();

    // 2. Same-VM native reuse: ONLY the 5 metadata pages [meta..payload) are
    // re-zeroed; tilemap/TPC and all 32 pages (512 KiB) of 0x1ca48 payload are
    // left untouched without CPU kmap+memset.
    let allocs_before = vm.low.allocs.len();
    let mut mesh2 = parameters!(g16_render, 0, 1, 1);
    mesh2.mesh = Some(Profile::default());
    let lease2 = vm.prepare_render(&mut mesh2).unwrap();
    assert_eq!(vm.low.allocs.len(), allocs_before);
    assert_eq!(lease2.range.start, base);
    for va in (base..meta).step_by(UAT_PGSZ) {
        assert_eq!(vm.page_byte(va), 0x5a, "tilemap/tpc page {va:#x} must not be cleared");
        assert_eq!(vm.clear_count(va), 0);
    }
    for va in (meta..payload).step_by(UAT_PGSZ) {
        assert_eq!(vm.page_byte(va), 0, "metadata page {va:#x} must be cleared");
        assert_eq!(vm.clear_count(va), 1);
    }
    for va in (payload..lease2.range.end).step_by(UAT_PGSZ) {
        assert_eq!(vm.page_byte(va), 0x5a, "payload page {va:#x} must not be re-cleared");
        assert_eq!(vm.clear_count(va), 0);
    }

    // 3. Release native lease and split it into multiple ordinary renders so an
    // ordinary render's metadata pages land directly on former dirty 0x1ca48
    // payload pages: those metadata pages MUST still be freshly zeroed!
    vm.fill_range(lease2.range.clone(), 0xa5);
    vm.release_scratch(lease2).unwrap();
    let mut ordinary_leases = Vec::new();
    let mut metadata_on_former_payload = false;
    while {
        let mut ord = parameters!(g16_render, 0, 1, 1);
        let (o_tm, o_tpc) = ord.scratch_sizes().unwrap();
        let ord_size = o_tm + o_tpc + 5 * UAT_PGSZ;
        // Stop before allocating fresh VA outside the released native lease.
        let free_avail = vm.scratch_free[1]
            .iter()
            .any(|r| r.end - r.start >= ord_size as u64);
        if free_avail {
            let lease = vm.prepare_render(&mut ord).unwrap();
            let o_meta = lease.range.start + (o_tm + o_tpc) as u64;
            if o_meta >= payload {
                metadata_on_former_payload = true;
            }
            for va in (o_meta..o_meta + 5 * UAT_PGSZ as u64).step_by(UAT_PGSZ) {
                assert_eq!(vm.page_byte(va), 0, "reused ordinary metadata {va:#x} must be zeroed");
            }
            ordinary_leases.push(lease);
            true
        } else {
            false
        }
    } {}
    assert!(metadata_on_former_payload, "test must cover ordinary metadata landing on former payload pages");
    // Coalesce all ordinary leases back into one free range and verify native reuse.
    for lease in ordinary_leases {
        vm.release_scratch(lease).unwrap();
    }
    assert_eq!(vm.scratch_free[1].len(), 1);
    let mut mesh3 = parameters!(g16_render, 0, 1, 1);
    mesh3.mesh = Some(Profile::default());
    let lease3 = vm.prepare_render(&mut mesh3).unwrap();
    assert_eq!(lease3.range.start, base);
    vm.release_scratch(lease3).unwrap();

    // 4. Compute scratch reuse clears BOTH marker (+0x20000) and save_area (+0x24000).
    let c1 = vm.lease_scratch(false, 0x28000, 0x20000, 2 * UAT_PGSZ).unwrap();
    let c_base = c1.range.start;
    vm.fill_range(c1.range.clone(), 0x77);
    vm.release_scratch(c1).unwrap();
    let c2 = vm.lease_scratch(false, 0x28000, 0x20000, 2 * UAT_PGSZ).unwrap();
    assert_eq!(c2.range.start, c_base);
    for va in (c_base..c_base + 0x20000).step_by(UAT_PGSZ) {
        assert_eq!(vm.page_byte(va), 0x77);
    }
    for offset in [0x20000u64, 0x24000u64] {
        assert_eq!(vm.page_byte(c_base + offset), 0);
        assert_eq!(vm.clear_count(c_base + offset), 1);
    }
    vm.release_scratch(c2).unwrap();

    // 4b. A write_low failure inside prepare_render releases the native scratch
    // lease back to scratch_free (no leaked scratch_users).
    vm.fail_write = true;
    let mut mesh_fail = parameters!(g16_render, 0, 1, 1);
    mesh_fail.mesh = Some(Profile::default());
    assert_eq!(vm.prepare_render(&mut mesh_fail), Err(EIO));
    assert_eq!(vm.scratch_users[1], 0);
    assert_eq!(vm.scratch_free[1].len(), 1);
    vm.fail_write = false;

    // 5. Validation errors: zero size, misalignment, clear range out of bounds, overflow.
    for (size, clear_from, clear_len) in [
        (0, 0, 0),
        (UAT_PGSZ + 1, 0, 0),
        (2 * UAT_PGSZ, 1, UAT_PGSZ),
        (2 * UAT_PGSZ, UAT_PGSZ, 1),
        (2 * UAT_PGSZ, UAT_PGSZ, 2 * UAT_PGSZ),
        (2 * UAT_PGSZ, 3 * UAT_PGSZ, 0),
        (2 * UAT_PGSZ, usize::MAX - UAT_PGSZ + 1, UAT_PGSZ),
    ] {
        assert_eq!(
            vm.lease_scratch(true, size, clear_from, clear_len),
            Err(EINVAL),
            "size={size:#x} clear_from={clear_from:#x} clear_len={clear_len:#x}"
        );
    }
}

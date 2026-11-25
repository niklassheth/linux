// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors
// Adapted from Niklas Sheth's linux-m4-integration prototype.

//! G16 client roots. The firmware bootstrap root is separate from these
//! roots, even when the hardware context table is using slot zero.

use crate::g16_alloc::Arena;
use crate::pgtable::{prot, UatPageTable, UAT_PGSZ};
use kernel::rbtree::{RBTree, RBTreeNode};
use kernel::{bindings, device, page::Page, prelude::*, types::Owned};

const IAS: usize = 42;
const OAS: u32 = 42;
const USC_BASE: u64 = 0x100_0000_0000;

/// A page the GPU uses on behalf of a client or the firmware. Its lifetime is
/// counted in the node's `NR_GPU_ACTIVE` (`GPUActive` in /proc/meminfo,
/// `nr_gpu_active` in vmstat), as TTM counts its pool pages, so these pages are
/// not missing from the meminfo totals. The count is per node only: memory
/// cgroups have no such item. Pages allocated with `__GFP_ACCOUNT` are charged
/// to the allocating task's memory cgroup until they are freed.
pub(crate) struct GpuPage(Owned<Page>);

impl GpuPage {
    pub(crate) fn alloc(flags: kernel::alloc::Flags) -> Result<Self, kernel::alloc::AllocError> {
        let page = Page::alloc_page(flags)?;
        // SAFETY: `page` is a valid page owned by this allocation.
        unsafe {
            bindings::mod_node_page_state(
                bindings::page_pgdat(page.as_ptr()),
                bindings::node_stat_item_NR_GPU_ACTIVE,
                1,
            )
        };
        Ok(Self(page))
    }
}

impl core::ops::Deref for GpuPage {
    type Target = Page;
    fn deref(&self) -> &Page {
        &self.0
    }
}

impl Drop for GpuPage {
    fn drop(&mut self) {
        // SAFETY: The page stays allocated until `self.0` is dropped, after
        // this function returns.
        unsafe {
            bindings::mod_node_page_state(
                bindings::page_pgdat(self.0.as_ptr()),
                bindings::node_stat_item_NR_GPU_ACTIVE,
                -1,
            )
        };
    }
}

/// Published root addresses. The submission owner must retain their VM until
/// GPU completion; copying these addresses does not transfer page ownership.
#[derive(Clone, Copy)]
pub(crate) struct Roots {
    pub(crate) low: u64,
    pub(crate) high: u64,
}

pub(crate) struct AddressSpace {
    pub(crate) low: UatPageTable,
    pub(crate) high: UatPageTable,
    // Drop the owned tables before releasing their mapped pages.
    pages: RBTree<u64, GpuPage>,
    /// Bytes of `pages`. Pages are only released with the address space.
    owned_bytes: usize,
    compute_arena: Arena,
    render_arena: Arena,
    scratch_free: [KVec<core::ops::Range<u64>>; 2],
    scratch_users: [usize; 2],
    /// Largest contiguous scratch block installed per kind (`0=compute, 1=render`).
    scratch_max_block: [usize; 2],
    /// Firmware Work slots owned and recycled strictly within this VM.
    work_pool: crate::g16_work_pool::VmWorkPool<KVec<u64>>,
    /// The support of this compute root's FList (a private pool's own lease,
    /// or the VM's render support when sharing its pool). Pending and
    /// quarantined Works retain it with the root, so its hardware slot is not
    /// recycled while the firmware can still use it.
    compute_support: Option<kernel::sync::Arc<crate::g16::Support>>,
    /// Owner of pool pages this root maps but does not own (the render root,
    /// when sharing its pool); retained as long as the mappings.
    _pool_owner: Option<kernel::sync::Arc<kernel::sync::Mutex<AddressSpace>>>,
}

impl crate::g16_work_pool::SlotVec for KVec<u64> {
    fn len(&self) -> usize {
        KVec::len(self)
    }

    fn pop_slot(&mut self) -> Option<u64> {
        self.pop()
    }

    fn last_slot(&self) -> Option<u64> {
        self.last().copied()
    }

    fn push_within(&mut self, va: u64) -> core::result::Result<(), u64> {
        self.push_within_capacity(va).map_err(|_| va)
    }

    fn contains_slot(&self, va: u64) -> bool {
        self.iter().any(|&v| v == va)
    }

    fn remove_slot(&mut self, va: u64) -> bool {
        if let Some(pos) = self.iter().position(|&v| v == va) {
            self.swap_remove(pos);
            true
        } else {
            false
        }
    }
}

/// An exclusive suballocation; its backing remains owned by the VM.
#[derive(Debug, PartialEq)]
pub(crate) struct Scratch {
    range: core::ops::Range<u64>,
    render: bool,
}

impl AddressSpace {
    /// Install a freshly allocated Work alias in this VM as GPU read-only.
    /// The GPU only reads register tables and the CDM entry trampoline from
    /// this page; GPU-writable compute save storage lives on separate scratch
    /// backing (`prepare_compute`), so client shaders can never overwrite live
    /// firmware Work control data. Reused slots stay permanently mapped in
    /// their owning VM and never call this again; any pre-existing PTE at `va`
    /// is rejected so aliases cannot collide.
    pub(crate) fn map_work_alias_gfp(
        &mut self,
        va: u64,
        pa: u64,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        if self.low.translate(va)?.is_some() {
            return Err(EEXIST);
        }
        self.low.map_pages_gfp(
            va..va + UAT_PGSZ as u64,
            pa,
            prot::PROT_GPU_SHARED_RO,
            false,
            gfp,
        )
    }

    /// Remove Work alias PTEs during VM teardown or failed slot installation.
    pub(crate) fn unmap_work_alias_gfp(
        &mut self,
        range: core::ops::Range<u64>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        self.low.unmap_pages_gfp(range, gfp)
    }

    pub(crate) fn has_free_work(&self, render: bool) -> bool {
        self.work_pool.has_free(render)
    }

    pub(crate) fn work_owned(&self, render: bool) -> usize {
        self.work_pool.owned_count(render)
    }

    pub(crate) fn work_owned_any(&self) -> bool {
        self.work_pool.owned_count(false) != 0 || self.work_pool.owned_count(true) != 0
    }

    pub(crate) fn work_leased(&self, render: bool) -> usize {
        self.work_pool.leased_count(render)
    }

    pub(crate) fn work_pool_all_idle(&self) -> bool {
        self.work_pool.all_idle()
    }

    pub(crate) fn pop_free_work(&mut self, render: bool) -> Option<u64> {
        self.work_pool.pop_free(render)
    }

    pub(crate) fn reserve_work_slot_gfp(
        &mut self,
        render: bool,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        let (owned, free, tearing_down) = self.work_pool.lists_mut(render);
        owned.reserve(1, gfp)?;
        let target = owned.len() + 1;
        free.reserve(target.saturating_sub(free.len()), gfp)?;
        tearing_down.reserve(1usize.saturating_sub(tearing_down.len()), gfp)?;
        Ok(())
    }

    pub(crate) fn record_idle_work(&mut self, render: bool, va: u64) -> Result {
        self.work_pool.record_idle(render, va).map_err(|_| EIO)
    }

    pub(crate) fn release_work(&mut self, render: bool, va: u64) -> Result {
        self.work_pool.release(render, va).map_err(|_| EIO)
    }

    pub(crate) fn peek_tearing_down_work(&self, render: bool) -> Option<u64> {
        self.work_pool.peek_tearing_down(render)
    }

    pub(crate) fn begin_teardown_work(&mut self, render: bool) -> Option<u64> {
        self.work_pool.begin_teardown(render)
    }

    pub(crate) fn finish_teardown_work(&mut self, render: bool, va: u64) -> Result {
        self.work_pool.finish_teardown(render, va).map_err(|_| EIO)
    }

    /// Bytes of backing owned by this root (render private storage, scratch,
    /// tiler blocks and per-VM firmware Work slots), for fdinfo.
    pub(crate) fn owned_bytes(&self) -> usize {
        self.owned_bytes + self.work_pool.owned_bytes()
    }

    pub(crate) fn roots(&self) -> Roots {
        Roots {
            low: self.low.ttb(),
            high: self.high.ttb(),
        }
    }

    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            low: UatPageTable::new_with_ias(OAS, IAS)?,
            high: UatPageTable::new_with_ias(OAS, IAS)?,
            pages: RBTree::new(),
            owned_bytes: 0,
            compute_arena: Arena::default(),
            render_arena: Arena::default(),
            scratch_free: [KVec::new(), KVec::new()],
            scratch_users: [0; 2],
            scratch_max_block: [0; 2],
            work_pool: crate::g16_work_pool::VmWorkPool::new(),
            compute_support: None,
            _pool_owner: None,
        })
    }

    pub(crate) fn alloc_low(
        &mut self,
        va: u64,
        size: usize,
        access: crate::pgtable::Prot,
    ) -> Result {
        if size == 0 || (va as usize | size) & (UAT_PGSZ - 1) != 0 {
            return Err(EINVAL);
        }
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        for v in (va..end).step_by(UAT_PGSZ) {
            if self.pages.get(&v).is_some() || self.low.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        for v in (va..end).step_by(UAT_PGSZ) {
            let page = GpuPage::alloc(GFP_KERNEL | __GFP_ZERO)?;
            let phys = page.phys();
            self.pages.try_create_and_insert(v, page, GFP_KERNEL)?;
            self.owned_bytes += UAT_PGSZ;
            self.low
                .map_pages(v..v + UAT_PGSZ as u64, phys, access, false)?;
        }
        Ok(())
    }

    /// Build backend-only render storage before this root is published.
    /// ENOMEM may leave a partial graph, all owned here. This root has never
    /// rendered: retry can finish missing pages/PTEs and reinitialize storage
    /// before its first publication. Never replace a conflicting mapping.
    /// `pool` must be the one whose support object this root's renders use.
    /// Runs in the submitting client's ioctl, which is charged for the pages.
    pub(crate) fn alloc_render_private(
        &mut self,
        start: u64,
        end: u64,
        pool: &crate::g16_render::OperandPool,
    ) -> Result {
        use crate::g16_render as render;
        let mut params = render::Parameters::default();
        params.set_private(start, end).ok_or(EINVAL)?;
        if render::OperandPool::new(start, end).map(|p| p.directory) != Some(pool.directory) {
            return Err(EINVAL);
        }
        let remaining = pool.end().ok_or(EINVAL)?..end.min(render::CONTEXT_BASE + (1 << 32));
        if remaining.start > remaining.end {
            return Err(ENOMEM);
        }
        self.render_arena = Arena::new(remaining);
        for offset in (0..render::PRIVATE_SIZE).step_by(UAT_PGSZ) {
            if !pool.backed(offset) {
                continue;
            }
            let va = start + offset as u64;
            if self.pages.get(&va).is_none() {
                if self.low.translate(va)?.is_some() {
                    return Err(EEXIST);
                }
                let page = GpuPage::alloc(GFP_KERNEL_ACCOUNT | __GFP_ZERO)?;
                self.pages.try_create_and_insert(va, page, GFP_KERNEL_ACCOUNT)?;
                self.owned_bytes += UAT_PGSZ;
            }
            let physical = self.pages.get(&va).ok_or(EIO)?.phys();
            self.map_render_page(va, physical)?;
        }
        for offset in (0..render::PRIVATE_SIZE).step_by(UAT_PGSZ) {
            if !pool.backed(offset) {
                continue;
            }
            let va = start + offset as u64;
            let page = self.pages.get(&va).ok_or(EIO)?;
            page.with_pointer_into_page(0, UAT_PGSZ, |ptr| {
                // SAFETY: The closure has exclusive access to the full page
                // owned by this unpublished VM; no GPU root references it.
                let bytes = unsafe { core::slice::from_raw_parts_mut(ptr, UAT_PGSZ) };
                render::private_page(pool, offset, bytes).ok_or(EINVAL)
            })?;
        }
        for (alias, offset, size) in render::private_aliases(pool) {
            for page in (0..size).step_by(UAT_PGSZ) {
                let va = alias + page as u64;
                let physical = self
                    .low
                    .translate(start + offset + page as u64)?
                    .ok_or(EIO)?;
                self.map_render_page(va, physical)?;
            }
        }
        self.sync();
        Ok(())
    }

    /// A failed first-render allocation can already own this exact PTE.
    fn map_render_page(&mut self, va: u64, physical: u64) -> Result {
        match self.low.translate(va)? {
            Some(existing) if existing == physical => Ok(()),
            Some(_) => Err(EEXIST),
            None => self.low.map_pages(
                va..va + UAT_PGSZ as u64,
                physical,
                prot::PROT_GPU_SHARED_RW,
                false,
            ),
        }
    }

    /// Each active render exclusively leases tile metadata and save storage.
    pub(crate) fn prepare_render(
        &mut self,
        p: &mut crate::g16_render::Parameters,
    ) -> Result<Scratch> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_PREPARE_RENDER);
        let (tilemap, tpc) = p.scratch_sizes().ok_or(EINVAL)?;
        let size = tilemap
            .checked_add(tpc)
            .and_then(|n| n.checked_add(5 * UAT_PGSZ))
            .and_then(|n| n.checked_add(if p.mesh.is_some() {
                crate::g16_mesh::Profile::PAYLOAD_BYTES
            } else { 0 }))
            .ok_or(ENOMEM)?;
        // Only the 5 metadata pages `[meta..meta + 5 * UAT_PGSZ)` need
        // re-zeroing on same-VM reuse; the tilemap, TPC, and trailing
        // hardware-written `0x1ca48` native mesh payload aperture (`512 KiB`)
        // are zeroed once on initial VM page allocation (`__GFP_ZERO` in
        // `alloc_low` / `provision_scratch_prealloc`), preserving cross-VM
        // isolation without re-clearing 32 payload pages on every native submit.
        let scratch = self.lease_scratch(true, size, tilemap + tpc, 5 * UAT_PGSZ)?;
        let base = scratch.range.start;
        p.tilemap = base;
        p.tpc = base + tilemap as u64;
        let meta = p.tpc + tpc as u64;
        p.layermeta = meta;
        p.heapmeta = meta + if p.layers > 1 { 0x100 } else { 0 };
        p.deflake_3 = meta + 0x4000;
        p.deflake_2 = p.deflake_3 + 0x20;
        p.deflake_1 = p.deflake_3 + 0x2a0;
        p.ta_status = meta + 0x8000 + 0x240;
        p.fragment_status = meta + 0xc000 + 0x2c0;
        p.aux_fb = meta + 0x10000;
        let init_res: Result = (|| {
            if let Some(mesh) = &mut p.mesh {
                // The lease lasts through both TA and fragment retirement; the
                // full `Profile::PAYLOAD_BYTES` (512 KiB) aperture is backed
                // with `__GFP_ZERO` pages on initial VM allocation and reused
                // without CPU re-zeroing within the same VM.
                mesh.payload = meta + 0x14000;
            }
            self.write_low(p.aux_fb + 0x600, &0x0000035b60000000u64.to_le_bytes())?;
            Ok(())
        })();
        if let Err(err) = init_res {
            let _ = self.release_scratch(scratch);
            return Err(err);
        }
        // Only clean page tables if lease_scratch allocated new mappings;
        // Normal-WB metadata/aux_fb writes are ordered by flush() before the
        // GPU can observe this render.
        if self.has_pending_tables() {
            self.sync();
        }
        Ok(scratch)
    }

    /// Back this compute root's private FList with `buffers` 2 MiB buffers
    /// and its ring directory, at the fixed pool VAs, so the pool's pages are
    /// reachable from no other client's roots. Runs in the submitting client's
    /// ioctl, which is charged for the pages. After ENOMEM a retry resumes:
    /// pages already owned here are kept, and the directory is rewritten.
    pub(crate) fn alloc_compute_pool(&mut self, buffers: usize) -> Result {
        use crate::g16_compute as compute;
        if !(1..=compute::BUFFER_COUNT).contains(&buffers) {
            return Err(EINVAL);
        }
        let ranges = Iterator::chain(
            core::iter::once((compute::DIRECTORY, compute::DIRECTORY_SIZE)),
            (0..buffers).map(|i| {
                (compute::BUFFER_BASE + i as u64 * compute::BUFFER_STRIDE, compute::BUFFER_SIZE)
            }),
        );
        for (base, size) in ranges {
            for va in (base..base + size as u64).step_by(UAT_PGSZ) {
                if self.pages.get(&va).is_none() {
                    if self.low.translate(va)?.is_some() {
                        return Err(EEXIST);
                    }
                    let page = GpuPage::alloc(GFP_KERNEL_ACCOUNT | __GFP_ZERO)?;
                    self.pages.try_create_and_insert(va, page, GFP_KERNEL_ACCOUNT)?;
                    self.owned_bytes += UAT_PGSZ;
                }
                let physical = self.pages.get(&va).ok_or(EIO)?.phys();
                self.map_render_page(va, physical)?;
            }
        }
        let mut row = [0u8; 256];
        for offset in (0..compute::DIRECTORY_SIZE).step_by(row.len()) {
            compute::directory_page(offset, buffers, &mut row);
            self.write_low(compute::DIRECTORY + offset as u64, &row)?;
        }
        self.sync();
        Ok(())
    }

    /// Fill caller-preallocated `out` with the `(VA, physical)` pages of this
    /// render root's FList (directory, descriptor table, and buffers). Performs
    /// zero allocations while this live render root is locked.
    pub(crate) fn fill_render_pool_pages(
        &mut self,
        pool: &crate::g16_render::OperandPool,
        out: &mut KVec<(u64, u64)>,
    ) -> Result {
        let end = pool.end().ok_or(EINVAL)?;
        for va in (pool.directory..end).step_by(UAT_PGSZ) {
            if let Some(physical) = self.low.translate(va)? {
                out.push_within_capacity((va, physical)).map_err(|_| EIO)?;
            }
        }
        Ok(())
    }

    /// Map the render pool of this VM (`pages`, from `fill_render_pool_pages` of
    /// `owner`) into this compute root at the same VAs, so compute Works can
    /// use the render support object. `owner` is retained with the mappings.
    pub(crate) fn share_render_pool(
        &mut self,
        pages: &[(u64, u64)],
        owner: kernel::sync::Arc<kernel::sync::Mutex<AddressSpace>>,
    ) -> Result {
        for &(va, physical) in pages {
            self.map_render_page(va, physical)?;
        }
        self._pool_owner = Some(owner);
        self.sync();
        Ok(())
    }

    /// Debug (debug_ctx): name this compute root's pool placement, so
    /// separate clients' pools can be told apart by physical address.
    pub(crate) fn report_compute_pool(&mut self, kind: &str) {
        use crate::g16_compute as compute;
        if crate::module_parameters::debug_ctx.value() == 0 {
            return;
        }
        let (directory, buffer) = match self._pool_owner {
            Some(_) => (0, 0),
            None => (compute::DIRECTORY, compute::BUFFER_BASE),
        };
        let pa = |space: &mut Self, va: u64| {
            if va == 0 { 0 } else { space.low.translate(va).ok().flatten().unwrap_or(0) }
        };
        let (d, b) = (pa(self, directory), pa(self, buffer));
        pr_info!(
            "G16: compute root {:#x}: {} pool, support {:#x}, directory pa {:#x}, buffer0 pa {:#x}, owned {} KiB\n",
            self.low.ttb(),
            kind,
            self.compute_support.as_ref().map_or(0, |s| s.address()),
            d,
            b,
            self.owned_bytes / 1024
        );
    }

    pub(crate) fn compute_support(&self) -> Option<&crate::g16::Support> {
        self.compute_support.as_deref()
    }

    pub(crate) fn set_compute_support(&mut self, support: kernel::sync::Arc<crate::g16::Support>) -> Result {
        if self.compute_support.is_some() {
            return Err(EEXIST);
        }
        self.compute_support = Some(support);
        Ok(())
    }

    /// Compute commands use distinct private scratch addresses in the caller's
    /// reserved kernel aperture. The persistent root and all backing remain
    /// owned by the VM; allocating a later command never replaces a live PTE.
    pub(crate) fn init_compute_private(&mut self, range: core::ops::Range<u64>) {
        self.compute_arena = Arena::new(range);
    }

    pub(crate) fn prepare_compute(
        &mut self,
        p: &mut crate::g16_compute::Parameters,
    ) -> Result<Scratch> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_PREPARE_COMPUTE);
        // 0x00000..0x20000: compute scratch; 0x20000..0x24000: marker;
        // 0x24000..0x28000: GPU-writable CDM save_area (kept on separate client
        // backing so the firmware Work control page stays GPU read-only).
        // `clear_from = 0x20000, clear_len = 2 * UAT_PGSZ` clears both marker
        // and save_area on reuse.
        let scratch = self.lease_scratch(false, 0x28000, 0x20000, 2 * UAT_PGSZ)?;
        let base = scratch.range.start;
        p.scratch = base;
        p.marker = base + 0x20000;
        p.save_area = base + 0x24000;
        Ok(scratch)
    }

    /// Check whether SUBMIT needs to preallocate backing for a scratch request
    /// of `size` bytes, and verify arena fit BEFORE allocating any pages.
    /// Returns `Ok(false)` when existing provisioned or coalesced free space
    /// already covers `size`, `Err(ENOMEM)` when the remaining arena cannot
    /// fit `size`, and `Ok(true)` when preallocation is both needed and valid.
    pub(crate) fn scratch_needs_prealloc(&self, render: bool, size: usize) -> Result<bool> {
        if size == 0 || size & (UAT_PGSZ - 1) != 0 {
            return Err(EINVAL);
        }
        let index = usize::from(render);
        if self.scratch_max_block[index] >= size
            || self.scratch_free[index]
                .iter()
                .any(|r| r.end - r.start >= size as u64)
        {
            return Ok(false);
        }
        let mut arena = if render {
            self.render_arena.clone()
        } else {
            self.compute_arena.clone()
        };
        arena.alloc(size as u64, UAT_PGSZ as u64).ok_or(ENOMEM)?;
        Ok(true)
    }

    /// Pre-provision a contiguous scratch block of `size` bytes from pages
    /// allocated outside retirement locks (`SUBMIT` ioctl). Uses only
    /// `GFP_NOWAIT | __GFP_NOWARN` while this VM's mutex is held, and installs
    /// leaf tables before advancing the arena so no failure strands VA.
    pub(crate) fn provision_scratch_prealloc(
        &mut self,
        render: bool,
        size: usize,
        prealloc: &mut KVec<GpuPage>,
    ) -> Result {
        if size == 0 || size & (UAT_PGSZ - 1) != 0 {
            return Err(EINVAL);
        }
        let index = usize::from(render);
        if self.scratch_max_block[index] >= size
            || self.scratch_free[index]
                .iter()
                .any(|r| r.end - r.start >= size as u64)
        {
            return Ok(());
        }
        let gfp = GFP_NOWAIT | __GFP_NOWARN;
        let page_count = size / UAT_PGSZ;
        if prealloc.len() < page_count {
            return Err(ENOMEM);
        }
        let need_cap = self.scratch_free[index].len() + self.scratch_users[index] + 2;
        if self.scratch_free[index].capacity() < need_cap {
            self.scratch_free[index]
                .reserve(need_cap - self.scratch_free[index].len(), gfp)?;
        }
        let mut next_arena = if render {
            self.render_arena.clone()
        } else {
            self.compute_arena.clone()
        };
        let range = next_arena.alloc(size as u64, UAT_PGSZ as u64).ok_or(ENOMEM)?;
        for v in (range.start..range.end).step_by(UAT_PGSZ) {
            if self.pages.get(&v).is_some() || self.low.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        let mut nodes = KVec::new();
        nodes.reserve(page_count, gfp)?;
        self.low.prepare_map_gfp(range.clone(), gfp)?;
        for v in (range.start..range.end).step_by(UAT_PGSZ) {
            let page = prealloc.pop().ok_or(EIO)?;
            let node = RBTreeNode::new(v, page, gfp)?;
            nodes.push_within_capacity(node).map_err(|_| EIO)?;
        }
        if render {
            self.render_arena = next_arena;
        } else {
            self.compute_arena = next_arena;
        }
        for node in nodes {
            self.pages.insert(node);
            self.owned_bytes += UAT_PGSZ;
        }
        for v in (range.start..range.end).step_by(UAT_PGSZ) {
            let phys = self.pages.get(&v).ok_or(EIO)?.phys();
            self.low
                .map_pages_gfp(v..v + UAT_PGSZ as u64, phys, prot::PROT_GPU_SHARED_RW, false, gfp)?;
        }
        self.sync();
        // Insert into the free list (coalescing with any adjacent range).
        self.scratch_users[index] += 1;
        self.release_scratch(Scratch { range, render })?;
        self.scratch_max_block[index] = self.scratch_max_block[index].max(size);
        Ok(())
    }

    /// `clear_from` and `clear_len`: lease-relative byte range zeroed when
    /// reusing a previously freed range (fresh allocations come zeroed from
    /// `__GFP_ZERO`). Runs on the fence-signalling pump worker, so every
    /// allocation uses `GFP_NOWAIT | __GFP_NOWARN` (never enters direct reclaim).
    fn lease_scratch(
        &mut self,
        render: bool,
        size: usize,
        clear_from: usize,
        clear_len: usize,
    ) -> Result<Scratch> {
        let clear_end = clear_from.checked_add(clear_len).ok_or(EINVAL)?;
        if size == 0
            || clear_end > size
            || (size | clear_from | clear_len) & (UAT_PGSZ - 1) != 0
        {
            return Err(EINVAL);
        }
        let index = usize::from(render);
        let gfp = GFP_NOWAIT | __GFP_NOWARN;
        let no_mem = |users: usize, max_block: usize| -> Error {
            if users > 0 && max_block >= size {
                EBUSY
            } else {
                ENOMEM
            }
        };
        let free = self.scratch_free[index]
            .iter()
            .position(|r| r.end - r.start >= size as u64);
        let exact_match = free.is_some_and(|slot| {
            let r = &self.scratch_free[index][slot];
            r.end - r.start == size as u64
        });
        // Splitting a free range or adding a fresh block adds at most one
        // future free-list entry; an exact match replaces its own slot.
        // Reserve now; completion and coalescing cannot allocate.
        let need_cap =
            self.scratch_free[index].len() + self.scratch_users[index] + usize::from(!exact_match);
        if self.scratch_free[index].capacity() < need_cap {
            self.scratch_free[index]
                .reserve(need_cap - self.scratch_free[index].len(), gfp)
                .map_err(|_| no_mem(self.scratch_users[index], self.scratch_max_block[index]))?;
        }
        let range = if let Some(slot) = free {
            let start = self.scratch_free[index][slot].start;
            let end = start + size as u64;
            // All previous GPU writes have retired. Reinitialize only the
            // metadata range `[clear_from..clear_from + clear_len)` of the
            // leased range (the tilemap, TPC, compute scratch, and trailing
            // hardware-written `0x1ca48` native mesh payload aperture need no
            // clearing on same-VM reuse; full VK CTS clean, #181) before
            // mutating `scratch_free`, so a lookup error never orphans the slot.
            let clear_va_start = start + clear_from as u64;
            let clear_va_end = start + clear_end as u64;
            for va in (clear_va_start..clear_va_end).step_by(UAT_PGSZ) {
                let page = self.pages.get(&va).ok_or(EIO)?;
                page.with_page_mapped(|ptr| {
                    // SAFETY: The lease owns this full page exclusively.
                    unsafe { core::ptr::write_bytes(ptr, 0, UAT_PGSZ) };
                });
            }
            if end == self.scratch_free[index][slot].end {
                self.scratch_free[index].remove(slot).map_err(|_| EIO)?;
            } else {
                self.scratch_free[index][slot].start = end;
            }
            start..end
        } else {
            // Stage the arena advance, page tables, and backing pages with
            // GFP_NOWAIT before mutating the arena or page tables so ENOMEM
            // never enters reclaim and never strands scratch VA or backing.
            let mut next_arena = if render {
                self.render_arena.clone()
            } else {
                self.compute_arena.clone()
            };
            let range = next_arena
                .alloc(size as u64, UAT_PGSZ as u64)
                .ok_or_else(|| no_mem(self.scratch_users[index], self.scratch_max_block[index]))?;
            for v in (range.start..range.end).step_by(UAT_PGSZ) {
                if self.pages.get(&v).is_some() || self.low.translate(v)?.is_some() {
                    return Err(EEXIST);
                }
            }
            let mut nodes = KVec::new();
            nodes
                .reserve(size / UAT_PGSZ, gfp)
                .map_err(|_| no_mem(self.scratch_users[index], self.scratch_max_block[index]))?;
            if let Err(err) = self.low.prepare_map_gfp(range.clone(), gfp) {
                return Err(if err == ENOMEM {
                    no_mem(self.scratch_users[index], self.scratch_max_block[index])
                } else {
                    err
                });
            }
            for v in (range.start..range.end).step_by(UAT_PGSZ) {
                let page = GpuPage::alloc(gfp | __GFP_ZERO).map_err(|_| {
                    no_mem(self.scratch_users[index], self.scratch_max_block[index])
                })?;
                let node = RBTreeNode::new(v, page, gfp).map_err(|_| {
                    no_mem(self.scratch_users[index], self.scratch_max_block[index])
                })?;
                nodes.push_within_capacity(node).map_err(|_| EIO)?;
            }
            if render {
                self.render_arena = next_arena;
            } else {
                self.compute_arena = next_arena;
            }
            for node in nodes {
                self.pages.insert(node);
                self.owned_bytes += UAT_PGSZ;
            }
            for v in (range.start..range.end).step_by(UAT_PGSZ) {
                let phys = self.pages.get(&v).ok_or(EIO)?.phys();
                self.low
                    .map_pages_gfp(v..v + UAT_PGSZ as u64, phys, prot::PROT_GPU_SHARED_RW, false, gfp)?;
            }
            self.scratch_max_block[index] = self.scratch_max_block[index].max(size);
            range
        };
        self.scratch_users[index] += 1;
        Ok(Scratch { range, render })
    }

    pub(crate) fn release_scratch(&mut self, scratch: Scratch) -> Result {
        let index = usize::from(scratch.render);
        let mut range = scratch.range;
        let free = &mut self.scratch_free[index];
        let mut slot = 0;
        while slot < free.len() {
            if free[slot].end == range.start || range.end == free[slot].start {
                let old = free.remove(slot).map_err(|_| EIO)?;
                range.start = range.start.min(old.start);
                range.end = range.end.max(old.end);
                slot = 0;
            } else {
                slot += 1;
            }
        }
        // Capacity was reserved in `lease_scratch`, so retirement and prep
        // rollback never allocate.
        let merged = (range.end - range.start) as usize;
        free.push_within_capacity(range).map_err(|_| EIO)?;
        self.scratch_max_block[index] = self.scratch_max_block[index].max(merged);
        self.scratch_users[index] -= 1;
        Ok(())
    }

    /// TVB blocks that still fit in the render arena's free VA (each block
    /// reserves 0x28000). Scratch shares the arena from its other end.
    pub(crate) fn tvb_va_blocks(&self) -> u32 {
        (self.render_arena.free() / 0x28000).min(u64::from(u32::MAX)) as u32
    }

    /// Allocate tiler blocks from the shared private aperture. Before mapping,
    /// failure leaves both existing backing and the arena reservation untouched.
    /// `gfp` comes from the caller: TVB growth must not enter reclaim. Page
    /// tables and invalidation slots are prepared with `gfp` before committing.
    pub(crate) fn alloc_tvb_blocks(&mut self, count: usize, gfp: kernel::alloc::Flags) -> Result<Option<u64>> {
        if count == 0 || count > crate::g16_tvb::MAX_BLOCKS as usize {
            return Err(EINVAL);
        }
        let mut arena = self.render_arena.clone();
        let Some(range) = arena.alloc_back(count as u64 * 0x28000, 0x8000) else {
            return Ok(None);
        };
        let base = range.start;
        let mut pages = KVec::new();
        if pages.reserve(count * 8, gfp).is_err() {
            return Ok(None);
        }
        if self.low.reserve_invalidations_gfp(count, gfp).is_err() {
            return Ok(None);
        }
        for block in 0..count {
            let start = base + block as u64 * 0x28000;
            for va in (start..start + 0x28000).step_by(UAT_PGSZ) {
                if self.pages.get(&va).is_some() || self.low.translate(va)?.is_some() {
                    return Err(EEXIST);
                }
            }
            match self.low.prepare_map_gfp(start..start + 0x20000, gfp) {
                Ok(()) => {}
                Err(err) if err == ENOMEM => return Ok(None),
                Err(err) => return Err(err),
            }
            for va in (start..start + 0x20000).step_by(UAT_PGSZ) {
                let page = match GpuPage::alloc(gfp | __GFP_ZERO) {
                    Ok(page) => page,
                    Err(_) => return Ok(None),
                };
                let node = match RBTreeNode::new(va, page, gfp) {
                    Ok(node) => node,
                    Err(_) => return Ok(None),
                };
                pages.push_within_capacity(node).map_err(|_| EIO)?;
            }
        }
        // Transfer every preallocated node only after page-table preparation
        // succeeded with the caller's GFP flags.
        self.render_arena = arena;
        for node in pages {
            self.pages.insert(node);
            self.owned_bytes += UAT_PGSZ;
        }
        for block in 0..count {
            let start = base + block as u64 * 0x28000;
            for va in (start..start + 0x20000).step_by(UAT_PGSZ) {
                self.low.map_pages_gfp(
                    va..va + UAT_PGSZ as u64,
                    self.pages.get(&va).ok_or(EIO)?.phys(),
                    prot::PROT_GPU_SHARED_RW,
                    false,
                    gfp,
                )?;
            }
        }
        Ok(Some(base))
    }

    pub(crate) fn write_low(&mut self, mut va: u64, mut bytes: &[u8]) -> Result {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_WRITE_LOW);
        while !bytes.is_empty() {
            let base = va & !(UAT_PGSZ as u64 - 1);
            let page = self.pages.get(&base).ok_or(EINVAL)?;
            let offset = (va - base) as usize;
            let size = bytes.len().min(UAT_PGSZ - offset);
            page.with_pointer_into_page(offset, size, |p| {
                // SAFETY: This range belongs to an unpublished client allocation.
                unsafe {
                    core::ptr::copy_nonoverlapping(bytes.as_ptr(), p, size);
                }
                Ok(())
            })?;
            va = va.checked_add(size as u64).ok_or(EINVAL)?;
            bytes = &bytes[size..];
        }
        Ok(())
    }

    pub(crate) fn has_pending_tables(&self) -> bool {
        self.low.has_pending_tables() || self.high.has_pending_tables()
    }

    pub(crate) fn has_invalidations(&self) -> bool {
        self.low.has_invalidations() || self.high.has_invalidations()
    }

    /// Publish page-table edits. Owned client pages are cleaned when initialized;
    /// mapping changes do not need to sweep all existing client allocations.
    /// Firmware-private storage is managed separately by FirmwareSpace.
    pub(crate) fn sync(&self) {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_VM_SYNC);
        self.low.clean();
        self.high.clean();
        crate::mem::sync();
    }

    /// Exercise the ownership pattern needed for the firmware bootstrap
    /// root using private pages before touching firmware-owned tables.
    pub(crate) fn check_borrowed_root(&mut self, dev: &device::Device) -> Result {
        let a = Page::alloc_page(GFP_KERNEL | __GFP_ZERO)?;
        let b = Page::alloc_page(GFP_KERNEL | __GFP_ZERO)?;
        let page = UAT_PGSZ as u64;
        let far = 1u64 << 36;
        self.low
            .map_pages(page..2 * page, a.phys(), prot::PROT_GPU_SHARED_RW, false)?;
        let result = (|| {
            let mut borrowed =
                UatPageTable::new_with_ttb_and_ias(self.low.ttb(), 0..1u64 << IAS, OAS, IAS)?;
            // Extend both an existing leaf table and a previously empty L1 slot.
            borrowed.map_pages(
                2 * page..3 * page,
                b.phys(),
                prot::PROT_GPU_SHARED_RW,
                false,
            )?;
            borrowed.map_pages(far..far + page, b.phys(), prot::PROT_GPU_SHARED_RW, false)?;
            let valid = borrowed.translate(page)? == Some(a.phys())
                && borrowed.translate(2 * page)? == Some(b.phys())
                && borrowed.translate(far)? == Some(b.phys());
            borrowed.unmap_pages(2 * page..3 * page)?;
            borrowed.unmap_pages(far..far + page)?;
            drop(borrowed);
            if !valid
                || self.low.translate(page)? != Some(a.phys())
                || self.low.translate(far)?.is_some()
                || self.low.translate(2 * page)?.is_some()
            {
                return Err(EIO);
            }
            Ok(())
        })();
        self.low.unmap_pages(page..2 * page)?;
        result?;
        dev_info!(
            dev,
            "G16: borrowed-root teardown preserved existing mappings\n"
        );
        Ok(())
    }

    /// Bring-up check before either root is made visible to firmware. A
    /// legacy 39-bit mask aliases the two addresses exercised here, which
    /// would silently corrupt client data when installing the USC archive.
    pub(crate) fn check_geometry(&mut self, dev: &device::Device) -> Result {
        let a = Page::alloc_page(GFP_KERNEL | __GFP_ZERO)?;
        let b = Page::alloc_page(GFP_KERNEL | __GFP_ZERO)?;
        let low = UAT_PGSZ as u64;
        let usc = USC_BASE + low;
        self.low
            .map_pages(low..low + low, a.phys(), prot::PROT_GPU_SHARED_RW, false)?;
        if let Err(e) =
            self.low
                .map_pages(usc..usc + low, b.phys(), prot::PROT_GPU_SHARED_RW, false)
        {
            self.low.unmap_pages(low..low + low)?;
            return Err(e);
        }
        let result = (|| {
            if self.low.translate(low + 37)? != Some(a.phys() + 37)
                || self.low.translate(usc + 91)? != Some(b.phys() + 91)
                || self.high.translate(usc)?.is_some()
            {
                return Err(EIO);
            }
            self.low.unmap_pages(usc..usc + low)?;
            if self.low.translate(usc)?.is_some() || self.low.translate(low)? != Some(a.phys()) {
                return Err(EIO);
            }
            Ok(())
        })();
        // Remove both mappings on all paths before their backing pages drop.
        // The upper mapping has already been removed on the successful path.
        if self.low.translate(usc)?.is_some() {
            self.low.unmap_pages(usc..usc + low)?;
        }
        self.low.unmap_pages(low..low + low)?;
        result?;
        dev_info!(
            dev,
            "G16: 42-bit UAT mapping/unmapping verified across USC base; roots {:#x}/{:#x}\n",
            self.low.ttb(),
            self.high.ttb()
        );
        Ok(())
    }
}

struct FirmwareRegion {
    va: u64,
    end: u64,
    pages: KVec<GpuPage>,
}

/// The firmware uses this bootloader root independently of all client slots.
/// Its existing tables remain owned by the firmware reservation.
pub(crate) struct FirmwareSpace {
    table: UatPageTable,
    regions: RBTree<u64, FirmwareRegion>,
    external: KVec<core::ops::Range<u64>>,
}


impl FirmwareSpace {
    pub(crate) fn attach(dev: &device::Device) -> Result<Self> {
        let node = dev.of_node().ok_or(EINVAL)?;
        let res = node.reserved_mem_region_to_resource_byname(kernel::c_str!("pagetables"))?;
        let table = UatPageTable::new_with_ttb_and_ias(
            res.start(),
            0xffff_fc00_0000_0000..0xffff_ffff_ffff_c000,
            OAS,
            IAS,
        )?;
        dev_info!(dev, "G16: attached firmware root {:#x}\n", table.ttb());
        Ok(Self {
            table,
            regions: RBTree::new(),
            external: KVec::new(),
        })
    }

    /// Borrow a hardware aperture. No ownership of physical pages is implied.
    pub(crate) fn map_external(
        &mut self,
        va: u64,
        pa: u64,
        size: usize,
        prot: crate::pgtable::Prot,
    ) -> Result {
        if size == 0 || (va | pa | size as u64) & (UAT_PGSZ as u64 - 1) != 0 {
            return Err(EINVAL);
        }
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        for v in (va..end).step_by(UAT_PGSZ) {
            if self.table.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        // Retain the whole range first so partial mapping failures also unwind.
        self.external.push(va..end, GFP_KERNEL)?;
        self.table.map_pages(va..end, pa, prot, false)
    }

    pub(crate) fn map_external_prealloc_gfp(
        &mut self,
        va: u64,
        pa: u64,
        size: usize,
        prot: crate::pgtable::Prot,
        prealloc: &mut KVec<kernel::types::Owned<Page>>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        if size == 0 || (va | pa | size as u64) & (UAT_PGSZ as u64 - 1) != 0 {
            return Err(EINVAL);
        }
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        for v in (va..end).step_by(UAT_PGSZ) {
            if self.table.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        self.external.reserve(1, gfp)?;
        self.table.reserve_teardown_gfp(gfp)?;
        self.table.prepare_map_prealloc_gfp(va..end, prealloc, gfp)?;
        // Retain the whole range before leaf writes so partial failures unwind.
        self.external.push_within_capacity(va..end).map_err(|_| EIO)?;
        self.table.map_pages_gfp(va..end, pa, prot, false, gfp)
    }

    pub(crate) fn unmap_external_gfp(
        &mut self,
        range: core::ops::Range<u64>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        self.table.unmap_pages_gfp(range.clone(), gfp)?;
        self.table.publish();
        self.external
            .retain(|r| r.start < range.start || r.end > range.end);
        Ok(())
    }

    pub(crate) fn physical(&mut self, va: u64) -> Result<u64> {
        self.table.translate(va)?.ok_or(EINVAL)
    }

    /// Whether a firmware region starting at `va` is currently retained.
    pub(crate) fn has_region(&self, va: u64) -> bool {
        self.regions.get(&va).is_some()
    }

    /// Pre-reserve invalidation and dirty-table capacity so later region
    /// teardown under retirement locks needs zero allocations.
    pub(crate) fn reserve_teardown_gfp(&mut self, gfp: kernel::alloc::Flags) -> Result {
        self.table.reserve_teardown_gfp(gfp)
    }

    pub(crate) fn missing_tables_for_range(&self, range: &core::ops::Range<u64>) -> usize {
        self.table.missing_tables_for_range(range)
    }

    /// Map preallocated zeroed `GpuPage`s at `va..va+size` using `gfp` for
    /// metadata and page-table allocations (`GFP_NOWAIT | __GFP_NOWARN` under
    /// retirement locks). Preallocates leaf tables before inserting into
    /// `self.regions` so allocation failure leaves `self.regions` untouched.
    pub(crate) fn alloc_prealloc_gfp(
        &mut self,
        va: u64,
        size: usize,
        prot: crate::pgtable::Prot,
        prealloc: &mut KVec<GpuPage>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        if size == 0 || (va as usize | size) & (UAT_PGSZ - 1) != 0 {
            return Err(EINVAL);
        }
        if crate::module_parameters::fw_trace.value() & 128 != 0 {
            pr_info!("G16: fwmap {:#x}+{:#x} {:?}\n", va, size, prot);
        }
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        let previous = match self.regions.cursor_lower_bound(&va) {
            Some(cursor) => {
                if *cursor.current().0 < end {
                    return Err(EEXIST);
                }
                cursor.peek_prev().map(|(base, _)| *base)
            }
            None => self.regions.cursor_back().map(|cursor| *cursor.current().0),
        };
        if previous.is_some_and(|base| {
            let region = self.regions.get(&base).unwrap();
            base + (region.pages.len() * UAT_PGSZ) as u64 > va
        }) {
            return Err(EEXIST);
        }
        for v in (va..end).step_by(UAT_PGSZ) {
            if self.table.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        let count = size / UAT_PGSZ;
        if prealloc.len() < count {
            return Err(ENOMEM);
        }
        let mut pages = KVec::new();
        pages.reserve(count, gfp)?;
        self.table.prepare_map_gfp(va..end, gfp)?;
        for _ in 0..count {
            let page = prealloc.pop().ok_or(EIO)?;
            pages.push_within_capacity(page).map_err(|_| EIO)?;
        }
        let node = RBTreeNode::new(va, FirmwareRegion { va, end, pages }, gfp)?;
        self.regions.insert(node);
        let region = self.regions.get(&va).ok_or(EIO)?;
        for (i, page) in region.pages.iter().enumerate() {
            let v = va + (i * UAT_PGSZ) as u64;
            if let Err(e) = self
                .table
                .map_pages_gfp(v..v + UAT_PGSZ as u64, page.phys(), prot, false, gfp)
            {
                if v != va {
                    self.table.unmap_pages_gfp(va..v, gfp)?;
                }
                self.table.publish();
                self.regions.remove(&va);
                return Err(e);
            }
        }
        Ok(())
    }

    pub(crate) fn alloc(&mut self, va: u64, size: usize, prot: crate::pgtable::Prot) -> Result {
        if size == 0 || (va as usize | size) & (UAT_PGSZ - 1) != 0 {
            return Err(EINVAL);
        }
        if crate::module_parameters::fw_trace.value() & 128 != 0 {
            pr_info!("G16: fwmap {:#x}+{:#x} {:?}\n", va, size, prot);
        }
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        // Failed mapping cleanup may retain an owned but partly unmapped
        // region. Its address range must not be replaced or overlapped.
        let previous = match self.regions.cursor_lower_bound(&va) {
            Some(cursor) => {
                if *cursor.current().0 < end {
                    return Err(EEXIST);
                }
                cursor.peek_prev().map(|(base, _)| *base)
            }
            None => self.regions.cursor_back().map(|cursor| *cursor.current().0),
        };
        if previous.is_some_and(|base| {
            let region = self.regions.get(&base).unwrap();
            base + (region.pages.len() * UAT_PGSZ) as u64 > va
        }) {
            return Err(EEXIST);
        }
        for v in (va..end).step_by(UAT_PGSZ) {
            if self.table.translate(v)?.is_some() {
                return Err(EEXIST);
            }
        }
        let mut pages = KVec::new();
        for _ in 0..size / UAT_PGSZ {
            pages.push(GpuPage::alloc(GFP_KERNEL | __GFP_ZERO)?, GFP_KERNEL)?;
        }
        let node = RBTreeNode::new(va, FirmwareRegion { va, end, pages }, GFP_KERNEL)?;
        self.regions.insert(node);
        let region = self.regions.get(&va).ok_or(EIO)?;
        for (i, page) in region.pages.iter().enumerate() {
            let v = va + (i * UAT_PGSZ) as u64;
            if let Err(e) = self
                .table
                .map_pages(v..v + UAT_PGSZ as u64, page.phys(), prot, false)
            {
                if v != va {
                    self.table.unmap_pages(va..v)?;
                }
                self.table.publish();
                self.regions.remove(&va);
                return Err(e);
            }
        }
        Ok(())
    }

    pub(crate) fn write(&mut self, va: u64, bytes: &[u8]) -> Result {
        let region = self.region(va, bytes.len())?;
        let mut offset = (va - region.va) as usize;
        let mut remaining = bytes;
        while !remaining.is_empty() {
            let within = offset & (UAT_PGSZ - 1);
            let size = remaining.len().min(UAT_PGSZ - within);
            region.pages[offset / UAT_PGSZ].with_pointer_into_page(within, size, |p| {
                // SAFETY: These owned bytes are not yet published to firmware.
                unsafe {
                    core::ptr::copy_nonoverlapping(remaining.as_ptr(), p, size);
                }
                Ok(())
            })?;
            remaining = &remaining[size..];
            offset += size;
        }
        Ok(())
    }

    /// Initialize a whole owned page before its contents are published.
    pub(crate) fn init_page(
        &mut self,
        va: u64,
        initialize: impl FnOnce(&mut [u8]) -> Result,
    ) -> Result {
        if va & (UAT_PGSZ as u64 - 1) != 0 {
            return Err(EINVAL);
        }
        let region = self.region(va, UAT_PGSZ)?;
        region.pages[((va - region.va) as usize) / UAT_PGSZ].with_pointer_into_page(
            0,
            UAT_PGSZ,
            |ptr| {
                // SAFETY: This page is owned by this space and initialization
                // occurs before it is published to firmware.
                initialize(unsafe { core::slice::from_raw_parts_mut(ptr, UAT_PGSZ) })
            },
        )
    }

    pub(crate) fn alloc_render_support(&mut self) -> Result {
        use crate::g16_render::Addresses;
        let a = Addresses::bootstrap();
        for (base, size) in a.private_regions() {
            self.alloc(base, size, prot::PROT_FW_PRIV_RW)?;
            for va in (base..base + size as u64).step_by(UAT_PGSZ) {
                self.init_page(va, |bytes| a.private_page(va, bytes).ok_or(EINVAL))?;
            }
        }
        for va in [a.tiling_shared_tail, a.fragment_shared_tail] {
            self.alloc(va, UAT_PGSZ, prot::PROT_FW_SHARED_RW)?;
        }
        self.alloc(
            crate::g16_render::SUPPORT_BASE,
            64 * UAT_PGSZ,
            prot::PROT_FW_PRIV_RW,
        )?;
        // Each lease's render shared state, which the host advances while
        // firmware runs, stays uncached apart from the cached support page.
        self.alloc(
            crate::g16_render::SUPPORT_SHARED_BASE,
            64 * UAT_PGSZ,
            prot::PROT_FW_SHARED_RW,
        )?;
        for i in 0..64 {
            let mut support = Addresses::bootstrap();
            support.support = crate::g16_render::SUPPORT_BASE + i * UAT_PGSZ as u64;
            self.init_page(support.support, |bytes| {
                support.private_page(support.support, bytes).ok_or(EINVAL)
            })?;
        }
        Ok(())
    }

    /// Order prior staged coherent firmware writes before subsequent ring-head
    /// or descriptor publication writes (`dmb oshst`, matching ARM64 `dma_wmb()`).
    /// G16 firmware memory is Normal-WB coherent, so no `dc cvac` is needed.
    #[inline(always)]
    pub(crate) fn release_barrier(&self) {
        crate::mem::dma_wmb();
    }

    /// Begin a barrier-free staging write batch over coherent firmware memory.
    ///
    /// Caches up to 8 recently resolved regions and records one `P_LIVE`
    /// profile section for the batch. Callers must issue `release_barrier()`
    /// (`dmb oshst`) before exposing lane write pointers and `crate::mem::sync()`
    /// (`dsb sy`) before MMIO channel tail / doorbell writes (inside `flush()`),
    /// or `dsb_oshst()` when publishing consumer RX cursors without a doorbell.
    pub(crate) fn writer(&mut self) -> FirmwareWriter<'_> {
        FirmwareWriter {
            space: self,
            cache: [None; 8],
            next: 0,
            _timer: crate::g16_timeline::Timer::start(&crate::g16_timeline::P_LIVE),
        }
    }

    pub(crate) fn has_pending_tables(&self) -> bool {
        self.table.has_pending_tables() || self.table.has_invalidations()
    }

    /// Update host-owned bytes in memory firmware may be reading.
    pub(crate) fn write_live(&mut self, va: u64, bytes: &[u8]) -> Result {
        self.update_live(va, bytes.len(), |ptr, offset, size| {
            // SAFETY: update_live supplies an exclusively host-owned destination
            // and a range within the source slice, with no alias between them.
            unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr().add(offset), ptr, size) };
        })
    }

    pub(crate) fn zero_live(&mut self, va: u64, size: usize) -> Result {
        self.update_live(va, size, |ptr, _, size| {
            // SAFETY: update_live supplies a valid host-owned byte range.
            unsafe { core::ptr::write_bytes(ptr, 0, size) };
        })
    }

    fn update_live(
        &mut self,
        va: u64,
        size: usize,
        mut update: impl FnMut(*mut u8, usize, usize),
    ) -> Result {
        self.update_batch(1, |_| (va, size), |_, ptr, offset, size| update(ptr, offset, size))
    }

    /// Whether `region` holds all of `va..va + size`.
    fn holds(region: &FirmwareRegion, va: u64, size: usize) -> bool {
        va >= region.va
            && va
                .checked_add(size as u64)
                .is_some_and(|end| end <= region.end)
    }

    /// Update host-owned bytes in memory firmware may be reading, between one
    /// barrier pair. G16 firmware memory is coherent, as writeback user BOs
    /// are, so no CPU cache maintenance is needed.
    /// `range(n)` is the destination of write `n` of `count`.
    fn update_batch(
        &mut self,
        count: usize,
        range: impl Fn(usize) -> (u64, usize),
        mut update: impl FnMut(usize, *mut u8, usize, usize),
    ) -> Result {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_LIVE);
        // Validate every destination before touching any of them, resolving
        // each distinct region once: a render's writes alternate between a
        // few regions (notifier, Work slot, lane rings).
        // Fixed-size bookkeeping: no allocation per write. Destinations past
        // these bounds are looked up individually (NONE).
        const NONE: u8 = u8::MAX;
        let mut found: [Option<&FirmwareRegion>; 4] = [None; 4];
        let mut owner = [NONE; 32];
        for n in 0..count {
            let (va, size) = range(n);
            let region = match found.iter().flatten().position(|r| Self::holds(r, va, size)) {
                Some(index) => {
                    if let Some(slot) = owner.get_mut(n) {
                        *slot = index as u8;
                    }
                    continue;
                }
                None => self.region(va, size)?,
            };
            if let (Some(slot), Some(free)) = (owner.get_mut(n), found.iter().position(Option::is_none)) {
                found[free] = Some(region);
                *slot = free as u8;
            }
        }
        let resolve = |n: usize, va: u64, size: usize| -> Result<&FirmwareRegion> {
            match owner.get(n).and_then(|&i| found.get(i as usize).copied().flatten()) {
                Some(region) => Ok(region),
                None => self.region(va, size),
            }
        };
        crate::mem::sync();
        for which in 0..count {
            let (va, size) = range(which);
            if size == 0 {
                continue;
            }
            let region = resolve(which, va, size)?;
            let start = (va - region.va) as usize;
            let end = start + size;
            for index in start / UAT_PGSZ..=(end - 1) / UAT_PGSZ {
                let base = index * UAT_PGSZ;
                let within = start.saturating_sub(base);
                let limit = (end - base).min(UAT_PGSZ);
                region.pages[index].with_page_mapped(|p| {
                    // SAFETY: The checked range lies in this mapped page, and
                    // the caller owns these bytes.
                    unsafe { update(which, p.add(within), base + within - start, limit - within) };
                });
            }
        }
        crate::mem::sync();
        Ok(())
    }

    /// Read one firmware-owned 64-bit status value as two 32-bit reads.
    /// Host writes to these words must have been published first.
    pub(crate) fn read_u64(&self, va: u64) -> Result<u64> {
        Ok(u64::from(self.read_u32(va)?) | (u64::from(self.read_u32(va + 4)?) << 32))
    }

    /// Debug (debugfs `fw_mem`): the page-aligned VA and physical address of
    /// each page of the region at `va`, which must be one never released.
    pub(crate) fn region_pages(&self, va: u64) -> Result<KVec<(u64, kernel::addr::PhysicalAddr)>> {
        let region = self.regions.get(&va).ok_or(EINVAL)?;
        let mut pages = KVec::with_capacity(region.pages.len(), GFP_KERNEL)?;
        for (i, page) in region.pages.iter().enumerate() {
            pages.push((va + (i * UAT_PGSZ) as u64, page.phys()), GFP_KERNEL)?;
        }
        Ok(pages)
    }

    /// Called only after the context is drained and its hardware roots detached.
    pub(crate) fn release_region_gfp(&mut self, va: u64, gfp: kernel::alloc::Flags) -> Result {
        let size = self.regions.get(&va).ok_or(EINVAL)?.pages.len() * UAT_PGSZ;
        self.table.unmap_pages_gfp(va..va + size as u64, gfp)?;
        self.table.publish();
        self.regions.remove(&va);
        Ok(())
    }

    /// Order subsequent coherent firmware loads after prior notification,
    /// cursor, or status loads (`dmb oshld`, matching ARM64 `dma_rmb()`).
    /// G16 firmware pages are Normal-WB coherent with the ASC/GPU fabric, so
    /// no CPU cache invalidation (`dc ivac`) is needed.
    #[inline(always)]
    pub(crate) fn acquire_barrier(&self) {
        crate::mem::dma_rmb();
    }

    /// Begin an acquire-scoped batch of coherent firmware reads.
    ///
    /// Issues one `dmb oshld` on entry and caches recently resolved regions so
    /// a retire, event, or admission scan avoids both per-word `dsb sy` stalls
    /// and repeated RBTree walks. Call `acquire_barrier()` between reading a
    /// firmware-written producer index and reading the ring entries it
    /// publishes (ARM64 control dependencies do not order loads), and before
    /// reusing retired storage or reading GPU output.
    pub(crate) fn reader(&self) -> FirmwareReader<'_> {
        self.acquire_barrier();
        FirmwareReader {
            space: self,
            cache: [None; 8],
            next: 0,
        }
    }

    pub(crate) fn read_u32(&self, va: u64) -> Result<u32> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_READ);
        if va & 3 != 0 {
            return Err(EINVAL);
        }
        let region = self.region(va, 4)?;
        let offset = (va - region.va) as usize;
        region.pages[offset / UAT_PGSZ].with_pointer_into_page(offset & (UAT_PGSZ - 1), 4, |p| {
            // SAFETY: The aligned word lies in this live owned page, mapped
            // coherently with firmware; the barrier orders the volatile read
            // after the caller's publication, and nothing here cleans caches.
            unsafe {
                core::arch::asm!("dsb sy");
                Ok(u32::from_le(p.cast::<u32>().read_volatile()))
            }
        })
    }

    pub(crate) fn sync(&self) {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_FW_SYNC);
        self.table.publish();
    }

    /// Find the preceding allocation in logarithmic time, then validate the
    /// entire access. Adjacent regions must not hide an out-of-bounds request.
    fn region(&self, va: u64, size: usize) -> Result<&FirmwareRegion> {
        let end = va.checked_add(size as u64).ok_or(EINVAL)?;
        let base = match self.regions.cursor_lower_bound(&va) {
            Some(cursor) if *cursor.current().0 == va => va,
            Some(cursor) => *cursor.peek_prev().ok_or(EINVAL)?.0,
            None => *self.regions.cursor_back().ok_or(EINVAL)?.current().0,
        };
        let region = self.regions.get(&base).ok_or(EINVAL)?;
        if end > region.end {
            return Err(EINVAL);
        }
        Ok(region)
    }
}

/// Scoped acquire-ordered reader over coherent firmware memory.
pub(crate) struct FirmwareReader<'a> {
    space: &'a FirmwareSpace,
    cache: [Option<&'a FirmwareRegion>; 8],
    next: usize,
}

impl<'a> FirmwareReader<'a> {
    /// Outer-Shareable acquire barrier (`dmb oshld`) separating a producer
    /// cursor load from payload loads, or completion loads from storage reuse.
    #[inline(always)]
    pub(crate) fn acquire_barrier(&self) {
        crate::mem::dma_rmb();
    }

    fn resolve(&mut self, va: u64, size: usize) -> Result<&'a FirmwareRegion> {
        for region in self.cache.iter().flatten() {
            if FirmwareSpace::holds(region, va, size) {
                return Ok(region);
            }
        }
        let region = self.space.region(va, size)?;
        self.cache[self.next] = Some(region);
        self.next = (self.next + 1) & 7;
        Ok(region)
    }

    /// Read one aligned 32-bit coherent firmware word without a per-read barrier.
    pub(crate) fn read_u32_relaxed(&mut self, va: u64) -> Result<u32> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_READ);
        if va & 3 != 0 {
            return Err(EINVAL);
        }
        let region = self.resolve(va, 4)?;
        let offset = (va - region.va) as usize;
        region.pages[offset / UAT_PGSZ].with_pointer_into_page(offset & (UAT_PGSZ - 1), 4, |p| {
            // SAFETY: The aligned word lies in this live owned page, mapped
            // coherently with firmware; volatile avoids tearing and stale
            // register caching across the acquire-scoped scan.
            Ok(u32::from_le(unsafe { p.cast::<u32>().read_volatile() }))
        })
    }

    /// Read one 4-byte-aligned 64-bit coherent firmware word as two relaxed loads.
    pub(crate) fn read_u64_relaxed(&mut self, va: u64) -> Result<u64> {
        Ok(u64::from(self.read_u32_relaxed(va)?)
            | (u64::from(self.read_u32_relaxed(va.checked_add(4).ok_or(EINVAL)?)?) << 32))
    }

    /// Read a 4-byte-aligned slice of coherent firmware words in one region
    /// lookup without per-word barriers.
    pub(crate) fn read_slice_relaxed(&mut self, va: u64, dst: &mut [u32]) -> Result {
        if va & 3 != 0 {
            return Err(EINVAL);
        }
        let bytes = dst.len().checked_mul(4).ok_or(EINVAL)?;
        if bytes == 0 {
            return Ok(());
        }
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_READ);
        let region = self.resolve(va, bytes)?;
        let mut offset = (va - region.va) as usize;
        let mut remaining = dst;
        while !remaining.is_empty() {
            let within = offset & (UAT_PGSZ - 1);
            let words = remaining.len().min((UAT_PGSZ - within) / 4);
            region.pages[offset / UAT_PGSZ].with_pointer_into_page(within, words * 4, |p| {
                for (i, slot) in remaining[..words].iter_mut().enumerate() {
                    // SAFETY: Every aligned word lies within this checked page
                    // range in coherent firmware RAM.
                    *slot = u32::from_le(unsafe { p.add(i * 4).cast::<u32>().read_volatile() });
                }
                Ok(())
            })?;
            remaining = &mut remaining[words..];
            offset += words * 4;
        }
        Ok(())
    }
}

/// Scoped barrier-free staging writer over coherent firmware memory.
///
/// Borrowing `&mut FirmwareSpace` exclusively on creation ensures no other
/// host access aliases while allowing safe immutable region-cache references.
pub(crate) struct FirmwareWriter<'a> {
    space: &'a FirmwareSpace,
    cache: [Option<&'a FirmwareRegion>; 8],
    next: usize,
    _timer: crate::g16_timeline::Timer,
}

impl<'a> FirmwareWriter<'a> {
    fn resolve(&mut self, va: u64, size: usize) -> Result<&'a FirmwareRegion> {
        for region in self.cache.iter().flatten() {
            if FirmwareSpace::holds(region, va, size) {
                return Ok(region);
            }
        }
        let region = self.space.region(va, size)?;
        self.cache[self.next] = Some(region);
        self.next = (self.next + 1) & 7;
        Ok(region)
    }

    /// Stage a byte slice into coherent firmware memory without per-write barriers.
    pub(crate) fn write_staged(&mut self, va: u64, bytes: &[u8]) -> Result {
        if bytes.is_empty() {
            return Ok(());
        }
        let region = self.resolve(va, bytes.len())?;
        let start = (va - region.va) as usize;
        let end = start + bytes.len();
        for index in start / UAT_PGSZ..=(end - 1) / UAT_PGSZ {
            let base = index * UAT_PGSZ;
            let within = start.saturating_sub(base);
            let limit = (end - base).min(UAT_PGSZ);
            let src_off = base + within - start;
            let len = limit - within;
            region.pages[index].with_page_mapped(|p| {
                // SAFETY: `resolve` verified `[start, end)` lies within this
                // owned region, and the caller holds exclusive host ownership.
                unsafe {
                    core::ptr::copy_nonoverlapping(bytes.as_ptr().add(src_off), p.add(within), len);
                }
            });
        }
        Ok(())
    }

    /// Stage one aligned 32-bit word with a single-copy atomic volatile store.
    pub(crate) fn write_u32_staged(&mut self, va: u64, value: u32) -> Result {
        if va & 3 != 0 {
            return Err(EINVAL);
        }
        let region = self.resolve(va, 4)?;
        let offset = (va - region.va) as usize;
        region.pages[offset / UAT_PGSZ].with_pointer_into_page(offset & (UAT_PGSZ - 1), 4, |p| {
            // SAFETY: Aligned 32-bit destination in live coherent firmware RAM;
            // volatile emits a single non-tearing `str w` for words firmware
            // may read concurrently (heads, shared counters, RX cursors).
            unsafe { p.cast::<u32>().write_volatile(value.to_le()) };
            Ok(())
        })
    }

    /// Stage one aligned 64-bit word with a single-copy atomic volatile store.
    pub(crate) fn write_u64_staged(&mut self, va: u64, value: u64) -> Result {
        if va & 7 != 0 {
            return Err(EINVAL);
        }
        let region = self.resolve(va, 8)?;
        let offset = (va - region.va) as usize;
        region.pages[offset / UAT_PGSZ].with_pointer_into_page(offset & (UAT_PGSZ - 1), 8, |p| {
            // SAFETY: Aligned 64-bit destination in live coherent firmware RAM.
            unsafe { p.cast::<u64>().write_volatile(value.to_le()) };
            Ok(())
        })
    }
}

impl Drop for FirmwareSpace {
    fn drop(&mut self) {
        // Only valid before publishing the graph or after firmware is stopped.
        // Remove leaf mappings before their backing pages are released.
        for region in self.regions.values() {
            let _ = self
                .table
                .unmap_pages(region.va..region.va + (region.pages.len() * UAT_PGSZ) as u64);
        }
        for range in &self.external {
            let _ = self.table.unmap_pages(range.clone());
        }
        self.table.publish();
    }
}

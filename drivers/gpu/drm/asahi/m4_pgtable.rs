// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors
// Adapted from the Asahi UAT implementation and Niklas Sheth's G16 port.

//! UAT Page Table management
//!
//! AGX GPUs use an MMU called the UAT, which is largely compatible with the ARM64 page table
//! format. This module manages the actual page tables by allocating raw memory pages from
//! the kernel page allocator.

use core::cell::{Cell, RefCell};
use core::fmt::Debug;
use core::mem::size_of;
use core::ops::Range;
use core::sync::atomic::{AtomicU64, Ordering};

use kernel::rbtree::RBTree;
use kernel::{addr::PhysicalAddr, error::Result, page::Page, prelude::*};

use crate::util::align;

/// Number of bits in a page offset.
pub(crate) const UAT_PGBIT: usize = 14;
/// UAT page size.
pub(crate) const UAT_PGSZ: usize = 1 << UAT_PGBIT;
/// UAT page offset mask.
pub(crate) const UAT_PGMSK: usize = UAT_PGSZ - 1;

type Pte = AtomicU64;

const PTE_BIT: usize = 3; // log2(sizeof(Pte))
const PTE_SIZE: usize = 1 << PTE_BIT;

/// Number of PTEs per page.
const UAT_NPTE: usize = UAT_PGSZ / size_of::<Pte>();

/// Number of address bits to address a level
const UAT_LVBIT: usize = UAT_PGBIT - PTE_BIT;
/// Number of entries per level
const UAT_LVSZ: usize = UAT_NPTE;
/// Mask of level bits
const UAT_LVMSK: u64 = (UAT_LVSZ - 1) as u64;

const UAT_LEVELS: usize = 3;

const PTE_TYPE_BITS: u64 = 3;
const PTE_TYPE_LEAF_TABLE: u64 = 3;

const UAT_NON_GLOBAL: u64 = 1 << 11;
const UAT_AP_SHIFT: u32 = 6;
const UAT_HIGH_BITS_SHIFT: u32 = 52;
const UAT_MEMATTR_SHIFT: u32 = 2;

const UAT_AF: u64 = 1 << 10;

const MEMATTR_CACHED: u8 = 0;
const MEMATTR_DEV: u8 = 1;
const MEMATTR_UNCACHED: u8 = 2;

const AP_FW_GPU: u8 = 0;
const AP_FW: u8 = 1;
const AP_GPU: u8 = 2;

const HIGH_BITS_PXN: u16 = 1 << 1;
const HIGH_BITS_UXN: u16 = 1 << 2;
const HIGH_BITS_GPU_ACCESS: u16 = 1 << 3;


#[derive(Debug, Copy, Clone)]
pub(crate) struct Prot {
    memattr: u8,
    ap: u8,
    high_bits: u16,
}

// Firmware + GPU access
const PROT_FW_GPU_NA: Prot = Prot::from_bits(AP_FW_GPU, 0, 0);

// Firmware only access
const PROT_FW_RO: Prot = Prot::from_bits(AP_FW, 0, 0);
const PROT_FW_RW: Prot = Prot::from_bits(AP_FW, 1, 0);

// GPU only access
const PROT_GPU_RO: Prot = Prot::from_bits(AP_GPU, 0, 0);
const PROT_GPU_WO: Prot = Prot::from_bits(AP_GPU, 0, 1);
const PROT_GPU_RW: Prot = Prot::from_bits(AP_GPU, 1, 0);



pub(crate) mod prot {
    pub(crate) use super::Prot;
    use super::*;

    /// Firmware MMIO R/W
    pub(crate) const PROT_FW_MMIO_RW: Prot = PROT_FW_RW.memattr(MEMATTR_DEV);
    /// Firmware MMIO R/O
    pub(crate) const PROT_FW_MMIO_RO: Prot = PROT_FW_RO.memattr(MEMATTR_DEV);
    /// Firmware shared (uncached) RW
    pub(crate) const PROT_FW_SHARED_RW: Prot = PROT_FW_RW.memattr(MEMATTR_UNCACHED);
    /// Firmware shared (uncached) RO
    pub(crate) const PROT_FW_SHARED_RO: Prot = PROT_FW_RO.memattr(MEMATTR_UNCACHED);
    /// Firmware private (cached) RW
    pub(crate) const PROT_FW_PRIV_RW: Prot = PROT_FW_RW.memattr(MEMATTR_CACHED);
    /// GPU shared/coherent RW
    pub(crate) const PROT_GPU_SHARED_RW: Prot = PROT_GPU_RW.memattr(MEMATTR_UNCACHED);
    /// GPU shared/coherent RO
    pub(crate) const PROT_GPU_SHARED_RO: Prot = PROT_GPU_RO.memattr(MEMATTR_UNCACHED);
    /// GPU shared/coherent WO
    pub(crate) const PROT_GPU_SHARED_WO: Prot = PROT_GPU_WO.memattr(MEMATTR_UNCACHED);
}

impl Prot {
    const fn from_bits(ap: u8, uxn: u16, pxn: u16) -> Self {
        assert!(uxn <= 1);
        assert!(pxn <= 1);
        assert!(ap <= 3);

        Prot {
            high_bits: HIGH_BITS_GPU_ACCESS | (pxn * HIGH_BITS_PXN) | (uxn * HIGH_BITS_UXN),
            memattr: 0,
            ap,
        }
    }



    const fn memattr(&self, memattr: u8) -> Self {
        Self { memattr, ..*self }
    }

    const fn as_pte(&self) -> u64 {
        (self.ap as u64) << UAT_AP_SHIFT
            | (self.high_bits as u64) << UAT_HIGH_BITS_SHIFT
            | (self.memattr as u64) << UAT_MEMATTR_SHIFT
            | UAT_AF
    }
}

impl Default for Prot {
    fn default() -> Self {
        PROT_FW_GPU_NA
    }
}


enum Walk {
    Read,
    Write,
    Allocate,
}

struct OwnedTable {
    phys: PhysicalAddr,
    parent: PhysicalAddr,
    index: usize,
}

pub(crate) struct UatPageTable {
    ttb: PhysicalAddr,
    ttb_owned: bool,
    va_range: Range<u64>,
    oas_mask: u64,
    ias_mask: u64,
    owned_tables: KVec<OwnedTable>,
    // Membership survives publication; the queue contains only pending cleans.
    dirty_tables: RBTree<PhysicalAddr, Cell<bool>>,
    pending_tables: RefCell<KVec<PhysicalAddr>>,
    invalidations: RefCell<KVec<Range<u64>>>,
}

impl UatPageTable {
    /// Allocate a root with the address width of this GPU generation.
    /// G16 has 64 top-level entries (42 address bits per TTBR), while
    /// G13/G14 use 8 entries (39 bits per TTBR).
    pub(crate) fn new_with_ias(oas: u32, ias: usize) -> Result<Self> {
        if !(UAT_PGBIT..=UAT_PGBIT + UAT_LEVELS * UAT_LVBIT).contains(&ias)
            || !(UAT_PGBIT as u32..=52).contains(&oas)
        {
            return Err(EINVAL);
        }
        pr_debug!("UATPageTable::new: oas={} ias={}\n", oas, ias);
        let ttb_page = Page::alloc_page(GFP_KERNEL | __GFP_ZERO)?;
        let mut dirty_tables = RBTree::new();
        dirty_tables.try_create_and_insert(ttb_page.phys(), Cell::new(true), GFP_KERNEL)?;
        let mut pending_tables = KVec::new();
        pending_tables.push(ttb_page.phys(), GFP_KERNEL)?;
        let ttb = Page::into_phys(ttb_page);
        Ok(UatPageTable {
            ttb,
            ttb_owned: true,
            va_range: 0..(1u64 << ias),
            oas_mask: (1u64 << oas) - 1,
            ias_mask: (1u64 << ias) - 1,
            owned_tables: KVec::new(),
            dirty_tables,
            pending_tables: RefCell::new(pending_tables),
            invalidations: RefCell::new(KVec::new()),
        })
    }

    /// Borrow a firmware root without owning its existing child tables.
    pub(crate) fn new_with_ttb_and_ias(
        ttb: PhysicalAddr,
        va_range: Range<u64>,
        oas: u32,
        ias: usize,
    ) -> Result<Self> {
        if !(UAT_PGBIT..=UAT_PGBIT + UAT_LEVELS * UAT_LVBIT).contains(&ias)
            || !(UAT_PGBIT as u32..=52).contains(&oas)
            || va_range.is_empty()
            || va_range.end - va_range.start > 1u64 << ias
        {
            return Err(EINVAL);
        }
        pr_debug!(
            "UATPageTable::new_with_ttb: ttb={:#x} range={:#x?} oas={}\n",
            ttb,
            va_range,
            oas
        );
        if ttb & (UAT_PGMSK as PhysicalAddr) != 0 {
            return Err(EINVAL);
        }
        if (va_range.start | va_range.end) & (UAT_PGMSK as u64) != 0 {
            return Err(EINVAL);
        }
        // SAFETY: The TTB is should remain valid (if properly mapped), as it is bootloader-managed.
        if unsafe { Page::borrow_phys(&ttb) }.is_none() {
            pr_err!(
                "UATPageTable::new_with_ttb: ttb at {:#x} is not mapped (DT using no-map?)\n",
                ttb
            );
            return Err(EIO);
        }

        Ok(UatPageTable {
            ttb,
            ttb_owned: false,
            va_range,
            oas_mask: (1u64 << oas) - 1,
            ias_mask: (1u64 << ias) - 1,
            owned_tables: KVec::new(),
            dirty_tables: RBTree::new(),
            pending_tables: RefCell::new(KVec::new()),
            invalidations: RefCell::new(KVec::new()),
        })
    }

    /// Queue cache cleaning for edited tables, including borrowed ancestors.
    /// The enclosing publication batch supplies the completion barrier.
    pub(crate) fn clean(&self) {
        for phys in self.pending_tables.borrow_mut().drain_all() {
            self.dirty_tables.get(&phys).unwrap().set(false);
            // SAFETY: Every recorded table is live until this owner is dropped.
            let page = unsafe { Page::borrow_phys_unchecked(&phys) };
            page.with_page_mapped(|p| {
                for off in (0..UAT_PGSZ).step_by(64) {
                    // SAFETY: This cache line lies within the mapped table page.
                    unsafe {
                        core::arch::asm!("dc cvac, {addr}", addr = in(reg) p.add(off));
                    }
                }
            });
        }
    }

    pub(crate) fn sync(&self) {
        self.clean();
        crate::mem::sync();
    }

    /// Publish changed global mappings, then forget the completed ranges.
    pub(crate) fn publish(&self) {
        self.sync();
        self.invalidate(None);
        crate::mem::sync();
        self.clear_invalidations();
    }

    /// Record before editing so an allocation failure cannot hide a changed
    /// mapping. Adjacent edits share one invalidation interval.
    fn changed_gfp(&mut self, range: Range<u64>, gfp: kernel::alloc::Flags) -> Result {
        if range.is_empty()
            || range.start < self.va_range.start
            || range.end > self.va_range.end
            || (range.start | range.end) & UAT_PGMSK as u64 != 0
        {
            return Err(EINVAL);
        }
        let ranges = self.invalidations.get_mut();
        if let Some(last) = ranges.last_mut() {
            if last.start <= range.end && range.start <= last.end {
                last.start = last.start.min(range.start);
                last.end = last.end.max(range.end);
                return Ok(());
            }
        }
        ranges.push(range, gfp)?;
        Ok(())
    }

    /// PTE cleaning must have completed before invalidation. None targets
    /// global firmware mappings by VA across all ASIDs, never the whole TLB.
    pub(crate) fn invalidate(&self, asid: Option<u8>) {
        for range in self.invalidations.borrow().iter() {
            crate::mem::tlbi_range(asid, range.start, range.end);
        }
    }

    pub(crate) fn reserve_invalidation_gfp(&mut self, gfp: kernel::alloc::Flags) -> Result {
        self.reserve_invalidations_gfp(1, gfp)
    }

    pub(crate) fn reserve_invalidations_gfp(
        &mut self,
        additional: usize,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        self.invalidations.get_mut().reserve(additional, gfp)?;
        Ok(())
    }

    pub(crate) fn reserve_pending_tables_gfp(
        &mut self,
        additional: usize,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        self.pending_tables.get_mut().reserve(additional, gfp)?;
        Ok(())
    }

    /// Pre-reserve invalidation and dirty-table queue capacity so tearing down
    /// any single Work alias or TVB region (at most two leaf tables) cannot
    /// allocate when `sync()` / `clear_invalidations()` drains between items.
    pub(crate) fn reserve_teardown_gfp(&mut self, gfp: kernel::alloc::Flags) -> Result {
        let inv = self.invalidations.get_mut();
        if inv.capacity() < 2 {
            inv.reserve(2 - inv.len(), gfp)?;
        }
        let pending = self.pending_tables.get_mut();
        if pending.capacity() < 4 {
            pending.reserve(4 - pending.len(), gfp)?;
        }
        Ok(())
    }

    pub(crate) fn has_pending_tables(&self) -> bool {
        !self.pending_tables.borrow().is_empty()
    }

    pub(crate) fn has_invalidations(&self) -> bool {
        !self.invalidations.borrow().is_empty()
    }

    pub(crate) fn clear_invalidations(&self) {
        self.invalidations.borrow_mut().clear();
    }

    // Record dirtiness before writing a PTE so allocation failure cannot leave
    // an untracked edit. Read-only walks neither allocate nor dirty metadata.
    fn mark_dirty_gfp(&mut self, phys: PhysicalAddr, gfp: kernel::alloc::Flags) -> Result {
        match self.dirty_tables.get(&phys) {
            Some(dirty) if dirty.get() => return Ok(()),
            Some(_) => {}
            None => {
                self.dirty_tables
                    .try_create_and_insert(phys, Cell::new(false), gfp)?;
            }
        }
        // Queue before setting membership or editing a PTE. A failed reserve
        // leaves the table clean and permits a later attempt to enqueue it.
        self.pending_tables.get_mut().push(phys, gfp)?;
        self.dirty_tables.get(&phys).unwrap().set(true);
        Ok(())
    }

    pub(crate) fn ttb(&self) -> PhysicalAddr {
        self.ttb
    }

    fn with_pages<F>(&mut self, iova_range: Range<u64>, walk: Walk, cb: F) -> Result
    where
        F: FnMut(u64, &[Pte]) -> Result,
    {
        self.with_pages_gfp(iova_range, walk, GFP_KERNEL, cb)
    }

    /// Exact read-only count of intermediate + leaf page tables currently
    /// missing for `iova_range`. Zero allocations; monotonic upper bound while
    /// this page table is alive because intermediate tables are never freed.
    pub(crate) fn missing_tables_for_range(&self, iova_range: &Range<u64>) -> usize {
        if iova_range.is_empty()
            || iova_range.start < self.va_range.start
            || iova_range.end > self.va_range.end
            || (iova_range.start | iova_range.end) & (UAT_PGMSK as u64) != 0
        {
            return 0;
        }
        let mut iova = iova_range.start & self.ias_mask;
        let end = ((iova_range.end - 1) & self.ias_mask) + 1;
        let l0_shift = (UAT_PGBIT + UAT_LVBIT) as u64;
        let l1_shift = (UAT_PGBIT + 2 * UAT_LVBIT) as u64;
        let l0_block = 1u64 << l0_shift;
        let l1_block = 1u64 << l1_shift;
        let mut missing = 0usize;
        let read_pte = |table_phys: PhysicalAddr, idx: usize| -> u64 {
            // SAFETY: Live page table owned by us or firmware.
            let page = unsafe { Page::borrow_phys_unchecked(&table_phys) };
            page.with_pointer_into_page(idx * PTE_SIZE, PTE_SIZE, |p| {
                // SAFETY: Index is aligned and in-bounds for a 16 KiB table.
                Ok(unsafe { &*(p as *const Pte) }.load(Ordering::Relaxed))
            })
            .unwrap_or(0)
        };
        while iova < end {
            let l1_idx = ((iova >> l1_shift) & UAT_LVMSK) as usize;
            let l1_pte = read_pte(self.ttb, l1_idx);
            let next_l1 = align(iova + 1, l1_block);
            if l1_pte & PTE_TYPE_BITS != PTE_TYPE_LEAF_TABLE {
                if l1_pte == 0 {
                    let sub_end = end.min(next_l1) - 1;
                    let l0_count = ((sub_end >> l0_shift) - (iova >> l0_shift) + 1) as usize;
                    missing = missing.saturating_add(1).saturating_add(l0_count);
                }
                iova = next_l1;
                continue;
            }
            let l1_phys = l1_pte & self.oas_mask & (!UAT_PGMSK as u64);
            let sub_end = end.min(next_l1);
            while iova < sub_end {
                let l0_idx = ((iova >> l0_shift) & UAT_LVMSK) as usize;
                let l0_pte = read_pte(l1_phys, l0_idx);
                if l0_pte == 0 {
                    missing = missing.saturating_add(1);
                }
                iova = align(iova + 1, l0_block);
            }
        }
        missing
    }

    fn with_pages_gfp<F>(
        &mut self,
        iova_range: Range<u64>,
        walk: Walk,
        gfp: kernel::alloc::Flags,
        cb: F,
    ) -> Result
    where
        F: FnMut(u64, &[Pte]) -> Result,
    {
        self.with_pages_gfp_opt(iova_range, walk, gfp, None, cb)
    }

    fn with_pages_gfp_opt<F>(
        &mut self,
        iova_range: Range<u64>,
        walk: Walk,
        gfp: kernel::alloc::Flags,
        mut prealloc: Option<&mut KVec<kernel::types::Owned<Page>>>,
        mut cb: F,
    ) -> Result
    where
        F: FnMut(u64, &[Pte]) -> Result,
    {
        let alloc = matches!(walk, Walk::Allocate);
        let write = !matches!(walk, Walk::Read);
        pr_debug!(
            "UATPageTable::with_pages: {:#x?} alloc={}\n",
            iova_range,
            alloc
        );
        if (iova_range.start | iova_range.end) & (UAT_PGMSK as u64) != 0 {
            pr_err!(
                "UATPageTable::with_pages: iova range not aligned: {:#x?}\n",
                iova_range
            );
            return Err(EINVAL);
        }

        if iova_range.is_empty() {
            return Ok(());
        }

        let mut iova = iova_range.start & self.ias_mask;
        let mut last_iova = iova;
        // Handle the case where iova_range.end is just at the top boundary of the IAS
        let end = ((iova_range.end - 1) & self.ias_mask) + 1;

        let mut pt_addr: [Option<PhysicalAddr>; UAT_LEVELS] = Default::default();
        pt_addr[UAT_LEVELS - 1] = Some(self.ttb);

        'outer: while iova < end {
            pr_debug!("UATPageTable::with_pages: iova={:#x}\n", iova);
            let addr_diff = last_iova ^ iova;
            for level in (0..UAT_LEVELS - 1).rev() {
                // If the iova has changed at this level or above, invalidate the physaddr
                if addr_diff & !((1 << (UAT_PGBIT + (level + 1) * UAT_LVBIT)) - 1) != 0 {
                    if pt_addr[level].take().is_some() {
                        pr_debug!("UATPageTable::with_pages: invalidate level {}\n", level);
                    }
                }
            }
            last_iova = iova;
            for level in (0..UAT_LEVELS - 1).rev() {
                // Fetch the page table base address for this level
                if pt_addr[level].is_none() {
                    let phys = pt_addr[level + 1].unwrap();
                    pr_debug!(
                        "UATPageTable::with_pages: need level {}, parent phys {:#x}\n",
                        level,
                        phys
                    );
                    let upidx = ((iova >> (UAT_PGBIT + (level + 1) * UAT_LVBIT) as u64) & UAT_LVMSK)
                        as usize;
                    // SAFETY: Page table addresses are either allocated by us, or
                    // firmware-managed and safe to borrow a struct page from.
                    let upt = unsafe { Page::borrow_phys_unchecked(&phys) };
                    pr_debug!("UATPageTable::with_pages: borrowed phys {:#x}\n", phys);
                    pt_addr[level] =
                        upt.with_pointer_into_page(upidx * PTE_SIZE, PTE_SIZE, |p| {
                            let uptep = p as *const _ as *const Pte;
                            // SAFETY: with_pointer_into_page() ensures the pointer is valid,
                            // and our index is aligned so it is safe to deref as an AtomicU64.
                            let upte = unsafe { &*uptep };
                            let mut upte_val = upte.load(Ordering::Relaxed);
                            // Allocate if requested
                            if upte_val == 0 && alloc {
                                self.mark_dirty_gfp(phys, gfp)?;
                                self.owned_tables.reserve(1, gfp)?;
                                self.pending_tables.get_mut().reserve(1, gfp)?;
                                let pt_page = match prealloc.as_deref_mut().and_then(KVec::pop) {
                                    Some(page) => page,
                                    None => Page::alloc_page(gfp | __GFP_ZERO)?,
                                };
                                pr_debug!("UATPageTable::with_pages: alloc PT at {:#x}\n", pt_page.phys());
                                let pt_paddr = pt_page.phys();
                                let dirty_node = kernel::rbtree::RBTreeNode::new(
                                    pt_paddr,
                                    Cell::new(true),
                                    gfp,
                                )?;
                                // Every fallible allocation succeeded; commit
                                // ownership, dirty tracking for the zeroed new
                                // table, and the parent PTE atomically.
                                let _ = Page::into_phys(pt_page);
                                self.dirty_tables.insert(dirty_node);
                                let _ = self.pending_tables.get_mut().push_within_capacity(pt_paddr);
                                let _ = self.owned_tables.push_within_capacity(OwnedTable {
                                    phys: pt_paddr,
                                    parent: phys,
                                    index: upidx,
                                });
                                upte_val = pt_paddr | PTE_TYPE_LEAF_TABLE;
                                upte.store(upte_val, Ordering::Relaxed);
                            }
                            if upte_val & PTE_TYPE_BITS == PTE_TYPE_LEAF_TABLE {
                                Ok(Some(upte_val & self.oas_mask & (!UAT_PGMSK as u64)))
                            } else if upte_val == 0 || !alloc {
                                pr_debug!("UATPageTable::with_pages: no level {}\n", level);
                                Ok(None)
                            } else {
                                pr_err!("UATPageTable::with_pages: Unexpected Table PTE value {:#x} at iova {:#x} index {} phys {:#x}\n", upte_val,
                                        iova, level + 1, phys + ((upidx * PTE_SIZE) as PhysicalAddr));
                                Ok(None)
                            }
                        })?;
                    pr_debug!(
                        "UATPageTable::with_pages: level {} PT {:#x?}\n",
                        level,
                        pt_addr[level]
                    );
                }
                // If we don't have a page table, skip this entire level
                if pt_addr[level].is_none() {
                    let block = 1 << (UAT_PGBIT + UAT_LVBIT * (level + 1));
                    let old = iova;
                    iova = align(iova + 1, block);
                    pr_debug!(
                        "UATPageTable::with_pages: skip {:#x} {:#x} -> {:#x}\n",
                        block,
                        old,
                        iova
                    );
                    continue 'outer;
                }
            }

            let idx = ((iova >> UAT_PGBIT as u64) & UAT_LVMSK) as usize;
            let max_count = UAT_NPTE - idx;
            let count = (((end - iova) >> UAT_PGBIT) as usize).min(max_count);
            let phys = pt_addr[0].unwrap();
            pr_debug!(
                "UATPageTable::with_pages: leaf PT at {:#x} idx {:#x} count {:#x} iova {:#x}\n",
                phys,
                idx,
                count,
                iova
            );
            if write {
                self.mark_dirty_gfp(phys, gfp)?;
            }
            // SAFETY: Page table addresses are either allocated by us, or
            // firmware-managed and safe to borrow a struct page from.
            let pt = unsafe { Page::borrow_phys_unchecked(&phys) };
            pt.with_pointer_into_page(idx * PTE_SIZE, count * PTE_SIZE, |p| {
                let ptep = p as *const _ as *const Pte;
                // SAFETY: We know this is a valid pointer to PTEs and the range is valid and
                // checked by with_pointer_into_page().
                let ptes = unsafe { core::slice::from_raw_parts(ptep, count) };
                cb(iova, ptes)?;
                Ok(())
            })?;

            let block = 1 << (UAT_PGBIT + UAT_LVBIT);
            iova = align(iova + 1, block);
        }

        Ok(())
    }

    fn pte_bits(&self) -> u64 {
        if self.ttb_owned {
            // Owned page tables are userspace, so non-global
            PTE_TYPE_LEAF_TABLE | UAT_NON_GLOBAL
        } else {
            // The sole non-owned page table is kernelspace, so global
            PTE_TYPE_LEAF_TABLE
        }
    }

    /// Preallocate intermediate page tables, dirty-table tracking, and
    /// invalidation slot capacity for `iova_range` using `gfp` without writing
    /// any leaf PTEs. Once this succeeds, `map_pages_gfp` over subranges of
    /// `iova_range` will not allocate.
    pub(crate) fn prepare_map_gfp(
        &mut self,
        iova_range: Range<u64>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        if iova_range.is_empty()
            || iova_range.start < self.va_range.start
            || iova_range.end > self.va_range.end
            || (iova_range.start | iova_range.end) & UAT_PGMSK as u64 != 0
        {
            return Err(EINVAL);
        }
        self.reserve_invalidation_gfp(gfp)?;
        self.with_pages_gfp(iova_range, Walk::Allocate, gfp, |_, _| Ok(()))
    }

    pub(crate) fn prepare_map_prealloc_gfp(
        &mut self,
        iova_range: Range<u64>,
        prealloc: &mut KVec<kernel::types::Owned<Page>>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        if iova_range.is_empty()
            || iova_range.start < self.va_range.start
            || iova_range.end > self.va_range.end
            || (iova_range.start | iova_range.end) & UAT_PGMSK as u64 != 0
        {
            return Err(EINVAL);
        }
        self.reserve_invalidation_gfp(gfp)?;
        self.with_pages_gfp_opt(iova_range, Walk::Allocate, gfp, Some(prealloc), |_, _| Ok(()))
    }

    pub(crate) fn map_pages(
        &mut self,
        iova_range: Range<u64>,
        phys: PhysicalAddr,
        prot: Prot,
        one_page: bool,
    ) -> Result {
        self.map_pages_gfp(iova_range, phys, prot, one_page, GFP_KERNEL)
    }

    pub(crate) fn map_pages_gfp(
        &mut self,
        iova_range: Range<u64>,
        mut phys: PhysicalAddr,
        prot: Prot,
        one_page: bool,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        pr_debug!(
            "UATPageTable::map_pages: {:#x?} {:#x?} {:?}\n",
            iova_range,
            phys,
            prot
        );
        if phys & (UAT_PGMSK as PhysicalAddr) != 0 {
            pr_err!("UATPageTable::map_pages: phys not aligned: {:#x?}\n", phys);
            return Err(EINVAL);
        }

        self.changed_gfp(iova_range.clone(), gfp)?;
        let pte_bits = self.pte_bits();

        self.with_pages_gfp(iova_range, Walk::Allocate, gfp, |iova, ptes| {
            for (idx, pte) in ptes.iter().enumerate() {
                let ptev = pte.load(Ordering::Relaxed);
                if ptev != 0 {
                    pr_err!(
                        "UATPageTable::map_pages: Page at IOVA {:#x} is mapped (PTE: {:#x})\n",
                        iova + (idx * UAT_PGSZ) as u64,
                        ptev
                    );
                }
                pte.store(phys | prot.as_pte() | pte_bits, Ordering::Relaxed);
                if !one_page {
                    phys += UAT_PGSZ as PhysicalAddr;
                }
            }
            Ok(())
        })
    }

    /// Resolve a mapped byte address without allocating page tables.
    pub(crate) fn translate(&mut self, iova: u64) -> Result<Option<PhysicalAddr>> {
        let page = iova & !(UAT_PGMSK as u64);
        let end = page.checked_add(UAT_PGSZ as u64).ok_or(EINVAL)?;
        if page < self.va_range.start || end > self.va_range.end {
            return Err(EINVAL);
        }
        let mut result = None;
        let mask = self.oas_mask & !(UAT_PGMSK as u64);
        self.with_pages(page..end, Walk::Read, |_, ptes| {
            let pte = ptes[0].load(Ordering::Relaxed);
            if pte & PTE_TYPE_BITS == PTE_TYPE_LEAF_TABLE {
                result = Some((pte & mask) | (iova & UAT_PGMSK as u64));
            }
            Ok(())
        })?;
        Ok(result)
    }

    pub(crate) fn unmap_pages(&mut self, iova_range: Range<u64>) -> Result {
        self.unmap_pages_gfp(iova_range, GFP_KERNEL)
    }

    pub(crate) fn unmap_pages_gfp(
        &mut self,
        iova_range: Range<u64>,
        gfp: kernel::alloc::Flags,
    ) -> Result {
        self.changed_gfp(iova_range.clone(), gfp)?;
        pr_debug!("UATPageTable::unmap_pages: {:#x?}\n", iova_range);
        self.with_pages_gfp(iova_range, Walk::Write, gfp, |iova, ptes| {
            for (idx, pte) in ptes.iter().enumerate() {
                if pte.load(Ordering::Relaxed) & PTE_TYPE_LEAF_TABLE == 0 {
                    pr_err!(
                        "UATPageTable::unmap_pages: Page at IOVA {:#x} already unmapped\n",
                        iova + (idx * UAT_PGSZ) as u64
                    );
                }
                pte.store(0, Ordering::Relaxed);
            }
            Ok(())
        })
    }

}

impl Drop for UatPageTable {
    fn drop(&mut self) {
        pr_debug!("UATPageTable::drop range: {:#x?}\n", &self.va_range);
        // Free only the child tables allocated by this owner. G16 extends
        // firmware-owned child tables inside its host VA range; walking and
        // freeing the whole range would release reserved firmware memory.
        while let Some(table) = self.owned_tables.pop() {
            // SAFETY: Parents precede children in the allocation list. A
            // parent is either still owned here or is bootloader-reserved.
            let parent = unsafe { Page::borrow_phys_unchecked(&table.parent) };
            let _ = parent.with_pointer_into_page(table.index * PTE_SIZE, PTE_SIZE, |p| {
                // SAFETY: This checked slot is an aligned atomic page-table entry.
                let pte = unsafe { &*p.cast::<Pte>() };
                pte.store(0, Ordering::Relaxed);
                Ok(())
            });
            // SAFETY: Each tracked table was transferred once with into_phys.
            unsafe { Page::from_phys(table.phys) };
        }
        if self.ttb_owned {
            pr_debug!("UATPageTable::drop: Free TTB {:#x}\n", self.ttb);
            // SAFETY: If we own the ttb, it was allocated with Page::into_phys().
            unsafe {
                Page::from_phys(self.ttb);
            }
        }
    }
}

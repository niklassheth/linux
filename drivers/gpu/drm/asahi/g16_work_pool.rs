// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Per-VM firmware Work slot ownership and recycling state machine.
//!
//! Each client `AddressSpace` owns its own leased and idle firmware Work slots.
//! Retired slots return only to their owning VM's free list so a Work physical
//! page and its GPU alias PTE never cross VM boundaries, while intra-VM reuse
//! requires zero PTE edits, zero allocations, and zero TLB invalidations.
//! Pure state logic, host-tested.

/// Firmware VA stride for one compute Work slot (`0x4000` priv + `0x4000` shared).
pub(crate) const COMPUTE_STRIDE: u64 = 0x8000;
/// Firmware VA stride for one render Work slot (`0x10000` priv + `0xc000` shared).
pub(crate) const RENDER_STRIDE: u64 = 0x1c000;
/// Base of the GPU alias window for compute Work pages.
pub(crate) const COMPUTE_ALIAS_BASE: u64 = 0x71_0000_0000;
/// Base of the GPU alias window for render Work pages.
pub(crate) const RENDER_ALIAS_BASE: u64 = 0x72_0000_0000;

/// Firmware VA stride (and resident backing size) for one Work slot.
#[inline]
pub(crate) const fn stride(render: bool) -> u64 {
    if render {
        RENDER_STRIDE
    } else {
        COMPUTE_STRIDE
    }
}

/// GPU alias VA range for one Work slot (`0x4000` for compute, `0x8000` for render).
pub(crate) fn alias_range(
    work_va: u64,
    work_base: u64,
    work_window: u64,
    render: bool,
) -> Option<core::ops::Range<u64>> {
    let offset = work_va.checked_sub(work_base)?;
    let (base, len) = if render {
        (RENDER_ALIAS_BASE, 0x8000u64)
    } else {
        (COMPUTE_ALIAS_BASE, 0x4000u64)
    };
    let start = base.checked_add(offset)?;
    let end = start.checked_add(len)?;
    if end > base.checked_add(work_window)? {
        return None;
    }
    Some(start..end)
}

/// Fixed-capacity `u64` list abstraction (`KVec<u64>` in kernel, `Vec<u64>` in host tests).
pub(crate) trait SlotVec: Default {
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn pop_slot(&mut self) -> Option<u64>;
    fn last_slot(&self) -> Option<u64>;
    fn push_within(&mut self, va: u64) -> core::result::Result<(), u64>;
    fn contains_slot(&self, va: u64) -> bool;
    fn remove_slot(&mut self, va: u64) -> bool;
}

/// Per-VM Work slot pool (`0 = compute`, `1 = render`).
///
/// Invariant: for each kind `i`, `free[i].len() + leased[i] == owned[i].len()`,
/// every element of `free[i]` is a distinct member of `owned[i]`, and slots in
/// `owned[i]` never move to any other `VmWorkPool` while this VM is alive.
pub(crate) struct VmWorkPool<V: SlotVec> {
    owned: [V; 2],
    free: [V; 2],
    leased: [usize; 2],
}

impl<V: SlotVec> Default for VmWorkPool<V> {
    fn default() -> Self {
        Self {
            owned: [V::default(), V::default()],
            free: [V::default(), V::default()],
            leased: [0; 2],
        }
    }
}

impl<V: SlotVec> VmWorkPool<V> {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn has_free(&self, render: bool) -> bool {
        !self.free[usize::from(render)].is_empty()
    }

    pub(crate) fn leased_count(&self, render: bool) -> usize {
        self.leased[usize::from(render)]
    }

    pub(crate) fn all_idle(&self) -> bool {
        self.leased == [0, 0]
    }

    pub(crate) fn owned_bytes(&self) -> usize {
        self.owned[0].len() * COMPUTE_STRIDE as usize
            + self.owned[1].len() * RENDER_STRIDE as usize
    }

    pub(crate) fn lists_mut(&mut self, render: bool) -> (&mut V, &mut V) {
        let idx = usize::from(render);
        (&mut self.owned[idx], &mut self.free[idx])
    }

    /// Reuse an already-mapped idle Work slot owned by this VM.
    pub(crate) fn pop_free(&mut self, render: bool) -> Option<u64> {
        let idx = usize::from(render);
        let va = self.free[idx].pop_slot()?;
        self.leased[idx] += 1;
        Some(va)
    }

    /// Record a freshly allocated and mapped Work slot as owned and leased by this VM.
    /// Caller must have reserved capacity in `owned` and `free` up front.
    pub(crate) fn record_fresh(&mut self, render: bool, va: u64) -> core::result::Result<(), ()> {
        let idx = usize::from(render);
        if self.owned[idx].contains_slot(va) {
            return Err(());
        }
        self.owned[idx].push_within(va).map_err(|_| ())?;
        self.leased[idx] += 1;
        Ok(())
    }

    /// Return a retired or rolled-back Work slot to this VM's idle free list.
    /// Never allocates; rejects slots not owned by this VM or already free.
    pub(crate) fn release(&mut self, render: bool, va: u64) -> core::result::Result<(), ()> {
        let idx = usize::from(render);
        if self.leased[idx] == 0
            || !self.owned[idx].contains_slot(va)
            || self.free[idx].contains_slot(va)
        {
            return Err(());
        }
        self.free[idx].push_within(va).map_err(|_| ())?;
        self.leased[idx] -= 1;
        Ok(())
    }

    /// Peek the next owned idle slot to tear down during VM detach.
    /// Returns `None` when no slots of `render` remain or any slot is still leased.
    pub(crate) fn peek_teardown(&self, render: bool) -> Option<u64> {
        let idx = usize::from(render);
        if self.leased[idx] != 0 {
            return None;
        }
        self.owned[idx].last_slot()
    }

    /// Remove a torn-down slot after its aliases and firmware pages were released.
    pub(crate) fn complete_teardown(&mut self, render: bool, va: u64) -> core::result::Result<(), ()> {
        let idx = usize::from(render);
        if self.leased[idx] != 0 {
            return Err(());
        }
        if !self.free[idx].contains_slot(va) || !self.owned[idx].contains_slot(va) {
            return Err(());
        }
        if !self.free[idx].remove_slot(va) || !self.owned[idx].remove_slot(va) {
            return Err(());
        }
        Ok(())
    }
}

/// Sink for automatic RAII rollback of pre-publication `Scratch` and `Work` leases.
pub(crate) trait LeaseSink<S> {
    fn poisoned(&self) -> bool;
    fn release_work(&mut self, render: bool, va: u64);
    fn release_scratch(&mut self, scratch: S);
}

/// RAII guard owning pre-publication `Scratch` and per-VM `Work` leases until
/// publication starts (`commit()`).
///
/// Any `?` error exit before `commit()` runs `Drop`: when the runtime is not
/// poisoned, both held leases return to the owning VM automatically; when
/// poisoned, both remain quarantined.
pub(crate) struct PrepGuard<'a, S, T: LeaseSink<S>> {
    sink: &'a mut T,
    render: bool,
    scratch: Option<S>,
    work: Option<u64>,
}

impl<'a, S, T: LeaseSink<S>> PrepGuard<'a, S, T> {
    pub(crate) fn new(sink: &'a mut T, render: bool) -> Self {
        Self {
            sink,
            render,
            scratch: None,
            work: None,
        }
    }

    pub(crate) fn sink_mut(&mut self) -> &mut T {
        self.sink
    }

    pub(crate) fn set_scratch(&mut self, scratch: S) {
        self.scratch = Some(scratch);
    }

    pub(crate) fn set_work(&mut self, va: u64) {
        self.work = Some(va);
    }

    /// Transfer both leases out of the guard right before the point of no
    /// return (publication / quarantine boundary), disarming `Drop`.
    pub(crate) fn commit(mut self) -> Option<(S, u64)> {
        let scratch = self.scratch.take()?;
        let work = self.work.take()?;
        Some((scratch, work))
    }
}

impl<S, T: LeaseSink<S>> Drop for PrepGuard<'_, S, T> {
    fn drop(&mut self) {
        if !self.sink.poisoned() {
            if let Some(va) = self.work.take() {
                self.sink.release_work(self.render, va);
            }
            if let Some(scratch) = self.scratch.take() {
                self.sink.release_scratch(scratch);
            }
        }
    }
}

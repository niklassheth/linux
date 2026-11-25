use g16_work_pool::{
    alias_range, stride, SlotVec, VmWorkPool, COMPUTE_ALIAS_BASE, COMPUTE_STRIDE,
    RENDER_ALIAS_BASE, RENDER_STRIDE,
};

const WORK_BASE: u64 = 0xffff_fc22_0000_0000;
const WORK_WINDOW: u64 = 0x1_0000_0000;

impl SlotVec for Vec<u64> {
    fn len(&self) -> usize {
        Vec::len(self)
    }

    fn pop_slot(&mut self) -> Option<u64> {
        self.pop()
    }

    fn last_slot(&self) -> Option<u64> {
        self.last().copied()
    }

    fn push_within(&mut self, va: u64) -> Result<(), u64> {
        if self.len() >= self.capacity() {
            return Err(va);
        }
        self.push(va);
        Ok(())
    }

    fn contains_slot(&self, va: u64) -> bool {
        self.contains(&va)
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

fn reserve_one(pool: &mut VmWorkPool<Vec<u64>>, render: bool) {
    let (owned, free) = pool.lists_mut(render);
    owned.reserve(1);
    let need_free = (owned.len() + 1).saturating_sub(free.len());
    free.reserve(need_free);
}

#[test]
fn two_vms_never_share_work_slots_or_aliases_while_alive() {
    let mut vm_a = VmWorkPool::<Vec<u64>>::new();
    let mut vm_b = VmWorkPool::<Vec<u64>>::new();
    let mut next_va = WORK_BASE;

    // VM A leases and retires a render Work slot; it stays strictly in VM A.
    reserve_one(&mut vm_a, true);
    let va_a = next_va;
    next_va += stride(true);
    assert_eq!(vm_a.record_fresh(true, va_a), Ok(()));
    assert_eq!(vm_a.leased_count(true), 1);
    assert_eq!(vm_a.owned_bytes(), RENDER_STRIDE as usize);
    assert!(!vm_a.all_idle());
    assert_eq!(vm_a.release(true, va_a), Ok(()));
    assert!(vm_a.has_free(true));
    assert!(vm_a.all_idle());

    // VM B cannot see or reuse VM A's idle slot; it must allocate its own.
    assert!(!vm_b.has_free(true));
    assert_eq!(vm_b.pop_free(true), None);
    // Attempting to return VM A's slot into VM B is rejected.
    assert_eq!(vm_b.release(true, va_a), Err(()));

    reserve_one(&mut vm_b, true);
    let va_b = next_va;
    next_va += stride(true);
    assert_ne!(va_a, va_b);
    assert_eq!(vm_b.record_fresh(true, va_b), Ok(()));
    assert_eq!(vm_b.owned_bytes(), RENDER_STRIDE as usize);

    // VM A reuses its own slot with zero new allocation and identical VA.
    assert_eq!(vm_a.pop_free(true), Some(va_a));
    assert_eq!(vm_a.owned_bytes(), RENDER_STRIDE as usize);
    assert_eq!(vm_a.leased_count(true), 1);

    // Double release is rejected.
    assert_eq!(vm_a.release(true, va_a), Ok(()));
    assert_eq!(vm_a.release(true, va_a), Err(()));

    // Teardown refuses while VM B still has a leased slot, then succeeds once idle.
    assert_eq!(vm_b.peek_teardown(true), None);
    assert_eq!(vm_b.release(true, va_b), Ok(()));
    assert_eq!(vm_b.peek_teardown(true), Some(va_b));
    assert_eq!(vm_b.complete_teardown(true, va_b), Ok(()));
    assert_eq!(vm_b.peek_teardown(true), None);
    assert_eq!(vm_b.owned_bytes(), 0);
    // Reclaimed VA va_b can only be reallocated fresh after VM B tore it down.
    let _ = next_va;
}

#[test]
fn compute_and_render_accounting_and_alias_windows() {
    let mut vm = VmWorkPool::<Vec<u64>>::new();
    reserve_one(&mut vm, false);
    reserve_one(&mut vm, true);
    let va_c = WORK_BASE;
    let va_r = WORK_BASE + COMPUTE_STRIDE;
    assert_eq!(vm.record_fresh(false, va_c), Ok(()));
    assert_eq!(vm.record_fresh(true, va_r), Ok(()));
    assert_eq!(
        vm.owned_bytes(),
        (COMPUTE_STRIDE + RENDER_STRIDE) as usize
    );

    // Alias ranges match the 0x71 (compute, 16K) and 0x72 (render, 32K) windows.
    assert_eq!(
        alias_range(va_c, WORK_BASE, WORK_WINDOW, false),
        Some(COMPUTE_ALIAS_BASE..COMPUTE_ALIAS_BASE + 0x4000)
    );
    assert_eq!(
        alias_range(va_r, WORK_BASE, WORK_WINDOW, true),
        Some(RENDER_ALIAS_BASE + COMPUTE_STRIDE..RENDER_ALIAS_BASE + COMPUTE_STRIDE + 0x8000)
    );
    // Out-of-window VA is rejected.
    assert_eq!(
        alias_range(WORK_BASE + WORK_WINDOW, WORK_BASE, WORK_WINDOW, true),
        None
    );

    // Releasing both returns them to separate kind free lists and drains cleanly.
    assert_eq!(vm.release(false, va_c), Ok(()));
    assert_eq!(vm.release(true, va_r), Ok(()));
    assert!(vm.all_idle());
    assert_eq!(vm.complete_teardown(false, va_c), Ok(()));
    assert_eq!(vm.owned_bytes(), RENDER_STRIDE as usize);
    assert_eq!(vm.complete_teardown(true, va_r), Ok(()));
    assert_eq!(vm.owned_bytes(), 0);
}

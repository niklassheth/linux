// SPDX-License-Identifier: GPL-2.0-only
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

fn provision_one(pool: &mut VmWorkPool<Vec<u64>>, render: bool, va: u64) {
    let (owned, free, tearing_down) = pool.lists_mut(render);
    owned.reserve(1);
    let target = owned.len() + 1;
    free.reserve(target.saturating_sub(free.len()));
    tearing_down.reserve(1usize.saturating_sub(tearing_down.len()));
    assert_eq!(pool.record_idle(render, va), Ok(()));
}

#[test]
fn two_vms_never_share_work_slots_or_aliases_while_alive() {
    let mut vm_a = VmWorkPool::<Vec<u64>>::new();
    let mut vm_b = VmWorkPool::<Vec<u64>>::new();
    let mut next_va = WORK_BASE;

    // Provision one render Work slot into VM A (SUBMIT ioctl path).
    let va_a = next_va;
    next_va += stride(true);
    provision_one(&mut vm_a, true, va_a);
    assert_eq!(vm_a.owned_count(true), 1);
    assert!(vm_a.has_free(true));
    assert!(vm_a.all_idle());
    assert_eq!(vm_a.owned_bytes(), RENDER_STRIDE as usize);

    // VM A leases and retires its slot.
    assert_eq!(vm_a.pop_free(true), Some(va_a));
    assert_eq!(vm_a.leased_count(true), 1);
    assert!(!vm_a.all_idle());
    assert_eq!(vm_a.release(true, va_a), Ok(()));
    assert!(vm_a.has_free(true));
    assert!(vm_a.all_idle());

    // VM B cannot see or reuse VM A's idle slot; returning va_a to VM B fails.
    assert!(!vm_b.has_free(true));
    assert_eq!(vm_b.pop_free(true), None);
    assert_eq!(vm_b.release(true, va_a), Err(()));

    let va_b = next_va;
    next_va += stride(true);
    assert_ne!(va_a, va_b);
    provision_one(&mut vm_b, true, va_b);
    assert_eq!(vm_b.pop_free(true), Some(va_b));
    assert_eq!(vm_b.owned_bytes(), RENDER_STRIDE as usize);

    // VM A reuses its own slot with zero new allocation and identical VA.
    assert_eq!(vm_a.pop_free(true), Some(va_a));
    assert_eq!(vm_a.owned_bytes(), RENDER_STRIDE as usize);
    assert_eq!(vm_a.leased_count(true), 1);

    // Double release is rejected.
    assert_eq!(vm_a.release(true, va_a), Ok(()));
    assert_eq!(vm_a.release(true, va_a), Err(()));

    // Teardown refuses while VM B still has a leased slot; once idle,
    // begin_teardown moves va_b out of `free` into `tearing_down` while
    // retaining ownership until finish_teardown completes.
    assert_eq!(vm_b.begin_teardown(true), None);
    assert_eq!(vm_b.release(true, va_b), Ok(()));
    assert_eq!(vm_b.begin_teardown(true), Some(va_b));
    assert!(!vm_b.has_free(true));
    assert_eq!(vm_b.pop_free(true), None);
    assert_eq!(vm_b.peek_tearing_down(true), Some(va_b));
    assert_eq!(vm_b.owned_count(true), 1);
    assert_eq!(vm_b.owned_bytes(), RENDER_STRIDE as usize);
    assert_eq!(vm_b.finish_teardown(true, va_b), Ok(()));
    assert_eq!(vm_b.peek_tearing_down(true), None);
    assert_eq!(vm_b.owned_count(true), 0);
    assert_eq!(vm_b.owned_bytes(), 0);
    let _ = next_va;
}

#[test]
fn compute_and_render_accounting_and_alias_windows() {
    let mut vm = VmWorkPool::<Vec<u64>>::new();
    let va_c = WORK_BASE;
    let va_r = WORK_BASE + COMPUTE_STRIDE;
    provision_one(&mut vm, false, va_c);
    provision_one(&mut vm, true, va_r);
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

    // Teardown keeps ownership until finish_teardown for each kind.
    assert_eq!(vm.begin_teardown(false), Some(va_c));
    assert_eq!(vm.owned_bytes(), (COMPUTE_STRIDE + RENDER_STRIDE) as usize);
    assert_eq!(vm.finish_teardown(false, va_c), Ok(()));
    assert_eq!(vm.owned_bytes(), RENDER_STRIDE as usize);
    assert_eq!(vm.begin_teardown(true), Some(va_r));
    assert_eq!(vm.finish_teardown(true, va_r), Ok(()));
    assert_eq!(vm.owned_bytes(), 0);
}

#[test]
fn interrupted_teardown_stays_unleasable_and_resumes_cleanly() {
    let mut vm = VmWorkPool::<Vec<u64>>::new();
    let va1 = WORK_BASE;
    let va2 = WORK_BASE + RENDER_STRIDE;
    provision_one(&mut vm, true, va1);
    provision_one(&mut vm, true, va2);

    // Start tearing down va2 and simulate an error before finish_teardown.
    assert_eq!(vm.begin_teardown(true), Some(va2));
    // A second begin_teardown refuses until the interrupted slot finishes.
    assert_eq!(vm.begin_teardown(true), None);
    // The tearing-down slot cannot be leased or released back to free.
    assert_eq!(vm.release(true, va2), Err(()));
    assert_eq!(vm.owned_count(true), 2);
    assert_eq!(vm.owned_bytes(), 2 * RENDER_STRIDE as usize);
    // Retry resumes via peek_tearing_down and finishes va2, then va1.
    assert_eq!(vm.peek_tearing_down(true), Some(va2));
    assert_eq!(vm.finish_teardown(true, va2), Ok(()));
    assert_eq!(vm.peek_tearing_down(true), None);
    assert_eq!(vm.owned_count(true), 1);
    assert_eq!(vm.begin_teardown(true), Some(va1));
    assert_eq!(vm.finish_teardown(true, va1), Ok(()));
    assert_eq!(vm.owned_count(true), 0);
    assert_eq!(vm.owned_bytes(), 0);
}

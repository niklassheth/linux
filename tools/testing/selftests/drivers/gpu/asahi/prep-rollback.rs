// SPDX-License-Identifier: GPL-2.0-only
use g16_work_pool::{LeaseSink, PrepGuard, SlotVec, VmWorkPool};

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

#[derive(Debug, PartialEq, Eq)]
struct FakeScratch(u64);

struct FakeRuntime {
    poisoned: bool,
    scratch_users: usize,
    returned_scratch: Vec<u64>,
    work_pool: VmWorkPool<Vec<u64>>,
}

impl FakeRuntime {
    fn new() -> Self {
        Self {
            poisoned: false,
            scratch_users: 0,
            returned_scratch: Vec::new(),
            work_pool: VmWorkPool::new(),
        }
    }

    fn lease_scratch(&mut self, id: u64) -> FakeScratch {
        self.scratch_users += 1;
        FakeScratch(id)
    }

    fn alloc_work(&mut self, render: bool, va: u64) -> u64 {
        let (owned, free, tearing_down) = self.work_pool.lists_mut(render);
        owned.reserve(1);
        free.reserve(1);
        tearing_down.reserve(1);
        self.work_pool.record_idle(render, va).unwrap();
        self.work_pool.pop_free(render).unwrap()
    }
}

impl LeaseSink<FakeScratch> for FakeRuntime {
    fn poisoned(&self) -> bool {
        self.poisoned
    }

    fn release_work(&mut self, render: bool, va: u64) {
        self.work_pool.release(render, va).unwrap();
    }

    fn release_scratch(&mut self, scratch: FakeScratch) {
        self.scratch_users -= 1;
        self.returned_scratch.push(scratch.0);
    }
}

#[test]
fn allocate_work_error_releases_scratch_via_drop() {
    let mut rt = FakeRuntime::new();
    let res: Result<(), &'static str> = (|| {
        let mut prep = PrepGuard::new(&mut rt, true);
        let scratch = prep.sink_mut().lease_scratch(0x1000);
        prep.set_scratch(scratch);
        // Simulate allocate_work returning ENOMEM before set_work.
        Err("ENOMEM")?;
        Ok(())
    })();
    assert_eq!(res, Err("ENOMEM"));
    assert_eq!(rt.scratch_users, 0);
    assert_eq!(rt.returned_scratch, vec![0x1000]);
    assert!(rt.work_pool.all_idle());
}

#[test]
fn post_work_error_releases_both_work_and_scratch_via_drop() {
    let mut rt = FakeRuntime::new();
    let res: Result<(), &'static str> = (|| {
        let mut prep = PrepGuard::new(&mut rt, false);
        let scratch = prep.sink_mut().lease_scratch(0x2000);
        prep.set_scratch(scratch);
        let work = prep.sink_mut().alloc_work(false, 0xffff_fc22_0000_0000);
        prep.set_work(work);
        // Simulate acquire_context returning EBUSY.
        Err("EBUSY")?;
        Ok(())
    })();
    assert_eq!(res, Err("EBUSY"));
    assert_eq!(rt.scratch_users, 0);
    assert_eq!(rt.returned_scratch, vec![0x2000]);
    assert!(rt.work_pool.all_idle());
    assert!(rt.work_pool.has_free(false));
}

#[test]
fn poisoned_runtime_quarantines_both_leases_on_drop() {
    let mut rt = FakeRuntime::new();
    let res: Result<(), &'static str> = (|| {
        let mut prep = PrepGuard::new(&mut rt, true);
        let scratch = prep.sink_mut().lease_scratch(0x3000);
        prep.set_scratch(scratch);
        let work = prep.sink_mut().alloc_work(true, 0xffff_fc22_0001_c000);
        prep.set_work(work);
        prep.sink_mut().poisoned = true;
        Err("EIO")?;
        Ok(())
    })();
    assert_eq!(res, Err("EIO"));
    assert_eq!(rt.scratch_users, 1);
    assert!(rt.returned_scratch.is_empty());
    assert_eq!(rt.work_pool.leased_count(true), 1);
    assert!(!rt.work_pool.has_free(true));
}

#[test]
fn commit_disarms_drop_and_transfers_ownership() {
    let mut rt = FakeRuntime::new();
    let (scratch, work) = {
        let mut prep = PrepGuard::new(&mut rt, true);
        let scratch = prep.sink_mut().lease_scratch(0x4000);
        prep.set_scratch(scratch);
        let work = prep.sink_mut().alloc_work(true, 0xffff_fc22_0003_8000);
        prep.set_work(work);
        prep.commit().unwrap()
    };
    assert_eq!(scratch, FakeScratch(0x4000));
    assert_eq!(work, 0xffff_fc22_0003_8000);
    assert_eq!(rt.scratch_users, 1);
    assert!(rt.returned_scratch.is_empty());
    assert_eq!(rt.work_pool.leased_count(true), 1);
}

#[test]
fn partial_commit_failure_still_rolls_back_held_scratch() {
    let mut rt = FakeRuntime::new();
    let res = {
        let mut prep = PrepGuard::new(&mut rt, true);
        let scratch = prep.sink_mut().lease_scratch(0x5000);
        prep.set_scratch(scratch);
        // Work not set: commit() must return None AND leave scratch for Drop.
        prep.commit()
    };
    assert_eq!(res, None);
    assert_eq!(rt.scratch_users, 0);
    assert_eq!(rt.returned_scratch, vec![0x5000]);
}

#[test]
fn scratch_coalesced_reuse_and_arena_fit_precheck() {
    use std::ops::Range;

    struct ScratchArenaModel {
        arena_next: u64,
        arena_end: u64,
        free: Vec<Range<u64>>,
        max_block: usize,
        allocated_pages: usize,
    }

    impl ScratchArenaModel {
        fn new(size: u64) -> Self {
            Self {
                arena_next: 0,
                arena_end: size,
                free: Vec::new(),
                max_block: 0,
                allocated_pages: 0,
            }
        }

        fn needs_prealloc(&self, size: usize) -> Result<bool, &'static str> {
            if self.max_block >= size
                || self.free.iter().any(|r| r.end - r.start >= size as u64)
            {
                return Ok(false);
            }
            if self.arena_next + size as u64 > self.arena_end {
                return Err("ENOMEM");
            }
            Ok(true)
        }

        fn alloc_block(&mut self, size: usize) -> Range<u64> {
            let start = self.arena_next;
            self.arena_next += size as u64;
            self.allocated_pages += size / 0x4000;
            self.max_block = self.max_block.max(size);
            start..self.arena_next
        }

        fn release_and_coalesce(&mut self, mut range: Range<u64>) {
            let mut i = 0;
            while i < self.free.len() {
                if self.free[i].end == range.start || range.end == self.free[i].start {
                    let old = self.free.remove(i);
                    range.start = range.start.min(old.start);
                    range.end = range.end.max(old.end);
                    i = 0;
                } else {
                    i += 1;
                }
            }
            let merged = (range.end - range.start) as usize;
            self.free.push(range);
            self.max_block = self.max_block.max(merged);
        }
    }

    // 256 KiB total arena: an oversized 512 KiB request fails BEFORE allocating.
    let mut m = ScratchArenaModel::new(0x40000);
    assert_eq!(m.needs_prealloc(0x80000), Err("ENOMEM"));
    assert_eq!(m.allocated_pages, 0);

    // Allocate two adjacent 128 KiB blocks, exhausting the 256 KiB arena.
    assert_eq!(m.needs_prealloc(0x20000), Ok(true));
    let b1 = m.alloc_block(0x20000);
    let b2 = m.alloc_block(0x20000);
    assert_eq!(m.arena_next, m.arena_end);

    // Release both: coalescing merges them into one 256 KiB block and raises
    // max_block, so a subsequent 256 KiB request needs ZERO new backing even
    // though the remaining arena is 0!
    m.release_and_coalesce(b1);
    m.release_and_coalesce(b2);
    assert_eq!(m.max_block, 0x40000);
    assert_eq!(m.needs_prealloc(0x40000), Ok(false));
    assert_eq!(m.allocated_pages, 0x40000 / 0x4000);
}

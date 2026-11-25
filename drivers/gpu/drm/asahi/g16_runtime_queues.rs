// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Firmware queue lifecycle: Work arena slots, queue contexts, and preparing
//! a userspace queue's lanes, events and TVB pool before its first command.

use super::*;

impl Bootstrap {
    /// Lower-bound check for `check_cap_headroom`: true while at least one live
    /// VM holds an idle pre-provisioned Work slot of `render` kind.
    pub(super) fn work_space_left(&self, render: bool) -> bool {
        self.vm_free_work[usize::from(render)] != 0
    }

    /// For the SUBMIT ioctl (process context, BEFORE fence publication):
    /// ensure `client` owns at least `min_slots` pre-mapped per-VM Work slots
    /// so the fence-signalling pump worker never allocates Work pages, PTEs,
    /// or bookkeeping vectors.
    pub(crate) fn provision_work(
        &mut self,
        client: &mut g16_vm::AddressSpace,
        render: bool,
        min_slots: usize,
    ) -> Result {
        if self.render_failed {
            return Err(EIO);
        }
        while client.work_owned(render) < min_slots {
            self.provision_one_work_slot(client, render)?;
        }
        Ok(())
    }

    #[inline(never)]
    fn provision_one_work_slot(
        &mut self,
        client: &mut g16_vm::AddressSpace,
        render: bool,
    ) -> Result {
        use crate::g16_work_pool as wp;
        use crate::pgtable::prot::{PROT_FW_PRIV_RW, PROT_FW_SHARED_RW};
        let index = usize::from(render);
        let stride = wp::stride(render);
        let (priv_size, shared_size) = if render {
            (0x10000usize, 0xc000usize)
        } else {
            (0x4000usize, 0x4000usize)
        };
        // Reserve VM and teardown capacities up front so retirement and VM
        // teardown never allocate.
        client.reserve_work_slot(render)?;
        let from_free = !self.free_work_va[index].is_empty();
        let va = if from_free {
            *self.free_work_va[index].last().ok_or(EIO)?
        } else {
            let end = self.next_work_va.checked_add(stride).ok_or(ENOSPC)?;
            if end > WORK_BASE + WORK_WINDOW {
                return Err(ENOSPC);
            }
            let slots = self.work_va_slots[index] + 1;
            self.free_work_va[index].reserve(slots - self.free_work_va[index].len(), GFP_KERNEL)?;
            self.next_work_va
        };
        let alias_range = wp::alias_range(va, WORK_BASE, WORK_WINDOW, render).ok_or(ENOSPC)?;
        if from_free {
            let popped = self.free_work_va[index].pop().ok_or(EIO)?;
            if popped != va {
                return Err(EIO);
            }
        } else {
            self.next_work_va += stride;
            self.work_va_slots[index] += 1;
        }

        let stages = if render { 2usize } else { 1usize };
        let mut pas = [0u64; 2];
        {
            let fw = self._firmware_space.as_mut().ok_or(EIO)?;
            if let Err(err) = fw.alloc(va, priv_size, PROT_FW_PRIV_RW) {
                // Only recycle `va` if `fw.alloc` did not retain a partial region.
                if !fw.has_region(va) {
                    let _ = self.free_work_va[index].push_within_capacity(va);
                }
                return Err(err);
            }
            if let Err(err) = fw.alloc(va + priv_size as u64, shared_size, PROT_FW_SHARED_RW) {
                let r1 = fw.release_region(va);
                if r1.is_ok() && !fw.has_region(va) && !fw.has_region(va + priv_size as u64) {
                    let _ = self.free_work_va[index].push_within_capacity(va);
                }
                return Err(err);
            }
            for (stage, pa_slot) in pas.iter_mut().take(stages).enumerate() {
                match fw.physical(va + stage as u64 * 0x8000) {
                    Ok(pa) => *pa_slot = pa,
                    Err(err) => {
                        let r1 = fw.release_region(va);
                        let r2 = fw.release_region(va + priv_size as u64);
                        if r1.is_ok()
                            && r2.is_ok()
                            && !fw.has_region(va)
                            && !fw.has_region(va + priv_size as u64)
                        {
                            let _ = self.free_work_va[index].push_within_capacity(va);
                        }
                        return Err(err);
                    }
                }
            }
        }

        let mut dev_mapped = 0u64;
        let mut client_mapped = 0u64;
        let map_res: Result = (|| {
            for (stage, &pa) in pas.iter().take(stages).enumerate() {
                let register_page = alias_range.start + stage as u64 * 0x4000;
                self._address_space
                    .as_mut()
                    .ok_or(EIO)?
                    .map_work_alias(register_page, pa)?;
                dev_mapped = stage as u64 + 1;
                client.map_work_alias(register_page, pa)?;
                client_mapped = stage as u64 + 1;
            }
            Ok(())
        })();
        if let Err(err) = map_res {
            let mut clean = true;
            if client_mapped != 0 {
                let end = alias_range.start + client_mapped * 0x4000;
                if client.unmap_work_alias(alias_range.start..end).is_err() {
                    clean = false;
                }
                if client.has_pending_tables() {
                    client.sync();
                }
                self.invalidate_client(client);
            }
            if dev_mapped != 0 {
                let end = alias_range.start + dev_mapped * 0x4000;
                if let Some(dev_space) = self._address_space.as_mut() {
                    if dev_space.unmap_work_alias(alias_range.start..end).is_err() {
                        clean = false;
                    }
                    if dev_space.has_pending_tables() {
                        dev_space.sync();
                    }
                }
                if let Some(dev_space) = self._address_space.as_ref() {
                    self.invalidate_client(dev_space);
                }
            }
            if clean {
                if let Some(fw) = self._firmware_space.as_mut() {
                    let r1 = fw.release_region(va);
                    let r2 = fw.release_region(va + priv_size as u64);
                    if r1.is_ok()
                        && r2.is_ok()
                        && !fw.has_region(va)
                        && !fw.has_region(va + priv_size as u64)
                    {
                        let _ = self.free_work_va[index].push_within_capacity(va);
                    }
                }
            }
            return Err(err);
        }

        if let Some(fw) = self._firmware_space.as_ref() {
            if fw.has_pending_tables() {
                fw.sync();
            }
        }
        let dev_space = self._address_space.as_ref().ok_or(EIO)?;
        if dev_space.has_pending_tables() {
            dev_space.sync();
        }
        self.invalidate_client(dev_space);
        if client.has_pending_tables() {
            client.sync();
        }
        self.invalidate_client(client);

        client.record_idle_work(render, va)?;
        self.vm_free_work[index] += 1;
        Ok(())
    }

    /// Lease a pre-provisioned per-VM Work slot in the pump worker.
    /// Zero allocations, zero PTE edits, zero TLB invalidations; returns
    /// `EBUSY` if every slot owned by `client` is currently in flight.
    pub(super) fn allocate_work(
        &mut self,
        client: &mut g16_vm::AddressSpace,
        render: bool,
    ) -> Result<u64> {
        let index = usize::from(render);
        if let Some(va) = client.pop_free_work(render) {
            self.vm_free_work[index] = self.vm_free_work[index].checked_sub(1).ok_or(EIO)?;
            return Ok(va);
        }
        if client.work_leased(render) != 0 {
            self.report_pressure(64, "Work storage");
            return Err(EBUSY);
        }
        Err(EIO)
    }

    /// Return a retired or rolled-back Work slot to its owning VM's idle pool.
    /// Split-borrow signature allows callers holding a `FirmwareReader` over
    /// `self._firmware_space`. Never allocates.
    pub(super) fn release_work_counted(
        vm_free_work: &mut [usize; 2],
        client: &mut g16_vm::AddressSpace,
        render: bool,
        va: u64,
    ) -> Result {
        client.release_work(render, va)?;
        vm_free_work[usize::from(render)] += 1;
        Ok(())
    }

    /// Collect storage whose context destruction firmware has consumed. Retire
    /// polls this too. Monotonic 64-bit control epochs eliminate modular
    /// half-ring ambiguity even when collection trails other control traffic.
    /// It must not allocate: publication reserved each free-list slot.
    pub(super) fn collect_destroyed_queues(&mut self) -> Result {
        if self.destroying_queues.is_empty() {
            return Ok(());
        }
        let guard = self._sgx.try_access().ok_or(ENODEV)?;
        let read = guard.try_read32(0xd640c0)?;
        let done = guard.try_read32(0xd640c8)?;
        let tail = guard.try_read32(0xd60060)?;
        drop(guard);
        self.control_ring
            .observe(read, done, tail)
            .map_err(|_| EIO)?;
        let mut i = 0;
        while i < self.destroying_queues.len() {
            let (base, target) = self.destroying_queues[i];
            if self.control_ring.reached(target) {
                self.destroying_queues.swap_remove(i);
                self.free_queues
                    .push_within_capacity(base)
                    .map_err(|_| EIO)?;
            } else {
                i += 1;
            }
        }
        Ok(())
    }

    /// Firmware may still hold a retired queue's context ID binding, so the
    /// context is destroyed before its storage serves another queue.
    pub(super) fn recycle_queues(&mut self) -> Result {
        self.collect_destroyed_queues()?;
        loop {
            self.destroying_queues.reserve(1, GFP_KERNEL)?;
            self.free_queues
                .reserve(self.destroying_queues.len() + 1, GFP_KERNEL)?;
            let Some(base) = self.retired_queues.lock().pop() else {
                return Ok(());
            };
            let mut committed = false;
            match self.destroy_queue_context(base, &mut committed) {
                Ok(true) => {}
                Ok(false) => {
                    // The control ring reached its half-ring in-flight bound.
                    // Its slot in retired_queues was just vacated.
                    let _ = self.retired_queues.lock().push_within_capacity(base);
                    return Ok(());
                }
                Err(err) => {
                    // Preserve `base` if we failed before publishing to the
                    // control ring; once committed, `(base, target)` is already
                    // recorded in `destroying_queues`.
                    if !committed {
                        let _ = self.retired_queues.lock().push_within_capacity(base);
                    }
                    return Err(err);
                }
            }
        }
    }

    /// Publish a context destruction without waiting, as growth replies are.
    /// Records `(base, target)` in `destroying_queues` immediately on tail
    /// commit (before the fallible RTKit kick) so no queue storage record is
    /// lost on error. Returns `Ok(true)` when published, `Ok(false)` when the
    /// half-ring in-flight window is full.
    pub(super) fn destroy_queue_context(&mut self, base: u64, committed: &mut bool) -> Result<bool> {
        let context = base + 0x4140;
        let fw = self._firmware_space.as_mut().ok_or(EIO)?;
        let ids = fw.read_u32(context)?;
        let fields = [
            (fw.read_u32(context + 0x24)? >> 16) as u8,
            ids as u8,
            (ids >> 8) as u8,
            fw.read_u32(context + 4)? as u8,
        ];
        let guard = self._sgx.try_access().ok_or(ENODEV)?;
        let head = guard.try_read32(0xd640c0)?;
        let ack = guard.try_read32(0xd640c8)?;
        let tail = guard.try_read32(0xd60060)?;
        drop(guard);
        self.control_ring
            .observe(head, ack, tail)
            .map_err(|_| EIO)?;
        if !self.control_ring.has_room() {
            return Ok(false);
        }
        let (slot, successor) = self.control_ring.next_slot();
        let control = g16_fw::MainConfig::bootstrap(g16_fw::BUNDLE_ADDRESS).channels[12].ring;
        fw.write_live(
            control + u64::from(slot) * 64,
            &g16_fw::destroy_context(context, fields),
        )?;
        crate::mem::sync();
        let guard = self._sgx.try_access().ok_or(ENODEV)?;
        guard.try_write32(successor, 0xd60060)?;
        drop(guard);
        *committed = true;
        let target = self.control_ring.commit();
        // Capacity was reserved in recycle_queues() before popping `base`.
        self.destroying_queues
            .push_within_capacity((base, target))
            .map_err(|_| EIO)?;
        crate::mem::sync();
        self._rtkit
            .as_mut()
            .send_message(0x21, 0x0084_0000_0000_0011)?;
        Ok(true)
    }

    /// Initialize three lanes in `base`, which is newly allocated or recycled.
    /// `identity` is a fresh address whose page index names the queues, so a
    /// recycled queue never reuses a destroyed queue's identity.
    pub(super) fn init_queues(
        &mut self,
        owner: &FirmwareQueues,
        base: u64,
        identity: u64,
        fresh: bool,
    ) -> Result<[Lane; 3]> {
        use crate::pgtable::prot::{PROT_FW_PRIV_RW, PROT_FW_SHARED_RW};
        use g16_fw::queue as q;

        let lanes: [Lane; 3] = core::array::from_fn(|stage| {
            let queue = base + stage as u64 * 0xc000;
            Lane {
                queue,
                pointers: queue + 0x4000,
                ring: queue + 0x8000,
                head: 0,
                new: true,
            }
        });
        if fresh {
            // Reserve before the region exists, so it can always be retired.
            let total = self.queue_regions + 1;
            let mut retired = self.retired_queues.lock();
            let additional = total - retired.len();
            retired.reserve(additional, GFP_KERNEL)?;
            drop(retired);
            self.queue_regions = total;
        }
        let fw = self._firmware_space.as_mut().ok_or(EIO)?;
        for lane in &lanes {
            if fresh {
                fw.alloc(lane.queue, 0x4000, PROT_FW_PRIV_RW)?;
                fw.alloc(lane.pointers, 0x8000, PROT_FW_SHARED_RW)?;
            } else {
                // Restore a new allocation's zeroed state, including the
                // firmware-private words after each queue descriptor.
                fw.zero_live(lane.queue, 0x4000)?;
                fw.zero_live(lane.pointers, 0x8000)?;
            }
        }
        // A notifier list and GPU context belong to the public queue,
        // shared only by its own vertex, fragment and compute lanes.
        let jobs = base + 0x4100;
        let context = base + 0x4140;
        for (stage, lane) in lanes.iter().enumerate() {
            let named = identity + stage as u64 * 0xc000;
            let mut descriptor = q::Queue {
                pointers: lane.pointers,
                ring: lane.ring,
                jobs,
                private: lane.queue + 0xb0,
                context,
                uuid: ((named - 0xffff_fc22_0000_0000) >> 14) as u32 + 2,
            }
            .encode_priority(owner.priority)
            .ok_or(EINVAL)?;
            // Native TA/3D profiles allow firmware to suspend and restart
            // renders. Their Work/scratch leases survive until the final
            // notifier/driver stamp, including intervening partial runs.
            // Compute remains non-preemptible, matching the M1/M2 driver;
            // Metal's compute queues use the native preemptible profile.
            let preemptible = stage != 2;
            if !preemptible {
                descriptor[0x30..0x34].copy_from_slice(&0u32.to_le_bytes());
                descriptor[0x48..0x4c].copy_from_slice(&1u32.to_le_bytes());
            }
            fw.write_live(lane.queue, &descriptor)?;
            fw.write_live(lane.pointers, &q::pointers(0x500, 0))?;
            // A newly created timeline starts immediately before its first
            // target. This also permits qualification near stamp rollover.
            let (ordinal, first) = match stage {
                0 => (owner.render_count, 0xc00),
                1 => (owner.render_count, 0x100),
                _ => (owner.compute_count, 0x100),
            };
            let current = g16_stamp::previous(g16_stamp::value(ordinal, first));
            fw.write_live(lane.firmware_stamp(), &current.to_le_bytes())?;
            if stage < 2 {
                fw.write_live(lane.driver_stamp(), &current.to_le_bytes())?;
            }
        }
        fw.write_live(jobs, &q::jobs(jobs))?;
        fw.write_live(context, &q::context())?;
        let notifier = render_notifier(&lanes);
        let count = render_notifier_count(&lanes);
        fw.write_live(notifier, &[0u8; 0x100])?;
        fw.write_live(notifier, &count.to_le_bytes())?;
        fw.write_live(notifier + 0x10, &0x50u32.to_le_bytes())?;
        fw.write_live(count, &0u32.to_le_bytes())?;
        fw.sync();
        if !fresh {
            for lane in &lanes {
                self.last_scan.forget(lane.firmware_stamp());
            }
        }
        Ok(lanes)
    }

    /// For the SUBMIT ioctl: allocate the queue's firmware rings now rather
    /// than at its first publication.
    pub(crate) fn provision_queue(&mut self, owner: &mut FirmwareQueues) -> Result {
        if self.render_failed {
            return Err(EIO);
        }
        self.prepare_lanes(owner)
    }

    /// For the SUBMIT ioctl: create the VM root's TVB pool now rather than
    /// at its first render publication.
    pub(crate) fn provision_tvb(&mut self, client: &mut g16_vm::AddressSpace, support: &Support) -> Result {
        if self.render_failed {
            return Err(EIO);
        }
        self.tvb_pool(client, support).map(|_| ())
    }

    /// The index of the client root's TVB pool, created on first use. Not
    /// inlined: its creation path would otherwise enlarge the job worker's frame.
    #[inline(never)]
    pub(super) fn tvb_pool(&mut self, client: &mut g16_vm::AddressSpace, support: &Support) -> Result<usize> {
        let root = client.roots().low;
        if let Some(index) = self.tvb_pools.iter().position(|p| p.root == root) {
            return Ok(index);
        }
        self.tvb_pools.reserve(1, GFP_KERNEL)?;
        let base = self.next_object_va;
        self.next_object_va = base.checked_add(0x44000).ok_or(ENOSPC)?;
        let pool = crate::g16_tvb::Tvb::new(
            self._firmware_space.as_mut().ok_or(EIO)?,
            client,
            base,
            7 + u64::from(support.index),
        )?;
        self.tvb_pools.push_within_capacity(pool).map_err(|_| ENOMEM)?;
        Ok(self.tvb_pools.len() - 1)
    }

    pub(super) fn prepare_queues(&mut self, owner: &mut FirmwareQueues) -> Result {
        self.prepare_lanes(owner)?;
        self.prepare_events(owner)
    }

    /// The queue's firmware rings, allocated once per public queue. Not
    /// inlined, like `tvb_pool`: it is cold and its frame is large.
    #[inline(never)]
    pub(super) fn prepare_lanes(&mut self, owner: &mut FirmwareQueues) -> Result {
        if owner.lanes.is_none() {
            self.recycle_queues()?;
            let identity = self.next_object_va;
            self.next_object_va = identity.checked_add(0x24000).ok_or(ENOSPC)?;
            let recycled = self.free_queues.pop();
            let base = recycled.unwrap_or(identity);
            let lanes = match self.init_queues(owner, base, identity, recycled.is_none()) {
                Ok(lanes) => lanes,
                Err(error) => {
                    // A failed fresh allocation keeps any partial regions
                    // owned, like a failed Work refill; recycled storage returns.
                    if let Some(base) = recycled {
                        let _ = self.free_queues.push_within_capacity(base);
                    }
                    return Err(error);
                }
            };
            owner.storage = Some(QueueStorage {
                base,
                retired: self.retired_queues.clone(),
            });
            owner.lanes = Some(lanes);
            for c in &owner.cursors {
                c.set((u32::MAX, u32::MAX));
            }
            owner.notified_works = 0;
            if crate::module_parameters::fw_trace.value() & 1 != 0 {
                dev_info!(
                    self.dev.as_ref(),
                    "G16: queues vertex={:#x} fragment={:#x} compute={:#x} priority={} recycled={}\n",
                    lanes[0].queue,
                    lanes[1].queue,
                    lanes[2].queue,
                    owner.priority,
                    recycled.is_some()
                );
            }
        }
        Ok(())
    }

    /// An event index for each busy period of the queue (released when its
    /// last Work retires). EBUSY while all are in use: admission retries.
    pub(super) fn prepare_events(&mut self, owner: &mut FirmwareQueues) -> Result {
        if owner.events.is_none() {
            // Bits 0-31 are the event indices in use; a queue takes the
            // lowest free one.
            let mut picked = 0u32;
            self.queue_events
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                    let free = !(value as u32);
                    if free == 0 {
                        return None;
                    }
                    picked = free.trailing_zeros();
                    Some(value | (1 << picked))
                })
                .map_err(|_| {
                    self.report_pressure(8, "events");
                    EBUSY
                })?;
            if crate::module_parameters::fw_trace.value() & 256 != 0 && owner.last_event != Some(picked) {
                pr_info!("G16: queue event index {:?} -> {}\n", owner.last_event, picked);
            }
            owner.last_event = Some(picked);
            if let Some(lanes) = owner.lanes {
                for (stage, lane) in lanes.iter().enumerate() {
                    self.set_lane_event(lane.firmware_stamp(), 32 + picked * 3 + stage as u32);
                }
            }
            owner.events = Some(QueueEvents {
                slots: self.queue_events.clone(),
                index: picked,
            });
        }
        Ok(())
    }
}

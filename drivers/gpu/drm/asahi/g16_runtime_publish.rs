// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Admission and publication: reserving a flight's ring and lane room,
//! staging queue writes and flushing them to firmware.

use super::*;

impl Bootstrap {
    /// Current capacity snapshot for the pump's O(1) fast-skip check.
    pub(crate) fn cap_state(&self) -> crate::g16_headroom::CapBlock {
        crate::g16_headroom::CapBlock {
            retire_gen: self.retire_gen,
            queue_cap: crate::g16_timeline::QUEUE_CAP.load(Ordering::Relaxed),
            lane_cap: crate::g16_timeline::LANE_CAP.load(Ordering::Relaxed),
        }
    }

    /// Fast O(1) lower-bound headroom check for `queue` using the caller's
    /// `cap` snapshot (avoiding any TOCTOU mismatch between evaluated caps and
    /// a latched `CapBlock`), before any VM lock, page-table walk, dependency
    /// resolution, MMIO, or firmware read.
    pub(super) fn check_cap_headroom(
        &self,
        queue: &FirmwareQueues,
        render: bool,
        cap: crate::g16_headroom::CapBlock,
    ) -> Result {
        if self.render_failed {
            return Err(EIO);
        }
        let lanes = queue.lanes.map(|lanes| {
            lanes.map(|lane| {
                self.ledger
                    .lane(lane.pointers)
                    .map_or(crate::g16_headroom::LaneLoad::default(), |b| {
                        crate::g16_headroom::LaneLoad {
                            works: b.works as usize,
                            load: b.load as usize,
                            owned: b.owned as usize,
                        }
                    })
            })
        });
        match crate::g16_headroom::check_headroom(
            render,
            self.work_space_left(render),
            self.flights.len(),
            MAX_FLIGHTS,
            self.ledger.has_room(),
            cap.queue_cap as usize,
            crate::module_parameters::max_lane_works.value() as usize,
            cap.lane_cap as usize,
            lanes,
        ) {
            Ok(()) => Ok(()),
            Err(crate::g16_headroom::HeadroomBlock::WorkSpaceExhausted) => Err(ENOSPC),
            Err(crate::g16_headroom::HeadroomBlock::WorkSpaceBusy) => {
                self.report_pressure(64, "Work storage");
                Err(EBUSY)
            }
            Err(crate::g16_headroom::HeadroomBlock::FlightsFull) => {
                self.report_pressure(128, "flights");
                Err(EBUSY)
            }
            Err(crate::g16_headroom::HeadroomBlock::QueueCap) => {
                self.report_pressure(16, "queue entries");
                Err(EBUSY)
            }
            Err(crate::g16_headroom::HeadroomBlock::LaneWorks) => {
                self.report_pressure(16, "workqueue");
                Err(EBUSY)
            }
            Err(crate::g16_headroom::HeadroomBlock::LaneCap) => {
                self.report_pressure(32, "lane entries");
                Err(EBUSY)
            }
        }
    }

    /// Lock `queues` briefly to run `check_cap_headroom` from the pump loop
    /// before barrier/dependency/mesh preparation, using the same `cap`
    /// snapshot that the pump will latch on `EBUSY`.
    pub(crate) fn check_queue_headroom(
        &self,
        queues: &Mutex<FirmwareQueues>,
        render: bool,
        cap: crate::g16_headroom::CapBlock,
    ) -> Result {
        let queue = queues.lock();
        self.check_cap_headroom(&queue, render, cap)
    }

    pub(super) fn reserve_flight(
        &mut self,
        queue: &FirmwareQueues,
        render: bool,
        root: u64,
        client_has_free_work: bool,
        client_work_leased: usize,
        entries: [u32; 3],
    ) -> Result {
        if self.render_failed {
            return Err(EIO);
        }
        // Work storage is owned per VM and bounded globally by its 4 GiB alias
        // window. When the window is full and this VM has no idle slot, only
        // this VM's own leased slots will return to it on retirement.
        if !client_has_free_work && !self.global_work_space_left(render) {
            if client_work_leased == 0 {
                return Err(ENOSPC);
            }
            self.report_pressure(64, "Work storage");
            return Err(EBUSY);
        }
        let stages: &[usize] = if render { &[0, 1] } else { &[2] };
        // Preallocated at init (MAX_FLIGHTS): at the cap, wait for retirement.
        if self.flights.len() >= MAX_FLIGHTS
            || !self.ledger.has_room()
            || self.publications.capacity() - self.publications.len() < stages.len()
        {
            self.report_pressure(128, "flights");
            return Err(EBUSY);
        }
        // Check scarce resources before allocating any per-Work storage.
        // Commands in either persistent VM root can share its live ASID.
        if !(1..64).any(|i| {
            self.context_users[i] == 0 || self.context_roots[i].is_some_and(|s| s.low == root)
        }) {
            self.report_pressure(1, "ASIDs");
            return Err(EBUSY);
        }
        // The firmware stops completing a queue's Works (its shared notifier
        // stalls with the stamps already past, blocked=0x2) when too many
        // are outstanding: k24-cap129 (129 Works on a lane) and k69 on #108,
        // where compute waits on the own render lanes add firmware dependency
        // items. Bound the
        // whole queue's unretired Works plus their dependency items.
        let cap = crate::g16_timeline::QUEUE_CAP.load(Ordering::Relaxed) as usize;
        if cap != 0 {
            if let Some(lanes) = &queue.lanes {
                let outstanding: usize = lanes
                    .iter()
                    .filter_map(|l| self.ledger.lane(l.pointers))
                    .map(|b| b.owned as usize)
                    .sum();
                let new = entries.iter().copied().max().unwrap_or(1) as usize;
                if outstanding + new > cap {
                    self.report_pressure(16, "queue entries");
                    return Err(EBUSY);
                }
            }
        }
        // Check exact per-lane work and dependency-item caps in host memory
        // BEFORE reading SGX MMIO channels or firmware lane cursors.
        if let Some(lanes) = &queue.lanes {
            let max_works = crate::module_parameters::max_lane_works.value() as usize;
            let lane_cap = crate::g16_timeline::LANE_CAP.load(Ordering::Relaxed) as usize;
            for &stage in stages {
                let lane = lanes[stage];
                if max_works != 0
                    && self
                        .ledger
                        .lane(lane.pointers)
                        .map_or(0, |b| b.works as usize)
                        >= max_works
                {
                    self.report_pressure(16, "workqueue");
                    return Err(EBUSY);
                }
                // Dependency items on a lane deeper than its 128-Work window
                // stall the firmware. Bound each lane's unretired Works plus
                // the items queued on it (preludes are not Works).
                if lane_cap != 0 {
                    let load = self
                        .ledger
                        .lane(lane.pointers)
                        .map_or(0, |b| b.load as usize);
                    // Fragment always writes a prelude entry (not a Work)
                    // before the fragment Work and any moved render item.
                    let new = if stage == 1 {
                        entries[stage].saturating_sub(1) as usize
                    } else {
                        entries[stage] as usize
                    };
                    if load + new > lane_cap {
                        self.report_pressure(32, "lane entries");
                        return Err(EBUSY);
                    }
                }
            }
        }
        for &stage in stages {
            let channel = queue.priority as usize * 3 + stage;
            let staged_count = self
                .publications
                .iter()
                .filter(|p| p.channel == channel)
                .count() as u32;
            let mut cursors = self.ledger.cursors[channel];
            if !cursors.is_some_and(|[read, done, tail]| {
                ring_room((tail + staged_count) & 255, read, done, 1, 256)
            }) {
                cursors = Some(self.read_channel(channel)?);
                self.ledger.cursors[channel] = cursors;
            }
            let [read, done, tail] = cursors.ok_or(EIO)?;
            let staged = self
                .publications
                .iter()
                .filter(|p| p.channel == channel)
                .count() as u32;
            let coalesced = queue.lanes.as_ref().is_some_and(|lanes| {
                self.publications
                    .iter()
                    .any(|p| p.lane.queue == lanes[stage].queue)
            });
            if !ring_room(
                (tail + staged) & 255,
                read,
                done,
                u32::from(!coalesced),
                256,
            ) {
                self.report_pressure(2, "channel");
                return Err(EBUSY);
            }
            // Bound transport epochs, not the number of Works sharing each
            // epoch. A coalesced batch consumes only one channel-ring slot.
            let next = (tail + staged + u32::from(!coalesced)) & 255;
            if self
                .ledger
                .targets
                .iter()
                .any(|&(c, target)| c == channel && !reached(next, target, 256))
            {
                self.report_pressure(2, "channel");
                return Err(EBUSY);
            }
            if let Some(lanes) = &queue.lanes {
                let lane = lanes[stage];
                let fw = self._firmware_space.as_ref().ok_or(EIO)?;
                let before = crate::g16_timeline::reads();
                let (mut read, mut done) = queue.cursors[stage].get();
                if read >= 0x500
                    || done >= 0x500
                    || !ring_room(lane.head, read, done, entries[stage], 0x500)
                {
                    let mut reader = fw.reader();
                    read = reader.read_u32_relaxed(lane.pointers)?;
                    done = reader.read_u32_relaxed(lane.pointers + 0x30)?;
                    // Order lane-cursor loads explicitly before subsequent ring writes.
                    reader.acquire_barrier();
                    queue.cursors[stage].set((read, done));
                }
                crate::g16_timeline::attribute(&crate::g16_timeline::P_RD_ADMIT, before);
                if read >= 0x500 || done >= 0x500 || lane.head >= 0x500 {
                    return Err(EIO);
                }
                if !ring_room(lane.head, read, done, entries[stage], 0x500) {
                    self.report_pressure(16, "workqueue");
                    return Err(EBUSY);
                }
                // Retirement compares the firmware cursors with each flight's
                // head modulo the ring, which is only unambiguous within half
                // a ring. Like the channel epochs above, never let the head
                // run half a ring past an unretired flight on this lane, or
                // that flight's ring check stays false and it never retires.
                let next = (lane.head + entries[stage]) % 0x500;
                if self
                    .ledger
                    .heads
                    .iter()
                    .any(|&(pointers, head)| pointers == lane.pointers && !reached(next, head, 0x500))
                {
                    self.report_pressure(16, "workqueue");
                    return Err(EBUSY);
                }
            }
        }
        Ok(())
    }

    /// Read a work channel's transport cursors from the device. The driver
    /// is the tail's only writer: a cached tail that disagrees means that
    /// assumption broke.
    pub(super) fn read_channel(&self, channel: usize) -> Result<[u32; 3]> {
        let route = g16_fw::work_channel(g16_fw::BUNDLE_ADDRESS, channel);
        let guard = self._sgx.try_access().ok_or(ENODEV)?;
        let read =
            guard.try_read32(0xd64000 + (route.state[0] - 0xffff_fc20_0002_8000) as usize)?;
        let done =
            guard.try_read32(0xd64000 + (route.state[1] - 0xffff_fc20_0002_8000) as usize)?;
        let tail =
            guard.try_read32(0xd60000 + (route.state[2] - 0xffff_fc20_0002_0000) as usize)?;
        if read >= 256 || done >= 256 || tail >= 256 {
            return Err(EIO);
        }
        if let Some([_, _, cached]) = self.ledger.cursors[channel] {
            if cached != tail {
                pr_warn!("G16: channel {} tail {} differs from the cached {}\n", channel, tail, cached);
            }
        }
        Ok([read, done, tail])
    }

    /// Stage a queue head; multiple Works share one transport message.
    pub(super) fn stage_queue(
        &mut self,
        channel: usize,
        lane: Lane,
        event: u32,
        sequence: u64,
    ) -> Result<u32> {
        if let Some(p) = self
            .publications
            .iter_mut()
            .find(|p| p.lane.queue == lane.queue)
        {
            p.lane.head = lane.head;
            p.sequence = sequence;
            return Ok(p.epoch);
        }
        let tail = match self.ledger.cursors[channel] {
            Some([_, _, tail]) => tail,
            None => {
                let cursors = self.read_channel(channel)?;
                self.ledger.cursors[channel] = Some(cursors);
                cursors[2]
            }
        };
        let reserved = self
            .publications
            .iter()
            .filter(|p| p.channel == channel)
            .count() as u32;
        let epoch = (tail + reserved) & 255;
        // reserve_flight checked the room.
        self.publications
            .push_within_capacity(Publication {
                channel,
                epoch,
                lane,
                event,
                sequence,
            })
            .map_err(|_| EIO)?;
        Ok(epoch)
    }

    /// Publish fully prepared rings together, then kick each used engine once
    /// per priority. No staged Work may remain when the worker sleeps.
    pub(crate) fn flush(&mut self) -> Result {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_FLUSH);
        if self.publications.is_empty() {
            return Ok(());
        }
        // Seal every staged shared notifier before exposing its renders to
        // firmware, so a later render of the same submission cannot raise
        // event_count_array after firmware has already drained it.
        for notifier in &mut self.job_notifiers {
            notifier.flushed = true;
        }
        self.render_failed = true;
        let config = g16_fw::MainConfig::bootstrap(g16_fw::BUNDLE_ADDRESS);
        let fw = self._firmware_space.as_mut().ok_or(EIO)?;
        // Order all staged Normal-WB writes (Work descriptors, microsequences,
        // preludes, notifiers, shared counts, driver stamps, dependency items,
        // lane ring entries, and client scratch writes) BEFORE advancing lane
        // write pointers (+0x40) and writing channel ring messages.
        fw.release_barrier();
        let mut tails: [Option<u32>; 12] = [None; 12];
        let mut kicks = 0u32;
        {
            let mut writer = fw.writer();
            // Fragment transports must precede tiling, matching normal publication.
            for stage in [1usize, 0, 2] {
                for p in self.publications.iter().filter(|p| p.channel % 3 == stage) {
                    let route = &config.channels[p.channel];
                    writer.write_u32_staged(p.lane.pointers + 0x40, p.lane.head)?;
                    writer.write_staged(
                        route.ring + u64::from(p.epoch) * 0x18,
                        &g16_fw::queue::channel(
                            p.lane.queue,
                            p.lane.head as u16,
                            p.event as u8,
                            stage as u32,
                            p.lane.new,
                            p.sequence,
                        ),
                    )?;
                    tails[p.channel] = Some((p.epoch + 1) & 255);
                    kicks |= 1 << ((p.channel / 3) * 2 + usize::from(stage == 2));
                }
            }
        }
        crate::mem::sync();
        let guard = self._sgx.try_access().ok_or(ENODEV)?;
        for stage in [1usize, 0, 2] {
            for channel in (stage..12).step_by(3) {
                if let Some(tail) = tails[channel] {
                    let route = &config.channels[channel];
                    guard.try_write32(
                        tail,
                        0xd60000 + (route.state[2] - 0xffff_fc20_0002_0000) as usize,
                    )?;
                    if let Some(cursors) = &mut self.ledger.cursors[channel] {
                        cursors[2] = tail;
                    }
                }
            }
        }
        crate::mem::sync();
        drop(guard);
        for bit in 0..8 {
            if kicks & (1 << bit) != 0 {
                let priority = bit / 2;
                let engine = (bit % 2) * 2;
                self._rtkit.as_mut().send_message(
                    0x21,
                    0x0083_0000_0000_0000 | ((priority as u64) << 2) | engine as u64,
                )?;
            }
        }
        if crate::module_parameters::fw_trace.value() & 4 != 0 {
            dev_info!(
                self.dev.as_ref(),
                "G16: batch works={} messages={} kicks={}\n",
                self.batch_works,
                self.publications.len(),
                kicks.count_ones()
            );
        }
        self.publications.clear();
        self.batch_works = 0;
        self.render_failed = false;
        Ok(())
    }

    pub(crate) fn poison(&mut self) {
        self.render_failed = true;
    }
}

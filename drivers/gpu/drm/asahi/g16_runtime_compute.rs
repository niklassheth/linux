// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Compute submission: dependency resolution and publishing a compute Work.

use super::*;

impl Bootstrap {
    /// Order a compute Work against other queues in the kernel rather than
    /// with firmware dependency items, which can stall the firmware when a
    /// burst of compute Works carries them (Dota 2's loading screen); Metal's
    /// compute Works carry none either. The queue's own compute lane is
    /// ordered by its ring. Any other awaited stamp must already be reached:
    /// otherwise return EBUSY, and the submission worker publishes what it
    /// has staged and retries after the next completion, holding back the
    /// rest of this queue.
    /// Iterate `(address, value)` stamps of all in-flight Works that have user
    /// timestamp destinations.
    pub(super) fn timestamp_flight_stamps(&self) -> impl Iterator<Item = (u64, u32)> + '_ {
        self.flights
            .iter()
            .filter(|f| f.user_timestamps)
            .flat_map(|f| f.stamps.iter().flatten().map(|s| (s.address, s.value)))
    }

    /// Whether `dep` covers any Work still in flight that has user timestamp
    /// destinations (used by the host CPU-hold path, which emits no kind-1 item).
    pub(super) fn covers_timestamps(&self, dep: &Stamp) -> bool {
        crate::g16_wait_state::latest_covered_timestamp(
            self.timestamp_flight_stamps(),
            dep.address,
            dep.value,
        )
        .is_some()
    }

    /// Whether `dep` covers an in-flight Work with user timestamp destinations
    /// that has not yet been serialized by a prior `kind = 1` wait on `lane`.
    ///
    /// The firmware writes a Work's user timestamps after the Work has ended,
    /// so neither same-lane ring order nor a kind-0 dependency item (nor a
    /// firmware-stamp reach check) waits for them. Keeping the first wait on
    /// `lane` as a kind-1 dependency item orders `lane` after those writes;
    /// once `lane` has emitted a kind-1 wait reaching the latest covered
    /// timestamped flight, later Works on `lane` do not need to re-emit
    /// redundant kind-1 items for that same flight.
    pub(super) fn uncovered_timestamps(
        &self,
        queue: &FirmwareQueues,
        lane: usize,
        dep: &Stamp,
    ) -> bool {
        crate::g16_wait_state::has_uncovered_timestamps(
            &queue.waited,
            lane,
            self.timestamp_flight_stamps(),
            dep.address,
            dep.value,
        )
    }

    pub(super) fn resolve_compute_dependencies(
        &self,
        queue: &FirmwareQueues,
        timestamped: bool,
        dependencies: &[Option<Stamp>; 2],
        tally: &mut DepTally,
    ) -> Result<[Option<ResolvedDep>; 2]> {
        let own_lane = queue.lanes.as_ref().map(|lanes| lanes[2].firmware_stamp());
        // A wait on this queue's own render lanes (the
        // render -> compute edge inside one submission) stays a firmware
        // item, so the firmware starts the compute right after the render
        // instead of after a host round trip. Other queues stay kernel-side.
        let own_render = queue
            .lanes
            .as_ref()
            .map(|lanes| [lanes[0].firmware_stamp(), lanes[1].firmware_stamp()]);
        let cross_kind = crate::module_parameters::cross_dependency_kind.value();
        let mut kept = [None; 2];
        let fw = self._firmware_space.as_ref().ok_or(EIO)?;
        let mut reader = None;
        for (slot, dep) in dependencies.iter().enumerate() {
            let Some(dep) = dep else { continue };
            if own_render.is_some_and(|r| r.contains(&dep.address)) {
                let uncovered_ts = self.uncovered_timestamps(queue, 2, dep);
                let kind = if timestamped || uncovered_ts {
                    1
                } else {
                    cross_kind
                };
                if !self.elide_item(queue, 2, dep, kind, false, uncovered_ts, tally)? {
                    kept[slot] = Some(ResolvedDep { stamp: *dep, kind });
                }
                continue;
            }
            // The compute lane orders its own Works by ring position alone,
            // which does not wait for a previous Work's user timestamps. Emit
            // a kind-1 item until lane 2 has serialized past the latest
            // covered timestamped flight.
            if own_lane == Some(dep.address) {
                if self.uncovered_timestamps(queue, 2, dep) {
                    tally.items += 1;
                    tally.same_lane += 1;
                    kept[slot] = Some(ResolvedDep {
                        stamp: *dep,
                        kind: 1,
                    });
                }
                continue;
            }
            let r = reader.get_or_insert_with(|| fw.reader());
            let now = r.read_u32_relaxed(dep.address)?;
            let done = g16_stamp::reached(now, dep.value) && !self.covers_timestamps(dep);
            self.hold_check("compute", dep, now, done)?;
            if !done {
                crate::g16_timeline::DEFERRED_CPU_HOLD.fetch_add(1, Ordering::Relaxed);
                return Err(EBUSY);
            }
        }
        if let Some(r) = reader {
            r.acquire_barrier();
        }
        Ok(kept)
    }

    pub(crate) fn submit_compute(
        &mut self,
        queues: Arc<Mutex<FirmwareQueues>>,
        owner: Arc<Mutex<g16_vm::AddressSpace>>,
        params: &compute::Parameters,
        timestamps: [u64; 4],
        dependencies: &[Option<Stamp>; 2],
    ) -> Result<Receipt> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_SUBMIT_COMPUTE);
        let mut queue = queues.lock();
        let cap = self.cap_state();
        self.check_cap_headroom(&queue, false, cap)?;
        let mut client = owner.lock();
        let mut tally = DepTally::default();
        let timestamped = timestamps[0] != 0 || timestamps[1] != 0;
        let resolved =
            self.resolve_compute_dependencies(&queue, timestamped, dependencies, &mut tally)?;
        let dependencies = &resolved;
        self.reserve_flight(
            &queue,
            false,
            client.roots().low,
            client.has_free_work(false),
            client.work_leased(false),
            crate::g16_headroom::FlightCharge::compute(
                dependencies.iter().flatten().count() as u32,
            ),
            cap,
        )?;
        self.prepare_queues(&mut queue)?;
        let result = self.submit_compute_queue(
            &mut queue,
            queues.clone(),
            &mut client,
            owner.clone(),
            params,
            timestamps,
            dependencies,
        );
        if queue.pending == 0 {
            queue.events = None;
        }
        if result.is_ok() {
            tally.publish();
        }
        result
    }

    #[inline(never)]
    pub(super) fn submit_compute_queue(
        &mut self,
        queue: &mut FirmwareQueues,
        queues: Arc<Mutex<FirmwareQueues>>,
        client: &mut g16_vm::AddressSpace,
        owner: Arc<Mutex<g16_vm::AddressSpace>>,
        params: &compute::Parameters,
        timestamps: [u64; 4],
        dependencies: &[Option<ResolvedDep>; 2],
    ) -> Result<Receipt> {
        let lane = queue.lanes.as_ref().ok_or(EIO)?[2];
        let priority = queue.priority;
        if self.render_failed {
            return Err(EIO);
        }
        if !(2..=3).contains(&priority) {
            return Err(EINVAL);
        }

        let mut params = *params;
        let space = client.roots();
        let ordinal = queue.compute_count;
        // Wrap pre-publication leases (scratch + per-VM Work slot) in an RAII
        // Drop guard so any `?` error before publication returns both cleanly.
        let (scratch, alias, mut a) = {
            let mut sink = RuntimeLeaseSink {
                runtime: self,
                client,
            };
            let mut prep = crate::g16_work_pool::PrepGuard::new(&mut sink, false);
            let scratch = prep.sink_mut().client.prepare_compute(&mut params)?;
            prep.set_scratch(scratch);
            let work = {
                let s = prep.sink_mut();
                s.runtime.allocate_work(s.client, false)?
            };
            prep.set_work(work);
            let alias = crate::g16_work_pool::alias_range(work, WORK_BASE, WORK_WINDOW, false)
                .ok_or(ENOSPC)?
                .start;
            let mut a = compute::Addresses::publication(
                prep.sink_mut().runtime.compute_publication,
                ordinal,
                work,
                alias,
            );
            let support = prep.sink_mut().client.compute_support().ok_or(EIO)?;
            a.support = support.address();
            a.queue = lane.queue;
            a.driver_stamp = work + 0x4000;
            a.firmware_stamp = lane.firmware_stamp();
            a.event = queue.event(2)?;
            {
                let s = prep.sink_mut();
                if s.client.has_pending_tables() {
                    s.client.sync();
                }
                s.runtime.invalidate_client(s.client);
            }
            a.context = prep.sink_mut().runtime.acquire_context(space, 1)?;
            a.identity = (u64::from(a.context) << 32) | (a.identity & 0xffff_ffff);
            a.register_identity = (u64::from(a.context) << 32) | 1;
            let (scratch, _work) = prep.commit().ok_or(EIO)?;
            (scratch, alias, a)
        };
        self.render_failed = true;
        let dep_stamps = dependencies.map(|d| d.map(|r| r.stamp));
        let own = queue.lanes.map_or([0; 3], |l| l.map(|lane| lane.firmware_stamp()));
        self.note_dependency_events(&dep_stamps, own);
        a.cdm_entry = Some(alias + compute::ENTRY_OFFSET);
        let work_buf = &mut self.encodings.compute;
        work_buf.fill(0);
        if params.work(&a, work_buf).is_none() {
            pr_err!("G16: compute Work encoding failed for ioctl-validated parameters\n");
            return Err(EIO);
        }
        // Timestamp's user destinations must lie in the validated special-
        // object aperture. Firmware writes nanoseconds directly, as on M1/M2.
        // Firmware consumes this pointer pair, so it lives in the Work's
        // uncached shared page: in the cached private page, stale firmware
        // cache lines lost timestamps once the Work was reused.
        let user_timestamps = a.work + 0x4040;
        let count = self.compute_publication.wrapping_add(1);

        let first = lane.head;
        let head = (first + 1 + dependencies.iter().flatten().count() as u32) % 0x500;
        // The support's shared state counts every Work submitted against
        // it (render items included, when compute shares the render pool).
        let support = client.compute_support().ok_or(EIO)?;
        let submitted = support.submissions.load(Ordering::Relaxed).wrapping_add(1);
        let support_shared = support.shared_state();
        let mut microsequence = params.microsequence(&a);
        for base in [0x1bc, 0x20c] {
            microsequence[base + 0x24..base + 0x2c].copy_from_slice(&user_timestamps.to_le_bytes());
        }
        let notifier = a.notifier(0);
        let entry_bytes = compute::entry(params.cdm);
        let timestamped = timestamps[0] != 0 || timestamps[1] != 0;
        // Stage every byte of this compute Work in one barrier-free writer
        // pass with cached region lookups. `support_shared` is a live
        // cumulative counter already reachable by earlier work on this pool
        // (monotonic, not rolled back on error); all newly written per-Work
        // descriptors, microsequences, notifiers, dependency items, and ring
        // entries are ordered by flush()'s release barrier before advancing
        // lane.head and ringing the doorbell.
        {
            let fw = self._firmware_space.as_mut().ok_or(EIO)?;
            let mut writer = fw.writer();
            writer.write_u32_staged(support_shared, submitted as u32)?;
            writer.write_staged(a.work, &self.encodings.compute)?;
            writer.write_staged(a.work + compute::ENTRY_OFFSET, &entry_bytes)?;
            writer.write_u64_staged(user_timestamps, timestamps[0])?;
            writer.write_u64_staged(user_timestamps + 8, timestamps[1])?;
            writer.write_staged(a.microsequence, &microsequence)?;
            // Retained notifier list links are firmware-owned even after completion.
            writer.write_staged(a.notifier, &notifier[..0x14])?;
            writer.write_staged(a.notifier + 0x24, &notifier[0x24..0x28])?;
            writer.write_u32_staged(a.threshold, 1)?;
            writer.write_u32_staged(a.driver_stamp, g16_stamp::previous(a.stamp))?;
            let mut pos = first;
            for (index, dep) in dependencies.iter().flatten().enumerate() {
                // Between the threshold/timestamps and the CDM entry trampoline.
                let address = a.work + 0x1900 + index as u64 * 0x40;
                let item = g16_fw::queue::dependency(
                    dep.stamp.address,
                    dep.stamp.value,
                    dep.stamp.event,
                    a.stamp,
                    a.identity as u32,
                    dep.kind,
                );
                writer.write_staged(address, &item)?;
                writer.write_u64_staged(lane.ring + u64::from(pos) * 8, address)?;
                pos = (pos + 1) % 0x500;
            }
            writer.write_u64_staged(lane.ring + u64::from(pos) * 8, a.work)?;
        }
        support.submissions.store(submitted, Ordering::Relaxed);
        let channel = priority as usize * 3 + 2;
        let mut pending_lane = lane;
        pending_lane.head = head;
        let epoch =
            self.stage_queue(channel, pending_lane, a.event, count)?;
        self.compute_publication = count;
        queue.compute_count = ordinal.wrapping_add(1);
        let lane = &mut queue.lanes.as_mut().ok_or(EIO)?[2];
        lane.head = head;
        lane.new = false;
        let stamp = Stamp {
            address: a.firmware_stamp,
            value: a.stamp,
            event: a.event,
        };
        let pointers = lane.pointers;
        queue.last[1] = Some(stamp);
        queue.waited.prune(stamp.address, stamp.value);
        for dep in dependencies.iter().flatten() {
            queue
                .waited
                .note(2, dep.stamp.address, dep.stamp.value, dep.kind);
        }
        queue.pending += 1;
        self.flights.push_within_capacity(
            Flight {
                id: a.work,
                owner: queues.clone(),
                context: a.context,
                stream: params.cdm,
                ordinal,
                tgid: params.tgid,
                comm: params.comm,
                started: Instant::now(),
                notifier_count: None,
                job_notifier: None,
                stamps_seen: None,
                blocked: 0,
                dependencies: dep_stamps,
                stamps: [Some(stamp), None],
                user_timestamps: timestamped,
                driver_stamps: [
                    Some(Stamp {
                        address: a.driver_stamp,
                        ..stamp
                    }),
                    None,
                ],
                scratch,
                client: owner,
                queues: [(pointers, head), (0, 0)],
                lane_items: [dependencies.iter().flatten().count() as u32, 0],
                channels: [(channel, (epoch + 1) & 255), (usize::MAX, 0)],
                render: None,
            },
        )
        .map_err(|_| EIO)?;
        // Capacity was reserved with the flight in reserve_flight.
        let flight = self.flights.last().ok_or(EIO)?;
        self.ledger.add(flight)?;
        #[cfg(CONFIG_APPLE_PMP_REPORT)]
        // SAFETY: the helper publishes only scalar activity; it neither retains
        // a GPU reference nor performs MMIO/locking in this runtime context.
        unsafe { kernel::bindings::apple_pmp_cpu_vote_gpu_activity(self.flights.len() as u32) };

        self.render_failed = false;
        self.batch_works += 1;
        self.trace_publication("compute", a.work)?;
        self.trace_dependencies("compute", a.work, a.context, &dep_stamps)?;
        Ok(Receipt { id: a.work, stamp })
    }
}

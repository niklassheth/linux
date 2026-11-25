// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Render submission: dependency resolution and item elision, then building
//! and publishing a render's TA and 3D Works.

use super::*;

impl Bootstrap {
    /// Count a firmware dependency item and decide whether to drop it as
    /// redundant: when this lane's previous Work already waited on that stamp
    /// or a later one with at least `kind` (Works on a lane start in order),
    /// or when the stamp has already been reached at publish. Items covering
    /// an in-flight timestamped producer not yet serialized by a kind-1 wait
    /// on this lane are never dropped. An in-flight, unwaited item on the
    /// same lane's earlier 3D Work is kept and counted: `lanes[1]` uses the
    /// preemptible/partial-render profile, so ring order alone is not assumed
    /// to order 3D->3D visibility.
    pub(super) fn elide_item(
        &self,
        queue: &FirmwareQueues,
        lane: usize,
        dep: &Stamp,
        kind: u32,
        same_lane: bool,
        uncovered_ts: bool,
        tally: &mut DepTally,
    ) -> Result<bool> {
        use crate::g16_timeline as t;
        tally.items += 1;
        let drop = if uncovered_ts {
            if same_lane {
                tally.same_lane += 1;
            }
            false
        } else if queue.waited.covers(lane, dep.address, dep.value, kind) {
            tally.repeat += 1;
            true
        } else {
            let before = t::reads();
            // The last retire scan's value: stamps only advance, so a value
            // that already reached the target still does.
            let now = self.last_scan.peek(dep.address);
            t::attribute(&t::P_RD_ELIDE, before);
            let reached = now.is_some_and(|v| g16_stamp::reached(v, dep.value));
            if reached {
                tally.reached += 1;
            } else if same_lane {
                tally.same_lane += 1;
            }
            reached
        };
        if drop {
            tally.dropped += 1;
        }
        Ok(drop)
    }

    /// The lane a render's dependency item sits on: slot 0 (render) on the
    /// fragment lane with a fragment barrier, else the tiling lane.
    pub(super) fn render_item_lane(params: &render::Parameters, slot: usize) -> usize {
        usize::from(slot == 0 && params.vdm_barrier_fragment)
    }

    pub(super) fn resolve_render_dependencies(
        &self,
        queue: &mut FirmwareQueues,
        params: &render::Parameters,
        timestamped: bool,
        dependencies: &[Option<Stamp>; 2],
        tally: &mut DepTally,
    ) -> Result<[Option<ResolvedDep>; 2]> {
        let own_fragment = queue.lanes.as_ref().map(|lanes| lanes[1].firmware_stamp());
        let render_kind = crate::module_parameters::dependency_kind.value();
        // Slot 1 waits on compute. As the internal TA-to-fragment wait (kind
        // 0) the firmware starts the render as soon as the compute is done;
        // in the dynamic dependency graph (kind 1) each such edge idled the
        // GPU about 100 us. Waits on an in-flight producer with unwaited user
        // timestamps (and renders carrying user timestamps themselves) stay
        // kind 1 so user timestamp writes complete before the consumer starts.
        let cross_kind = crate::module_parameters::cross_dependency_kind.value();
        let mut kept = [None; 2];
        for (slot, dep) in dependencies.iter().enumerate() {
            let Some(dep) = dep else { continue };
            let lane = Self::render_item_lane(params, slot);
            let same_lane = lane == 1 && own_fragment == Some(dep.address);
            let uncovered_ts = self.uncovered_timestamps(queue, lane, dep);
            let kind = if timestamped || uncovered_ts {
                1
            } else if slot == 0 {
                render_kind
            } else {
                cross_kind
            };
            if !self.elide_item(queue, lane, dep, kind, same_lane, uncovered_ts, tally)? {
                kept[slot] = Some(ResolvedDep { stamp: *dep, kind });
            }
        }
        Ok(kept)
    }

    pub(crate) fn submit_render(
        &mut self,
        queues: Arc<Mutex<FirmwareQueues>>,
        owner: Arc<Mutex<g16_vm::AddressSpace>>,
        params: &render::Parameters,
        support: &Support,
        timestamps: [u64; 4],
        dependencies: &[Option<Stamp>; 2],
        job: u64,
    ) -> Result<Receipt> {
        let _t = crate::g16_timeline::Timer::start(&crate::g16_timeline::P_SUBMIT_RENDER);
        if self.render_failed {
            return Err(EIO);
        }
        // Fast O(1) capacity check before VM locks, native-mesh page-table
        // walks/decode, or dependency resolution (lock order: queues -> owner).
        let mut queue = queues.lock();
        let cap = self.cap_state();
        self.check_cap_headroom(&queue, true, cap)?;
        let mut mesh_params;
        // The VM's latched mode, not the current one: a VM created native keeps
        // decoding its streams after a runtime switch to 0.
        let mesh_mode = support.mode;
        // Peek at the first word without waiting for producers: an ordinary
        // header publishes as at native_mesh=0, with no stall behind earlier
        // work. Userspace writes a native header on the CPU before SUBMIT, and
        // no GPU job rewrites a render's first word (Honeykrisp audit,
        // 2026-10-24), so a stale read can only see a native header that is
        // gone by now: that case still waits and decodes, which is
        // authoritative. An unreadable first word also waits and then fails
        // in the decode, as before.
        let params = if mesh_mode.enabled()
            && owner.lock().command_word(params.encoder).map_or(true, g16_mesh::may_be_native)
        {
            mesh_params = *params;
            let params = &mut mesh_params;
            // These are the raw producer dependencies, before same-lane wait
            // elision. A firmware barrier alone cannot protect a CPU read.
            let mut reader = self._firmware_space.as_ref().ok_or(EIO)?.reader();
            for dep in dependencies.iter().flatten() {
                if !g16_stamp::reached(reader.read_u32_relaxed(dep.address)?, dep.value) {
                    crate::g16_timeline::DEFERRED_CPU_HOLD.fetch_add(1, Ordering::Relaxed);
                    return Err(EBUSY);
                }
            }
            // Order subsequent CPU decode reads of client command memory after
            // observing all producer completion stamps.
            reader.acquire_barrier();
            drop(reader);
            let mut client = owner.lock();
            params.mesh = g16_mesh::decode(params.encoder, mesh_mode, |va| client.command_word(va).ok())
                .map_err(|error| match error {
                    g16_mesh::DecodeError::Unmapped => EFAULT,
                    g16_mesh::DecodeError::Unsupported => EOPNOTSUPP,
                })?;
            drop(client);
            if params.mesh.is_some() && (params.samples != 1 || params.layers != 1) {
                return Err(EOPNOTSUPP);
            }
            // A VM that first rendered with native_mesh=0 keeps its ordinary
            // support header, which cannot run a native stream.
            if params.mesh.is_some() && !support.native {
                return Err(EOPNOTSUPP);
            }
            // The VM already owns and advertises all 24 operand buffers.
            // This initialized pool serves both ordinary and native Work.
            &mesh_params
        } else {
            params
        };
        let mut tally = DepTally::default();
        let timestamped = timestamps.iter().any(|&t| t != 0);
        let resolved =
            self.resolve_render_dependencies(&mut queue, params, timestamped, dependencies, &mut tally)?;
        let dependencies = &resolved;
        let (root, client_has_free_work, client_work_leased) = {
            let client = owner.lock();
            (
                client.roots().low,
                client.has_free_work(true),
                client.work_leased(true),
            )
        };
        let initbm = !self
            .tvb_pools
            .iter()
            .any(|p| p.root == root && p.initialized);
        let stage_deps = if params.vdm_barrier_fragment {
            [
                u32::from(dependencies[1].is_some()),
                u32::from(dependencies[0].is_some()),
            ]
        } else {
            [dependencies.iter().flatten().count() as u32, 0]
        };
        self.reserve_flight(
            &queue,
            true,
            root,
            client_has_free_work,
            client_work_leased,
            crate::g16_headroom::FlightCharge::render(initbm, stage_deps[0], stage_deps[1]),
            cap,
        )?;
        self.prepare_queues(&mut queue)?;
        let result = self.submit_render_queue(
            &mut queue,
            queues.clone(),
            owner,
            params,
            support,
            timestamps,
            dependencies,
            job,
        );
        if queue.pending == 0 {
            queue.events = None;
        }
        if result.is_ok() {
            tally.publish();
        }
        result
    }

    pub(super) fn submit_render_queue(
        &mut self,
        queue: &mut FirmwareQueues,
        queues: Arc<Mutex<FirmwareQueues>>,
        owner: Arc<Mutex<g16_vm::AddressSpace>>,
        params: &render::Parameters,
        support: &Support,
        timestamps: [u64; 4],
        dependencies: &[Option<ResolvedDep>; 2],
        job: u64,
    ) -> Result<Receipt> {
        let mut guard = owner.lock();
        let client = &mut *guard;
        // The SUBMIT ioctl created the pool (provision_tvb); this finds it.
        let index = self.tvb_pool(client, support)?;
        let scene = self.tvb_pools[index].reserve_scene().inspect_err(|_| {
            self.report_pressure(4, "scenes");
        })?;
        let mut pool = self.tvb_pools.swap_remove(index);
        // Out of `self` while publication also borrows it; always returned.
        let mut encodings = core::mem::take(&mut self.encodings);
        let result = self.submit_render_pool(
            client,
            params,
            support,
            queue,
            queues,
            &mut pool,
            &mut encodings,
            owner.clone(),
            scene,
            timestamps,
            dependencies,
            job,
        );
        self.encodings = encodings;
        if result.is_err() && !self.render_failed {
            pool.release_scene(scene);
        }
        // Back into the slot swap_remove freed: no allocation.
        self.tvb_pools.push_within_capacity(pool).map_err(|_| EIO)?;
        result
    }

    #[inline(never)]
    pub(super) fn submit_render_pool(
        &mut self,
        client: &mut g16_vm::AddressSpace,
        params: &render::Parameters,
        support: &Support,
        queue: &mut FirmwareQueues,
        queues: Arc<Mutex<FirmwareQueues>>,
        pool: &mut crate::g16_tvb::Tvb,
        encodings: &mut Encodings,
        owner: Arc<Mutex<g16_vm::AddressSpace>>,
        scene: u32,
        timestamps: [u64; 4],
        dependencies: &[Option<ResolvedDep>; 2],
        job: u64,
    ) -> Result<Receipt> {
        if self.render_failed {
            return Err(EIO);
        }
        if !params.valid() || !(2..=3).contains(&queue.priority) {
            return Err(EINVAL);
        }
        let space = client.roots();
        let mut params = *params;
        params.tiling_admission = pool.addresses.buffer_manager_slot;
        params.fragment_admission = pool.addresses.buffer_manager_slot;
        // These accelerator pointers must select the same leased scene as
        // BufferThing. Reusing scene 1 here corrupts other in-flight renders.
        params.scene_slot = u64::from(scene);
        params.cycle = 0x240000 + u64::from(scene) * 0x30;
        let queue_ordinal = queue.render_count;
        // Wrap pre-publication leases (scratch + per-VM Work slot) in an RAII
        // Drop guard so any `?` error before publication returns both cleanly.
        let (scratch, va, a, lanes, job_owner, notifier_write) = {
            let mut sink = RuntimeLeaseSink {
                runtime: self,
                client,
            };
            let mut prep = crate::g16_work_pool::PrepGuard::new(&mut sink, true);
            let scratch = prep.sink_mut().client.prepare_render(&mut params)?;
            prep.set_scratch(scratch);
            let mut a = render::Addresses::bootstrap()
                .publication(prep.sink_mut().runtime.render_publication);
            pool.work_addresses(&mut a, scene);
            // Keep profiling storage private to the Work. Public timestamp BOs
            // are written by the firmware through its separate user destinations.
            let lanes = *queue.lanes.as_ref().ok_or(EIO)?;
            a.tiling_queue = lanes[0].queue;
            a.fragment_queue = lanes[1].queue;
            a.tiling_event = u64::from(queue.event(0)?);
            a.fragment_event = u64::from(queue.event(1)?);
            a.support = support.address();
            a.render_shared_state = support.shared_state();
            a.tiling_status_page = params.ta_status & !0x3fff;
            a.fragment_status_page = params.fragment_status & !0x3fff;
            a.fragment_counter = queue_ordinal.wrapping_mul(2);
            a.tiling_counter = a.fragment_counter.wrapping_add(1);
            // Firmware's dependency graph requires consecutive stamp updates
            // within each lane, even when other queues publish between them.
            a.fragment_stamp = u64::from(g16_stamp::value(queue_ordinal, 0x100));
            a.tiling_stamp = u64::from(g16_stamp::value(queue_ordinal, 0xc00));
            let (va, _reused) = {
                let s = prep.sink_mut();
                s.runtime.allocate_work(s.client, true)?
            };
            prep.set_work(va);
            a.tiling_shared_tail = va + 0x10000;
            a.fragment_shared_tail = va + 0x14000;
            // The notifier pass stores driver stamps, then sends the IRQ after
            // a DSB. These destinations must be firmware-uncached: a DSB does
            // not clean a cached stamp, leaving Linux asleep on stale memory.
            // Each render has its own driver stamps and, with shared_notifier=0,
            // its own notifier and count. A notifier shared by the whole queue
            // with a cumulative count (2026-10-03 to 10-27) was announced only
            // once every Work published to it had completed, so a busy queue
            // waited for the safety poll; one per submission (below) is not.
            // The Work count lives with the stamps in the firmware-uncached page:
            // a shared notifier's count is raised while the firmware reads it.
            a.event_control = va + 0x200;
            a.event_count_array = va + 0x18080;
            a.tiling_driver_stamp = va + 0x18000;
            a.fragment_driver_stamp = va + 0x18040;
            // shared_notifier=1: renders of one submission staged in the same
            // flush batch share the notifier AND uncached driver-stamp slots of
            // its first render (the owner), as Metal shares one per command
            // buffer. Firmware's per-notifier completion pass coalesces
            // consecutive stage driver-stamp writes within a shared notifier:
            // giving member renders distinct driver-stamp addresses leaves earlier
            // renders' private slots unwritten (blocked=0x1) whenever firmware
            // flushes only the later Work's address. Sharing owner_va+0x18000 /
            // +0x18040 (initialized once by the owner to previous(first_stamp))
            // lets monotonically rising coalesced writes satisfy every render in
            // the notifier. Each render raises the notifier's Work count by its
            // own two Works before flush() exposes the batch to firmware. Once
            // flush() runs, firmware can complete and drain that notifier before
            // the owner retires on the host CPU, so a later render split across a
            // flush boundary by backpressure (EBUSY) starts a fresh notifier
            // rather than re-arming one that may have drained.
            let job_owner = if crate::g16_timeline::shared_notifier() {
                let owner = prep
                    .sink_mut()
                    .runtime
                    .job_notifiers
                    .iter()
                    .find(|j| j.job == job && !j.flushed && !j.owner_retired)
                    .map(|j| j.owner);
                let owner_va = owner.unwrap_or(va);
                a.event_control = owner_va + 0x200;
                a.event_count_array = owner_va + 0x18080;
                a.tiling_driver_stamp = owner_va + 0x18000;
                a.fragment_driver_stamp = owner_va + 0x18040;
                Some((owner_va, owner.is_none()))
            } else {
                None
            };
            // What this render writes into the notifier: the full header (its
            // own notifier, or a submission's first) and the Work count.
            let notifier_write = match job_owner {
                None | Some((_, true)) => (true, 2u32),
                Some((owner_va, false)) => {
                    let entry = prep
                        .sink_mut()
                        .runtime
                        .job_notifiers
                        .iter()
                        .find(|j| j.owner == owner_va)
                        .ok_or(EIO)?;
                    (false, entry.works + 2)
                }
            };
            // Fail before publication: past it, a render must have its Flight.
            if matches!(job_owner, Some((_, true)))
                && prep.sink_mut().runtime.job_notifiers.len()
                    == prep.sink_mut().runtime.job_notifiers.capacity()
            {
                return Err(EIO);
            }

            a.tiling_firmware_stamp = lanes[0].firmware_stamp();
            a.fragment_firmware_stamp = lanes[1].firmware_stamp();
            let alias = crate::g16_work_pool::alias_range(va, WORK_BASE, WORK_WINDOW, true)
                .ok_or(ENOSPC)?
                .start;
            for stage in 0..2u64 {
                let work_page = va + stage * 0x8000;
                let register_page = alias + stage * 0x4000;
                if stage == 0 {
                    a.tiling_work = work_page + (a.tiling_work & 0x3fff);
                    a.tiling_microsequence =
                        work_page + 0x4000 + (a.tiling_microsequence & 0x3fff);
                    a.tiling_prelude = work_page + 0x4000;
                    a.tiling_register_alias = register_page + (a.tiling_register_alias & 0x3fff);
                } else {
                    a.fragment_work = work_page + (a.fragment_work & 0x3fff);
                    a.fragment_microsequence =
                        work_page + 0x4000 + (a.fragment_microsequence & 0x3fff);
                    a.fragment_prelude = work_page + 0x4000;
                    a.fragment_register_alias =
                        register_page + (a.fragment_register_alias & 0x3fff);
                }
            }
            {
                let s = prep.sink_mut();
                if s.client.has_pending_tables() {
                    s.client.sync();
                }
                s.runtime.invalidate_client(s.client);
            }
            // A live context lease keeps these roots fixed through retirement.
            a.context_id = u64::from(prep.sink_mut().runtime.acquire_context(space, 9)?);
            a.tiling_user_timestamp_start = timestamps[0];
            a.tiling_user_timestamp_end = timestamps[1];
            a.fragment_user_timestamp_start = timestamps[2];
            a.fragment_user_timestamp_end = timestamps[3];
            let (scratch, va) = prep.commit().ok_or(EIO)?;
            (scratch, va, a, lanes, job_owner, notifier_write)
        };
        // From here any publication failure quarantines the roots.
        self.render_failed = true;
        let (ta, frag) = (&mut encodings.tiling, &mut encodings.fragment);
        ta.fill(0);
        frag.fill(0);
        // The ioctl validated the parameters and every address here is the
        // kernel's own, so a failed encoding is a driver bug, not bad input.
        if params.tiling_work(&a, ta).is_none() || params.fragment_work(&a, frag).is_none() {
            pr_err!("G16: render Work encoding failed for ioctl-validated parameters\n");
            return Err(EIO);
        }
        // No per-Work start or tiling-end profiling stamps; fragment end
        // uses one location shared by the queue, separate from UAPI timestamps.
        ta[0x8c8..0x8d8].fill(0);
        frag[0xc10..0xc18].fill(0);
        frag[0xc18..0xc20].copy_from_slice(&(lanes[1].pointers + 0x2080).to_le_bytes());
        if crate::module_parameters::fw_trace.value() & 128 != 0
            && !CONFIG_DUMPED.swap(true, Ordering::Relaxed)
        {
            // Live firmware configuration, for comparison with macOS.
            let fw = self._firmware_space.as_ref().ok_or(EIO)?;
            for (base, size) in [
                (0xffff_fc20_0010_0000u64, 0x4000u64),
                (0xffff_fc20_0010_8000, 0x4000),
                (0xffff_fc20_000f_8000, 0x4000),
                (0xffff_fc20_c04d_8000, 0x20000),
                (0xffff_fc20_0003_e000, 0x2000),
            ] {
                for line in (base..base + size).step_by(32) {
                    let words = [
                        fw.read_u64(line)?,
                        fw.read_u64(line + 8)?,
                        fw.read_u64(line + 16)?,
                        fw.read_u64(line + 24)?,
                    ];
                    if words != [0; 4] {
                        pr_info!(
                            "G16: cfgdump {:#x}: {:016x} {:016x} {:016x} {:016x}\n",
                            line, words[0], words[1], words[2], words[3]
                        );
                    }
                }
            }
        }
        if crate::module_parameters::fw_trace.value() & 32 != 0 && queue_ordinal == 10 {
            pr_info!(
                "G16: work dump TA={:#x} 3D={:#x} queues={:#x}/{:#x} bm={:#x} thing={:#x} support={:#x} micro={:#x}/{:#x}\n",
                a.tiling_work, a.fragment_work, a.tiling_queue, a.fragment_queue,
                a.buffer_manager, a.buffer_thing, a.support,
                a.tiling_microsequence, a.fragment_microsequence
            );
            for (name, bytes) in [("TA", &ta[..]), ("3D", &frag[..])] {
                for (i, chunk) in bytes.chunks(32).enumerate() {
                    pr_info!("G16: work {} {:#06x}: {:02x?}\n", name, i * 32, chunk);
                }
            }
        }
        // TVB initialization and first publication of a firmware queue are
        // independent: several public queues can share one VM's TVB pool.
        let initbm = !pool.initialized;

        // The shared count covers individual Work items, not render pairs.
        // Firmware retires one tiling and one fragment item per submission.
        let submitted = support.submissions.load(Ordering::Relaxed);
        let next_submitted = submitted.wrapping_add(2);
        // Firmware observes the low word of this cumulative count.
        let use_count = next_submitted as u32;
        // From here an error conservatively quarantines the client root.
        self.render_failed = true;
        let dep_stamps = dependencies.map(|d| d.map(|r| r.stamp));
        let own = queue.lanes.map_or([0; 3], |l| l.map(|lane| lane.firmware_stamp()));
        self.note_dependency_events(&dep_stamps, own);
        let (heads, epochs, lane_items) = self.publish_render(
            &a, &ta, &frag, queue, pool, initbm, use_count, dependencies,
            params.vdm_barrier_fragment, notifier_write,
        )?;
        pool.initialized = true;
        support.submissions.store(next_submitted, Ordering::Relaxed);
        self.render_publication = self.render_publication.wrapping_add(1);
        queue.render_count = queue_ordinal.wrapping_add(1);
        // A shared notifier's completed count (+0xc) reaches this render's
        // running total within the submission once both its Works are done.
        let notifier_count = match job_owner {
            None => None,
            Some((owner_va, first)) => {
                if first {
                    self.job_notifiers
                        .push_within_capacity(JobNotifier {
                            job,
                            owner: owner_va,
                            owner_client: owner.clone(),
                            owner_retired: false,
                            flushed: false,
                            works: 0,
                            refs: 0,
                        })
                        .map_err(|_| EIO)?;
                }
                let entry = self.job_notifiers.iter_mut().find(|j| j.owner == owner_va).ok_or(EIO)?;
                entry.works += 2;
                entry.refs += 1;
                Some((a.event_control + 0xc, entry.works))
            }
        };
        let job_notifier = job_owner.map(|(owner_va, _)| owner_va);
        let lanes = queue.lanes.as_mut().ok_or(EIO)?;
        for stage in 0..2 {
            lanes[stage].head = heads[stage];
            lanes[stage].new = false;
        }
        let stamp = Stamp {
            address: a.fragment_firmware_stamp,
            value: a.fragment_stamp as u32,
            event: a.fragment_event as u32,
        };
        let receipt = Receipt { id: va, stamp };
        queue.last[0] = Some(stamp);
        queue.waited.prune(stamp.address, stamp.value);
        for (slot, dep) in dependencies.iter().enumerate() {
            if let Some(dep) = dep {
                queue.waited.note(
                    Self::render_item_lane(&params, slot),
                    dep.stamp.address,
                    dep.stamp.value,
                    dep.kind,
                );
            }
        }
        queue.pending += 1;
        self.flights.push_within_capacity(
            Flight {
                id: va,
                owner: queues,
                context: a.context_id as u32,
                stream: params.encoder,
                ordinal: queue_ordinal,
                tgid: params.tgid,
                comm: params.comm,
                started: Instant::now(),
                notifier_count,
                job_notifier,
                stamps_seen: None,
                blocked: 0,
                dependencies: dep_stamps,
                stamps: [
                    Some(Stamp {
                        address: a.tiling_firmware_stamp,
                        value: a.tiling_stamp as u32,
                        event: a.tiling_event as u32,
                    }),
                    Some(stamp),
                ],
                user_timestamps: a.tiling_user_timestamp_start != 0
                    || a.tiling_user_timestamp_end != 0
                    || a.fragment_user_timestamp_start != 0
                    || a.fragment_user_timestamp_end != 0,
                driver_stamps: [
                    Some(Stamp {
                        address: a.tiling_driver_stamp,
                        value: a.tiling_stamp as u32,
                        event: a.tiling_event as u32,
                    }),
                    Some(Stamp {
                        address: a.fragment_driver_stamp,
                        ..stamp
                    }),
                ],
                scratch,
                client: owner.clone(),
                queues: [(lanes[0].pointers, heads[0]), (lanes[1].pointers, heads[1])],
                lane_items,
                channels: [
                    (queue.priority as usize * 3, (epochs[0] + 1) & 255),
                    (queue.priority as usize * 3 + 1, (epochs[1] + 1) & 255),
                ],
                render: Some(RenderFlight {
                    addresses: a,
                    client: owner,
                    root: space.low,
                    events: RenderEvents::default(),
                    scene,
                }),
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
        self.trace_publication("render", va)?;
        self.trace_dependencies("render", va, a.context_id as u32, &dep_stamps)?;
        Ok(receipt)
    }

    pub(super) fn publish_render(
        &mut self,
        a: &render::Addresses,
        ta: &[u8],
        frag: &[u8],
        queue: &FirmwareQueues,
        pool: &mut crate::g16_tvb::Tvb,
        initbm: bool,
        use_count: u32,
        dependencies: &[Option<ResolvedDep>; 2],
        vdm_barrier_fragment: bool,
        notifier_write: (bool, u32),
    ) -> Result<([u32; 2], [u32; 2], [u32; 2])> {
        let priority = queue.priority;
        let lanes = queue.lanes.as_ref().ok_or(EIO)?;
        let publication = self.render_publication;
        let firsts = [lanes[0].head, lanes[1].head];
        // Only the render dependency can move to fragment. Compute output
        // may feed the vertex stage, and input fences were already consumed
        // by the scheduler before either lane was published.
        let stage_dependencies = if vdm_barrier_fragment {
            [[None, dependencies[1]], [dependencies[0], None]]
        } else {
            [*dependencies, [None, None]]
        };
        let heads = [
            (firsts[0] + 1 + u32::from(initbm)
                + stage_dependencies[0].iter().flatten().count() as u32)
                % 0x500,
            (firsts[1] + 2 + stage_dependencies[1].iter().flatten().count() as u32) % 0x500,
        ];
        // Stage every byte this render publishes in one barrier-free writer
        // pass with cached region lookups. `render_shared_state` and the TVB
        // pool counter (`increment_staged`) are live cumulative counters
        // already reachable by earlier work on this pool (advancing
        // monotonically, with no transaction or rollback); all newly written
        // per-Work descriptors, preludes, microsequences, notifiers, driver
        // stamps, dependency items, and ring entries are ordered by flush()'s
        // release barrier before advancing lane heads and ringing the doorbell.
        {
            let fw = self._firmware_space.as_mut().ok_or(EIO)?;
            let mut writer = fw.writer();
            writer.write_u32_staged(a.render_shared_state, use_count)?;
            pool.increment_staged(&mut writer)?;
            if notifier_write.0 {
                writer.write_u64_staged(a.event_control, a.event_count_array)?;
                writer.write_u32_staged(a.event_control + 8, a.fragment_stamp as u32)?;
                writer.write_u32_staged(a.event_control + 12, 0)?;
                writer.write_u32_staged(a.event_control + 0x10, 0x50)?;
                writer.write_u32_staged(a.event_control + 0x24, a.context_id as u32)?;
                // Initialize shared driver stamps once on the owner to before
                // the first render's stamps; member renders must not overwrite
                // them with previous(later_stamp) or they would pre-satisfy
                // earlier renders in the same batch.
                writer.write_u32_staged(
                    a.tiling_driver_stamp,
                    g16_stamp::previous(a.tiling_stamp as u32),
                )?;
                writer.write_u32_staged(
                    a.fragment_driver_stamp,
                    g16_stamp::previous(a.fragment_stamp as u32),
                )?;
            }
            writer.write_u32_staged(a.event_count_array, notifier_write.1)?;

            let preludes = [a.tiling_prelude(pool.blocks), a.fragment_prelude()];
            let tiling_micro = a.tiling_microsequence();
            let fragment_micro = a.fragment_microsequence();
            for stage in 0..2 {
                let (prelude, work, micro, work_bytes, micro_bytes, stamp, uuid) = if stage == 0 {
                    (
                        a.tiling_prelude,
                        a.tiling_work,
                        a.tiling_microsequence,
                        ta,
                        &tiling_micro[..],
                        a.tiling_stamp,
                        a.tiling_uuid,
                    )
                } else {
                    (
                        a.fragment_prelude,
                        a.fragment_work,
                        a.fragment_microsequence,
                        frag,
                        &fragment_micro[..],
                        a.fragment_stamp,
                        a.fragment_uuid,
                    )
                };
                writer.write_staged(prelude, &preludes[stage])?;
                writer.write_staged(work, work_bytes)?;
                writer.write_staged(micro, micro_bytes)?;
                let mut pos = firsts[stage];
                let ring = lanes[stage].ring;
                // The prelude page leaves +0x40..+0xc0 free before its
                // microsequence. All barrier bytes share the Work's lifetime.
                for (index, dep) in stage_dependencies[stage].iter().flatten().enumerate() {
                    let item_va = prelude + 0x40 + index as u64 * 0x40;
                    let item = g16_fw::queue::dependency(
                        dep.stamp.address,
                        dep.stamp.value,
                        dep.stamp.event,
                        stamp as u32,
                        uuid as u32,
                        dep.kind,
                    );
                    writer.write_staged(item_va, &item)?;
                    writer.write_u64_staged(ring + u64::from(pos) * 8, item_va)?;
                    pos = (pos + 1) % 0x500;
                }
                if stage == 1 || initbm {
                    writer.write_u64_staged(ring + u64::from(pos) * 8, prelude)?;
                    pos = (pos + 1) % 0x500;
                }
                writer.write_u64_staged(ring + u64::from(pos) * 8, work)?;
            }
        }
        let mut epochs = [0; 2];
        for stage in [1usize, 0] {
            let mut lane = lanes[stage];
            lane.head = heads[stage];
            epochs[stage] = self.stage_queue(
                priority as usize * 3 + stage,
                lane,
                if stage == 0 {
                    a.tiling_event
                } else {
                    a.fragment_event
                } as u32,
                publication.wrapping_add(1),
            )?;
        }
        let lane_items = stage_dependencies.map(|d| d.iter().flatten().count() as u32);
        Ok((heads, epochs, lane_items))
    }
}

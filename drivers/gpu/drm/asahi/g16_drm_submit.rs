// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! SUBMIT: parsing and validating commands into render and compute
//! parameters, and queueing them as scheduler jobs.

use super::*;

impl File {
    pub(super) fn submit(device: &RegDevice, _reg: &RegData<'_>, data: &mut uapi::drm_asahi_submit, file: &DrmFile) -> Result<u32> {
        let device: &Device = device;
        if data.flags != 0
            || data.pad != 0
            || data.cmdbuf_size == 0
            || data.cmdbuf_size > 1024 * 1024
            || data.in_sync_count > 4096
            || data.out_sync_count > 4096
        {
            return Err(reject(format_args!("bad flags/pad, cmdbuf size {} or sync counts {}/{}", data.cmdbuf_size, data.in_sync_count, data.out_sync_count)));
        }
        let mut bytes = KVVec::new();
        UserSlice::new(
            UserPtr::from_addr(data.cmdbuf.try_into()?),
            data.cmdbuf_size as usize,
        )
        .reader()
        .read_all(&mut bytes, GFP_KERNEL)?;
        let mut commands = KVec::new();
        let mut barriers = KVec::new();
        let mut attachments = KVec::new();
        let mut offset = 0usize;
        let mut renders = 0u16;
        let mut computes = 0u16;
        while offset < bytes.len() {
            let mut reader = crate::util::Reader::new(&bytes[offset..]);
            let header: uapi::drm_asahi_cmd_header = reader.read()?;
            offset = offset.checked_add(8).ok_or_else(|| reject(format_args!("command header past the buffer")))?;
            let end = offset.checked_add(header.size as usize).ok_or_else(|| reject(format_args!("command size overflows")))?;
            let payload = bytes.get(offset..end).ok_or_else(|| reject(format_args!("command payload past the buffer ({} > {})", end, bytes.len())))?;
            offset = end;
            match u32::from(header.cmd_type) {
                uapi::drm_asahi_cmd_type_DRM_ASAHI_CMD_RENDER => {
                    if (header.vdm_barrier != 0xffff && header.vdm_barrier > renders)
                        || (header.cdm_barrier != 0xffff && header.cdm_barrier > computes)
                        || renders + computes == 64
                    {
                        return Err(reject(format_args!("render barrier {}/{} beyond {} renders/{} computes, or 64 commands", header.vdm_barrier, header.cdm_barrier, renders, computes)));
                    }
                    let command = crate::util::Reader::new(payload)
                        .read_up_to::<uapi::drm_asahi_cmd_render>(payload.len())?;
                    commands.push(Command::Render(command), GFP_KERNEL)?;
                    barriers.push([header.vdm_barrier, header.cdm_barrier], GFP_KERNEL)?;
                    renders += 1;
                }
                uapi::drm_asahi_cmd_type_DRM_ASAHI_CMD_COMPUTE => {
                    if (header.vdm_barrier != 0xffff && header.vdm_barrier > renders)
                        || (header.cdm_barrier != 0xffff && header.cdm_barrier > computes)
                        || renders + computes == 64
                    {
                        return Err(reject(format_args!("compute barrier {}/{} beyond {} renders/{} computes, or 64 commands", header.vdm_barrier, header.cdm_barrier, renders, computes)));
                    }
                    let command = crate::util::Reader::new(payload)
                        .read_up_to::<uapi::drm_asahi_cmd_compute>(payload.len())?;
                    commands.push(Command::Compute(command), GFP_KERNEL)?;
                    barriers.push([header.vdm_barrier, header.cdm_barrier], GFP_KERNEL)?;
                    computes += 1;
                }
                uapi::drm_asahi_cmd_type_DRM_ASAHI_SET_VERTEX_ATTACHMENTS
                | uapi::drm_asahi_cmd_type_DRM_ASAHI_SET_FRAGMENT_ATTACHMENTS
                | uapi::drm_asahi_cmd_type_DRM_ASAHI_SET_COMPUTE_ATTACHMENTS => {
                    if header.vdm_barrier != 0xffff
                        || header.cdm_barrier != 0xffff
                        || payload.len() % 24 != 0
                        || payload.len() / 24 > 16
                    {
                        return Err(reject(format_args!("attachment command with barriers, or {} bytes (not 24 x 1..16)", payload.len())));
                    }
                    let mut reader = crate::util::Reader::new(payload);
                    while !reader.is_empty() {
                        let attachment: uapi::drm_asahi_attachment = reader.read()?;
                        if attachment.flags != 0
                            || attachment.pad != 0
                            || attachment.pointer.checked_add(attachment.size).is_none()
                        {
                            return Err(reject(format_args!("attachment flags/pad nonzero or range overflows")));
                        }
                        attachments.push(attachment, GFP_KERNEL)?;
                    }
                }
                kind => return Err(unsupported(format_args!("command type {}", kind))),
            }
        }
        if renders + computes == 0 {
            return Err(reject(format_args!("no render or compute command")));
        }
        let count = data.in_sync_count + data.out_sync_count;
        let mut sync_bytes = KVec::new();
        UserSlice::new(
            UserPtr::from_addr(data.syncs.try_into()?),
            count as usize * 16,
        )
        .reader()
        .read_all(&mut sync_bytes, GFP_KERNEL)?;
        let mut outputs = KVec::new();
        let mut dependencies = KVec::new();
        for (index, bytes) in sync_bytes.chunks_exact(16).enumerate() {
            let kind = u32::from_ne_bytes(bytes[0..4].try_into().map_err(|_| EINVAL)?);
            let handle = u32::from_ne_bytes(bytes[4..8].try_into().map_err(|_| EINVAL)?);
            let point = u64::from_ne_bytes(bytes[8..16].try_into().map_err(|_| EINVAL)?);
            if kind > 1 || (kind == 0 && point != 0) {
                return Err(reject(format_args!("sync {} kind {} point {}", index, kind, point)));
            }
            let object = drm::syncobj::SyncObj::lookup_handle(file, handle)?;
            if index >= data.in_sync_count as usize {
                outputs.push(
                    OutputSync {
                        object,
                        point,
                        chain: if kind == 1 {
                            Some(dma_fence::FenceChain::new()?)
                        } else {
                            None
                        },
                    },
                    GFP_KERNEL,
                )?;
            } else {
                let fence = object.fence_get().ok_or_else(|| reject(format_args!("in-sync {} (handle {}) has no fence: waited before any signal was submitted", index, handle)))?;
                let fence = if kind == 1 {
                    fence.chain_find_seqno(point)?
                } else {
                    Some(fence)
                };
                if let Some(fence) = fence {
                    dependencies.push(fence, GFP_KERNEL)?;
                }
            }
        }
        let mut trace = Trace::default();
        if crate::module_parameters::timeline.value() != 0 {
            trace.ioctl = ticks();
            trace.queue = data.queue_id;
            trace.inputs = dependencies.len() as u32;
            trace.pending = dependencies
                .iter()
                // SAFETY: The vector holds a live reference to each fence.
                .filter(|f| !unsafe { bindings::dma_fence_is_signaled(f.raw()) })
                .count() as u32;
        }
        let inner = file.inner();
        let (mut admission, mut state) = loop {
            let admission = device.admission.lock();
            if device.failed.load(Ordering::Acquire) {
                return Err(EIO);
            }
            let mut state = inner.state.lock();
            let queue = state.queues.iter()
                .find(|q| q.id == data.queue_id).ok_or(ENOENT)?;
            let vm = state.vms.iter().find(|vm| vm.id == queue.vm).ok_or(ENOENT)?;
            if vm.draining == 0 {
                break (admission, state);
            }
            // Wait atomically with state dropped. Drop admission as well:
            // holding it would block submissions to unrelated VMs and other
            // files and teardown paths that need admission before state.
            drop(admission);
            // No submission state has been published yet; let a signalled
            // submitter leave without waiting for the drainer's whole budget.
            if inner.drained.wait_interruptible(&mut state) {
                return Err(ERESTARTSYS);
            }
            drop(state);
            // Reacquire in admission -> state order and re-find both IDs.
        };
        // Completed records no longer need lifetime bookkeeping.
        admission.retain(|f| {
            // SAFETY: The vector retains a live reference while queried.
            !unsafe { bindings::dma_fence_is_signaled(f.raw()) }
        });
        admission.reserve(1, GFP_KERNEL)?;
        let queue = state
            .queues
            .iter()
            .find(|q| q.id == data.queue_id)
            .ok_or(ENOENT)?;
        // Render and compute on even one public queue may complete out of
        // order. Give each submission its own timeline: a later independent
        // completion must never subsume an earlier dependency in DRM.
        let unique = dma_fence::FenceContexts::new(1, c_str!("asahi_m4"), FENCE_KEY)?
            .new_fence(0, Completion)?;
        // A queue that has failed work stays failed: refuse new work instead
        // of accepting jobs that can only complete with ECANCELED.
        if queue.firmware.lock().rejected {
            return Err(ECANCELED);
        }
        let vm_id = queue.vm;
        let firmware = queue.firmware.clone();
        let mut timestamps = KVec::new();
        let resolve = |stamp: &uapi::drm_asahi_timestamp| -> Result<u64> {
            if stamp.handle == 0 {
                return if stamp.offset == 0 {
                    Ok(0)
                } else {
                    Err(reject(format_args!("timestamp offset {} without a handle", stamp.offset)))
                };
            }
            let binding = state
                .timestamps
                .iter()
                .find(|t| t.id == stamp.handle)
                .ok_or(ENOENT)?;
            let offset = u64::from(stamp.offset);
            if offset & 7 != 0 || offset.checked_add(8).ok_or_else(|| reject(format_args!("timestamp offset overflows")))? > binding.size {
                return Err(reject(format_args!("timestamp offset {} unaligned or beyond {}", offset, binding.size)));
            }
            Ok(binding.address + offset)
        };
        for command in &commands {
            let resolved = match command {
                Command::Render(c) => [
                    resolve(&c.ts_vtx.start)?,
                    resolve(&c.ts_vtx.end)?,
                    resolve(&c.ts_frag.start)?,
                    resolve(&c.ts_frag.end)?,
                ],
                Command::Compute(c) => [resolve(&c.ts.start)?, resolve(&c.ts.end)?, 0, 0],
            };
            timestamps.push(resolved, GFP_KERNEL)?;
        }
        let mut timestamp_bindings = KVec::new();
        for binding in &state.timestamps {
            timestamp_bindings.push(binding.clone(), GFP_KERNEL)?;
        }
        let index = state.vms.iter().position(|v| v.id == vm_id).ok_or(ENOENT)?;
        let vm = &mut state.vms[index];
        if vm.render_broken {
            return Err(EIO);
        }
        for attachment in &attachments {
            vm.cover(attachment.pointer, attachment.size, 4)?;
        }
        let mut parameters = KVec::new();
        for command in &commands {
            parameters.push(
                match command {
                    Command::Render(c) => Parameters::Render(vm.render_parameters(c)?),
                    Command::Compute(c) => Parameters::Compute(vm.compute_parameters(c)?),
                },
                GFP_KERNEL,
            )?;
        }
        let first_compute = computes != 0 && !vm.compute_ready;
        // Experimental: compute on the VM's render pool needs that pool.
        let share = first_compute
            && crate::g16_timeline::COMPUTE_SHARES_RENDER_POOL.load(Ordering::Relaxed) != 0;
        let needs_mapping = (renders != 0 && !vm.render_ready) || first_compute;
        if needs_mapping {
            // These reserved namespaces are initialized once before this
            // VM's first command on the corresponding engine. Keep every
            // GFP_KERNEL allocation outside `device.runtime.lock()` so reclaim
            // cannot deadlock against retirement of earlier exported fences;
            // `acquire_*_support()` performs zero allocations under the lock.
            if (renders != 0 || share) && !vm.render_ready {
                // Native mesh keeps its qualified full-size pool.
                let buffers = if vm.native_mesh {
                    render::OPERAND_BUFFERS_MAX
                } else {
                    crate::g16_timeline::RENDER_OPERAND_BUFFERS.load(Ordering::Relaxed)
                };
                let pool =
                    render::OperandPool::with_buffers(vm.kernel.start, vm.kernel.end, buffers).ok_or_else(|| reject(format_args!("VM kernel VA {:#x}..{:#x} too small for the render operand pool, or render_operand_buffers={} outside {}..={}", vm.kernel.start, vm.kernel.end, buffers, render::OPERAND_BUFFERS_MIN, render::OPERAND_BUFFERS_MAX)))?;
                let support_raw = {
                    let mut runtime = device.runtime.lock();
                    if runtime.render_failed() {
                        return Err(EIO);
                    }
                    runtime.acquire_render_support(&pool, vm.native_mesh)?
                };
                // Acquire scarce support and its Arc before editing this
                // root. ENOSPC/ENOMEM here must not quarantine a healthy VM.
                let support = Arc::new(support_raw, GFP_KERNEL)?;
                if let Err(error) = vm.space.lock()
                    .alloc_render_private(vm.kernel.start, vm.kernel.end, &pool)
                {
                    // The unpublished graph owns every partial allocation
                    // and resumes on ENOMEM. Structural/PTE inconsistencies
                    // still quarantine the VM; do not mask those failures.
                    vm.render_broken = error != ENOMEM;
                    return Err(error);
                }
                vm.render_support = Some(support);
                vm.render_pool = Some(pool);
                vm.render_ready = true;
            }
            if first_compute {
                let result = if share {
                    if device.runtime.lock().render_failed() {
                        return Err(EIO);
                    }
                    let support = vm.render_support.clone().ok_or(EIO)?;
                    let pool = vm.render_pool.ok_or(EIO)?;
                    let end = pool.end().ok_or(EINVAL)?;
                    let count = ((end - pool.directory) as usize) / crate::pgtable::UAT_PGSZ;
                    let mut pages = KVec::with_capacity(count, GFP_KERNEL)?;
                    vm.space.lock().fill_render_pool_pages(&pool, &mut pages)?;
                    let start = end;
                    let mut space = vm.compute_space.lock();
                    space
                        .share_render_pool(&pages, vm.space.clone())
                        .and_then(|()| space.set_compute_support(support))
                        .map(|()| {
                            // Compute scratch stays clear of the pool VAs.
                            space.init_compute_private(start..vm.kernel.end);
                            space.sync();
                            space.report_compute_pool("render-shared");
                        })
                } else {
                    let buffers =
                        crate::g16_timeline::COMPUTE_POOL_BUFFERS.load(Ordering::Relaxed) as usize;
                    // End the first `compute_space` guard before acquiring
                    // `device.runtime` and reacquiring `compute_space` below.
                    let pool_res = { vm.compute_space.lock().alloc_compute_pool(buffers) };
                    match pool_res {
                        Ok(()) => (|| {
                            let support_raw = {
                                let mut runtime = device.runtime.lock();
                                if runtime.render_failed() {
                                    return Err(EIO);
                                }
                                runtime.acquire_compute_support(buffers)?
                            };
                            let support = Arc::new(support_raw, GFP_KERNEL)?;
                            let mut space = vm.compute_space.lock();
                            space.set_compute_support(support)?;
                            space.init_compute_private(vm.kernel.clone());
                            space.sync();
                            space.report_compute_pool("private");
                            Ok(())
                        })(),
                        Err(err) => Err(err),
                    }
                };
                if let Err(error) = result {
                    // Allocation failures resume on a retry; anything else
                    // (a conflicting PTE) quarantines the VM.
                    vm.render_broken = error != ENOMEM && error != ENOSPC;
                    return Err(error);
                }
                vm.compute_ready = true;
            }
        }
        // Prune signaled fences first so per-kind pending counts reflect live
        // queued submissions on this VM when sizing per-VM Work pools.
        let keep_live = |f: &mut dma_fence::Fence| {
            // SAFETY: Each entry owns its live fence reference.
            !unsafe { bindings::dma_fence_is_signaled(f.raw()) }
        };
        vm.pending.retain(keep_live);
        vm.pending_render.retain(keep_live);
        vm.pending_compute.retain(keep_live);
        let pending_renders = vm.pending_render.len();
        let pending_computes = vm.pending_compute.len();

        // Provision what this queue's or VM root's publication would otherwise
        // allocate in the job worker (firmware rings, TVB pool, per-VM Work
        // slots, and initial scratch backing). Preallocate backing pages with
        // GFP_KERNEL *outside* device.runtime and VM AddressSpace locks, then
        // install them inside those locks using only GFP_NOWAIT | __GFP_NOWARN
        // so reclaim can never deadlock against retirement of earlier fences.
        const MAX_VM_WORK_SLOTS: usize = 64;
        let tvb = renders != 0 && !vm.tvb_ready;
        let (render_owned, render_work_add, render_min_add) = if renders != 0 {
            let need = usize::from(renders);
            let space = vm.space.lock();
            let owned = space.work_owned(true);
            let queued_want = (pending_renders + 1)
                .saturating_mul(need)
                .min(MAX_VM_WORK_SLOTS);
            let idle_want = if space.has_free_work(true) {
                owned
            } else {
                owned.saturating_add(need).min(MAX_VM_WORK_SLOTS)
            };
            let want = queued_want.max(idle_want);
            (owned, want.saturating_sub(owned), usize::from(owned == 0))
        } else {
            (0, 0, 0)
        };
        let (compute_owned, compute_work_add, compute_min_add) = if computes != 0 {
            let need = usize::from(computes);
            let space = vm.compute_space.lock();
            let owned = space.work_owned(false);
            let queued_want = (pending_computes + 1)
                .saturating_mul(need)
                .min(MAX_VM_WORK_SLOTS);
            let idle_want = if space.has_free_work(false) {
                owned
            } else {
                owned.saturating_add(need).min(MAX_VM_WORK_SLOTS)
            };
            let want = queued_want.max(idle_want);
            (owned, want.saturating_sub(owned), usize::from(owned == 0))
        } else {
            (0, 0, 0)
        };
        let mut max_render_scratch = 0usize;
        if renders != 0 {
            for p in &parameters {
                if let Parameters::Render(r) = p {
                    if let Some((tilemap, tpc)) = r.scratch_sizes() {
                        // `DRM_ASAHI_RENDER_NATIVE_MESH` already populated
                        // `r.mesh` in `render_parameters()`, so scratch sizing
                        // is exact without reading command-stream memory.
                        let mesh_extra = if r.mesh.is_some() {
                            crate::g16_mesh::Profile::PAYLOAD_BYTES
                        } else {
                            0
                        };
                        let size = tilemap
                            .checked_add(tpc)
                            .and_then(|n| n.checked_add(5 * crate::pgtable::UAT_PGSZ))
                            .and_then(|n| n.checked_add(mesh_extra))
                            .ok_or(ENOMEM)?;
                        max_render_scratch = max_render_scratch.max(size);
                    }
                }
            }
        }
        // Try to claim an acknowledged recycled queue region first so memory
        // pressure never rejects a queue that needs zero fresh pages.
        let need_queue = if !firmware.lock().provisioned() {
            !device
                .runtime
                .lock()
                .provision_queue_recycled(&mut firmware.lock())?
        } else {
            false
        };
        let need_render_scratch = if max_render_scratch != 0 {
            vm.space
                .lock()
                .scratch_needs_prealloc(true, max_render_scratch)?
        } else {
            false
        };
        let need_compute_scratch = if computes != 0 {
            vm.compute_space
                .lock()
                .scratch_needs_prealloc(false, 0x28000)?
        } else {
            false
        };

        let alloc_pages = |count: usize| -> Result<KVec<crate::g16_vm::GpuPage>> {
            let mut pages = KVec::with_capacity(count, GFP_KERNEL)?;
            for _ in 0..count {
                pages
                    .push_within_capacity(crate::g16_vm::GpuPage::alloc(GFP_KERNEL | __GFP_ZERO)?)
                    .map_err(|_| EIO)?;
            }
            Ok(pages)
        };
        let mut prealloc_queue = if need_queue {
            alloc_pages(crate::g16::Bootstrap::QUEUE_INIT_PAGES)?
        } else {
            KVec::new()
        };
        let mut prealloc_tvb = if tvb {
            alloc_pages(crate::g16_tvb::Tvb::INIT_PAGES)?
        } else {
            KVec::new()
        };
        let mut prealloc_render_scratch = if need_render_scratch {
            alloc_pages(max_render_scratch / crate::pgtable::UAT_PGSZ)?
        } else {
            KVec::new()
        };
        let mut prealloc_compute_scratch = if need_compute_scratch {
            alloc_pages(0x28000 / crate::pgtable::UAT_PGSZ)?
        } else {
            KVec::new()
        };
        // Allocate every mandatory executable Work slot BEFORE growing optional
        // pipelining headroom so optional Work pages never starve mandatory
        // scratch or the other engine's first slot.
        let mut prealloc_render_work = if render_min_add != 0 {
            alloc_pages(render_min_add * 7)?
        } else {
            KVec::new()
        };
        let mut prealloc_compute_work = if compute_min_add != 0 {
            alloc_pages(compute_min_add * 2)?
        } else {
            KVec::new()
        };
        let grow_work_slots = |pages: &mut KVec<crate::g16_vm::GpuPage>,
                               min_add: usize,
                               want_add: usize,
                               pages_per_slot: usize|
         -> usize {
            let mut slots = min_add;
            for _ in min_add..want_add {
                if pages.reserve(pages_per_slot, GFP_KERNEL).is_err() {
                    break;
                }
                let start_len = pages.len();
                let mut ok = true;
                for _ in 0..pages_per_slot {
                    match crate::g16_vm::GpuPage::alloc(GFP_KERNEL | __GFP_ZERO) {
                        Ok(page) => {
                            let _ = pages.push_within_capacity(page);
                        }
                        Err(_) => {
                            ok = false;
                            break;
                        }
                    }
                }
                if !ok {
                    pages.truncate(start_len);
                    break;
                }
                slots += 1;
            }
            slots
        };
        let render_slots_alloc = grow_work_slots(
            &mut prealloc_render_work,
            render_min_add,
            render_work_add,
            7,
        );
        let render_work_target = if render_slots_alloc != 0 {
            render_owned + render_slots_alloc
        } else {
            0
        };
        let compute_slots_alloc = grow_work_slots(
            &mut prealloc_compute_work,
            compute_min_add,
            compute_work_add,
            2,
        );
        let compute_work_target = if compute_slots_alloc != 0 {
            compute_owned + compute_slots_alloc
        } else {
            0
        };

        if need_render_scratch {
            vm.space.lock().provision_scratch_prealloc(
                true,
                max_render_scratch,
                &mut prealloc_render_scratch,
            )?;
        }
        if need_compute_scratch {
            vm.compute_space.lock().provision_scratch_prealloc(
                false,
                0x28000,
                &mut prealloc_compute_scratch,
            )?;
        }
        if tvb || need_queue || render_work_target != 0 || compute_work_target != 0 {
            let mut runtime = device.runtime.lock();
            if runtime.render_failed() {
                return Err(EIO);
            }
            if need_queue {
                runtime.provision_queue(&mut firmware.lock(), &mut prealloc_queue)?;
            }
            if tvb {
                let support = vm.render_support.as_deref().ok_or(EIO)?;
                runtime.provision_tvb(&mut vm.space.lock(), support, &mut prealloc_tvb)?;
                vm.tvb_ready = true;
            }
            if render_work_target != 0 {
                let mut space = vm.space.lock();
                match runtime.provision_work(
                    &mut space,
                    true,
                    render_work_target,
                    &mut prealloc_render_work,
                ) {
                    Ok(()) => {}
                    // Optional pipelining growth failed, but at least one
                    // executable Work slot is already installed on this VM.
                    Err(err) if (err == ENOMEM || err == ENOSPC) && space.work_owned(true) != 0 => {
                    }
                    Err(err) => return Err(err),
                }
            }
            if compute_work_target != 0 {
                let mut space = vm.compute_space.lock();
                match runtime.provision_work(
                    &mut space,
                    false,
                    compute_work_target,
                    &mut prealloc_compute_work,
                ) {
                    Ok(()) => {}
                    Err(err)
                        if (err == ENOMEM || err == ENOSPC) && space.work_owned(false) != 0 => {}
                    Err(err) => return Err(err),
                }
            }
        }
        // Every submission retains the VM's mappings until it completes.
        // Share one copy until the mappings change: CS2-sized address spaces
        // hold thousands of mappings and submit hundreds of times a frame.
        let mappings = match &vm.snapshot {
            Some(snapshot) => snapshot.clone(),
            None => {
                let mut copy = KVVec::with_capacity(vm.mappings.len(), GFP_KERNEL)?;
                for mapping in &vm.mappings {
                    copy.push(mapping.clone(), GFP_KERNEL)?;
                }
                let snapshot = Arc::new(copy, GFP_KERNEL)?;
                vm.snapshot = Some(snapshot.clone());
                snapshot
            }
        };
        let bindings = Bindings {
            _mappings: mappings,
            _timestamps: timestamp_bindings,
        };
        vm.pending.reserve(1, GFP_KERNEL)?;
        if renders != 0 {
            vm.pending_render.reserve(1, GFP_KERNEL)?;
        }
        if computes != 0 {
            vm.pending_compute.reserve(1, GFP_KERNEL)?;
        }
        let completion = dma_fence::Fence::from_fence(&unique);
        let worker_completion = completion.clone();
        let execution = Arc::pin_init(
            try_pin_init!(Execution {
                id: NEXT_EXECUTION.fetch_add(1, Ordering::Relaxed), firmware, barriers,
                device: device.into(), _owner: inner.state.clone(), reaper: inner.reaper.clone(),
                render_space: vm.space.clone(), space: vm.compute_space.clone(), _bindings: bindings,
                support: vm.render_support.clone(),
                parameters, timestamps, completion: worker_completion,
                started: AtomicBool::new(false), trace, work <- new_work!("m4-execution"),
            }),
            GFP_KERNEL,
        )?;
        let vm = &mut state.vms[index];
        vm.pending
            .push_within_capacity(completion.clone())
            .map_err(|_| EIO)?;
        if renders != 0 {
            vm.pending_render
                .push_within_capacity(completion.clone())
                .map_err(|_| EIO)?;
        }
        if computes != 0 {
            vm.pending_compute
                .push_within_capacity(completion.clone())
                .map_err(|_| EIO)?;
        }
        let queue = state
            .queues
            .iter_mut()
            .find(|q| q.id == data.queue_id)
            .ok_or(ENOENT)?;
        let mut history = [KVec::new(), KVec::new()];
        // One entry per command (at most 64, checked above) plus the queue's
        // previous stamp: run_job and the worker never grow them.
        for events in &mut history {
            events.reserve(65, GFP_KERNEL)?;
        }
        let mut job = queue.entity.new_job(1, SubmissionJob { execution, history: Some(history) })?;
        for fence in dependencies {
            job.add_dependency(fence)?;
        }
        // No fallible operation follows output-fence publication.
        // Publish the hardware lifetime fence directly. Scheduler finished
        // fences can be downgraded to scheduled dependencies by DRM; our
        // external inputs must wait for actual hardware completion.
        let fence = completion.clone();
        admission.push(completion, GFP_KERNEL)?;
        let job = job.arm();
        for output in outputs {
            if let Some(chain) = output.chain {
                output.object.add_point(chain, &fence, output.point);
            } else {
                output.object.replace_fence(Some(&fence));
            }
        }
        job.push();
        Ok(0)
    }
}

impl Vm {
    pub(super) fn cover(&self, start: u64, size: u64, permissions: u32) -> Result {
        Mapping::cover(&self.mappings, start, size, permissions)
    }

    pub(super) fn compute_parameters(&self, c: &uapi::drm_asahi_cmd_compute) -> Result<compute::Parameters> {
        if c.flags != 0 || c.helper.binary != 0 || c.helper.cfg != 0 || c.helper.data != 0 {
            return Err(unsupported(format_args!("compute flags {:#x} or a helper program", c.flags)));
        }
        let size = c
            .cdm_ctrl_stream_end
            .checked_sub(c.cdm_ctrl_stream_base)
            .ok_or_else(|| reject(format_args!("compute stream end before base")))?;
        if (c.cdm_ctrl_stream_base | c.cdm_ctrl_stream_end) & 3 != 0
            || size < 4
            || c.sampler_heap & 7 != 0
            || c.sampler_count > 1024
            || (c.sampler_count == 0) != (c.sampler_heap == 0)
        {
            return Err(reject(format_args!("compute stream {:#x}..{:#x} or sampler heap {:#x} x {}", c.cdm_ctrl_stream_base, c.cdm_ctrl_stream_end, c.sampler_heap, c.sampler_count)));
        }
        self.cover(c.cdm_ctrl_stream_base, size, 2)?;
        if c.sampler_count != 0 {
            self.cover(c.sampler_heap, u64::from(c.sampler_count) * 8, 2)?;
        }
        Ok(compute::Parameters {
            tgid: kernel::current!().group_leader().pid(),
            comm: current_comm(),
            cdm: c.cdm_ctrl_stream_base,
            cdm_end: c.cdm_ctrl_stream_end,
            sampler: c.sampler_heap,
            sampler_count: c.sampler_count,
            scratch: compute::SCRATCH,
            marker: compute::MARKER,
            save_area: 0,
        })
    }

    pub(super) fn render_parameters(&self, c: &uapi::drm_asahi_cmd_render) -> Result<render::Parameters> {
        use uapi::{
            drm_asahi_render_flags_DRM_ASAHI_RENDER_DBIAS_IS_INT as DBIAS_IS_INT,
            drm_asahi_render_flags_DRM_ASAHI_RENDER_FEW_PRIMITIVES as FEW_PRIMITIVES,
            drm_asahi_render_flags_DRM_ASAHI_RENDER_NATIVE_MESH as NATIVE_MESH,
            drm_asahi_render_flags_DRM_ASAHI_RENDER_PROCESS_EMPTY_TILES as PROCESS_EMPTY_TILES,
            drm_asahi_render_flags_DRM_ASAHI_RENDER_VDM_BARRIER_FRAGMENT as VDM_BARRIER_FRAGMENT,
        };

        if c.flags
            & !(PROCESS_EMPTY_TILES
                | DBIAS_IS_INT
                | VDM_BARRIER_FRAGMENT
                | FEW_PRIMITIVES
                | NATIVE_MESH)
            != 0
            || c.vertex_helper.binary != 0
            || c.vertex_helper.cfg != 0
            || c.vertex_helper.data != 0
            || c.fragment_helper.binary != 0
            || c.fragment_helper.cfg != 0
            || c.fragment_helper.data != 0
        {
            return Err(unsupported(format_args!(
                "render flags {:#x} (known {:#x}) or a vertex/fragment helper program",
                c.flags,
                PROCESS_EMPTY_TILES
                    | DBIAS_IS_INT
                    | VDM_BARRIER_FRAGMENT
                    | FEW_PRIMITIVES
                    | NATIVE_MESH
            )));
        }
        let mesh = crate::g16_mesh::render_profile(
            self.native_mesh,
            c.flags & NATIVE_MESH != 0,
            c.flags & FEW_PRIMITIVES != 0,
        )
        .map_err(|reason| match reason {
            crate::g16_mesh::RenderReject::VmDisabled => reject(format_args!(
                "DRM_ASAHI_RENDER_NATIVE_MESH on a VM without native mesh enabled"
            )),
            crate::g16_mesh::RenderReject::FewPrimitivesConflict => reject(format_args!(
                "DRM_ASAHI_RENDER_NATIVE_MESH cannot be combined with DRM_ASAHI_RENDER_FEW_PRIMITIVES"
            )),
        })?;
        let mut p = render::Parameters::default();
        p.mesh = mesh;
        p.tgid = kernel::current!().group_leader().pid();
        p.comm = current_comm();
        p.vdm_barrier_fragment = c.flags & VDM_BARRIER_FRAGMENT != 0;
        p.set_private(self.kernel.start, self.kernel.end)
            .ok_or_else(|| reject(format_args!("render private area outside the kernel VA")))?;
        p.width = u64::from(c.width_px);
        p.height = u64::from(c.height_px);
        p.layers = u64::from(c.layers);
        p.utile_width = u64::from(c.utile_width_px);
        p.utile_height = u64::from(c.utile_height_px);
        p.samples = u64::from(c.samples);
        p.sample_size = u64::from(c.sample_size_B);
        p.tib_blocks = (p.sample_size * p.utile_width * p.utile_height * p.samples).div_ceil(2048);
        p.encoder = c.vdm_ctrl_stream_base;
        if !p.valid() || p.encoder == 0 || p.encoder & 3 != 0 {
            return Err(reject(format_args!("render parameters or encoder {:#x}", p.encoder)));
        }
        self.cover(p.encoder, 4, 2)?;
        p.utile_config = (p.utile_width / 16) << 12
            | (p.utile_height / 16) << 14
            | match p.samples {
                1 => 0,
                2 => 1,
                4 => 2,
                _ => return Err(reject(format_args!("render samples {}", p.samples))),
            };
        p.process_empty_tiles = c.flags & PROCESS_EMPTY_TILES != 0;
        p.tile_config =
            0x280 | u64::from(p.layers > 1) | if p.process_empty_tiles { 0x10000 } else { 0 };
        p.multisample_control = c.ppp_multisamplectl;
        p.ppp_control = u64::from(c.ppp_ctrl);
        p.merge_upper_x_bits = u64::from(c.isp_merge_upper_x);
        p.merge_upper_y_bits = u64::from(c.isp_merge_upper_y);
        // ISP control: bit 18 is the integer depth-bias formula (the UAPI flag
        // matches it). Bit 0 selects a faster fragment tile dispatch that is
        // only safe for passes with very few primitives; macOS sets it for at
        // most four statically known primitives per pass, and userspace
        // asserts the same bound with FEW_PRIMITIVES.
        p.aux_fb_flags = 0xc000
            | u64::from(c.flags & DBIAS_IS_INT)
            | u64::from(c.flags & FEW_PRIMITIVES != 0);
        p.aux_fb_page_count = 0x100000;
        p.scissor_array = c.isp_scissor_base;
        p.depth_bias_array = c.isp_dbias_base;
        p.occlusion_query_base = c.isp_oclqry_base;
        if p.scissor_array == 0 {
            return Err(reject(format_args!("render without a scissor array")));
        }
        for (address, access) in [
            (p.scissor_array, 2),
            (p.depth_bias_array, 2),
            (p.occlusion_query_base, 4),
        ] {
            if address != 0 {
                if address & 7 != 0 {
                    return Err(reject(format_args!("render array {:#x} unaligned", address)));
                }
                self.cover(address, 8, access)?;
            }
        }
        for zls in [&c.depth, &c.stencil] {
            if (zls.base == 0 && (zls.comp_base != 0 || zls.stride != 0 || zls.comp_stride != 0))
                || (zls.comp_base == 0 && zls.comp_stride != 0)
                || (p.layers > 1 && zls.base != 0 && zls.stride == 0)
                || (zls.stride != 0 && zls.stride & 0x3fff != 1)
                || zls.comp_stride & 0x3fff != 0
            {
                return Err(reject(format_args!("render depth/stencil base {:#x} stride {:#x} comp stride {:#x} layers {}", zls.base, zls.stride, zls.comp_stride, p.layers)));
            }
            if zls.base != 0 {
                let stride = if zls.stride == 0 {
                    0
                } else {
                    (u64::from(zls.stride >> 14) + 1) * 0x4000
                };
                self.cover(zls.base, stride * (p.layers - 1) + 1, 6)?;
            }
            if zls.comp_base != 0 {
                self.cover(
                    zls.comp_base,
                    (u64::from(zls.comp_stride >> 14) + 1) * 0x80 * (p.layers - 1) + 1,
                    6,
                )?;
            }
        }
        p.depth_buffer = c.depth.base;
        p.depth_aux_buffer = c.depth.comp_base;
        p.depth_stride = u64::from(c.depth.stride);
        p.depth_aux_stride = u64::from(c.depth.comp_stride);
        p.stencil_buffer = c.stencil.base;
        p.stencil_aux_buffer = c.stencil.comp_base;
        p.stencil_stride = u64::from(c.stencil.stride);
        p.stencil_aux_stride = u64::from(c.stencil.comp_stride);
        p.depth_flags = c.zls_ctrl;
        p.depth_dimensions = u64::from(c.isp_zls_pixels);
        p.depth_clear_value_bits = u64::from(c.isp_bgobjdepth);
        p.stencil_clear_value = u64::from(c.isp_bgobjvals);
        p.sampler_array = c.sampler_heap;
        p.sampler_count = u64::from(c.sampler_count);
        if !p.valid() || p.sampler_count > 1024 {
            return Err(reject(format_args!("render parameters or {} samplers", p.sampler_count)));
        }
        if p.sampler_count != 0 {
            self.cover(p.sampler_array, p.sampler_count * 8, 2)?;
        }
        for (program, optional) in [
            (&c.bg, true),
            (&c.eot, false),
            (&c.partial_bg, c.bg.usc == 0),
            (&c.partial_eot, false),
        ] {
            if program.usc == 0 {
                if !optional || program.rsrc_spec != 0 {
                    return Err(reject(format_args!("render background/end-of-tile program missing or with resources")));
                }
            } else {
                self.cover((1 << 40) + u64::from(program.usc & !7), 4, 2)?;
            }
        }
        let pipeline = |v: u32| if v == 0 { 0 } else { (1 << 40) + u64::from(v) };
        let load_bind = |v: &uapi::drm_asahi_bg_eot| {
            if v.usc == 0 {
                0
            } else {
                0xffff800000000000 | u64::from(v.rsrc_spec)
            }
        };
        p.load_pipeline = pipeline(c.bg.usc);
        p.load_pipeline_bind = load_bind(&c.bg);
        p.partial_load_pipeline = pipeline(c.partial_bg.usc);
        p.partial_load_pipeline_bind = load_bind(&c.partial_bg);
        p.store_pipeline = pipeline(c.eot.usc);
        p.store_pipeline_bind = u64::from(c.eot.rsrc_spec);
        p.partial_store_pipeline = pipeline(c.partial_eot.usc);
        p.partial_store_pipeline_bind = u64::from(c.partial_eot.rsrc_spec);
        p.request_tvb_growth = true;
        p.tiling_admission = 7;
        p.fragment_admission = 7;
        p.cycle = 0x240030;
        p.tiling_gate = 0xa900400020;
        p.fragment_gate = 0xd500400020;
        p.tiling_lifecycle = 0x08009f520900a6bb;
        p.fragment_lifecycle = 0x08009f520900a6ba;
        p.tiling_work_stamp = 0x120;
        p.fragment_work_stamp = 0x121;
        // macOS writes 0-3 (3 solo, mostly 1 under contention); this driver's
        // original value is 4.
        p.completion_control = 4;
        p.layermeta = p.heapmeta;
        if p.layers > 1 {
            p.heapmeta += 0x100;
        }
        Ok(p)
    }
}

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host checks of G16 firmware read fastpath:
- Outer-Shareable acquire barrier (`dmb oshld`, ARM64 `dma_rmb()`) without
  `nomem`/`readonly` compiler constraints.
- Acquire-scoped `FirmwareReader` eliminates per-u32 `dsb sy` and repeated
  RBTree lookups while preserving bounds/alignment checks, `P_READ` profiling
  attribution, and no-allocation guarantees.
- Producer-cursor -> ring-entry and completion -> storage-reuse acquire
  boundaries are enforced at every hot read site.
"""
from pathlib import Path
import re

root = next(p for p in Path(__file__).resolve().parents
            if (p / 'drivers/gpu/drm/asahi/g16_vm.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'
mem = (driver / 'm4_mem.rs').read_text()
vm = (driver / 'g16_vm.rs').read_text()
retire = (driver / 'g16_runtime_retire.rs').read_text()
contexts = (driver / 'g16_runtime_contexts.rs').read_text()
publish = (driver / 'g16_runtime_publish.rs').read_text()
render = (driver / 'g16_runtime_render.rs').read_text()
compute = (driver / 'g16_runtime_compute.rs').read_text()
diag = (driver / 'g16_runtime_diag.rs').read_text()


def function(source, name):
    m = re.search(r'\n(\s*)(?:pub\((?:crate|super)\) )?fn ' + re.escape(name) + r'\b', source)
    assert m, name
    indent = m.group(1).lstrip('\n')
    end = re.search(r'\n' + indent + r'}\n', source[m.end():])
    return source[m.start():m.end() + end.end()]


checks = 0

# 1. dma_rmb() uses dmb oshld and acts as a full compiler memory barrier.
dma_rmb = function(mem, 'dma_rmb')
assert '"dmb oshld"' in dma_rmb
assert 'nomem' not in dma_rmb and 'readonly' not in dma_rmb
checks += 1

# 2. FirmwareReader: entry acquire barrier, zero dsb sy in relaxed reads,
# alignment + bounds checked, P_READ preserved, zero allocation.
reader_fn = function(vm, 'reader')
assert 'self.acquire_barrier();' in reader_fn
read_u32_rel = function(vm, 'read_u32_relaxed')
read_slice_rel = function(vm, 'read_slice_relaxed')
for fn_body in (read_u32_rel, read_slice_rel):
    assert 'dsb' not in fn_body
    assert 'va & 3 != 0' in fn_body
    assert 'P_READ' in fn_body
    assert 'read_volatile' in fn_body
    assert 'GFP_KERNEL' not in fn_body and 'KVec::' not in fn_body
checks += 1

# 3. retire(): single FirmwareReader for the scan, no per-word fw.read_u32(),
# and explicit acquire_barrier() before returning retired flights.
retire_fn = function(retire, 'retire')
assert 'fw.read_u32(' not in retire_fn
assert 'reader.read_u32_relaxed(' in retire_fn
assert re.search(r'if !self\.retired\.is_empty\(\) \{\s*reader\.acquire_barrier\(\);\s*\}', retire_fn)
checks += 1

# 4. service_flights(): acquire_barrier() after reading producer cursor `end`
# and before reading event-ring entries, with batched kind-1 STATE updates.
sf_fn = function(retire, 'service_flights')
end_pos = sf_fn.index('reader.read_u32_relaxed(STATE + 0x20)?')
acq_pos = sf_fn.index('reader.acquire_barrier();', end_pos)
kind_pos = sf_fn.index('reader.read_u32_relaxed(base)?', acq_pos)
assert end_pos < acq_pos < kind_pos
assert 'dirty_cursor = Some(cursor);' in sf_fn
checks += 1

# 5. drain_trace_rx(): single reader for all 8 trace rings, acquire_barrier()
# before reading 0x3f3c0 trace-ring entries, no per-ring fw.read_u32().
dtr_fn = function(contexts, 'drain_trace_rx')
assert 'fw.read_u32(' not in dtr_fn and 'fw.read_u64(' not in dtr_fn
w_pos = dtr_fn.index('reader.read_u32_relaxed(state + 0x20)?')
a_pos = dtr_fn.index('reader.acquire_barrier();', w_pos)
e_pos = dtr_fn.index('0xffff_fc20_000e_5c40', a_pos)
assert w_pos < a_pos < e_pos
checks += 1

# 6. reserve_flight(), check_wedge(), resolve_compute_dependencies(), and
# submit_render() avoid per-word fw.read_u32() (hot read paths use FirmwareReader).
rf_fn = function(publish, 'reserve_flight')
assert 'fw.read_u32(' not in rf_fn and 'reader.read_u32_relaxed(lane.pointers)' in rf_fn
cw_fn = function(diag, 'check_wedge')
assert 'fw.read_u32(' not in cw_fn and 'reader.read_u32_relaxed(' in cw_fn
rcd_fn = function(compute, 'resolve_compute_dependencies')
assert 'fw.read_u32(' not in rcd_fn and 'r.read_u32_relaxed(dep.address)' in rcd_fn
sr_fn = function(render, 'submit_render')
assert 'fw.read_u32(' not in sr_fn
checks += 1

# 7. dma_wmb() and dsb_oshst() use Outer-Shareable store barriers without
# nomem/readonly constraints.
dma_wmb = function(mem, 'dma_wmb')
assert '"dmb oshst"' in dma_wmb and 'nomem' not in dma_wmb and 'readonly' not in dma_wmb
dsb_oshst = function(mem, 'dsb_oshst')
assert '"dsb oshst"' in dsb_oshst and 'nomem' not in dsb_oshst and 'readonly' not in dsb_oshst
checks += 1

# 8. FirmwareWriter: zero per-write barriers, single-copy volatile stores for
# aligned u32/u64, P_LIVE timed once per writer(), zero allocations.
writer_fn = function(vm, 'writer')
assert 'P_LIVE' in writer_fn
for name in ('write_staged', 'write_u32_staged', 'write_u64_staged'):
    body = function(vm, name)
    assert 'dsb' not in body and 'dmb' not in body
    assert 'GFP_KERNEL' not in body and 'KVec::' not in body
assert 'va & 3 != 0' in function(vm, 'write_u32_staged')
assert 'write_volatile' in function(vm, 'write_u32_staged')
assert 'va & 7 != 0' in function(vm, 'write_u64_staged')
assert 'write_volatile' in function(vm, 'write_u64_staged')
checks += 1

# 9. Hot submission & flush paths use staged writes with zero write_live/zero_live.
for name, src in [('publish_render', render), ('submit_render_pool', render),
                  ('submit_compute_queue', compute), ('flush', publish)]:
    body = function(src, name)
    assert 'write_live(' not in body and 'zero_live(' not in body, name
checks += 1

# 10. flush() orders release_barrier() -> lane heads & channel entries ->
# crate::mem::sync() -> MMIO channel tails -> crate::mem::sync() -> RTKit kick.
flush_fn = function(publish, 'flush')
rel_pos = flush_fn.index('fw.release_barrier();')
head_pos = flush_fn.index('writer.write_u32_staged(p.lane.pointers + 0x40, p.lane.head)?')
sync1_pos = flush_fn.index('crate::mem::sync();', head_pos)
mmio_pos = flush_fn.index('guard.try_write32(', sync1_pos)
sync2_pos = flush_fn.index('crate::mem::sync();', mmio_pos)
kick_pos = flush_fn.index('send_message(', sync2_pos)
assert rel_pos < head_pos < sync1_pos < mmio_pos < sync2_pos < kick_pos
checks += 1

# 11. Compute save_area lives in dedicated client scratch (cleared by
# lease_scratch) rather than on the GPU-read-only firmware Work control page.
scq_fn = function(compute, 'submit_compute_queue')
assert 'save_area = alias' not in scq_fn
assert 'zero_staged(a.work + 0x2000' not in scq_fn
assert 'p.save_area = base + 0x24000;' in function(vm, 'prepare_compute')
checks += 1

# 12. RX consumer cursor updates order acquire_barrier() -> write_u32_staged() -> dsb_oshst().
for body in (sf_fn, dtr_fn):
    a_p = body.rindex('fw.acquire_barrier();')
    w_p = body.index('write_u32_staged(', a_p)
    d_p = body.index('crate::mem::dsb_oshst();', w_p)
    assert a_p < w_p < d_p
checks += 1

# 13. Fast headroom helpers never allocate.
for name in ('cap_state', 'check_cap_headroom', 'check_queue_headroom'):
    body = function(publish, name)
    assert 'GFP_KERNEL' not in body and 'KVec::' not in body, name
checks += 1

print(f'test-fw-fastpath: {checks} checks passed')

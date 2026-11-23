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
# submit_render() native-mesh CPU-hold all use FirmwareReader.
rf_fn = function(publish, 'reserve_flight')
assert 'fw.read_u32(' not in rf_fn and 'reader.read_u32_relaxed(lane.pointers)' in rf_fn
cw_fn = function(diag, 'check_wedge')
assert 'fw.read_u32(' not in cw_fn and 'reader.read_u32_relaxed(' in cw_fn
rcd_fn = function(compute, 'resolve_compute_dependencies')
assert 'fw.read_u32(' not in rcd_fn and 'r.read_u32_relaxed(dep.address)' in rcd_fn
sr_fn = function(render, 'submit_render')
assert 'fw.read_u32(' not in sr_fn
mesh_stamp_pos = sr_fn.index('reader.read_u32_relaxed(dep.address)?')
mesh_acq_pos = sr_fn.index('reader.acquire_barrier();', mesh_stamp_pos)
mesh_decode_pos = sr_fn.index('g16_mesh::decode(', mesh_acq_pos)
assert mesh_stamp_pos < mesh_acq_pos < mesh_decode_pos
checks += 1

print(f'test-fw-fastpath: {checks} checks passed')

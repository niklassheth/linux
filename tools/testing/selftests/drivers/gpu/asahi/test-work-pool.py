#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 per-VM Work slot ownership and recycling (g16_work_pool.rs):
- Work slots and their GPU alias PTEs never cross VM boundaries.
- Reused Work slots within a VM take the zero-PTE-edit fast path.
- VM teardown unmaps aliases, invalidates context 0, frees firmware backing,
  and reclaims only the unbacked firmware VA.
- Shared-notifier owner Work slots return strictly to their owning VM.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_work_pool.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

source = f'''#![allow(dead_code)]
#[path = "{driver / 'g16_work_pool.rs'}"] mod g16_work_pool;
''' + here.with_name('work-pool.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-work-pool-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

vm = (driver / 'g16_vm.rs').read_text()
queues = (driver / 'g16_runtime_queues.rs').read_text()
contexts = (driver / 'g16_runtime_contexts.rs').read_text()
retire = (driver / 'g16_runtime_retire.rs').read_text()
runtime = (driver / 'g16_runtime.rs').read_text()

# Device-wide Work free list is gone; Work aliases reject any pre-existing PTE
# and map strictly GPU read-only so clients cannot write firmware control data.
assert not re.search(r'\bfree_work:', (driver / 'g16.rs').read_text())
assert 'if self.low.translate(va)?.is_some() {\n            return Err(EEXIST);' in vm
mwa = vm[vm.index('pub(crate) fn map_work_alias_gfp('):vm.index('pub(crate) fn unmap_work_alias_gfp(')]
assert 'prot::PROT_GPU_SHARED_RO' in mwa and 'PROT_GPU_SHARED_RW' not in mwa
assert 'self.owned_bytes + self.work_pool.owned_bytes()' in vm

# allocate_work in the pump worker never allocates; SUBMIT provisions slots
# before fence publication using preallocated pages + GFP_NOWAIT under locks,
# bumps retire_gen to invalidate cached CapBlock EBUSY, and rollback checks
# !fw.has_region before VA reuse.
alloc_fn = queues[queues.index('pub(super) fn allocate_work('):queues.index('pub(super) fn release_work_counted(')]
assert 'if let Some(va) = client.pop_free_work(render)' in alloc_fn
assert 'GFP_KERNEL' not in alloc_fn and '.reserve(' not in alloc_fn and 'fw.alloc(' not in alloc_fn
prov_fn = queues[queues.index('fn provision_one_work_slot('):queues.index('pub(super) fn allocate_work(')]
assert 'GFP_NOWAIT | __GFP_NOWARN' in prov_fn and 'GFP_KERNEL' not in prov_fn
assert 'self.retire_gen = self.retire_gen.wrapping_add(1);' in prov_fn
assert 'if !fw.has_region(va)' in prov_fn

# VM teardown detaches contexts, requires all Work slots idle, removes each
# slot from circulation via take_teardown_work BEFORE the first destructive
# unmap, invalidates context 0, releases firmware regions, and only then
# returns the unbacked VA.
rel = contexts[contexts.index('pub(crate) fn release_render_vm('):]
assert rel.index('!space.work_pool_all_idle()') < rel.index('self.set_context(index, None)?')
assert rel.index('space.take_teardown_work(render)') < rel.index('space.unmap_work_alias_gfp(')
assert rel.index('space.unmap_work_alias_gfp(') < rel.index('fw.release_region_gfp(va, gfp)?')
assert rel.index('self.invalidate_client(dev_space);') < rel.index('fw.release_region_gfp(va, gfp)?')
assert rel.index('fw.release_region_gfp(va + priv_size, gfp)?') < rel.index('self.free_work_va[index]')

# JobNotifier retains owner_client so retired owner slots return strictly to it.
assert 'owner_client: Arc<Mutex<g16_vm::AddressSpace>>' in runtime
assert 'Self::release_work_counted(&mut self.vm_free_work, &mut client, render_work, va)?;' in retire
print('test-work-pool: ok')

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 RAII preparation lease rollback (PrepGuard):
- Any `?` error after prepare_render/prepare_compute or allocate_work (such as
  ENOMEM or acquire_context EBUSY) automatically releases Scratch and Work via
  Drop.
- Poisoned runtimes keep both leases quarantined on Drop.
- AddressSpace::prepare_render releases Scratch on write_low failure and
  release_scratch never allocates (uses push_within_capacity).
"""
from pathlib import Path
import os
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_work_pool.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

source = f'''#![allow(dead_code)]
#[path = "{driver / 'g16_work_pool.rs'}"] mod g16_work_pool;
''' + here.with_name('prep-rollback.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-prep-rollback-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

vm = (driver / 'g16_vm.rs').read_text()
compute = (driver / 'g16_runtime_compute.rs').read_text()
render = (driver / 'g16_runtime_render.rs').read_text()

# Both compute and render wrap pre-publication prep in PrepGuard and commit
# right before `self.render_failed = true;`.
for src in (compute, render):
    assert 'PrepGuard::new(&mut sink,' in src
    assert 'prep.set_scratch(scratch);' in src
    assert 'prep.set_work(' in src
    assert src.index('prep.commit()') < src.index('self.render_failed = true;')

# AddressSpace::prepare_render rolls back scratch on write_low error,
# lease_scratch and provision_scratch_prealloc use GFP_NOWAIT | __GFP_NOWARN
# (never entering direct reclaim in the pump worker or under VM locks) and call
# prepare_map_gfp before advancing the arena, and release_scratch never allocates.
pr = vm[vm.index('pub(crate) fn prepare_render('):vm.index('pub(crate) fn alloc_compute_pool(')]
assert 'let _ = self.release_scratch(scratch);' in pr
ps = vm[vm.index('pub(crate) fn provision_scratch_prealloc('):vm.index('fn lease_scratch(')]
assert 'GFP_NOWAIT | __GFP_NOWARN' in ps and 'GFP_KERNEL' not in ps
assert ps.index('self.low.prepare_map_gfp(range.clone(), gfp)?') < ps.index('self.render_arena = next_arena;')
ls = vm[vm.index('fn lease_scratch('):vm.index('pub(crate) fn release_scratch(')]
assert 'GFP_NOWAIT | __GFP_NOWARN' in ls and 'GFP_KERNEL' not in ls
assert ls.index('self.low.prepare_map_gfp(range.clone(), gfp)') < ls.index('self.render_arena = next_arena;')
assert ls.index('GpuPage::alloc(gfp | __GFP_ZERO)') < ls.index('self.render_arena = next_arena;')
rs = vm[vm.index('pub(crate) fn release_scratch('):vm.index('pub(crate) fn tvb_va_blocks(')]
assert 'push_within_capacity(range)' in rs and 'GFP_KERNEL' not in rs

print('test-prep-rollback: ok')

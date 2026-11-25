#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host source checks: G16 publication does not allocate, and the SUBMIT
ioctl provisions first-use resources before it queues a job.

Publication runs in the job worker, which signals completion fences: a
GFP_KERNEL allocation there can recurse into reclaim that waits on those
fences, and a failure there can only fail the queue after SUBMIT returned.
No device or kernel build is needed.
"""
from pathlib import Path
import re

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_runtime.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'
runtime = ''.join(p.read_text() for p in sorted(driver.glob('g16_runtime*.rs')))
vm = (driver / 'g16_vm.rs').read_text()
drm = ''.join(p.read_text() for p in sorted(driver.glob('g16_drm*.rs')))
render = (driver / 'g16_render.rs').read_text()
compute = (driver / 'g16_compute.rs').read_text()


def function(source, name):
    """The body of `fn name`, up to the next item at the same indentation."""
    m = re.search(r'\n(\s*)(?:pub\((?:crate|super)\) )?fn ' + name + r'\b', source)
    assert m, name
    indent = m.group(1).lstrip('\n')
    end = re.search(r'\n' + indent + r'}\n', source[m.end():])
    return source[m.start():m.end() + end.end()]


checks = 0
# Every step of publishing a render or compute Work, and the firmware batch
# write it uses.
for source, name in [(runtime, 'submit_render_pool'), (runtime, 'publish_render'),
                     (runtime, 'submit_compute_queue'), (runtime, 'submit_render'),
                     (runtime, 'submit_render_queue'), (runtime, 'submit_compute'),
                     (runtime, 'allocate_work'),
                     (vm, 'write_staged'), (vm, 'write_u32_staged'),
                     (vm, 'write_u64_staged'),
                     (vm, 'update_batch')]:
    body = function(source, name)
    assert 'GFP_KERNEL' not in body, f'{name} allocates'
    assert not re.search(r'\bKVec::(new|with_capacity)\b', body), f'{name} builds a vector'
    checks += 1

# The reusable encodings match the builders' required lengths.
encodings = re.search(r'impl Encodings \{.*?\n\}\n', runtime, re.S).group(0)
sizes = dict(re.findall(r'encodings\.(\w+)\.extend_with\((0x[0-9a-f]+)', encodings))
assert sizes == {'tiling': '0x940', 'fragment': '0xcc0', 'compute': '0x8c0'}, sizes
assert 'out.len() != 0x940' in function(render, 'tiling_work')
assert 'out.len() != 0xcc0' in function(render, 'fragment_work')
assert 'out.len() != 0x8c0' in function(compute, 'work')
checks += 1

# Encodings leave the runtime only around one publication and always return.
queue = function(runtime, 'submit_render_queue')
take = queue.index('core::mem::take(&mut self.encodings)')
pool = queue.index('self.submit_render_pool(', take)
restore = queue.index('self.encodings = encodings;', pool)
assert '?' not in queue[take:restore].replace('result', ''), 'an early return loses the encodings'
checks += 1

# The ioctl provisions the queue's rings and the VM root's TVB pool before it
# creates the job, so their failures return from SUBMIT with nothing queued.
submit = function(drm, 'submit')
provision = submit.index('runtime.provision_queue(')
tvb = submit.index('runtime.provision_tvb(')
work = submit.index('runtime.provision_work(')
job = submit.index('.new_job(')
assert provision < job and tvb < job and work < job
assert 'vm.tvb_ready = true' in submit[tvb:job]
checks += 1

# Publication finds them: the worker's TVB lookup is the shared helper, and
# prepare_queues / provision_queue / provision_tvb / publish_support never
# enter GFP_KERNEL reclaim under device.runtime.
assert 'self.tvb_pool(client, support)?' in queue
lanes = function(runtime, 'prepare_lanes')
assert 'if owner.lanes.is_none()' in lanes
assert 'self.prepare_lanes_prealloc(owner, prealloc)' in function(runtime, 'provision_queue')
for name in ('publish_support', 'provision_queue', 'provision_tvb', 'tvb_pool',
             'init_queues', 'recycle_queues', 'reserve_timestamp',
             'map_timestamp', 'release_timestamp', 'dump_hang_state',
             'set_lane_event', 'print_lane_events'):
    assert 'GFP_KERNEL' not in function(runtime, name), f'{name} enters reclaim under runtime lock'
assert 'GFP_KERNEL' not in function(vm, 'alloc_tvb_blocks')
assert 'GFP_KERNEL' not in function(vm, 'fill_render_pool_pages')
assert 'GFP_KERNEL' not in function(drm, 'unmap')
assert 'prepare_map_prealloc_gfp' in function(drm, 'map')
assert 'let pool_res = { vm.compute_space.lock().alloc_compute_pool(buffers) };' in submit
assert 'prepare_map_gfp' in function(vm, 'alloc_tvb_blocks')
assert 'map_pages_gfp' in function(vm, 'alloc_tvb_blocks')
assert 'scratch_needs_prealloc' in submit
assert submit.index('scratch_needs_prealloc') < submit.index('let alloc_pages')
checks += 1

# Retirement and the retire log never allocate: capacity is set at init.
assert 'retire_log.reserve' not in runtime
assert re.search(r'retire_log: KVec::with_capacity\(render_runtime::RETIRE_LOG, GFP_KERNEL\)',
                 (driver / 'g16.rs').read_text())
checks += 1

print(f'test-prep-ioctl: {checks} checks passed')

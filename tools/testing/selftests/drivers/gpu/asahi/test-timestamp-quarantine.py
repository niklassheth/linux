#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 timestamp fault quarantine:
- reserve_timestamp(), map_timestamp(), and release_timestamp() all refuse
  operations with EIO while runtime.render_failed is true.
- bind_object() (BIND and UNBIND) and File::drop() also check device.failed
  under the runtime mutex so a scheduler timeout cannot unmap or recycle a
  timestamp firmware VA before the pump poisons runtime.
- Failed UNBIND retains the TimestampBuffer in retained_timestamps so backing
  pages stay pinned until reset.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_runtime_contexts.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

contexts = (driver / 'g16_runtime_contexts.rs').read_text()
ioctl = (driver / 'g16_drm_ioctl.rs').read_text()
drm = (driver / 'g16_drm.rs').read_text()


def function(source, name):
    m = re.search(r'\n(\s*)(?:pub\((?:crate|super)\) )?fn ' + re.escape(name) + r'\b', source)
    assert m, name
    indent = m.group(1).lstrip('\n')
    end = re.search(r'\n' + indent + r'}\n', source[m.end():])
    return source[m.start():m.end() + end.end()]


# 1. All three runtime timestamp primitives refuse when self.render_failed is true,
#    before touching FirmwareSpace or timestamp_ranges.
for fn_name in ('reserve_timestamp', 'map_timestamp', 'release_timestamp'):
    body = function(contexts, fn_name)
    guard = re.search(r'if self\.render_failed \{\s*return Err\(EIO\);\s*\}', body)
    assert guard, f'missing render_failed guard in {fn_name}'
    if 'unmap_external' in body:
        assert guard.start() < body.index('unmap_external')
    if 'map_external' in body:
        assert guard.start() < body.index('map_external')
    if 'timestamp_ranges' in body:
        assert guard.start() < body.index('timestamp_ranges')

# 2. bind_object() checks device.failed under runtime.lock() on both BIND and UNBIND,
#    and only removes retained_timestamps after release_timestamp() succeeds.
bo = function(ioctl, 'bind_object')
bind_arm, unbind_arm = bo.split('DRM_ASAHI_BIND_OBJECT_OP_UNBIND', 1)
bind_lock = bind_arm.index('let mut runtime = device.runtime.lock();')
bind_fail = bind_arm.index('device.failed.load(Ordering::Acquire)', bind_lock)
assert bind_lock < bind_fail < bind_arm.index('runtime.reserve_timestamp(', bind_lock)
assert unbind_arm.index('let mut runtime = device.runtime.lock();') < unbind_arm.index('device.failed.load(Ordering::Acquire)')
assert unbind_arm.index('device.failed.load(Ordering::Acquire)') < unbind_arm.index('runtime.release_timestamp(')
assert unbind_arm.index('runtime.release_timestamp(') < unbind_arm.index('state.retained_timestamps.swap_remove(')

# 2b. vm_create() refuses on a failed device before allocating AddressSpaces.
vc = function(ioctl, 'vm_create')
assert vc.index('device.failed.load(Ordering::Acquire)') < vc.index('AddressSpace::new()')

# 2c. vm_destroy() withdraws visibility before drain_vm() and detach().
vd = function(ioctl, 'vm_destroy')
assert vd.index('state.vms[index].visible = false;') < vd.index('drain_vm(')

# 3. File::drop() filters never-published VMs and clears state.timestamps on
#    drain-timeout, faulted close, and healthy close (after drop(runtime)).
fdrop = drm[drm.index('impl PinnedDrop for File'):drm.index('static FENCE_KEY')]
assert fdrop.count('state.timestamps.clear();') >= 3
assert 'retain(|vm| !vm.pending.is_empty() || vm.has_firmware_state())' in fdrop
lock_pos = fdrop.index('let mut runtime = self.device.runtime.lock();')
guard_pos = fdrop.index('self.device.failed.load(Ordering::Acquire) || runtime.render_failed()', lock_pos)
retain_pos = fdrop.index('state.vms.retain(|vm| vm.has_firmware_state());', guard_pos)
non_empty_pos = fdrop.index('!state.vms.is_empty() || !state.retained_timestamps.is_empty()', retain_pos)
detach_pos = fdrop.index('.detach(&self.device, &mut runtime)', non_empty_pos)
rel_pos = fdrop.index('.release_timestamp(', detach_pos)
drop_rt_pos = fdrop.index('drop(runtime);', rel_pos)
clear_ts_pos = fdrop.index('state.timestamps.clear();', drop_rt_pos)
trunc_vm_pos = fdrop.index('state.vms.truncate(keep_vms);', clear_ts_pos)
trunc_ts_pos = fdrop.index('state.retained_timestamps.truncate(keep_timestamps);', trunc_vm_pos)
assert lock_pos < guard_pos < retain_pos < non_empty_pos < detach_pos < rel_pos < drop_rt_pos < clear_ts_pos < trunc_vm_pos < trunc_ts_pos

# 4. Behavioral Rust test modeling the quarantine state machine across faulted
#    unbind + rebind attempts.
rust_test = r'''
use std::ops::Range;

struct TimestampRuntime {
    render_failed: bool,
    device_failed: bool,
    ranges: Vec<Range<u64>>,
    mapped: Vec<Range<u64>>,
}

impl TimestampRuntime {
    fn new() -> Self {
        Self { render_failed: false, device_failed: false, ranges: Vec::new(), mapped: Vec::new() }
    }
    fn reserve_and_map(&mut self, size: u64) -> Result<Range<u64>, &'static str> {
        if self.device_failed || self.render_failed {
            return Err("EIO");
        }
        let mut base = 0xffff_fc21_0000_0000u64;
        for r in &self.ranges {
            if base + size <= r.start { break; }
            base = base.max(r.end);
        }
        let r = base..base + size;
        self.ranges.push(r.clone());
        self.ranges.sort_by_key(|x| x.start);
        self.mapped.push(r.clone());
        Ok(r)
    }
    fn release(&mut self, range: &Range<u64>) -> Result<(), &'static str> {
        if self.device_failed || self.render_failed {
            return Err("EIO");
        }
        self.mapped.retain(|r| r != range);
        self.ranges.retain(|r| r != range);
        Ok(())
    }
}

#[test]
fn fault_quarantines_timestamp_va_and_backing() {
    let mut rt = TimestampRuntime::new();
    let mut retained = Vec::new();

    let r1 = rt.reserve_and_map(0x4000).unwrap();
    retained.push(r1.clone());

    // Normal unbind before any fault releases VA and backing cleanly.
    let r2 = rt.reserve_and_map(0x4000).unwrap();
    retained.push(r2.clone());
    assert_eq!(rt.release(&r2), Ok(()));
    retained.retain(|r| r != &r2);
    assert_eq!(rt.ranges, vec![r1.clone()]);

    // Pipeline failure poisons runtime: unbind of r1 MUST fail and preserve
    // both the reserved VA range, its firmware mapping, and retained backing.
    rt.render_failed = true;
    assert_eq!(rt.release(&r1), Err("EIO"));
    assert_eq!(rt.ranges, vec![r1.clone()]);
    assert_eq!(rt.mapped, vec![r1.clone()]);
    assert_eq!(retained, vec![r1.clone()]);

    // Subsequent bind while poisoned MUST also fail (no VA reuse).
    assert_eq!(rt.reserve_and_map(0x4000), Err("EIO"));

    // Scheduler timeout (device_failed before runtime.poison) also quarantines.
    rt.render_failed = false;
    rt.device_failed = true;
    assert_eq!(rt.release(&r1), Err("EIO"));
    assert_eq!(rt.reserve_and_map(0x4000), Err("EIO"));
    assert_eq!(rt.mapped, vec![r1]);
}
'''

with tempfile.TemporaryDirectory(prefix='asahi-ts-quarantine-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(rust_test)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

print('test-timestamp-quarantine: ok')

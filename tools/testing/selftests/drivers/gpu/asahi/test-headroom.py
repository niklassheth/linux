#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 O(1) admission headroom pre-check, exact Ledger-aligned
cap checks, atomic CapPair updates (g16_headroom.rs), and pump/submit wiring:
- QUEUE_CAP and LANE_CAP deferrals bail before VM locks, native-mesh decode,
  dependency resolution, MMIO, or firmware cursor reads, and skip retrying in
  the pump until a flight retires or a cap knob changes.
- Empty queues always make forward progress even under queue_cap=1 / lane_cap=1.
- Concurrent debugfs writes to queue_cap / lane_cap use atomic CapPair CAS and
  can never produce (0, 0).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_headroom.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

source = f'''#![allow(dead_code)]
#[path = "{driver / 'g16_headroom.rs'}"] mod g16_headroom;
''' + here.with_name('headroom.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-headroom-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

publish = (driver / 'g16_runtime_publish.rs').read_text()
render = (driver / 'g16_runtime_render.rs').read_text()
compute = (driver / 'g16_runtime_compute.rs').read_text()
retire = (driver / 'g16_runtime_retire.rs').read_text()
pump = (driver / 'g16_drm_pump.rs').read_text()
timeline = (driver / 'g16_timeline.rs').read_text()

# Atomic CapPair replaces separate QUEUE_CAP / LANE_CAP atomics.
assert 'pub(crate) static CAPS: crate::g16_headroom::CapPair' in timeline
assert 'CAPS.update_lane(value)' in timeline and 'CAPS.update_queue(value)' in timeline
assert 'crate::g16_timeline::CAPS.load()' in publish

# submit_render checks headroom with a consistent cap snapshot before
# owner.lock() and dep resolution, and passes the same cap into reserve_flight.
sr = render[render.index('pub(crate) fn submit_render('):render.index('pub(super) fn submit_render_queue(')]
assert sr.index('let cap = self.cap_state();') < sr.index('self.check_cap_headroom(&queue, true, cap)?')
assert sr.index('self.check_cap_headroom(&queue, true, cap)?') < sr.index('owner.lock()')
assert sr.index('self.check_cap_headroom(&queue, true, cap)?') < sr.index('resolve_render_dependencies(')
assert 'FlightCharge::render(initbm, stage_deps[0], stage_deps[1])' in sr

# submit_compute checks headroom with a consistent cap snapshot before
# owner.lock() and dep resolution, and passes the same cap into reserve_flight.
sc = compute[compute.index('pub(crate) fn submit_compute('):compute.index('pub(super) fn submit_compute_queue(')]
assert sc.index('let cap = self.cap_state();') < sc.index('self.check_cap_headroom(&queue, false, cap)?')
assert sc.index('self.check_cap_headroom(&queue, false, cap)?') < sc.index('owner.lock()')
assert sc.index('self.check_cap_headroom(&queue, false, cap)?') < sc.index('resolve_compute_dependencies(')
assert 'FlightCharge::compute(' in sc

# reserve_flight checks exact caps (QUEUE_CAP, LANE_CAP, max_lane_works) before
# read_channel MMIO / lane.pointers reads, and explicitly orders lane-cursor
# loads with reader.acquire_barrier().
rf = publish[publish.index('pub(super) fn reserve_flight('):publish.index('pub(super) fn read_channel(')]
assert rf.index('check_exact_caps(') < rf.index('self.read_channel(')
assert rf.index('reader.read_u32_relaxed(lane.pointers + 0x30)?') < rf.index('reader.acquire_barrier();')

# retire() bumps retire_gen when removing a retired flight.
assert re.search(r'self\.ledger\.remove\(&flight\)\?;\s*self\.retire_gen = self\.retire_gen\.wrapping_add\(1\);', retire)

# Pump passes the exact cap_now snapshot into check_queue_headroom (no TOCTOU),
# fast-skips cap_blocked jobs, and widens deferred_mask to u128 for JOB_CREDITS=128.
assert 'CapBlock::still_blocked(job.cap_blocked, cap_now)' in pump
assert 'check_queue_headroom(&job.execution.firmware, !compute, cap_now)' in pump
assert 'let mut deferred_mask = 0u128;' in pump
assert pump.index('check_queue_headroom(') < pump.index('resolve_barriers(')
print('test-headroom: ok')

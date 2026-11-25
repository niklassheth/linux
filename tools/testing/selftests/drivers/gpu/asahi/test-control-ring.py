#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 control-channel monotonic epochs and half-ring bound
(g16_control_ring.rs):
- Both control-channel producers (destroy_queue_context and TVB growth/limit
  replies in service_render_events) enforce ControlRing's <= 127 half-ring
  in-flight bound.
- collect_destroyed_queues compares monotonic 64-bit epochs instead of wrapping
  8-bit modular cursors.
"""
from pathlib import Path
import os
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_control_ring.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

source = f'''#![allow(dead_code)]
#[path = "{driver / 'g16_control_ring.rs'}"] mod g16_control_ring;
''' + here.with_name('control-ring.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-control-ring-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

g16 = (driver / 'g16.rs').read_text()
queues = (driver / 'g16_runtime_queues.rs').read_text()
retire = (driver / 'g16_runtime_retire.rs').read_text()

# open_control initializes ControlRing::new(3) after confirming cursors == (3, 3, 3).
assert 'self.control_ring = crate::g16_control_ring::ControlRing::new(3);' in g16
assert 'destroying_queues: KVec<(u64, u64)>,' in g16

# destroy_queue_context, collect_destroyed_queues, and service_render_events
# all enforce ControlRing::observe / has_room / commit / reached.
assert 'self.control_ring.reached(target)' in queues
assert 'if !self.control_ring.has_room()' in queues
assert 'let target = self.control_ring.commit();' in queues
assert 'if !self.control_ring.has_room()' in retire
assert 'let _ = self.control_ring.commit();' in retire
assert 'self.control_ring.drained()' in retire

print('test-control-ring: ok')

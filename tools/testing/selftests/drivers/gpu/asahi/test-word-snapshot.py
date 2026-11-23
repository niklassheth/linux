#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 WordSnapshot (g16_snapshot.rs) and retirement scan
caching: driver_stamps read directly, last_scan holds only lane firmware stamps
with capacity >= 96, and recycled queues forget their old stamp addresses.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_snapshot.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'

source = f'''#![allow(dead_code)]
#[path = "{driver / 'g16_snapshot.rs'}"] mod g16_snapshot;
''' + here.with_name('word-snapshot.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-word-snapshot-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

retire = (driver / 'g16_runtime_retire.rs').read_text()
queues = (driver / 'g16_runtime_queues.rs').read_text()
assert re.search(
    r'for stamp in flight\.driver_stamps\.iter\(\)\.flatten\(\) \{\s*'
    r'done &= g16_stamp::reached\(reader\.read_u32_relaxed\(stamp\.address\)\?, stamp\.value\);',
    retire,
)
assert 'self.last_scan.clear();' in retire
assert 'self.last_scan.forget(lane.firmware_stamp());' in queues
print('test-word-snapshot: ok')

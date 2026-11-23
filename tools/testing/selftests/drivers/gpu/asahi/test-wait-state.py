#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of G16 kind-aware wait state and timestamp coverage (g16_wait_state.rs).

Compiles the production modules g16_stamp.rs and g16_wait_state.rs with
wait-state.rs. rustc must be on PATH; no device or kernel build is needed.
"""
from pathlib import Path
import os
import subprocess
import tempfile

here = Path(__file__).resolve()
root = next(p for p in here.parents if (p / 'drivers/gpu/drm/asahi/g16_wait_state.rs').exists())
source = f'''#![allow(dead_code)]
#[path = "{root / 'drivers/gpu/drm/asahi/g16_stamp.rs'}"] mod g16_stamp;
#[path = "{root / 'drivers/gpu/drm/asahi/g16_wait_state.rs'}"] mod g16_wait_state;
''' + here.with_name('wait-state.rs').read_text()

with tempfile.TemporaryDirectory(prefix='asahi-wait-state-') as temp:
    temp = Path(temp)
    (temp / 'test.rs').write_text(source)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test', '-Dwarnings',
                    str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    subprocess.run([str(temp / 'test')], check=True)

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host checks of asahi_m4.dependency_kind and cross_dependency_kind: kind 0 by
default, range-checked at probe; dependency_kind applies to render-to-render
items (a render's slot 0), cross_dependency_kind to cross-engine items (a
render's slot 1, a compute's wait on its render); a Work with user timestamps
waits with kind 1."""
from pathlib import Path
import re

root = next(p for p in Path(__file__).resolve().parents
            if (p / 'drivers/gpu/drm/asahi/g16_runtime.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'
runtime = ''.join(p.read_text() for p in sorted(driver.glob('g16_runtime*.rs')))
m4 = (driver / 'asahi_m4.rs').read_text()

# Render-to-render items default to kind 0, as production boots pass.
assert re.search(r'\n        dependency_kind: u32 \{\s*default: 0,', m4)
assert 'module_parameters::dependency_kind.value() > 1' in m4
# Renders: slot 0 (render producer) takes dependency_kind; slot 1 (compute
# producer) takes cross_dependency_kind, kind 0 by default and range-checked.
assert re.search(r'if timestamped \{\s*1\s*\} else if slot == 0 \{\s*render_kind\s*\} else \{\s*cross_kind\s*\}', runtime)
assert re.search(r'\n        cross_dependency_kind: u32 \{\s*default: 0,', m4)
assert 'module_parameters::cross_dependency_kind.value() > 1' in m4
# A compute's items take cross_dependency_kind, kind 1 when it has timestamps.
compute = (driver / 'g16_runtime_compute.rs').read_text()
assert re.search(r'a\.identity as u32,\s*kind,\s*\)', compute)
assert 'module_parameters::cross_dependency_kind.value()' in compute
print('test-dependency-kind: ok')

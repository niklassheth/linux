#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host checks of asahi_m4.dependency_kind and cross_dependency_kind: kind 0 by
default, range-checked at probe; dependency_kind applies to render-to-render
items (a render's slot 0), cross_dependency_kind to cross-engine items (a
render's slot 1, a compute's wait on its render); waits covering an in-flight
Work with user timestamps not yet serialized by a kind-1 wait on that lane
(and timestamped Works themselves) stay kind 1 and are not elided."""
from pathlib import Path
import re

root = next(p for p in Path(__file__).resolve().parents
            if (p / 'drivers/gpu/drm/asahi/g16_runtime.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'
m4 = (driver / 'asahi_m4.rs').read_text()
render = (driver / 'g16_runtime_render.rs').read_text()
compute = (driver / 'g16_runtime_compute.rs').read_text()
wait_state = (driver / 'g16_wait_state.rs').read_text()

# Render-to-render items default to kind 0, as production boots pass.
assert re.search(r'\n        dependency_kind: u32 \{\s*default: 0,', m4)
assert 'module_parameters::dependency_kind.value() > 1' in m4
assert re.search(r'\n        cross_dependency_kind: u32 \{\s*default: 0,', m4)
assert 'module_parameters::cross_dependency_kind.value() > 1' in m4

# Renders: slot 0 (render producer) takes dependency_kind; slot 1 (compute
# producer) takes cross_dependency_kind; uncovered producer timestamps and
# timestamped consumers force kind 1 and never elide while uncovered.
assert re.search(
    r'let uncovered_ts = self\.uncovered_timestamps\(queue, lane, dep\);\s*'
    r'let kind = if timestamped \|\| uncovered_ts \{\s*1\s*\} else if slot == 0 \{\s*render_kind\s*\} else \{\s*cross_kind\s*\};',
    render,
)
assert re.search(
    r'self\.elide_item\(queue, lane, dep, kind, same_lane, uncovered_ts, tally\)\?',
    render,
)
assert re.search(
    r'if uncovered_ts \{[\s\S]*?false\s*\}',
    render,
)
assert 'queue.waited.covers(lane, dep.address, dep.value, kind)' in render
assert 'queue.waited.note(' in render
assert 'queue.waited.prune(stamp.address, stamp.value)' in render

# Compute: waits on own render take cross_dependency_kind, or kind 1 when
# timestamped or covering unwaited producer timestamps; same-lane compute
# emits kind 1 only while uncovered producer timestamps remain in flight;
# CPU-hold checks covers_timestamps.
assert re.search(r'a\.identity as u32,\s*dep\.kind,\s*\)', compute)
assert 'module_parameters::cross_dependency_kind.value()' in compute
assert re.search(
    r'let uncovered_ts = self\.uncovered_timestamps\(queue, 2, dep\);\s*'
    r'let kind = if timestamped \|\| uncovered_ts \{\s*1\s*\} else \{\s*cross_kind\s*\};\s*'
    r'if !self\.elide_item\(queue, 2, dep, kind, false, uncovered_ts, tally\)\?',
    compute,
)
assert re.search(
    r'if own_lane == Some\(dep\.address\) \{\s*'
    r'if self\.uncovered_timestamps\(queue, 2, dep\) \{[\s\S]*?kind: 1,',
    compute,
)
assert re.search(
    r'g16_stamp::reached\(now, dep\.value\) && !self\.covers_timestamps\(dep\)',
    compute,
)
assert re.search(
    r'queue\s*\.waited\s*\.note\(2, dep\.stamp\.address, dep\.stamp\.value, dep\.kind\)',
    compute,
)
assert 'queue.waited.prune(stamp.address, stamp.value)' in compute

# Wait state tracks kind-1 separately and updates monotonically.
assert 'kind1_value' in wait_state
assert 'g16_stamp::reached(value, entry.any_value)' in wait_state
assert 'g16_stamp::reached(value, prev)' in wait_state

print('test-dependency-kind: ok')

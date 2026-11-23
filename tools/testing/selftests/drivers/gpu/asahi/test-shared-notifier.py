#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host checks of G16 shared_notifier=1 flush-boundary sealing: once flush()
exposes staged renders to firmware, later renders of the same submission
(split across a flush boundary by EBUSY backpressure) must start a fresh
JobNotifier instead of raising event_count_array on one firmware may have
already drained."""
from pathlib import Path
import re

root = next(p for p in Path(__file__).resolve().parents
            if (p / 'drivers/gpu/drm/asahi/g16_runtime.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'
runtime = (driver / 'g16_runtime.rs').read_text()
render = (driver / 'g16_runtime_render.rs').read_text()
publish = (driver / 'g16_runtime_publish.rs').read_text()
retire = (driver / 'g16_runtime_retire.rs').read_text()

# JobNotifier carries the flushed flag.
assert re.search(r'pub\(crate\) struct JobNotifier \{[\s\S]*?flushed: bool,', runtime)
# New JobNotifiers start unflushed, and reuse requires !j.flushed && j.owner_root.is_none().
assert re.search(
    r'\.find\(\|j\| j\.job == job && !j\.flushed && j\.owner_root\.is_none\(\)\)',
    render,
)
assert re.search(r'JobNotifier \{[\s\S]*?flushed: false,', render)
# Shared notifiers must also share the owner's uncached driver-stamp slots so
# firmware's per-notifier stamp coalescing satisfies every render in the batch.
shared_block = render[render.index('let job_owner = if crate::g16_timeline::shared_notifier()'):]
shared_block = shared_block[:shared_block.index('};')]
assert 'a.tiling_driver_stamp = owner_va + 0x18000;' in shared_block
assert 'a.fragment_driver_stamp = owner_va + 0x18040;' in shared_block
# Only the owner (notifier_write.0) initializes the shared driver stamps, so
# later member renders cannot overwrite them with previous(later_stamp) and
# pre-satisfy earlier renders in the same batch. Every driver-stamp reference
# in publish_render() must lie strictly inside `if notifier_write.0 { ... }`.
pub_fn = render[render.index('pub(super) fn publish_render('):]
m = re.search(r'if notifier_write\.0 \{([^{}]*)\}', pub_fn)
assert m, 'missing `if notifier_write.0 { ... }` block in publish_render'
nw_body = m.group(1)
assert nw_body.count('a.tiling_driver_stamp') == 1
assert nw_body.count('a.fragment_driver_stamp') == 1
assert pub_fn.count('a.tiling_driver_stamp') == 1, 'unguarded tiling_driver_stamp write in publish_render'
assert pub_fn.count('a.fragment_driver_stamp') == 1, 'unguarded fragment_driver_stamp write in publish_render'
# flush() seals all staged notifiers before publishing rings / doorbells.
flush_fn = publish[publish.index('pub(crate) fn flush(&mut self)'):]
seal_pos = flush_fn.index('notifier.flushed = true;')
kick_pos = flush_fn.index('send_message(')
assert seal_pos < kick_pos
# Retirement looks up JobNotifiers by unique owner VA, never by job id, so
# multiple notifiers from a split submission retire independently, and both
# the shared final-member (j.refs == 1) and per-Work (None) arms independently
# order +0x94 == 0 with an acquire_barrier() after completion loads.
assert 'self.job_notifiers.iter().position(|j| j.owner == owner_va)' in retire
nc_match = retire[retire.index('match flight.notifier_count {'):]
nc_match = nc_match[:nc_match.index('blocked |= u32::from(!notified)')]
some_arm, none_arm = nc_match.split('None =>', 1)
assert re.search(
    r'j\.refs == 1[\s\S]*?reader\.acquire_barrier\(\);[\s\S]*?let notifier = completed - 0xc;[\s\S]*?notifier \+ 0x94\)\? == 0',
    some_arm,
), 'missing acquire_barrier before +0x94 load in shared-notifier final-member arm'
assert re.search(
    r'reader\.acquire_barrier\(\);[\s\S]*?let notifier = flight\.id[\s\S]*?notifier \+ 0x94\)\? == 0',
    none_arm,
), 'missing acquire_barrier before +0x94 load in per-Work arm'
print('test-shared-notifier: ok')

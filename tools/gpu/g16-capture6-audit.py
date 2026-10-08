#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Audit raw own-Metal capture without inspecting Apple executable code."""
import collections
import json
import subprocess
import sys

states = {}
counts = collections.Counter()
controls = []
pins = []
runtime = []
qctx = []
errors = []
arm = None
last = None
p = subprocess.Popen(['zstd', '-dc', sys.argv[1]], stdout=subprocess.PIPE, text=True)
for line in p.stdout:
    r = json.loads(line)
    counts[r.get('kind')] += 1
    t = r.get('host_wall', 0) - 1791424484.0
    last = t
    if r.get('kind') == 'control_ring_at_arm':
        arm = {'cursors': r['words'], 'historical_1b': []}
        data = bytes.fromhex(r['bytes'])
        for i in range(r['words'][2]):
            b = data[64 * i:64 * (i + 1)]
            if int.from_bytes(b[:4], 'little') == 0x1b:
                arm['historical_1b'].append({'slot': i, 'bytes': b.hex()})
    if r.get('kind') == 'control_dump':
        for s in r['slots']:
            b = bytes.fromhex(s['bytes'])
            opcode = int.from_bytes(b[:4], 'little')
            controls.append({'time': t, 'slot': s['index'], 'opcode': opcode,
                             'field4': int.from_bytes(b[4:8], 'little'),
                             'destroy_object': hex(int.from_bytes(b[12:20], 'little')) if opcode == 0x14 else None,
                             'user_regions': {key: {'successes': [{k: v for k, v in m.items() if k != 'bytes'}
                                                               for m in region.get('successes', [])]}
                                              for key, region in s.get('user_regions', {}).items()}})
    if r.get('kind') == 'compute_pin':
        pins.append({k: v for k, v in r.items() if k != 'translations'})
        pins[-1]['translations'] = {key: {k: v for k, v in m.items() if k != 'bytes'}
                                    for key, m in r['translations'].items()}
    if r.get('kind') == 'timeout_snapshot':
        for name, change in r['changes'].items():
            if isinstance(change, dict):
                states[name] = bytearray.fromhex(change.get('initial', change.get('replaced', '')))
            else:
                data = states[name]
                for part in change:
                    offset = part['offset']
                    before = bytes.fromhex(part['before'])
                    after = bytes.fromhex(part['after'])
                    assert bytes(data[offset:offset + len(before)]) == before, (name, t, offset)
                    data[offset:offset + len(after)] = after
            if name.endswith('_error'):
                errors.append({'time': t, 'object': name, 'error': bytes(states[name]).decode()})
            if name == 'lane2_desc':
                value = int.from_bytes(states[name][0x9c:0xa4], 'little')
                if not runtime or runtime[-1]['value'] != value:
                    runtime.append({'time': t, 'value': value})
            if name == 'qctx_6b24c0':
                qctx.append({'time': t, 'e': bytes(states[name][0xe:0x10]).hex(),
                             '2f': bytes(states[name][0x2f:0x32]).hex()})
assert p.wait() == 0
out = {'counts': dict(counts), 'records': sum(counts.values()), 'arm': arm,
       'controls': controls, 'pins': pins, 'h_runtime_changes': runtime,
       'h_context_changes': qctx, 'snapshot_errors': errors, 'last_record_time': last,
       'limits': ['No H op14 observed; this is a bounded absence, not a guarantee of no future cancellation.',
                  'Lane-switch write timing is inferred from sampled state, not traced firmware writes.',
                  'Guest signal time is bounded by clock anchors; actual process exit status was not captured.']}
print(json.dumps(out, indent=2))

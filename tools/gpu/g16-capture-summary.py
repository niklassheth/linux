#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Summarize our G16 HV tracer's JSONL data; never decode shader/firmware code."""
import argparse
import collections
import contextlib
import json
import struct
import subprocess
from pathlib import Path


def number(value):
    return int(value, 0) if isinstance(value, str) else value


def u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def u64(data, offset):
    return struct.unpack_from('<Q', data, offset)[0]


@contextlib.contextmanager
def records(path):
    process = None
    if path.suffix == '.zst':
        process = subprocess.Popen(['zstd', '-dc', '--', str(path)],
                                   stdout=subprocess.PIPE, text=True)
        source = process.stdout
    else:
        source = path.open()
    try:
        yield (json.loads(line) for line in source if line.strip())
    finally:
        source.close()
        if process is not None and process.wait():
            raise RuntimeError(f'zstd failed: {path}')


def summarize(path):
    counts = collections.Counter()
    lanes = {}
    registrations = {}
    snapshot_slots = collections.Counter()
    errors = []
    with records(path) as stream:
        for record in stream:
            kind = record.get('kind', 'unknown')
            counts[kind] += 1
            if kind.endswith('_error'):
                errors.append({'kind': kind, 'error': record.get('error')})
            if kind == 'control_dump':
                for slot in record['slots']:
                    raw = bytes.fromhex(slot['bytes'])
                    if len(raw) < 0x38 or u32(raw, 0) != 0x20:
                        continue
                    fields = {name: u32(raw, offset) for name, offset in (
                        ('context_field', 4), ('mask', 8), ('uuid', 12),
                        ('size_field', 0x2c), ('count_field', 0x30), ('flag', 0x34))}
                    fields.update({name: hex(u64(raw, offset)) for name, offset in (
                        ('firmware_object', 0x14), ('user_address_a', 0x1c),
                        ('user_address_b', 0x24))})
                    key = raw.hex()
                    if key not in registrations:
                        fields['first_host_time'] = record['host_time']
                        fields['firmware_object_captured'] = 'fw_object' in slot
                        fields['user_regions'] = {
                            key: {k: v for k, v in region.items() if k != 'bytes'}
                            for key, region in slot.get('user_regions', {}).items()}
                        registrations[key] = fields
            if kind == 'timeout_snapshot':
                snapshot_slots.update(name for name in record['changes']
                                      if name.startswith('slot'))
            if kind != 'doorbell_dump':
                continue
            for stage, item in record.get('channels', {}).items():
                if stage != 's2' or not item.get('work'):
                    continue
                raw = bytes.fromhex(item['work'])
                if len(raw) < 0x88b:
                    continue
                queue = hex(number(item['queue']))
                lane = lanes.setdefault(queue, {
                    'works_observed': 0, 'contexts': set(), 'slots': [],
                    'support_addresses': set(), 'doorbell_contents': collections.Counter(),
                    'first_host_time': record['host_time']})
                lane['works_observed'] += 1
                lane['contexts'].add(u32(raw, 12))
                lane['slots'].append(u64(raw, 0x883))
                lane['support_addresses'].add(u64(raw, 0x86a))
                lane['last_host_time'] = record['host_time']
                if 'slot_at_doorbell' in item:
                    lane['doorbell_contents'][item['slot_at_doorbell']] += 1
                if item.get('slot_error'):
                    errors.append({'kind': 'slot_error', 'error': item['slot_error']})
    output_lanes = {}
    for queue, lane in lanes.items():
        sequence = lane.pop('slots')
        slots = sorted(set(sequence))
        repeated = next((i for i, slot in enumerate(sequence[1:], 1)
                         if slot == sequence[0]), None)
        lane.update(contexts=sorted(lane['contexts']),
                    support_addresses=[hex(a) for a in sorted(lane['support_addresses'])],
                    distinct_slots=len(slots), slot_min=hex(slots[0]),
                    slot_max=hex(slots[-1]),
                    slot_steps=sorted({b - a for a, b in zip(slots, slots[1:])}),
                    first_slot_repeat_after_works=repeated,
                    slot_span_bytes=slots[-1] - slots[0] + 0x40 if slots[0] else 0,
                    doorbell_contents=dict(lane['doorbell_contents']))
        output_lanes[queue] = lane
    return {'path': str(path), 'record_counts': dict(counts),
            'compute_lanes': output_lanes,
            'op20_registrations': list(registrations.values()),
            'slot_snapshot_changes': dict(snapshot_slots), 'errors': errors,
            'limits': ['Slot span and reuse are observations, not an ABI capacity claim.',
                       'op20 context_field is not assumed to be a Work ASID.',
                       'Snapshots after a doorbell do not establish who initialized memory.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path, nargs='+')
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.captures], indent=2))


if __name__ == '__main__':
    main()

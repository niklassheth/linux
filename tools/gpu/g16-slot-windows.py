#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Reconstruct captured slot windows, without interpreting their ABI or code."""
import argparse
import collections
import json
import struct
from pathlib import Path

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location('capture_summary',
                              Path(__file__).with_name('g16-capture-summary.py'))
capture = module_from_spec(spec)
spec.loader.exec_module(capture)


def words(data, width):
    return [hex(w) for w in struct.unpack('<' + ('I' if width == 4 else 'Q') *
                                         (0x40 // width), data[:0x40])]


def summarize(path):
    previous = {}
    counts = collections.defaultdict(collections.Counter)
    endpoints = {}
    with capture.records(path) as stream:
        for record in stream:
            if record.get('kind') != 'timeout_snapshot':
                continue
            for name, delta in record['changes'].items():
                if not name.startswith('slot') or name.endswith('_page'):
                    continue
                if isinstance(delta, dict):
                    data = bytearray.fromhex(delta['initial'])
                else:
                    data = previous[name].copy()
                    for run in delta:
                        offset = run['offset']
                        after = bytes.fromhex(run['after'])
                        before = bytes.fromhex(run['before'])
                        if data[offset:offset + len(before)] != before:
                            raise ValueError(f'{path}: inconsistent delta for {name}')
                        data[offset:offset + len(after)] = after
                previous[name] = data
                contents = bytes(data[:0x40])
                counts[name][contents] += 1
                sample = {'host_time': record['host_time'], 'u32': words(data, 4),
                          'u64': words(data, 8)}
                endpoints.setdefault(name, {'first': sample})['last'] = sample
    return {'path': str(path), 'windows': {
        name: dict(endpoints[name], contents=[{'u32': words(data, 4),
            'u64': words(data, 8), 'snapshot_change_count': count}
            for data, count in samples.items()]) for name, samples in counts.items()},
        'limits': [
            'C windows follow the latest submitted slot; counts are not writes to one address.',
            'Snapshots are post-publication and do not establish who initialized words.',
            'Both u32 and u64 views are shown; neither is an established field layout.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path, nargs='+')
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.captures], indent=2))

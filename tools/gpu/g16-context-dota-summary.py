#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Summarise copied Dota context-slot A/B evidence without touching hardware."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

workspace = Path(__file__).resolve().parents[4]
decoder_path = workspace / 'tmp/cs2-memory-lab-20261005/lab/dota-shader-identity-20261006/shader-ring.py'
spec = importlib.util.spec_from_file_location('shader_ring', decoder_path)
decoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decoder)


def read(path):
    return path.read_text(errors='replace') if path.exists() else ''


def summarize(run):
    results = sorted(run.glob('dota-trigger-rw-*'))
    if not results:
        return {'run': run.name, 'status': 'results not copied yet'}
    result = results[0]
    setup = read(run / 'setup.log')
    arm = re.search(r'asahi_m4.context_sticky=([01])', setup)
    report = {'run': run.name, 'sticky': int(arm[1]) if arm else None}
    verdict = result / 'safe-to-stop.json'
    report['watcher'] = json.loads(verdict.read_text()) if verdict.exists() else None
    inputs = read(run / 'harness-driver-inputs.txt').splitlines()
    report['driver_input'] = inputs[0] if inputs else None
    marker = read(result / 'loaded-driver.txt').strip()
    mapped = []
    for maps in result.glob('ring-snapshots/*/process-maps.txt'):
        mapped.extend(re.findall(r'/\S*libvulkan_asahi\S*', read(maps)))
    report['driver_marker'] = marker or None
    report['independent_mapped_libraries'] = sorted(set(mapped))
    report['harness_wrong_driver_marker'] = (result / 'wrong-driver').exists()
    kernel = read(result / 'kernel.log')
    pattern = (r'\[\s*(\d+\.\d+)\].*?hang flight Work=(0x[0-9a-f]+) '
               r'context=(\d+) age_ms=(\d+) render=(true|false) stream=(0x[0-9a-f]+)')
    flights = list(re.finditer(pattern, kernel))
    report['pending_render_reports'] = sum(m[5] == 'true' for m in flights)
    report['pending_compute_reports'] = sum(m[5] == 'false' for m in flights)
    if flights:
        first = flights[0]
        end = flights[1].start() if len(flights) > 1 else len(kernel)
        block = kernel[first.end():end]
        report['first_flight'] = {
            'kernel_time': float(first[1]), 'work': first[2],
            'slot': int(first[3]), 'age_since_progress_ms': int(first[4]),
            'render': first[5] == 'true', 'stream': first[6],
            'stages': re.findall(r'stage (\d+) fw stamp .*?=(0x[0-9a-f]+) want (0x[0-9a-f]+)', block),
            'waits': re.findall(r'waits on (render|compute) stamp .*?=(0x[0-9a-f]+) want (0x[0-9a-f]+)', block),
        }
        binds = list(re.finditer(
            r'\[\s*(\d+\.\d+)\].*?context ' + first[3] +
            r' bound to root (0x[0-9a-f]+) \(previous (0x[0-9a-f]+)\)',
            kernel[:first.start()]))
        if binds:
            last = binds[-1]
            report['last_slot_rebind'] = {'kernel_time': float(last[1]),
                                          'root': last[2], 'previous': last[3]}
    report['handoff_observations'] = sorted(set(re.findall(
        r'cur_slot=(\S+) lock_fw=(\S+) lock_ap=(\S+) turn=(\S+)', kernel)))
    rings = [p for p in result.glob('ring-snapshots/terminal/hk-shader-ring-*')
             if p.suffix != '.json']
    if rings:
        ring = decoder.read_ring(rings[0].read_bytes())
        report['ring_warnings'] = ring['warnings']
        if flights:
            report['first_flight']['shader_join'] = decoder.command_report(ring, int(flights[0][6], 16))
        latest = [e for e in ring['history'] if e['event'] == 'command' and e['flags']]
        if latest:
            e = latest[-1]
            report['last_retained_render_publication'] = {
                'guest_monotonic_ns': e['time_ns'], 'program_started_ns': ring['started_ns'],
                'queue': e['handle'], 'timeline': e['size'], 'seq': e['seq']}
    report['restored_production20'] = any(
        '#20 SMP PREEMPT_DYNAMIC' in read(p) and read(p).count('\nactive\n') >= 2
        for p in run.glob('production-services-*.log'))
    return report


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('runs', nargs='+', type=Path)
p.add_argument('--output', type=Path)
args = p.parse_args()
reports = [summarize(run) for run in args.runs]
text = json.dumps(reports, indent=2) + '\n'
if args.output:
    args.output.write_text(text)
else:
    print(text, end='')

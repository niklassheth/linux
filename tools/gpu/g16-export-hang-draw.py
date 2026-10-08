#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Package hash-verified Mesa shader exports, never proprietary executable code."""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('run', type=Path)
p.add_argument('output', type=Path)
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
lib = ctypes.CDLL(ctypes.util.find_library('xxhash'))
lib.XXH32.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint]
lib.XXH32.restype = ctypes.c_uint


def code_hash(data):
    return lib.XXH32(data, len(data), 0)


def copy_file(source, name):
    dest = args.output / name
    shutil.copyfile(source, dest)
    return dest


def assembly(data, stage, name):
    # Compiler rows are generated before its final four-byte STOP is appended.
    assert data[-4:] == b'\x0e\0\0\0', (name, 'missing STOP')
    source = args.run / 'dump' / f'part-{code_hash(data[:-4]):08x}-{stage}.asm'
    text = source.read_text()
    rows = re.findall(r'APPLE9_ASM offset=(\d+).*?bytes=([0-9a-f]*)', text)
    assembled = bytearray()
    for offset, raw in rows:
        assert int(offset) == len(assembled), (name, offset, len(assembled))
        assembled.extend(bytes.fromhex(raw))
    assembled.extend(b'\x0e\0\0\0')
    assert assembled == data, (name, 'assembly does not reproduce binary')
    dest = args.output / name
    dest.write_text(text.replace('APPLE9_ASM_END',
                    f'APPLE9_ASM offset={len(data)-4} STOP bytes=0e000000\nAPPLE9_ASM_END'))
    return source


def part_program(binary, info, role, stage):
    data = binary.read_bytes()
    if role.startswith('helper'):
        m = re.search(r'main (\d+) preamble_offset (\d+) preamble_size (\d+)', info)
    else:
        m = re.search(r'main_size (\d+) graphics_preamble_offset (\d+) graphics_preamble_size (\d+)', info)
    assert m, (role, 'missing binary part sizes')
    main, offset, size = map(int, m.groups())
    assert main + size == len(data) and (not size or offset == main), role
    assembly(data[:main], stage, role + '.main.asm')
    if size:
        assembly(data[offset:offset+size], stage, role + '.preamble.asm')
    return dict(bytes=len(data), code_hash=f'0x{code_hash(data):08x}',
                main_size=main, preamble_offset=offset, preamble_size=size)


report = {'run': str(args.run.resolve()), 'shaders': {}, 'helpers': {}}
for role, target, expected_size, stage, ext in [('vertex', 0x7f829920, 980, 0, 'vert'),
                                              ('fragment', 0x0a00d1f7, 1848, 4, 'frag')]:
    binaries = sorted((args.run / 'dump').glob(f'hk-dump-{target:08x}-*.bin'))
    assert binaries, (role, 'no hash-selected export')
    binary = binaries[0]
    data = binary.read_bytes()
    assert len(data) == expected_size and code_hash(data) == target, role
    for suffix in ['bin', 'nir', 'info']:
        copy_file(binary.with_suffix('.' + suffix), role + '.' + suffix)
    info = binary.with_suffix('.info').read_text()
    entry = part_program(binary, info, role, stage)
    blake3 = re.search(r'spirv_blake3 0x([a-f0-9]+)', info).group(1)
    spv = args.run / 'spirv' / f'0x{blake3}.{ext}'
    if spv.exists():
        copy_file(spv, role + '.spv')
        assert spv.read_bytes()[:4] == b'\x03\x02\x23\x07'
        spec = spv.with_suffix('.spec.txt')
        if spec.exists():
            copy_file(spec, role + '.spec.txt')
        if shutil.which('spirv-dis'):
            subprocess.run(['spirv-dis', str(spv), '-o', str(args.output / (role + '.spvasm'))], check=True)
        entry['spirv'] = 'source hash from exported NIR; matching frontend dump'
    else:
        entry['spirv'] = 'not present; inspect internal flag and NIR before assigning source'
    entry['source_blake3'] = blake3
    report['shaders'][role] = entry

for role, target, expected_size in [('helper-eot', 0xab89e07b, 92),
                                    ('helper-background', 0x1dfad39e, 484)]:
    binary = args.run / 'dump' / f'helper-{target:08x}.bin'
    data = binary.read_bytes()
    assert len(data) == expected_size and code_hash(data) == target, role
    for suffix in ['bin', 'nir', 'info']:
        copy_file(binary.with_suffix('.' + suffix), role + '.' + suffix)
    report['helpers'][role] = part_program(binary, binary.with_suffix('.info').read_text(), role, 4)

copy_file(args.run / 'dump' / 'draws.txt', 'later-run-draws.txt')
copy_file(args.run / 'dump' / 'helper-bindings.txt', 'later-run-helper-bindings.txt')
copy_file(args.run / 'loaded-driver.txt', 'export-loaded-driver.txt')
for file in sorted(args.output.iterdir()):
    if file.is_file() and file.name != 'export-manifest.json':
        report.setdefault('files', {})[file.name] = dict(bytes=file.stat().st_size,
             sha256=hashlib.sha256(file.read_bytes()).hexdigest())
(args.output / 'export-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k:v for k,v in report.items() if k != 'files'}, indent=2))

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Host tests of opaque bit-28 native mesh UAPI, serializers, support and scratch setup.

The ordinary-render byte comparison uses the bundled, hash-checked
g16_render.rs from before native mesh support (production #214 in the
original history). Its source revision is recorded beside the fixture. Older
checkouts can instead resolve the reference from Git history. No device,
kernel module, or external package is needed; rustc must be on PATH.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

root = next(p for p in Path(__file__).resolve().parents
            if (p / 'drivers/gpu/drm/asahi/g16_mesh.rs').exists())
driver = root / 'drivers/gpu/drm/asahi'


def item(source, pattern):
    start = re.search(pattern, source).start()
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


header = (root / 'include/uapi/drm/asahi_drm.h').read_text()
runtime = ''.join(p.read_text() for p in sorted(driver.glob('g16_runtime*.rs')))
drm = ''.join(p.read_text() for p in sorted(driver.glob('g16_drm*.rs')))
drm_ioctl = (driver / 'g16_drm_ioctl.rs').read_text()
drm_submit = (driver / 'g16_drm_submit.rs').read_text()
bootstrap = (driver / 'g16.rs').read_text()
params = (driver / 'asahi_m4.rs').read_text()
timeline_src = (driver / 'g16_timeline.rs').read_text()
vm_src = (driver / 'g16_vm.rs').read_text()
mesh = (driver / 'g16_mesh.rs').read_text()

# 1. Downstream G16 UAPI bit 28 definitions and compile-time guard (pinned + unique).
assert 'DRM_ASAHI_FEATURE_NATIVE_MESH = (1UL) << 28,' in header
assert 'DRM_ASAHI_RENDER_NATIVE_MESH = (1U << 28),' in header
assert 'drm_asahi_feature_DRM_ASAHI_FEATURE_NATIVE_MESH as u64,' in drm
assert 'drm_asahi_render_flags_DRM_ASAHI_RENDER_NATIVE_MESH as u64,' in drm
assert 'assert!(drm_asahi_feature_DRM_ASAHI_FEATURE_NATIVE_MESH as u64 == 1 << 28);' in drm
assert 'assert!(drm_asahi_render_flags_DRM_ASAHI_RENDER_NATIVE_MESH as u64 == 1 << 28);' in drm
assert 'assert!(seen & bit == 0);' in drm

# 2. Boot parameter (default OFF) and debugfs gate use parse_parameter (0 / 1 / 4).
assert re.search(r'native_mesh:\s*u32\s*\{\s*default: 0,', params)
assert 'crate::g16_mesh::parse_parameter(module_parameters::native_mesh.value()).is_none()' in params
assert re.search(
    r'g16_mesh::parse_parameter\(crate::module_parameters::native_mesh\.value\(\)\)\s*\.ok_or\(EINVAL\)\?',
    bootstrap,
)
assert 'c_str!("native_mesh"), crate::g16_timeline::NativeMeshKnob' in drm
assert 'crate::g16_mesh::parse_parameter(value).ok_or(EINVAL)?' in timeline_src
assert 'crate::g16_mesh::set_enabled(enabled);' in timeline_src

# 3. File::open latches native_mesh once; GET_PARAMS and VM_CREATE share that latch.
assert 'native_mesh: crate::g16_mesh::enabled(),' in drm
get_params_src = item(drm_ioctl, r'pub\(super\) fn get_params\(')
assert re.search(
    r'if file\.inner\(\)\.native_mesh\s*\{\s*'
    r'u64::from\(uapi::drm_asahi_feature_DRM_ASAHI_FEATURE_NATIVE_MESH\)\s*'
    r'\}\s*else\s*\{\s*0\s*\}',
    get_params_src,
)

# 4. VM_CREATE inherits file's native_mesh latch; render support & operand pool use it.
vm_create_src = item(drm_ioctl, r'pub\(super\) fn vm_create\(')
assert 'let native_mesh = inner.native_mesh;' in vm_create_src
assert re.search(r'render_pool: None,\s*native_mesh,', vm_create_src)
assert re.search(
    r'let buffers = if vm\.native_mesh \{\s*render::OPERAND_BUFFERS_MAX\s*\}',
    drm_submit,
)
assert 'runtime.acquire_render_support(&pool, vm.native_mesh)?' in drm_submit
assert re.search(
    r'fn acquire_render_support\(\s*&mut self,\s*pool: &render::OperandPool,\s*native: bool,\s*\)',
    runtime,
)
assert re.search(r'if lease\.native\s*\{\s*render::initialize_native_support', runtime)
assert 'g16_mesh::enabled()' not in runtime
assert 'native_mesh.value()' not in runtime

# 5. SUBMIT validates DRM_ASAHI_RENDER_NATIVE_MESH via g16_mesh::render_profile:
#    - rejects on VMs without native_mesh latched (EINVAL via reject)
#    - rejects combination with DRM_ASAHI_RENDER_FEW_PRIMITIVES (EINVAL via reject)
#    - sets p.mesh directly with zero CPU stream reads.
render_params_src = item(drm_submit, r'pub\(super\) fn render_parameters\(')
assert 'drm_asahi_render_flags_DRM_ASAHI_RENDER_NATIVE_MESH as NATIVE_MESH,' in render_params_src
assert 'NATIVE_MESH' in re.search(r'c\.flags\s*& !\(([^)]*)\)', render_params_src).group(1)
assert re.search(
    r'let mesh = crate::g16_mesh::render_profile\(\s*'
    r'self\.native_mesh,\s*'
    r'c\.flags & NATIVE_MESH != 0,\s*'
    r'c\.flags & FEW_PRIMITIVES != 0,\s*'
    r'\)',
    render_params_src,
)
assert 'RenderReject::VmDisabled => reject(' in render_params_src
assert 'RenderReject::FewPrimitivesConflict => reject(' in render_params_src
assert 'p.mesh = mesh;' in render_params_src

# 6. submit_render keeps defense-in-depth !support.native check with diagnostic,
#    counts published native_mesh_renders once via note_render_published, and
#    preserves native_tvb_refused.
submit_render_src = item(runtime, r'pub\(crate\) fn submit_render\(')
assert re.search(
    r'if params\.mesh\.is_some\(\) && !support\.native \{\s*'
    r'pr_err!\([^\n]+\);\s*'
    r'return Err\(EINVAL\);\s*\}',
    submit_render_src,
)
assert re.search(
    r'let result = self\.submit_render_queue\([\s\S]{0,400}?'
    r'crate::g16_mesh::note_render_published\(\s*'
    r'result\.is_ok\(\),\s*'
    r'params\.mesh\.is_some\(\),\s*'
    r'&crate::g16_timeline::NATIVE_MESH_RENDERS,\s*\);',
    submit_render_src,
)
assert submit_render_src.count('NATIVE_MESH_RENDERS') == 1
assert 'native: params.mesh.is_some(),' in runtime and 'pool_has_native,' in runtime
assert re.search(
    r'if native \{\s*(//[^\n]*\n\s*)*tl::NATIVE_TVB_REFUSED\.fetch_add\(1, Relaxed\);\s*'
    r'if !tl::NATIVE_TVB_REFUSED_WARNED\.swap\(true, Relaxed\) \{\s*dev_warn!',
    runtime,
)
assert 'native_mesh_renders {}' in timeline_src and 'native_tvb_refused {}' in timeline_src
assert re.search(
    r'NATIVE_MESH_RENDERS\.load\(Relaxed\),\s*NATIVE_TVB_REFUSED\.load\(Relaxed\)',
    timeline_src,
)
assert 'params.samples != 1 || params.layers != 1' not in runtime

# 7. Zero CPU command-stream peeking/parsing or obsolete sysfs/debugfs/module params remain.
all_driver = ''.join(p.read_text() for p in sorted(driver.glob('*.rs')))
for forbidden in (
    'command_word',
    'command_word_cached',
    'may_be_native',
    'decode_blocks',
    'g16_mesh::decode',
    'DecodeError',
    'native_cpu_wait',
    'NATIVE_CPU_WAIT',
    'native_multi_parent',
    'NativeMultiParentKnob',
    'native_blocks_qualified',
    'native_blocks_max',
    'native_blocks_mixed',
    'asahi_native_mesh',
    'asahi_native_blocks',
    'asahi_native_object',
    'NATIVE_BLOCK_RENDERS',
    'NATIVE_BLOCK_DISPATCHES',
    'NATIVE_BLOCK_ORDINARY',
    'NATIVE_MULTI_PARENT_RENDERS',
):
    assert forbidden not in all_driver, f'obsolete symbol still present: {forbidden}'

# 8. g16_mesh constants & g16_vm partial-clear scratch invariants (c13fa10c3986).
assert 'pub(crate) const CLUSTER_PAYLOAD_BYTES: usize = 0x40000;' in mesh
assert 'pub(crate) const NUM_CLUSTERS: usize = 2;' in mesh
assert 'pub(crate) const PAYLOAD_BYTES: usize = NUM_CLUSTERS * CLUSTER_PAYLOAD_BYTES;' in mesh
alloc_low_src = item(vm_src, r'pub\(crate\) fn alloc_low\(')
assert 'GpuPage::alloc(GFP_KERNEL | __GFP_ZERO)?' in alloc_low_src
lease_scratch_src = item(vm_src, r'fn lease_scratch\(')
assert 'let clear_end = clear_from.checked_add(clear_len).ok_or(EINVAL)?;' in lease_scratch_src
assert 'clear_end > size' in lease_scratch_src
assert '(size | clear_from | clear_len) & (UAT_PGSZ - 1) != 0' in lease_scratch_src
assert 'let clear_va_start = start + clear_from as u64;' in lease_scratch_src
assert 'let clear_va_end = start + clear_end as u64;' in lease_scratch_src
assert re.search(
    r'for va in \(clear_va_start\.\.clear_va_end\)\.step_by\(UAT_PGSZ\) \{\s*'
    r'let page = self\.pages\.get\(&va\)\.ok_or\(EIO\)\?;\s*'
    r'page\.with_page_mapped\(\|ptr\| \{\s*'
    r'(?://[^\n]*\n\s*)*unsafe \{ core::ptr::write_bytes\(ptr, 0, UAT_PGSZ\) \};\s*'
    r'\}\);\s*\}',
    lease_scratch_src,
)
prepare_render_src = item(vm_src, r'pub\(crate\) fn prepare_render\(')
assert 'crate::g16_mesh::Profile::PAYLOAD_BYTES' in prepare_render_src
assert 'self.lease_scratch(true, size, tilemap + tpc, 5 * UAT_PGSZ)?' in prepare_render_src
assert 'step_by(256)' not in prepare_render_src
prepare_compute_src = item(vm_src, r'pub\(crate\) fn prepare_compute\(')
assert 'self.lease_scratch(false, 0x28000, 0x20000, 2 * UAT_PGSZ)?' in prepare_compute_src

fixture = r'''
#![allow(dead_code, non_upper_case_globals, unused_imports)]
mod module_parameters {
    pub struct Parameter(u32);
    impl Parameter { pub fn value(&self) -> u32 { self.0 } }
    pub static micro_layout: Parameter = Parameter(0);
}
mod float {
    pub struct F32(f32);
    impl F32 {
        pub fn from_bits(bits: u32) -> Self { Self(f32::from_bits(bits)) }
        pub fn to_bits(self) -> u32 { self.0.to_bits() }
    }
    impl From<u32> for F32 { fn from(v: u32) -> Self { Self(v as f32) } }
    impl std::ops::Div for F32 {
        type Output = Self;
        fn div(self, rhs: Self) -> Self { Self(self.0 / rhs.0) }
    }
}
mod mem { pub fn sync() {} }
mod util {
'''
util = (driver / 'm4_util.rs').read_text()
for name in ('put32', 'put64'):
    fixture += item(util, r'pub\(crate\) fn ' + name + r'\(') + '\n'
fixture += '}\n'
fixture += f'#[path = "{Path(__file__).resolve().with_name("native-support.rs")}"] mod native_support;\n'
for name in ('g16_mesh', 'g16_render', 'g16_stamp'):
    fixture += f'#[path = "{driver / (name + ".rs")}"] mod {name};\n'

# Extract the production scratch methods; the small double records allocations
# and writes so the test checks actual ownership and clearing behavior.
tests = Path(__file__).with_name('native-mesh.rs').read_text()
fixture += tests
fixture = fixture.replace('/* PREPARE_RENDER */', item(vm_src, r'    pub\(crate\) fn prepare_render\('))
fixture = fixture.replace('/* LEASE_SCRATCH */', item(vm_src, r'    fn lease_scratch\('))
fixture = fixture.replace('/* RELEASE_SCRATCH */', item(vm_src, r'    pub\(crate\) fn release_scratch\('))


def baseline_render():
    """g16_render.rs as of the parent of the commit that added g16_mesh.rs."""
    baseline_dir = Path(__file__).with_name("baselines")
    fixture_path = baseline_dir / "g16_render_pre_mesh.rs"
    if fixture_path.is_file():
        source = fixture_path.read_bytes()
        metadata = json.loads((baseline_dir / "g16_render_pre_mesh.json").read_text())
        assert hashlib.sha256(source).hexdigest() == metadata["sha256"]
        return source.decode()

    try:
        added = subprocess.run(
            ['git', 'log', '--diff-filter=A', '--format=%H', 'HEAD', '--',
             'drivers/gpu/drm/asahi/g16_mesh.rs'],
            cwd=root, text=True, capture_output=True, check=True).stdout.split()
        if not added:
            return None
        return subprocess.run(
            ['git', 'show', added[-1] + '^:drivers/gpu/drm/asahi/g16_render.rs'],
            cwd=root, text=True, capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


baseline = baseline_render()
if baseline is None:
    print('SKIP: no git history with the commit that added g16_mesh.rs; '
          'the ordinary-render baseline is unavailable')
    sys.exit(4)

with tempfile.TemporaryDirectory(prefix='asahi-native-mesh-') as temp:
    temp = Path(temp)
    (temp / 'baseline.rs').write_text(baseline)
    fixture += f'#[path = "{temp / "baseline.rs"}"] mod baseline;\n'
    (temp / 'test.rs').write_text(fixture)
    subprocess.run([os.environ.get('RUSTC', 'rustc'), '--edition=2021', '--test',
                    '-Dwarnings', str(temp / 'test.rs'), '-o', str(temp / 'test')], check=True)
    # Single-threaded: the runtime enable gate is a global atomic.
    subprocess.run([str(temp / 'test'), '--nocapture', '--test-threads=1'], check=True)

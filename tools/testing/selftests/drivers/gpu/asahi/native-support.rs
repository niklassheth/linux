// SPDX-License-Identifier: GPL-2.0-only
// Included by test-native-mesh.py with the actual support serializer.
use super::{baseline, g16_render};

fn read32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

#[test]
fn native_support_mode_preserves_identity_pointers_and_cursors() {
    for id in 3..60 {
        let pool = g16_render::OperandPool::new(0x10e0000000, 0x1100000000).unwrap();
        let initial = pool.support(id, 0xfffffc2002800000 + (id - 3) * 0x4000);
        let baseline_pool = baseline::OperandPool::new(0x10e0000000, 0x1100000000).unwrap();
        let expected = baseline_pool.support(id, 0xfffffc2002800000 + (id - 3) * 0x4000);
        // FList ring capacity (+0x1c) was shrunk from 0x80000 to 24576 (2 * 24 * 512).
        assert_eq!(read32(&initial, 0x1c), 24576);
        for offset in 0..initial.len() {
            if !(0x1c..0x20).contains(&offset) {
                assert_eq!(initial[offset], expected[offset], "offset {offset:#x}");
            }
        }
        let mut native = initial;
        g16_render::initialize_native_support(&mut native);
        assert_eq!(read32(&native, 0x10), 2);
        assert_eq!(read32(&native, 0x40), 4);
        for offset in 0..native.len() {
            if !(0x10..0x14).contains(&offset) && !(0x40..0x44).contains(&offset) {
                assert_eq!(native[offset], initial[offset]);
            }
        }
    }
}


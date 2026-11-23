// SPDX-License-Identifier: GPL-2.0-only

use g16_snapshot::WordSnapshot;

#[test]
fn holds_all_32_active_queues_beyond_old_32_entry_limit() {
    let mut snap = WordSnapshot::<128>::default();
    let mut reads = 0usize;

    // 32 simultaneous active queues x 3 lanes = 96 distinct lane stamp addresses.
    for q in 0..32u64 {
        for lane in 0..3u64 {
            let addr = 0xffff_fc22_1000_0000 + q * 0x24000 + lane * 0xc000 + 0x5040;
            let expected = ((q * 3 + lane + 1) as u32) * 0x100;
            let v: u32 = snap
                .read_with::<()>(addr, |_| {
                    reads += 1;
                    Ok(expected)
                })
                .unwrap();
            assert_eq!(v, expected);
        }
    }
    assert_eq!(reads, 96);

    // Every single one of the 96 lane stamps is cached and peekable (zero drops).
    for q in 0..32u64 {
        for lane in 0..3u64 {
            let addr = 0xffff_fc22_1000_0000 + q * 0x24000 + lane * 0xc000 + 0x5040;
            let expected = ((q * 3 + lane + 1) as u32) * 0x100;
            assert_eq!(snap.peek(addr), Some(expected));
            // Second read_with hits cache without invoking reader.
            let v: u32 = snap
                .read_with::<()>(addr, |_| {
                    reads += 1;
                    Ok(expected + 0x100)
                })
                .unwrap();
            assert_eq!(v, expected);
        }
    }
    assert_eq!(reads, 96);
}

#[test]
fn overflow_falls_back_to_direct_read_without_evicting_existing_entries() {
    let mut snap = WordSnapshot::<4>::default();
    for i in 0..4u64 {
        let v: u32 = snap.read_with::<()>(0x1000 + i * 8, |_| Ok((i as u32) + 1)).unwrap();
        assert_eq!(v, (i as u32) + 1);
    }

    // 5th distinct address reads live without evicting entries 0..4.
    let mut extra_reads = 0usize;
    let v1: u32 = snap
        .read_with::<()>(0x2000, |_| {
            extra_reads += 1;
            Ok(0x55)
        })
        .unwrap();
    let v2: u32 = snap
        .read_with::<()>(0x2000, |_| {
            extra_reads += 1;
            Ok(0x66)
        })
        .unwrap();
    assert_eq!((v1, v2, extra_reads), (0x55, 0x66, 2));
    assert_eq!(snap.peek(0x2000), None);
    for i in 0..4u64 {
        assert_eq!(snap.peek(0x1000 + i * 8), Some((i as u32) + 1));
    }
}

#[test]
fn forget_and_clear_invalidate_stale_entries() {
    let mut snap = WordSnapshot::<16>::default();
    for i in 0..6u64 {
        let _: u32 = snap.read_with::<()>(0x4000 + i * 0x10, |_| Ok((i as u32) * 0x100)).unwrap();
    }

    // Recycled queue storage forgets its 3 lane stamps; others stay cached.
    snap.forget(0x4010);
    snap.forget(0x4030);
    assert_eq!(snap.peek(0x4010), None);
    assert_eq!(snap.peek(0x4030), None);
    assert_eq!(snap.peek(0x4000), Some(0x0));
    assert_eq!(snap.peek(0x4020), Some(0x200));
    assert_eq!(snap.peek(0x4040), Some(0x400));
    assert_eq!(snap.peek(0x4050), Some(0x500));

    // Forgetting an absent address is a no-op.
    snap.forget(0x9999);
    assert_eq!(snap.peek(0x4050), Some(0x500));

    // Clear resets everything for the next scan.
    snap.clear();
    for i in 0..6u64 {
        assert_eq!(snap.peek(0x4000 + i * 0x10), None);
    }
}

use g16_control_ring::{ControlRing, CAPACITY, MAX_IN_FLIGHT};

#[test]
fn half_ring_bound_blocks_128th_unacked_destroy_and_never_falsely_completes() {
    let mut ring = ControlRing::new(0);
    let mut hw_head = 0u32;
    let mut hw_ack = 0u32;
    let mut hw_tail = 0u32;
    let mut targets = Vec::new();

    // Enqueue MAX_IN_FLIGHT (127) entries while both firmware cursors stay at 0.
    for _ in 0..MAX_IN_FLIGHT {
        assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
        assert!(ring.has_room());
        let (_slot, succ) = ring.next_slot();
        hw_tail = succ;
        let target = ring.commit();
        targets.push(target);
    }

    // The 128th entry (which previously pushed target 129 and falsely satisfied
    // modular reached(0, 129, 256)) MUST be rejected while cursors stay at 0.
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(!ring.has_room());
    for &t in &targets {
        assert!(!ring.reached(t));
    }

    // Advancing only hw_head (ack still stalled at 0) still blocks admission
    // and keeps every destroy target pending.
    hw_head = 127;
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(!ring.has_room());
    for &t in &targets {
        assert!(!ring.reached(t));
    }

    // Advancing hw_ack halfway collects only the acknowledged prefix and opens
    // exactly that much room.
    hw_ack = 64;
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(ring.has_room());
    for (idx, &t) in targets.iter().enumerate() {
        assert_eq!(ring.reached(t), idx < 64);
    }
}

#[test]
fn delayed_collection_across_multiple_wraps_and_mixed_tvb_traffic() {
    let mut ring = ControlRing::new(3);
    let mut hw_head = 3u32;
    let mut hw_ack = 3u32;
    let mut hw_tail = 3u32;

    // Publish an early destroy entry at epoch 4, then leave it uncollected
    // while 600 mixed TVB replies + destroys wrap the 256-entry ring twice.
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    let (_, succ) = ring.next_slot();
    hw_tail = succ;
    let early_destroy = ring.commit();
    assert_eq!(early_destroy, 4);

    let mut pending = vec![early_destroy];
    let mut fw_head = 3u64;
    let mut fw_ack = 3u64;
    let mut fw_tail = 4u64;
    for step in 0..600u32 {
        assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
        if !ring.has_room() {
            // Firmware advances head up to 60 entries (capped by tail) and
            // lags ack up to 50 entries (capped by head).
            fw_head = (fw_head + 60).min(fw_tail);
            fw_ack = (fw_ack + 50).min(fw_head);
            hw_head = (fw_head & (CAPACITY as u64 - 1)) as u32;
            hw_ack = (fw_ack & (CAPACITY as u64 - 1)) as u32;
            assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
            assert!(ring.has_room());
        }
        let (_, succ) = ring.next_slot();
        hw_tail = succ;
        fw_tail += 1;
        let epoch = ring.commit();
        if step % 3 == 0 {
            pending.push(epoch);
        }
    }

    // Even after wrapping 256 twice, early_destroy (epoch 4) is still reached!
    assert!(ring.reached(early_destroy));

    // Drain firmware completely; every pending entry must now be reached.
    hw_head = hw_tail;
    hw_ack = hw_tail;
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    for t in pending {
        assert!(ring.reached(t));
    }

    // A render whose own TVB reply epoch was reached (or 0 for no reply) is
    // not blocked by newer unacknowledged queue destroys.
    let (_, succ) = ring.next_slot();
    hw_tail = succ;
    let newer_destroy = ring.commit();
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(ring.reached(0));
    assert!(ring.reached(early_destroy));
    assert!(!ring.reached(newer_destroy));
}

#[test]
fn rejects_out_of_range_and_corrupt_cursors() {
    let mut ring = ControlRing::new(3);
    assert_eq!(ring.observe(256, 3, 3), Err(()));
    assert_eq!(ring.observe(3, 256, 3), Err(()));
    assert_eq!(ring.observe(3, 3, 256), Err(()));
    // Tail divergence (driver is the sole tail writer).
    assert_eq!(ring.observe(3, 3, 4), Err(()));
    // Firmware cursor overtaking tail.
    assert_eq!(ring.observe(4, 3, 3), Err(()));
    assert_eq!(ring.observe(3, 4, 3), Err(()));
}

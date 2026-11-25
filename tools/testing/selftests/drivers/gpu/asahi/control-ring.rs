// SPDX-License-Identifier: GPL-2.0-only
use g16_control_ring::{ControlRing, DeferredEvent, CAPACITY, MAX_IN_FLIGHT};

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

#[test]
fn deferred_event_pins_owner_across_swap_remove_reordering() {
    #[derive(Clone, Copy)]
    struct Render {
        id: u64,
        pending_event: bool,
        reply_epoch: u64,
    }

    let mut ring = ControlRing::new(0);
    let mut hw_head = 0u32;
    let mut hw_ack = 0u32;
    let mut hw_tail = 0u32;
    for _ in 0..MAX_IN_FLIGHT {
        let (_, succ) = ring.next_slot();
        hw_tail = succ;
        ring.commit();
    }
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(!ring.has_room());

    // Three in-flight renders sharing context/TVB slot; flight 0 will retire
    // and swap_remove flight 3 into index 0, reordering flight 2 ahead of 1.
    let mut flights = vec![
        Render { id: 10, pending_event: false, reply_epoch: 0 },
        Render { id: 100, pending_event: false, reply_epoch: 0 },
        Render { id: 200, pending_event: false, reply_epoch: 0 },
    ];
    let mut deferred = DeferredEvent::new();
    let event_cursor = 7u32;

    // First service pass matches flight id=100 (index 1); ring is full -> defer.
    let pick = |flights: &[Render], deferred: &DeferredEvent, cursor: u32| -> usize {
        if let Some(id) = deferred.pinned_flight(cursor) {
            flights.iter().position(|f| f.id == id).unwrap()
        } else {
            // Unpinned match picks the first render with id >= 100.
            flights.iter().position(|f| f.id >= 100).unwrap()
        }
    };

    let idx1 = pick(&flights, &deferred, event_cursor);
    assert_eq!(flights[idx1].id, 100);
    assert!(!ring.has_room());
    flights[idx1].pending_event = true;
    deferred.pin(event_cursor, flights[idx1].id);
    // Flight 100 must NOT retire while pending_event is true.
    assert!(flights[idx1].pending_event);

    // Unrelated flight 10 retires via swap_remove(0), moving id=200 ahead of id=100!
    flights.swap_remove(0);
    assert_eq!(flights[0].id, 200);
    assert_eq!(flights[1].id, 100);

    // Firmware frees one control-ring slot; retry MUST still select id=100, not 200!
    hw_head = 1;
    hw_ack = 1;
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(ring.has_room());

    let idx2 = pick(&flights, &deferred, event_cursor);
    assert_eq!(flights[idx2].id, 100);
    let (_, succ) = ring.next_slot();
    hw_tail = succ;
    flights[idx2].reply_epoch = ring.commit();
    flights[idx2].pending_event = false;
    deferred.clear();

    // Still held until reply_epoch is acknowledged, then both flags allow retire.
    assert!(!ring.reached(flights[idx2].reply_epoch));
    hw_head = hw_tail;
    hw_ack = hw_tail;
    assert_eq!(ring.observe(hw_head, hw_ack, hw_tail), Ok(()));
    assert!(!flights[idx2].pending_event && ring.reached(flights[idx2].reply_epoch));
    assert_eq!(deferred.pinned_flight(event_cursor), None);
}

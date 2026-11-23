use g16_headroom::{check_headroom, CapBlock, HeadroomBlock, LaneLoad};

fn empty_lanes() -> [LaneLoad; 3] {
    [LaneLoad::default(); 3]
}

#[test]
fn queue_cap_uses_exact_lower_bounds_for_render_and_compute() {
    let mut lanes = empty_lanes();
    lanes[0].owned = 47;
    lanes[1].owned = 47;
    // outstanding = 94, queue_cap = 96 -> render needs >= 2 (fits), compute needs >= 1 (fits).
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Ok(())
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Ok(())
    );

    // outstanding = 95, queue_cap = 96 -> render needs >= 2 (blocked), compute needs >= 1 (fits).
    lanes[0].owned = 48;
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Err(HeadroomBlock::QueueCap)
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Ok(())
    );

    // outstanding = 96, queue_cap = 96 -> both render and compute blocked.
    lanes[2].owned = 1;
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Err(HeadroomBlock::QueueCap)
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Err(HeadroomBlock::QueueCap)
    );

    // queue_cap == 0 disables the queue cap.
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 0, 0, 0, Some(lanes)),
        Ok(())
    );
}

#[test]
fn lane_cap_and_max_lane_works_only_check_target_stages() {
    let mut lanes = empty_lanes();
    // Saturate compute lane (stage 2): render (stages 0, 1) must still pass.
    lanes[2].works = 64;
    lanes[2].load = 127;
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 0, 64, 127, Some(lanes)),
        Ok(())
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 0, 64, 127, Some(lanes)),
        Err(HeadroomBlock::LaneWorks)
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 0, 0, 127, Some(lanes)),
        Err(HeadroomBlock::LaneCap)
    );

    // Saturate fragment lane (stage 1) load: render blocked, compute passes.
    lanes[2] = LaneLoad::default();
    lanes[1].load = 96;
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 0, 0, 96, Some(lanes)),
        Err(HeadroomBlock::LaneCap)
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 0, 0, 96, Some(lanes)),
        Ok(())
    );

    // load == lane_cap - 1 passes lower-bound check (may still hit exact dep cap later).
    lanes[1].load = 95;
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 0, 0, 96, Some(lanes)),
        Ok(())
    );
}

#[test]
fn work_space_and_global_flight_caps_report_exact_reasons() {
    assert_eq!(
        check_headroom(true, false, 0, 1024, true, 96, 64, 96, None),
        Err(HeadroomBlock::WorkSpaceExhausted)
    );
    assert_eq!(
        check_headroom(true, false, 1, 1024, true, 96, 64, 96, None),
        Err(HeadroomBlock::WorkSpaceBusy)
    );
    assert_eq!(
        check_headroom(true, true, 1024, 1024, true, 96, 64, 96, None),
        Err(HeadroomBlock::FlightsFull)
    );
    assert_eq!(
        check_headroom(true, true, 10, 1024, false, 96, 64, 96, None),
        Err(HeadroomBlock::FlightsFull)
    );
    // Unprovisioned queue (lanes == None) passes queue/lane checks.
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 96, 64, 96, None),
        Ok(())
    );
}

#[test]
fn cap_block_unblocks_on_retire_or_runtime_cap_knob_change() {
    let base = CapBlock {
        retire_gen: 42,
        queue_cap: 96,
        lane_cap: 0,
    };
    assert!(!CapBlock::still_blocked(None, base));
    assert!(CapBlock::still_blocked(Some(base), base));

    // Any retirement advances retire_gen and unblocks.
    assert!(!CapBlock::still_blocked(
        Some(base),
        CapBlock {
            retire_gen: 43,
            ..base
        }
    ));
    // Runtime debugfs queue_cap or lane_cap change unblocks immediately.
    assert!(!CapBlock::still_blocked(
        Some(base),
        CapBlock {
            queue_cap: 120,
            ..base
        }
    ));
    assert!(!CapBlock::still_blocked(
        Some(base),
        CapBlock {
            lane_cap: 64,
            ..base
        }
    ));
    // Wrapping retire_gen still unblocks cleanly.
    let wrap = CapBlock {
        retire_gen: u64::MAX,
        ..base
    };
    assert!(!CapBlock::still_blocked(
        Some(wrap),
        CapBlock {
            retire_gen: wrap.retire_gen.wrapping_add(1),
            ..wrap
        }
    ));
}

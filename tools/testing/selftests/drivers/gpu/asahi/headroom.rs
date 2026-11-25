use g16_headroom::{
    caps_safe, check_exact_caps, check_headroom, CapBlock, CapPair, FlightCharge, HeadroomBlock,
    LaneLoad,
};
use std::sync::{Arc, Barrier};
use std::thread;

fn empty_lanes() -> [LaneLoad; 3] {
    [LaneLoad::default(); 3]
}

#[test]
fn queue_cap_uses_ledger_aligned_lower_bounds_for_render_and_compute() {
    let mut lanes = empty_lanes();
    lanes[0].owned = 48;
    lanes[1].owned = 47;
    // outstanding = 95, queue_cap = 96 -> both dependency-free render and compute
    // charge `owned += 1` in Ledger::add(), so both fit at 95 + 1 <= 96.
    assert_eq!(
        check_headroom(true, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Ok(())
    );
    assert_eq!(
        check_headroom(false, true, 10, 1024, true, 96, 0, 0, Some(lanes)),
        Ok(())
    );

    // Exact check with 1 dependency (queue_owned = 2) blocks at 95 + 2 > 96.
    let render_1dep = FlightCharge::render(false, 1, 0);
    assert_eq!(
        check_exact_caps(true, render_1dep, 96, 0, 0, Some(lanes)),
        Err(HeadroomBlock::QueueCap)
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
fn empty_queue_always_makes_forward_progress_under_queue_cap_1_and_lane_cap_1() {
    let empty = empty_lanes();
    // Dependency-free render on first pool use (initbm=true) has ring_entries=[2, 2, 0]
    // but Ledger charges queue_owned=1 and lane_load=[1, 1, 0].
    let first_render = FlightCharge::render(true, 0, 0);
    assert_eq!(first_render.ring_entries, [2, 2, 0]);
    assert_eq!(first_render.lane_load, [1, 1, 0]);
    assert_eq!(first_render.queue_owned, 1);

    // First render with 2 dependencies + initbm=true has queue_owned=3, TA load=3.
    let first_render_2deps = FlightCharge::render(true, 2, 0);
    assert_eq!(first_render_2deps.ring_entries, [4, 2, 0]);
    assert_eq!(first_render_2deps.lane_load, [3, 1, 0]);
    assert_eq!(first_render_2deps.queue_owned, 3);

    // Under queue_cap=1 or lane_cap=1, an empty queue MUST admit both!
    for (qcap, lcap) in [(1usize, 0usize), (0, 1), (1, 1), (2, 2)] {
        assert_eq!(
            check_headroom(true, true, 0, 1024, true, qcap, 64, lcap, Some(empty)),
            Ok(())
        );
        assert_eq!(
            check_exact_caps(true, first_render, qcap, 64, lcap, Some(empty)),
            Ok(())
        );
        assert_eq!(
            check_exact_caps(true, first_render_2deps, qcap, 64, lcap, Some(empty)),
            Ok(())
        );
        assert_eq!(
            check_headroom(false, true, 0, 1024, true, qcap, 64, lcap, Some(empty)),
            Ok(())
        );
        assert_eq!(
            check_exact_caps(false, FlightCharge::compute(2), qcap, 64, lcap, Some(empty)),
            Ok(())
        );
    }

    // Once that first flight is in flight (outstanding=1, load=[1, 1, 0]),
    // a second render blocks cleanly on queue_cap=1 or lane_cap=1 until retire.
    let mut busy = empty_lanes();
    busy[0] = LaneLoad {
        works: 1,
        load: 1,
        owned: 1,
    };
    busy[1] = LaneLoad {
        works: 1,
        load: 1,
        owned: 0,
    };
    assert_eq!(
        check_headroom(true, true, 1, 1024, true, 1, 64, 0, Some(busy)),
        Err(HeadroomBlock::QueueCap)
    );
    assert_eq!(
        check_headroom(true, true, 1, 1024, true, 0, 64, 1, Some(busy)),
        Err(HeadroomBlock::LaneCap)
    );
    assert_eq!(
        check_exact_caps(true, first_render, 0, 64, 1, Some(busy)),
        Err(HeadroomBlock::LaneCap)
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
    // Exact check with 1 fragment dep (lane_load[1] = 2) blocks at 95 + 2 > 96.
    assert_eq!(
        check_exact_caps(true, FlightCharge::render(false, 0, 1), 0, 0, 96, Some(lanes)),
        Err(HeadroomBlock::LaneCap)
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

#[test]
fn cap_pair_rejects_unsafe_pairs_and_serializes_concurrent_clears() {
    let pair = CapPair::new(96, 120);
    assert_eq!(pair.load(), (96, 120));
    assert_eq!(pair.init(0, 0), Err(()));
    assert_eq!(pair.init(0, 128), Err(()));
    assert_eq!(pair.init(128, 0), Err(()));
    assert_eq!(pair.init(96, 128), Err(()));
    assert_eq!(pair.init(0, 120), Ok(()));
    assert_eq!(pair.update_lane(0), Err(()));
    assert_eq!(pair.load(), (0, 120));

    // Race two writers attempting to clear queue_cap and lane_cap simultaneously
    // from (96, 120): in every single round, exactly one succeeds and the pair
    // NEVER becomes (0, 0).
    let shared = Arc::new(CapPair::new(96, 120));
    for _ in 0..2000 {
        shared.init(96, 120).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let s1 = Arc::clone(&shared);
        let b1 = Arc::clone(&barrier);
        let t1 = thread::spawn(move || {
            b1.wait();
            s1.update_queue(0).is_ok()
        });
        let s2 = Arc::clone(&shared);
        let b2 = Arc::clone(&barrier);
        let t2 = thread::spawn(move || {
            b2.wait();
            s2.update_lane(0).is_ok()
        });
        let ok1 = t1.join().unwrap();
        let ok2 = t2.join().unwrap();
        assert!(ok1 ^ ok2, "expected exactly one clear to succeed: ok1={ok1} ok2={ok2}");
        let (q, l) = shared.load();
        assert!(caps_safe(q, l), "observed unsafe cap pair ({q}, {l})");
        assert_ne!((q, l), (0, 0));
    }
}

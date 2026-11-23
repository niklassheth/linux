// SPDX-License-Identifier: GPL-2.0-only

use g16_wait_state::{has_uncovered_timestamps, latest_covered_timestamp, LaneWaits};

const A_3D: u64 = 0xffff_fc22_1000_1040;
const A_CDM: u64 = 0xffff_fc22_1000_d040;

#[test]
fn note_wait_is_monotonic_and_separates_kind0_from_kind1() {
    let mut waited = LaneWaits::new();

    // Kind-0 wait at 0x200 covers kind 0 up to 0x200, never kind 1.
    waited.note(2, A_3D, 0x200, 0);
    assert!(waited.covers(2, A_3D, 0x100, 0));
    assert!(waited.covers(2, A_3D, 0x200, 0));
    assert!(!waited.covers(2, A_3D, 0x300, 0));
    assert!(!waited.covers(2, A_3D, 0x100, 1));
    assert!(!waited.covers(2, A_3D, 0x200, 1));

    // Older wait at 0x100 (kind 0) must never regress any_value from 0x200.
    waited.note(2, A_3D, 0x100, 0);
    assert!(waited.covers(2, A_3D, 0x200, 0));

    // Kind-1 wait at 0x200 covers both kind 0 and kind 1 up to 0x200.
    waited.note(2, A_3D, 0x200, 1);
    assert!(waited.covers(2, A_3D, 0x200, 1));
    assert!(waited.covers(2, A_3D, 0x200, 0));

    // Older kind-1 wait at 0x100 must never regress kind1_value from 0x200.
    waited.note(2, A_3D, 0x100, 1);
    assert!(waited.covers(2, A_3D, 0x200, 1));

    // Later kind-0 wait at 0x300 advances kind-0 coverage to 0x300 without
    // claiming kind-1 coverage past 0x200.
    waited.note(2, A_3D, 0x300, 0);
    assert!(waited.covers(2, A_3D, 0x300, 0));
    assert!(waited.covers(2, A_3D, 0x200, 1));
    assert!(!waited.covers(2, A_3D, 0x300, 1));
}

#[test]
fn note_wait_handles_two_addresses_and_wraparound() {
    let mut waited = LaneWaits::new();
    waited.note(0, A_3D, 0xffff_ff00, 1);
    waited.note(0, A_CDM, 0xffff_fe00, 0);

    // Advance across u32 wraparound.
    waited.note(0, A_3D, 0x0000_0100, 1);
    assert!(waited.covers(0, A_3D, 0x0000_0100, 1));
    assert!(waited.covers(0, A_3D, 0xffff_ff00, 1));
    // Older pre-wrap stamp must not regress post-wrap 0x100.
    waited.note(0, A_3D, 0xffff_ff00, 1);
    assert!(waited.covers(0, A_3D, 0x0000_0100, 1));
    // Second address slot stayed intact.
    assert!(waited.covers(0, A_CDM, 0xffff_fe00, 0));
}

#[test]
fn compute_lane_timestamp_cascade_is_prevented_without_losing_first_kind1() {
    let mut waited = LaneWaits::new();
    // C1 at 0x100 has user timestamps and remains in flight.
    let mut ts_flights = vec![(A_CDM, 0x100u32)];

    // C2 waits on C1 (0x100): must emit kind 1.
    assert!(has_uncovered_timestamps(&waited, 2, ts_flights.iter().copied(), A_CDM, 0x100));
    waited.note(2, A_CDM, 0x100, 1);

    // C3..C10 wait on C2..C9 (0x200..0x900) while C1 is still in flight:
    // lane 2 already serialized past C1 with kind 1, so no cascade!
    for step in 2..=9u32 {
        assert!(!has_uncovered_timestamps(
            &waited,
            2,
            ts_flights.iter().copied(),
            A_CDM,
            step * 0x100,
        ));
    }

    // New timestamped compute C11 at 0xb00 enters flight (unordered vs C1).
    ts_flights.insert(0, (A_CDM, 0xb00));
    // C12 waiting on C11 (0xb00) is NOT covered by the old 0x100 kind-1 wait.
    assert_eq!(
        latest_covered_timestamp(ts_flights.iter().copied(), A_CDM, 0xb00),
        Some(0xb00),
    );
    assert!(has_uncovered_timestamps(&waited, 2, ts_flights.iter().copied(), A_CDM, 0xb00));
    waited.note(2, A_CDM, 0xb00, 1);

    // C13 waiting on C12 (0xc00) is covered again.
    assert!(!has_uncovered_timestamps(&waited, 2, ts_flights.iter().copied(), A_CDM, 0xc00));
}

#[test]
fn render_producer_timestamps_require_kind1_on_compute_even_after_kind0_wait() {
    let mut waited = LaneWaits::new();
    // R1 (0x100) has user timestamps; R2 (0x200) does not.
    let ts_flights = [(A_3D, 0x100u32)];

    // Even if lane 2 had a kind-0 wait at 0x100, R1's timestamps are uncovered!
    waited.note(2, A_3D, 0x100, 0);
    assert!(has_uncovered_timestamps(&waited, 2, ts_flights, A_3D, 0x100));
    // A wait on R2 (0x200) also covers R1 (0x100) and must stay kind 1 until covered.
    assert!(has_uncovered_timestamps(&waited, 2, ts_flights, A_3D, 0x200));

    // A kind-1 wait on lane 0 (TA) must NOT satisfy lane 2 (Compute).
    waited.note(0, A_3D, 0x100, 1);
    assert!(has_uncovered_timestamps(&waited, 2, ts_flights, A_3D, 0x100));

    // Once lane 2 itself emits kind 1 covering R1 (0x100):
    waited.note(2, A_3D, 0x100, 1);
    assert!(!has_uncovered_timestamps(&waited, 2, ts_flights, A_3D, 0x100));
    assert!(!has_uncovered_timestamps(&waited, 2, ts_flights, A_3D, 0x200));
    assert!(waited.covers(2, A_3D, 0x100, 0));
    assert!(waited.covers(2, A_3D, 0x100, 1));
    // Waiting on R2 (0x200) is not elided as repeat, and only needs kind 0 now.
    assert!(!waited.covers(2, A_3D, 0x200, 0));
}

#[test]
fn prune_prevents_rollover_false_coverage() {
    let mut waited = LaneWaits::new();
    waited.note(2, A_3D, 0x100, 1);
    assert!(waited.covers(2, A_3D, 0x100, 1));

    // While within a quarter-ring, the remembered wait stays intact.
    waited.prune(A_3D, 0x3fff_ff00);
    assert!(waited.covers(2, A_3D, 0x100, 1));

    // Once a quarter-ring has passed, prune drops it well before the 0x8000_0000 wrap.
    waited.prune(A_3D, 0x4000_0100);
    assert!(!waited.covers(2, A_3D, 0x100, 1));
    assert!(!waited.covers(2, A_3D, 0x100, 0));

    // A brand-new stamp 9M Works ahead (past half-range from 0x100) is never
    // falsely matched by the ancient 0x100 wait.
    let far_stamp = 0x9000_0100u32;
    assert!(!waited.covers(2, A_3D, far_stamp, 1));
    assert!(has_uncovered_timestamps(&waited, 2, [(A_3D, far_stamp)], A_3D, far_stamp));
}

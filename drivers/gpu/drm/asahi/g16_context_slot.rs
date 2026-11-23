// SPDX-License-Identifier: GPL-2.0-only
// Copyright The Gravity Linux Contributors

//! Pure ASID context slot selection (slots 1..64; slot 0 is firmware/bootstrap).
//!
//! Keeps idle clients' roots resident in unused slots instead of evicting them
//! back and forth on the preferred slot, avoiding `tlbi aside1os` and `ttbs`
//! remapping on every client switch. Pure slot logic, host-tested.

/// Select an ASID slot in `1..64` for `target`.
///
/// Returns `Some((slot, existing))`, where `existing` is `true` when `slot` is
/// already bound to `target` (no `set_context` / `tlbi_asid` needed).
///
/// Selection order:
/// 1. Reuse the slot already bound to `target`.
/// 2. Use `preferred` if it is genuinely empty (`roots[preferred].is_none()` and
///    `users[preferred] == 0`).
/// 3. Use any genuinely empty slot in `1..64`.
/// 4. Only when all 63 client slots are populated, evict an idle slot
///    (`users[slot] == 0`) starting from `*evict_next` in round-robin order so
///    alternating active clients do not thrash on a single slot while other
///    idle slots remain untouched.
pub(crate) fn select_slot(
    roots: &[Option<u64>; 64],
    users: &[u32; 64],
    target: u64,
    preferred: usize,
    evict_next: &mut u8,
) -> Option<(usize, bool)> {
    if let Some(slot) = (1..64).find(|&i| roots[i] == Some(target)) {
        return Some((slot, true));
    }
    if (1..64).contains(&preferred) && roots[preferred].is_none() && users[preferred] == 0 {
        return Some((preferred, false));
    }
    if let Some(slot) = (1..64).find(|&i| roots[i].is_none() && users[i] == 0) {
        return Some((slot, false));
    }
    let start = if (1..64).contains(&usize::from(*evict_next)) {
        usize::from(*evict_next) - 1
    } else {
        0
    };
    for offset in 0..63 {
        let slot = 1 + (start + offset) % 63;
        if users[slot] == 0 {
            *evict_next = (1 + (slot % 63)) as u8;
            return Some((slot, false));
        }
    }
    None
}

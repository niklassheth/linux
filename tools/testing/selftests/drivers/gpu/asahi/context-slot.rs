// SPDX-License-Identifier: GPL-2.0-only

use g16_context_slot::select_slot;

struct FakeContexts {
    roots: [Option<u64>; 64],
    users: [u32; 64],
    evict_next: u8,
    binds: usize,
    evictions: usize,
}

impl FakeContexts {
    fn new() -> Self {
        Self {
            roots: [None; 64],
            users: [0; 64],
            evict_next: 1,
            binds: 0,
            evictions: 0,
        }
    }

    fn acquire(&mut self, root: u64, preferred: usize) -> Option<usize> {
        let (slot, existing) =
            select_slot(&self.roots, &self.users, root, preferred, &mut self.evict_next)?;
        assert!((1..64).contains(&slot), "slot 0 is reserved for firmware");
        if !existing {
            assert_eq!(self.users[slot], 0, "must never evict an active slot");
            if self.roots[slot].is_some() {
                self.evictions += 1;
            }
            self.roots[slot] = Some(root);
            self.binds += 1;
        } else {
            assert_eq!(self.roots[slot], Some(root));
        }
        self.users[slot] += 1;
        Some(slot)
    }

    fn release_user(&mut self, slot: usize) {
        self.users[slot] -= 1;
    }

    fn release_vm(&mut self, root: u64) {
        for i in 1..64 {
            if self.roots[i] == Some(root) {
                assert_eq!(self.users[i], 0);
                self.roots[i] = None;
            }
        }
    }
}

#[test]
fn two_alternating_clients_do_not_thrash_preferred_slot() {
    let mut ctx = FakeContexts::new();
    let game = 0x1000_0000;
    let kwin = 0x2000_0000;

    let s_game = ctx.acquire(game, 9).unwrap();
    assert_eq!(s_game, 9);
    ctx.release_user(s_game);

    // KWin arrives while game is idle in slot 9: must pick an empty slot,
    // not evict game out of slot 9.
    let s_kwin = ctx.acquire(kwin, 9).unwrap();
    assert_ne!(s_kwin, s_game);
    assert_eq!(ctx.evictions, 0);
    ctx.release_user(s_kwin);

    // 100 frame alternations between game and kwin: zero evictions, zero rebinds.
    for _ in 0..100 {
        let g = ctx.acquire(game, 9).unwrap();
        assert_eq!(g, s_game);
        ctx.release_user(g);

        let k = ctx.acquire(kwin, 9).unwrap();
        assert_eq!(k, s_kwin);
        ctx.release_user(k);
    }
    assert_eq!(ctx.binds, 2);
    assert_eq!(ctx.evictions, 0);
}

#[test]
fn alternating_render_and_compute_across_multiple_vms_stay_warm() {
    let mut ctx = FakeContexts::new();
    let vms: Vec<(u64, u64)> = (1..=8)
        .map(|i| (i * 0x1_0000, i * 0x1_0000 + 0x4000))
        .collect();

    let mut assigned = Vec::new();
    for &(render_root, compute_root) in &vms {
        let sr = ctx.acquire(render_root, 9).unwrap();
        ctx.release_user(sr);
        let sc = ctx.acquire(compute_root, 1).unwrap();
        ctx.release_user(sc);
        assigned.push((sr, sc));
    }
    assert_eq!(ctx.evictions, 0);
    assert_eq!(ctx.binds, 16);

    for _ in 0..20 {
        for (&(render_root, compute_root), &(sr, sc)) in vms.iter().zip(&assigned) {
            assert_eq!(ctx.acquire(render_root, 9).unwrap(), sr);
            ctx.release_user(sr);
            assert_eq!(ctx.acquire(compute_root, 1).unwrap(), sc);
            ctx.release_user(sc);
        }
    }
    assert_eq!(ctx.evictions, 0);
    assert_eq!(ctx.binds, 16);
}

#[test]
fn full_table_evicts_round_robin_without_thrashing_active_pair() {
    let mut ctx = FakeContexts::new();
    // Fill all 63 client slots with idle VMs.
    for i in 1..=63u64 {
        let s = ctx.acquire(i << 16, 9).unwrap();
        ctx.release_user(s);
    }
    assert_eq!(ctx.evictions, 0);

    // Two new active clients alternate: round-robin eviction places them in
    // distinct slots so they stay resident after their initial eviction.
    let active_a = 0xaa << 16;
    let active_b = 0xbb << 16;

    let sa = ctx.acquire(active_a, 9).unwrap();
    ctx.release_user(sa);
    let sb = ctx.acquire(active_b, 9).unwrap();
    ctx.release_user(sb);
    assert_ne!(sa, sb);
    assert_eq!(ctx.evictions, 2);

    for _ in 0..50 {
        assert_eq!(ctx.acquire(active_a, 9).unwrap(), sa);
        ctx.release_user(sa);
        assert_eq!(ctx.acquire(active_b, 9).unwrap(), sb);
        ctx.release_user(sb);
    }
    assert_eq!(ctx.evictions, 2);
}

#[test]
fn never_touches_slot_zero_or_active_slots_and_reuses_released_slots() {
    let mut ctx = FakeContexts::new();
    ctx.roots[0] = Some(0xdead_0000);

    // Even if slot 0 holds target or preferred == 0, slot 0 is never returned.
    let s = ctx.acquire(0xdead_0000, 0).unwrap();
    assert!((1..64).contains(&s));
    ctx.release_user(s);
    ctx.release_vm(0xdead_0000);

    // Hold all 63 slots active simultaneously: a 64th must fail with None.
    let mut slots = Vec::new();
    for i in 1..=63u64 {
        slots.push(ctx.acquire(i << 20, 9).unwrap());
    }
    assert!(ctx.acquire(64 << 20, 9).is_none());

    // Releasing one active user + destroying its VM opens an empty slot.
    let freed = slots[5];
    ctx.release_user(freed);
    ctx.release_vm(6 << 20);
    let reused = ctx.acquire(64 << 20, 9).unwrap();
    assert_eq!(reused, freed);
    assert_eq!(ctx.evictions, 0);
}

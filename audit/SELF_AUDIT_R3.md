# Darbitex Sui — Self-Audit R3 (post-G-2 view additions)

**Scope:** Re-audit after adding 3 read-only view functions per G-2/K-1 finding (Gemini + Grok converged). `pool.move` 516 → 529 LOC (+13).

**Method:** Diff-vs-R2 + per-fn semantic check + invariant re-check + test parity.

**Build:** 0 errors, 4 W99001 lint (unchanged from R1/R2).
**Tests:** 21/21 PASS (no test changes).

---

## Diff vs R2

| File | R2 | R3 | Δ |
|------|----|----|---|
| `pool.move` | 516 | 529 | +13 |
| `pool_factory.move` | 190 | 190 | 0 |

**Added** (`pool.move:513-525`):
```move
public fun fee_per_share<A, B>(pool: &Pool<A, B>): (u128, u128) {
    (pool.lp_fee_per_share_a, pool.lp_fee_per_share_b)
}
public fun position_fee_debt<A, B>(pos: &LpPosition<A, B>): (u128, u128) {
    (pos.fee_debt_a, pos.fee_debt_b)
}
public fun pending_fees<A, B>(pool: &Pool<A, B>, pos: &LpPosition<A, B>): (u64, u64) {
    (
        pending_from_accumulator(pool.lp_fee_per_share_a, pos.fee_debt_a, pos.shares),
        pending_from_accumulator(pool.lp_fee_per_share_b, pos.fee_debt_b, pos.shares),
    )
}
```

**No other changes.** No struct field added/removed, no error code added, no event added, no entry function added, no invariant relaxed.

---

## Per-function review

### `fee_per_share<A, B>(&Pool<A,B>) -> (u128, u128)`
- Read-only by-ref borrow; returns tuple of immutable u128 fields.
- No mutation, no abort path, no math.
- `&Pool` is the standard composability pattern (no exclusive lock required).
- u128 exposure: same internal type already used in events (none) and storage. Frontends already index these via RPC `getObject` — view fn just makes the data on-chain accessible.
- **Risk: None.** Pure getter.

### `position_fee_debt<A, B>(&LpPosition<A,B>) -> (u128, u128)`
- Read-only by-ref borrow on user-owned NFT.
- No mutation, no abort path.
- `&LpPosition` (not `&mut`) — non-exclusive read.
- **Risk: None.** Pure getter.

### `pending_fees<A, B>(&Pool, &LpPosition) -> (u64, u64)`
- Composes the two private fields via existing `pending_from_accumulator(per_share_current, per_share_debt, shares)`.
- The helper has 2 paths:
  - `per_share_current <= per_share_debt` → returns 0 (early, no math).
  - else `((delta * shares) / SCALE) as u64`. Bounds: delta u128 max ≈ 3.4e38, shares u64 max ≈ 1.8e19, product ≤ 6.1e57 fits u256 (max 1.16e77). Final `as u64` cast safe because mathematically `pending ≤ pool.balance_X - pool.reserve_X` which is u64-bounded.
- Both A and B sides computed identically.
- This is the SAME computation `claim_lp_fees` performs internally before withdrawing real coins. The view returns the same number without performing the withdrawal — exactly what satellites need.
- **Risk: None.** Reuses an audited helper, no new arithmetic surface.

---

## Invariant re-check

| Invariant | R2 | R3 |
|-----------|----|----|
| Reentrancy: structurally impossible | ✓ | ✓ (read-only views can't reenter) |
| `balance_X == reserve_X + cumulative_unclaimed_fees` | ✓ | ✓ (no state touched) |
| `k_after >= k_before` at flash repay | ✓ | ✓ |
| Zero admin / zero privileged path post-seal | ✓ | ✓ (views are unprivileged) |
| Canonical-pair-per-(A,B) | ✓ | ✓ |
| Type safety via phantom A/B | ✓ | ✓ (views correctly phantom-generic) |
| u256 promote on math | ✓ | ✓ (pending_fees reuses existing) |
| Coin<T>-only | ✓ | ✓ |

---

## Composability impact (positive)

These views unlock:
1. **On-chain LP-staking satellite** can read `pending_fees(&pool, &user_position)` and trigger auto-compound (claim → re-add) without duplicating accumulator state.
2. **lp-locker satellite** can show pending fees pre-redemption to UIs that read on-chain only (e.g., a wallet that doesn't query our indexer).
3. **3rd-party frontends** can compute APY estimates on-chain without trusting an off-chain oracle.

Trade-off vs not adding them: **None at security or correctness layer.** Adds 4 view functions to the public surface, all read-only with `&` borrows.

---

## Findings

**0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO.**

R1's I-1..I-5 inherit unchanged. No new findings.

---

## R3 verdict

**Safe.** Additive read-only views with no mutation, no new abort path, no math beyond reuse of an already-audited helper. Test parity maintained. Ready to re-bundle for second external R1 pass (optional) or proceed to deploy.

The added composability surface is one of the design choices the user can no longer revisit post-seal — locking these in pre-deploy is the correct call.

# External R1 Audit — Gemini 3.1 Pro

**Auditor:** Gemini 3.1 Pro (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 516 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R1-BUNDLE.md` (commit `161a9e8`)

## Verdict

**GREEN.** "The contract logic is mathematically sound, structurally protected against reentrancy by the framework, and highly defensive against edge-case overflows."

## Findings

| ID | Severity | Title | Location |
|----|----------|-------|----------|
| G-1 | INFO | Per-share accumulator rounds dust fees to 0 when `fee × SCALE < lp_supply` | `pool::accrue_fee` |
| G-2 | OBSERVATION (no severity) | Composability gap — accumulator + debt fields not exposed via public views | `pool` view surface |

**0 HIGH / 0 MEDIUM / 0 LOW.**

## Per-finding detail

### G-1 (INFO) — Dust-fee rounding floor

- **Description:** Standard MasterChef rounding: when a swap generates a fee of `1` raw unit on a massive pool (`lp_supply > 1e12`), `add = (fee * SCALE) / lp_supply` rounds down to 0.
- **Impact:** Dust stays in `balance_X` but never accrues to `lp_fee_per_share_X`. `balance_X > reserve_X + pending_claims` by tiny dust amount permanently. **No security threat** — it's a slow LP-side donation rounding, not a value extraction vector.
- **Recommendation:** Document in WARNING (or accept silently — it's a well-known V2-MasterChef-pattern artifact).

### G-2 (OBSERVATION) — Composability surface gap

- **Description:** External smart contracts (e.g. future LP-staking, lp-locker satellites) cannot read `pool.lp_fee_per_share_a/b` or `position.fee_debt_a/b`. Indexers can read via RPC, but on-chain dispatch (e.g. an "auto-compound" or "claim-and-restake" entry) cannot compute pending fees.
- **Impact:** Future LP-staking satellite needs either (a) the data bridge added now (sealed package = no later upgrade) OR (b) the satellite duplicates fee accounting separately, doubling state surface and breaking single-source-of-truth.
- **Recommendation:** Before sealing, add three public views:
  ```move
  public fun current_accumulator<A, B>(pool: &Pool<A, B>): (u128, u128)
  public fun position_debt<A, B>(pos: &LpPosition<A, B>): (u128, u128)
  public fun pending_fees<A, B>(pool: &Pool<A, B>, pos: &LpPosition<A, B>): (u64, u64)
  ```

## Q1-Q8 answers (excerpts)

- **Q1 (flash safety):** Confirmed safe across all four scenarios (same-pool swap-then-repay, add-during-borrow, parallel cross-pool, repay-with-wrong-side). Sui PTB sequential model + no Coin callback + `&mut Pool` exclusive lock.
- **Q2 (u256 sufficiency):** Swap numerator max ≈ 3.2e42, accumulator ≈ 6.1e57, both ≪ u256 max ≈ 1.16e77. Zero overflow risk.
- **Q3 (lex byte ordering):** `bytes_lt` correctly handles shared-prefix (shorter wins via length fallback) and same-type rejection (loop exhausts → length-equal → false → E_WRONG_ORDER).
- **Q4 (sealing irrevocability):** OriginCap by-value consumption in `destroy_cap` makes double-call impossible. `assert!(!factory.sealed, E_SEALED)` is technically redundant but useful for off-chain clarity.
- **Q5 (accumulator precision):** See G-1 above.
- **Q6 (optimal-pair edges):** `b_opt = 0` falls cleanly into `assert amount_b > 0` (E_ZERO_AMOUNT). Ratio overflow trapped by explicit `<= U64_MAX` cast guard. No arithmetic abort.
- **Q7 (composability):** See G-2 above.
- **Q8 (fuzz cases):**
  1. Dust flash: borrow `1` on max-liquidity pool → fee floor-up to 1 → repay 2 succeeds.
  2. Ratio overflow guard: `reserve_a = 1, reserve_b = U64_MAX, amount_a = U64_MAX` → clean E_INSUFFICIENT_LIQUIDITY (not abort).
  3. Min-viable swap: `1` into pool with `reserve_out = MINIMUM_LIQUIDITY` (1000) → verify output ≠ 0 with input fee charged.

## Other observations

- "Idiomatic and highly secure" — `LpPosition` NFT + typed `FlashReceiptA/B<A,B>` flagged as well-aligned with Sui object model.
- Verbatim: "It is mathematically impossible to call destroy_cap twice."

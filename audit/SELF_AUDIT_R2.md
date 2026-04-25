# Darbitex Sui — Self-Audit R2 (post-compaction)

**Scope:** Re-audit of `pool.move` + `pool_factory.move` after 33% LOC reduction (commit `161a9e8`). R1 findings inherit; this R2 verifies compaction did not introduce semantic regressions.

**Method:** Diff-vs-R1 + per-function semantic re-walk + invariant re-check + test parity.

**Build:** 0 errors, 4 W99001 lint (intentional, unchanged from R1).
**Tests:** 20/20 PASS (identical to R1 — same test suite, same assertions).

---

## Executive summary

| Severity | R1 count | R2 count | Δ |
|---|---|---|---|
| HIGH | 0 | 0 | — |
| MEDIUM | 0 | 0 | — |
| LOW | 0 | 0 | — |
| INFO | 5 | 5 | unchanged (I1-I5 from R1 still apply) |

**New findings introduced by compaction: 0.**

**Verdict:** Compacted code is semantically identical to R1 baseline. Ready for external R1.

---

## Diff vs R1 — what changed

| Change category | Examples | Risk |
|---|---|---|
| Module-doc compressed | 4 paragraphs → 2 short paragraphs | None (docs only) |
| Multi-paragraph WHY → 1-2 lines | Flash accounting note 11 → 5 lines | None — load-bearing context preserved |
| Restating-the-obvious comments dropped | `// Asserts amount > 0` next to `assert!(amount > 0, ...)` | None — error code is self-documenting |
| Single-use locals inlined | `let position_id = object::id(&pos); event::emit(...{position_id...})` → `event::emit(...{position_id: object::id(&pos)...})` | None — same value passed to event |
| Nested call composition | `coin::split → coin::into_balance → balance::join` chained without intermediate bindings | None — same call sequence, same arguments |
| `if-else` braces dropped on single-stmt branches | `if (a_side) X = X+add else Y = Y+add;` | None — Move 2024 expression syntax accepts this; tests pass |
| Struct fields collapsed onto same line | `pool_id: ID, swapper: address, ...` | None — same struct shape |
| Decorative blank lines removed | section dividers kept, intra-function blanks dropped | None — readability slight cost, structure still clear |
| `let mut z, let mut y` in sqrt single-line | `let mut z = (x + 1) / 2; let mut y = x;` → same line `while` | None — semantics preserved |

**No public surface changes.** Function signatures, event schemas, struct fields, error codes, and view fns all bit-for-bit identical to R1.

**No internal logic changes.** Every branch, assert, and arithmetic operation preserved.

---

## Per-function re-walk

### `pool::sqrt` — unchanged logic, 1-liner while body
```move
while (z < y) { y = z; z = (x / z + z) / 2; };
```
Babylonian iteration intact. Termination + edge case `x == 0` preserved.

### `pool::compute_amount_out` — variable names shortened (`amount_in_after_fee` → `in_after_fee`, etc.)
u256 promote chain unchanged. Cast safety unchanged.

### `pool::compute_flash_fee` — unchanged

### `pool::accrue_fee` — `if-else` braces dropped:
```move
if (a_side) pool.lp_fee_per_share_a = pool.lp_fee_per_share_a + add
else pool.lp_fee_per_share_b = pool.lp_fee_per_share_b + add;
```
Both branches mutually exclusive, both update u128 with identical scaling math. Trailing `;` correctly closes the if-else statement-expression. Tests cover both branches via swap_a_to_b and swap_b_to_a (test_swap_round_trip).

### `pool::pending_from_accumulator` — unchanged logic, 1-line return

### `pool::maybe_transfer` — `if-else` braces dropped:
```move
if (coin::value(&coin) > 0) transfer::public_transfer(coin, recipient)
else coin::destroy_zero(coin);
```
Branches mutually exclusive. `transfer::public_transfer<T: key + store>` succeeds; `coin::destroy_zero<T>` requires zero value (verified by guard). No regression.

### `pool::create_pool` — `let position_id = object::id(&position);` removed; inlined into LiquidityAdded event field. Same ID passed.

### `pool::swap_a_to_b` / `swap_b_to_a` — comment about u256 promote present on a_to_b only (mirror of b_to_a). Math identical, branch logic identical. Reserve update math:
- `pool.reserve_a + amount_in - lp_fee` — lp_fee = amount_in * 5 / 10000, always < amount_in for amount_in > 0 → no underflow.
- `pool.reserve_b - amount_out` — guarded by `amount_out < reserve_b`.

### `pool::add_liquidity` — variable rename `amount_b_optimal_u256` → `b_opt_u256`, etc. Logic identical:
- Optimal-pair math + u64 cast guard preserved.
- `coin::split → coin::into_balance → balance::join` chain composed inline (3 calls, same as R1's 3 statements).
- min(lp_a, lp_b) + slippage assert preserved.
- New position's `fee_debt_*` = current accumulator (unchanged).

### `pool::remove_liquidity` — destructure of LpPosition unchanged. claim + amount math via u256 unchanged. lp_supply -= shares + MINIMUM_LIQUIDITY floor unchanged. balance::split for `(amount + claim)` unchanged. `object::delete(id)` unchanged.

### `pool::claim_lp_fees` — `if (claim_X > 0) ... else coin::zero<X>(ctx)` inlined as expression. Same: if pending > 0, withdraw real coins; else return zero coin. Debt update unchanged. Position by-mut-ref preserved.

### `pool::flash_borrow_a` / `flash_borrow_b` — k_before snapshot, fee compute, balance::split, receipt construction — unchanged. Receipt now constructed in tuple-return position rather than via intermediate `let receipt = ...; (coin_out, receipt)` — same value.

### `pool::flash_repay_a` / `flash_repay_b` — destructure receipt, assert pool match, assert exact repay, balance::join, accrue_fee, k_after check — unchanged.

### Entry wrappers — deadline + delegate + transfer pattern unchanged.

### Views — unchanged.

### `pool_factory::init` — combined event emit + share_object + transfer into 3 lines (was 5). Same operations, same order.

### `pool_factory::bytes_lt` — unchanged.

### `pool_factory::assert_sorted` — unchanged borrow-then-move pattern via inner block.

### `pool_factory::create_canonical_pool` — table::contains check + delegate to pool::create_pool + table::add + count++ — unchanged.

### `pool_factory::destroy_cap` — unchanged. Order: !sealed assert → destructure → make_immutable → sealed=true → emit. Same as R1.

### `pool_factory::canonical_pool_id` — `if-else` PairKey construction inline. Same key-canonicalization logic (swap fields if not a-first). table::contains + table::borrow with PairKey copy semantics — unchanged.

---

## Invariant re-check

| Invariant | R1 status | R2 status |
|---|---|---|
| Reentrancy: structurally impossible (Sui no-callback) | ✓ | ✓ |
| `balance_a/b == reserve_a/b + cumulative_unclaimed_fees` | ✓ | ✓ |
| `k_after >= k_before` enforced at flash repay | ✓ | ✓ |
| Zero admin / zero privileged path post-seal | ✓ | ✓ |
| Canonical-pair-per-(A,B) via table | ✓ | ✓ |
| Type safety via phantom A/B + distinct FlashReceiptA/B | ✓ | ✓ |
| u256 promote on swap math, fee, k snapshot | ✓ | ✓ |
| Coin<T>-only (no Token<T>) | ✓ | ✓ |

---

## INFO findings (unchanged from R1)

- **I1**: dead-share floor unreachable through normal API
- **I2**: pool_id check in remove_liquidity / claim_lp_fees is tautological (defense-in-depth)
- **I3**: `accrue_fee`'s `lp_supply > 0` guard always true post-creation
- **I4**: `compute_flash_fee(0) = 1` unreachable via flash_borrow_*
- **I5**: destroy_cap field-ordering (cap destroyed → make_immutable → sealed=true) — no realistic abort path

---

## Compaction-specific concerns checked

1. **Inline `if-else` without braces in `accrue_fee` / `maybe_transfer`** — verified Move 2024.beta accepts as statement-expression. Tests cover both branches.
2. **PairKey copy semantics in `canonical_pool_id`** — `table::contains(&t, key)` then `table::borrow(&t, key)` works because PairKey has `copy` ability; compiler implicit-copies on each call.
3. **Borrow-then-move in `assert_sorted` / `canonical_pool_id`** — inner block scope releases ascii::as_bytes borrows before type_a/type_b are moved into PairKey.
4. **Nested `coin::split → into_balance → balance::join`** — composition order correct, no leaked Coin/Balance objects.
5. **Single-line struct field declarations on same line** — Move parser accepts; no field reordering or missing fields.

All concerns clear.

---

## Test parity

R1 tests (20 total) pass without modification on R2 source. Same assertions, same expected outputs. No test was added, removed, or changed during compaction.

| Test | R1 | R2 |
|---|---|---|
| test_sqrt, test_compute_amount_out, test_compute_flash_fee | PASS | PASS |
| test_assert_sorted_correct/wrong/same | PASS | PASS |
| test_create_pool_basic/duplicate/too_small | PASS | PASS |
| test_swap_round_trip, test_swap_slippage | PASS | PASS |
| test_add_liquidity_unbalanced | PASS | PASS |
| test_remove_liquidity | PASS | PASS |
| test_lp_fee_accrual_and_claim | PASS | PASS |
| test_flash_round_trip_a/b | PASS | PASS |
| test_flash_repay_underpay, test_flash_borrow_too_much | PASS | PASS |
| test_destroy_cap_seals, test_destroy_cap_twice_aborts | PASS | PASS |

---

## R2 verdict

**Compaction safe. Zero new findings. Code semantically identical to R1.** Ready to package for external R1 audit.

The compacted code is *cleaner* without losing any auditor-relevant context — module docs concentrate the WHY, inline comments only mark non-obvious load-bearing decisions, and structural patterns (sealing, hot-potato, accumulator) remain visually clear.

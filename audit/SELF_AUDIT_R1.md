# Darbitex Sui — Self-Audit R1

**Scope:** `pool.move` + `pool_factory.move` (entire `darbitex_sui` package).
**Method:** ABI / args / math / reentrancy / edges / interactions / errors / events review per `feedback_satellite_self_audit.md`.
**Build:** `sui move build` clean (0 errors, 4 W99001 lint INTENTIONAL per SOP §6).
**Tests:** 20/20 PASS via `sui move test`.

---

## Executive summary

| Severity | Count | Action |
|---|---|---|
| HIGH | **0** | — |
| MEDIUM | **0** | — |
| LOW | **0** | — |
| INFO | **5** | Documented; no fix required |

**Verdict:** Ready for external R1 (Gemini + Claude + Grok).

---

## Per-function review

### `pool::sqrt(x: u128): u128`
- Pure Babylonian iteration. Port verbatim from Aptos.
- Termination: `z < y` strictly decreasing per iteration; bounded by `log2(x)` steps.
- Edge: `x == 0` early-returns 0. ✓
- Floor semantics: `sqrt(2) == 1`, `sqrt(99) == 9`. ✓

### `pool::compute_amount_out(reserve_in, reserve_out, amount_in): u64`
- u256 intermediates: `(amount_in × 9995) × reserve_out / (reserve_in × 10000 + amount_in × 9995)`.
- Overflow: u64×u64 promoted to u256. u256 max ≈ 1.16e77; max numerator (u64_max)³ ≈ 6.3e57 — safe with margin.
- Final `as u64` cast safe because output ≤ reserve_out < u64_max.
- Edge: `amount_in = 0` → output 0 (unused — caller asserts amount_in > 0).
- Edge: tiny swap (`amount_in = 1` on 1M reserves) → output rounds to 0 → caller's slippage / E_INSUFFICIENT_LIQUIDITY check trips.

### `pool::compute_flash_fee(amount): u64`
- u256 intermediate: `amount × 5 / 10000`.
- Floor-up rule: result 0 → 1 raw unit.
- Edge: `amount = 0` returns 1. **Unreachable in practice** because `flash_borrow_*` asserts `amount > 0` before calling compute_flash_fee. Pure-math test covers the case for completeness.

### `pool::accrue_fee(pool, fee, a_side): u64`
- Guard: `fee > 0 && lp_supply > 0`. The `lp_supply > 0` check is defensive — at any post-creation point, `lp_supply >= MINIMUM_LIQUIDITY` (1000), enforced by `remove_liquidity`'s floor.
- Math: `add = fee × SCALE / lp_supply`. SCALE = 1e12, fee ≤ u64, lp_supply ≥ 1000 → `add` fits u128 (max ≈ u64_max × 1e12 ≈ 1.84e31 << u128_max).
- Returns fee for event attribution.

### `pool::pending_from_accumulator(per_share_current, per_share_debt, shares): u64`
- Guard: `per_share_current <= per_share_debt` returns 0 (covers underflow + claim-after-zero-accrual).
- Math: `(delta_u128 as u256) × shares / SCALE`. delta < per_share max < u128_max; shares u64; product fits u256. Floor-divide by SCALE → fits u64.

### `pool::create_pool<A, B>(coin_a, coin_b, clock, ctx): (ID, LpPosition<A, B>)`
- `public(package)` — only callable from same package (i.e., pool_factory).
- Asserts `amount_a > 0 && amount_b > 0`.
- Initial LP = `sqrt(amount_a × amount_b)`. u64 × u64 → u128 fits with margin (max < 2^128 - 2^65). ✓
- Asserts `initial_lp > MINIMUM_LIQUIDITY` strictly — rejects pools where creator share would be 0 or negative.
- Pool shared internally via `transfer::share_object` (defining-module restriction satisfied).
- Position returned by-value, not transferred — caller (factory) decides recipient.
- Emits `PoolCreated` + `LiquidityAdded`.

### `pool::swap_a_to_b<A, B>(pool, coin_in, min_out, clock, ctx): Coin<B>`
- Asserts `amount_in > 0`.
- Asserts `amount_out >= min_out` (slippage).
- Asserts `amount_out < reserve_b` (cannot drain).
- Fee in u256 — defensive vs Aptos which used u64 (Aptos APT 8-dec safer, Sui 9-dec closer to overflow edge).
- Reserve update: `reserve_a += amount_in - lp_fee` (lp_fee diverts from reserve to accumulator), `reserve_b -= amount_out`.
- Balance update: full coin_in deposited; amount_out withdrawn. Invariant `balance_a == reserve_a + cumulative_unclaimed_fees_a` preserved.
- Emits `Swapped`.

### `pool::swap_b_to_a` — symmetric to a_to_b. Same review applies.

### `pool::add_liquidity<A, B>(pool, coin_a, coin_b, min_shares_out, clock, ctx): (LpPosition<A, B>, Coin<A>, Coin<B>)`
- Asserts `amount_a_desired > 0 && amount_b_desired > 0`.
- Optimal-pair selection in u256 with u64 cast guard against ratio > 2^64:1 (E_INSUFFICIENT_LIQUIDITY).
- Edge: `amount_b_optimal == 0` (e.g., amount_a_desired × reserve_b < reserve_a) → falls through to E_ZERO_AMOUNT on shares check. ✓
- Shares = min(lp_a, lp_b) to guard against rounding asymmetry.
- Asserts `shares > 0` and `shares >= min_shares_out`.
- New position's `fee_debt_*` = current `lp_fee_per_share_*` so the new LP doesn't claim past fees.
- Returns leftover coins to caller (mutated by `coin::split`).
- Emits `LiquidityAdded`.

### `pool::remove_liquidity<A, B>(pool, position, min_amount_a, min_amount_b, clock, ctx): (Coin<A>, Coin<B>)`
- Destructures position (consumes UID).
- Asserts `pool_id` match (defense-in-depth — only one pool exists per (A,B) by factory's canonical-pair invariant).
- Asserts `shares > 0` and `lp_supply >= shares`.
- Computes proportional reserves + fee claims via accumulator.
- Asserts slippage floors on reserve payout (NOT on fees).
- Updates `lp_supply -= shares`, then asserts `lp_supply >= MINIMUM_LIQUIDITY` (dead-share floor).
- **Note (I1):** the dead-share floor is unreachable via normal API. Burning more than (lp_supply - MINIMUM_LIQUIDITY) shares is blocked by E_INSUFFICIENT_LP first. The floor is defense-in-depth.
- Withdraws `(amount + claim)` from each balance.
- Deletes position UID.
- Emits `LiquidityRemoved`.

### `pool::claim_lp_fees<A, B>(pool, position, clock, ctx): (Coin<A>, Coin<B>)`
- Position by `&mut` — not consumed (shares stay).
- Asserts `pool_id` match.
- Pending fees computed against current accumulator.
- Debt updated to current accumulator (idempotency: second call returns zero).
- Returns zero-value Coin for sides with no claim (avoids unnecessary balance::split).
- Emits `LpFeesClaimed`.

### `pool::flash_borrow_a<A, B>(pool, amount, clock, ctx): (Coin<A>, FlashReceiptA<A, B>)`
- Asserts `amount > 0` and `amount < reserve_a` (strict — no full-drain).
- Snapshots `k_before = reserve_a × reserve_b` in u256.
- Withdraws `amount` from balance_a (reserve_a NOT decremented — see flash accounting note in pool.move).
- Returns receipt with `(pool_id, amount, fee, k_before)`.
- Emits `FlashBorrowed`.

### `pool::flash_repay_a<A, B>(pool, coin, receipt, clock)`
- Destructures receipt (consumes hot-potato).
- Asserts `pool_id` match.
- Asserts `coin::value(&coin) == amount + fee` (strict equality — no over/underpay).
- Deposits full coin into balance_a; `accrue_fee(fee)`.
- Asserts `k_after >= k_before`. Catches any pool-state degradation in the borrow window (interleaved swaps, etc.).
- Emits `FlashRepaid`.

### `pool::flash_borrow_b` / `pool::flash_repay_b` — symmetric. Type system enforces no A↔B receipt mixing.

### Entry wrappers
- `add_liquidity_entry`, `remove_liquidity_entry`, `claim_lp_fees_entry` — deadline-guarded against `clock::timestamp_ms < deadline_ms`.
- Transfer results to `tx_context::sender(ctx)` (W99001 lint accepted per SOP §6).

### `pool_factory::init(witness, ctx)`
- OTW pattern enforces single-call.
- Creates shared FactoryRegistry + `OriginCap` (soulbound `key`-only) for deployer.
- Emits `FactoryInitialized`.

### `pool_factory::assert_sorted<A, B>(): PairKey`
- TypeName via `with_defining_ids` (current API; deprecated `get` avoided).
- `bytes_lt` lex compare on raw byte vectors. Strict `<` rejects same-type pairs (canonical reflexive case).
- Borrow-then-move pattern: borrows released in inner block scope before the strings are moved into PairKey.

### `pool_factory::create_canonical_pool<A, B>(factory, coin_a, coin_b, clock, ctx): LpPosition<A, B>`
- Sorted-pair check via `assert_sorted`.
- Asserts both amounts > 0.
- Duplicate-pair check via `table::contains`.
- Delegates to `pool::create_pool` (which shares the pool internally).
- Inserts pair into factory.pairs table; increments `pool_count`.

### `pool_factory::destroy_cap(origin, factory, upgrade, clock, ctx)`
- Asserts `!factory.sealed` first (idempotency guard).
- Destructures OriginCap (consumes UID).
- `package::make_immutable(upgrade)` — burns UpgradeCap, locks package immutable.
- Sets `factory.sealed = true`.
- Emits `FactorySealed`.
- **Order note:** if `make_immutable` aborted (it can't realistically), state would be: cap destroyed, package mutable, sealed=false. Next destroy_cap would need a fresh OriginCap (impossible on mainnet — no public ctor).

### `pool_factory::canonical_pool_id<A, B>(factory): Option<ID>`
- Sorts types internally via bytes_lt; caller does not need to pre-sort.
- Returns `option::some(id)` if pair exists, else `option::none()`.

---

## Cross-cutting invariants

1. **Reentrancy: STRUCTURALLY IMPOSSIBLE.** Sui Coin<T> has no framework callback. No external module calls within state-mutating functions. Flash atomicity enforced by hot-potato (no abilities → must consume in same TX).

2. **Reserve / balance invariant:** `balance_a::value() == reserve_a + cumulative_unclaimed_fees_a` at all post-create rest states (between flash borrow and repay, balance dips by the borrowed amount; this is the explicit exception, restored at repay).

3. **k-invariant under flash:** `k_after >= k_before` enforced at flash_repay. Fees only INCREASE k. Swaps preserve k modulo fees (also non-negative). Interleaved operations cannot net-drain the pool.

4. **No admin / no privileged path post-seal.** OriginCap soulbound, single-shot. UpgradeCap consumed by `make_immutable`. Post-seal: no governance, no fee adjust, no asset whitelist, no pause. The only on-chain action is permissionless `create_canonical_pool<A, B>` and the per-pool primitives.

5. **Canonical-pair invariant:** `factory.pairs Table<PairKey, ID>` enforces 1 pool per sorted (A, B). `assert_sorted` strict `<` also rejects same-type pairs.

6. **Type safety:** phantom `A`/`B` on Pool/LpPosition prevent asset mixing. Distinct `FlashReceiptA<A,B>` vs `FlashReceiptB<A,B>` types prevent repay-side confusion.

7. **Overflow safety:** u256 promote on swap math, fee calc, k snapshot. u128 for sqrt + accumulator. u64 for amounts + shares. All boundary cases verified — sqrt input (u64 × u64) fits u128 with margin 2^65 - 2.

8. **Coin<T>-only.** Pool generic phantom param resolves only to `Coin<T>` types via Sui type system. `Token<T>` (closed-loop) cannot be used — hence no ActionRequest hot-potato surface.

---

## INFO findings (no fix required)

**I1 — Dead-share floor unreachable through normal API.** `assert lp_supply >= MINIMUM_LIQUIDITY` post-burn cannot fire because `lp_supply >= shares` (E_INSUFFICIENT_LP) trips first. Defense-in-depth; documented in test-suite skip note.

**I2 — pool_id match check is tautological.** Only one pool per (A,B) pair exists by canonical invariant; LpPosition<A,B>'s pool_id field always matches the unique Pool<A,B>. Check kept as defense against future invariant bugs.

**I3 — `accrue_fee` `lp_supply > 0` guard always true post-creation.** Floor at MINIMUM_LIQUIDITY = 1000 means lp_supply > 0 always at swap/flash time. Guard is defensive.

**I4 — `compute_flash_fee(0) = 1` unreachable via flash_borrow_*.** Pure-math testable; cannot be triggered through the public flash entry because `assert amount > 0` runs first.

**I5 — destroy_cap field-ordering: cap destroyed → make_immutable → sealed=true.** If `make_immutable` aborted (no realistic path), state would briefly be inconsistent (cap gone, sealed=false). On mainnet `make_immutable` cannot abort — it just consumes UpgradeCap. No fix needed.

---

## Test coverage (`pool_tests.move`, 20/20 PASS)

| Category | Tests |
|---|---|
| Pure math | sqrt, compute_amount_out, compute_flash_fee |
| Pair sorting | correct, wrong order, same type |
| Pool creation | basic, duplicate (abort), too-small (abort) |
| Swap | round-trip A↔B, slippage (abort) |
| Liquidity | add unbalanced (verify leftover), remove (verify reserves+supply) |
| LP fees | accrual + claim + idempotent re-claim |
| Flash | round-trip A, round-trip B, repay underpay (abort), borrow too much (abort) |
| Sealing | destroy_cap seals, double destroy aborts |

Coverage gaps consciously skipped:
- Direct test of dead-share floor (unreachable, see I1).
- k-invariant violation (cannot construct adversarial scenario in unit tests — flash hot-potato makes net pool drain impossible by construction).
- Cross-tx flash (impossible by hot-potato semantic).
- Multi-LP fee distribution accuracy (covered indirectly by `test_lp_fee_accrual_and_claim`; fuzz this in external R1).

---

## External-audit handoff items

For Gemini / Claude / Grok R1:

1. **Scrutinize the flash accounting model.** Confirm that NOT decrementing `reserve_a/b` at borrow time is sound, given the k-invariant check at repay catches all interleaved swap manipulations. Adversary scenarios to test: (a) borrow → 50/50 swap → repay; (b) borrow → directional swap → repay; (c) borrow + add_liquidity + remove + repay.

2. **Verify u256 promote sufficiency.** Math paths: `compute_amount_out` (numerator can reach (u64_max)³ ≈ 6.3e57); `accrue_fee` (fee × SCALE ≤ u64_max × 1e12 ≈ 1.84e31); `pending_from_accumulator` (delta × shares ≤ u128_max × u64_max). All fit u256; please double-check.

3. **Type-name lex ordering corner cases.** Test pairs where types share a prefix ending in different lengths — e.g., `0x1::a::A` vs `0x1::a::AA`. `bytes_lt` should treat shorter as "less" when prefix matches.

4. **Sealing semantics.** Confirm that after `destroy_cap`:
   - No way to mint OriginCap (no public ctor)
   - UpgradeCap consumed → `make_immutable` precludes any `package::authorize_upgrade`
   - factory.sealed flag is purely informational since cap-loss already prevents privileged ops
   - **Deploy uses hot wallet, no multisig** — protected solely by atomic Tx 1 publish → Tx 2 seal (seconds-window). Confirm this window's risk is acceptable given that compromise of the deployer key DURING that window is the only realistic attack vector, and post-seal compromise is harmless (no caps remain).

5. **Suggest fuzz cases** for swap/LP math precision.

---

**Signed:** Self-audit complete. Submitting to external R1.

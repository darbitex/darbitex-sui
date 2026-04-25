# Darbitex Sui Audit R1 Bundle

**Self-audit**: Claude Opus 4.7 (1M)
**Date**: 2026-04-25
**Scope**: `sources/pool.move` (516 LOC), `sources/pool_factory.move` (190 LOC)
**Package**: `darbitex` v0.1.0 on Sui (mainnet rev `6d4ec0b…`)
**Status**: Self-audit GREEN (R1 + R2 internal rounds), pending external AI review

R1 is the first audit round for Darbitex Sui — fresh port of Darbitex
Final core from Aptos. Pure utility deployment: no arb module, no
treasury, no admin authority post-seal. Single canonical pool per pair,
5 bps swap + 5 bps flash (100% LP), Position-NFT LP model
(claim-without-burn).

**Build evidence**:
```
$ sui move build
BUILDING Darbitex
[0 errors, 4 W99001 lint INTENTIONAL per SOP §6 entry-wrapper self-transfers]

$ sui move test
Test result: OK. Total tests: 21; passed: 21; failed: 0
```

**Architecture summary**:

| Item | Value |
|------|-------|
| Curve | x*y=k constant product (V2) |
| Pool storage | Per-pool shared object `Pool<phantom A, phantom B> has key` (no `store`) |
| LP container | Transferable NFT `LpPosition<phantom A, phantom B> has key, store` |
| Reserve model | `balance_X: Balance<X>` + `reserve_X: u64`; invariant `balance == reserve + cumulative_unclaimed_fees` |
| Fee accumulator | Per-share `lp_fee_per_share_a/b: u128` × per-position `fee_debt_a/b: u128` (MasterChef-style) |
| Flash | Distinct typed hot-potato receipts `FlashReceiptA/B<A, B>`, no abilities |
| Reentrancy | NONE — Sui Coin<T> has no callback (verified Trail of Bits 2025-09-10) |
| Factory | Singleton `FactoryRegistry has key`, `Table<PairKey, ID>` keyed on sorted TypeName lex bytes |
| Sealing | `destroy_cap` → `package::make_immutable(upgrade)` + OriginCap deletion + `sealed=true` |
| Deploy | Hot wallet, atomic Tx 1 publish + Tx 2 destroy_cap (no multisig) |
| Fees | 5 bps swap + 5 bps flash, 100% LP |
| Treasury / arb | NONE (pure utility deployment) |
| Admin / pause | NONE post-seal |
| Oracle | NONE (pool reserves are price source) |

---

## Self-Audit by Dimension

(per `feedback_satellite_self_audit.md`)

### 1. ABI

All `public` and `public(package)` signatures use Sui-idiomatic types: generics over phantom A/B, by-value Coin<T> consumption, &mut Pool<A, B> for shared-object access, `Clock` + `ctx` injected. No `Option<T>` in entry signatures (TS-SDK-safe). No `Token<T>` (closed-loop) — pool only accepts `Coin<T>`.

**Pool surface (composability)**:
- `swap_a_to_b<A, B>(pool, coin_in: Coin<A>, min_out, clock, ctx) -> Coin<B>`
- `swap_b_to_a<A, B>(pool, coin_in: Coin<B>, min_out, clock, ctx) -> Coin<A>`
- `add_liquidity<A, B>(...) -> (LpPosition<A, B>, Coin<A>, Coin<B>)` (returns leftovers)
- `remove_liquidity<A, B>(...) -> (Coin<A>, Coin<B>)`
- `claim_lp_fees<A, B>(pool, &mut position, ...) -> (Coin<A>, Coin<B>)`
- `flash_borrow_a<A, B>(pool, amount, ...) -> (Coin<A>, FlashReceiptA<A, B>)`
- `flash_borrow_b<A, B>(...) -> (Coin<B>, FlashReceiptB<A, B>)`
- `flash_repay_a<A, B>(pool, Coin<A>, FlashReceiptA<A, B>, clock)`
- `flash_repay_b<A, B>(pool, Coin<B>, FlashReceiptB<A, B>, clock)`
- Pure helpers: `sqrt`, `compute_amount_out`, `compute_flash_fee`
- Views: `reserves`, `lp_supply`, `position_shares`, `position_pool_id`, `read_warning`

**Factory surface**:
- `create_canonical_pool<A, B>(...) -> LpPosition<A, B>`
- `assert_sorted<A, B>() -> PairKey`
- `destroy_cap(origin, factory, upgrade, clock, ctx)`
- Views: `canonical_pool_id<A, B>`, `pool_count`, `is_sealed`

**`public(package)`**: only `pool::create_pool` (factory-only access; cross-package call impossible).

**Entry wrappers** (deadline-guarded, transfer-to-sender, accept W99001 lint per SOP §6):
- `pool::add_liquidity_entry`, `remove_liquidity_entry`, `claim_lp_fees_entry`
- `pool_factory::create_canonical_pool_entry`

**Status**: ✅ PASS

### 2. Args

All entry functions assert preconditions before state mutation:

- `pool::create_pool` (package-only): `amount_a > 0 && amount_b > 0`, `initial_lp > MINIMUM_LIQUIDITY` strict.
- `pool::swap_a_to_b` / `swap_b_to_a`: `amount_in > 0`, `amount_out >= min_out`, `amount_out < reserve_out` (no full drain).
- `pool::add_liquidity`: both desired amounts > 0; u64 cast guards on `b_opt_u256` and `a_opt_u256` against ratios > 2^64:1; `shares > 0`, `shares >= min_shares_out`.
- `pool::remove_liquidity`: pool_id match, `shares > 0`, `lp_supply >= shares`, `amount_a/b >= min_amount_a/b`, `lp_supply_post >= MINIMUM_LIQUIDITY` (dead-share floor).
- `pool::claim_lp_fees`: pool_id match.
- `pool::flash_borrow_a/b`: `amount > 0`, `amount < reserve` (strict — no full lend).
- `pool::flash_repay_a/b`: pool_id match, `coin::value(&coin) == amount + fee` strict equality.
- All `*_entry` wrappers: `clock::timestamp_ms(clock) < deadline_ms`.
- `pool_factory::create_canonical_pool`: `assert_sorted<A, B>()` first (also rejects same-type pairs via strict `<`), then both amounts > 0, then `!table::contains(pairs, key)`.
- `pool_factory::destroy_cap`: `!factory.sealed` (idempotency).

All asserts produce specific error codes — see §7.

**Status**: ✅ PASS

### 3. Math

- **`compute_amount_out`** (xyk swap math): u256 promote on `amount_in × (BPS_DENOM - SWAP_FEE_BPS)`; numerator can reach `(u64_max)³ ≈ 6.3e57` ≪ u256_max ≈ 1.16e77. Final `as u64` cast safe because output ≤ `reserve_out` < u64_max by construction.
- **`compute_flash_fee`**: u256 intermediate; floor-up to 1 raw unit so dust borrows still pay (preserves "no free flash" invariant).
- **`accrue_fee`**: `add = (fee × SCALE) / lp_supply` with `fee` u64 and `SCALE = 1e12`, max product `u64_max × 1e12 ≈ 1.84e31` fits u128 (max ≈ 3.4e38).
- **`pending_from_accumulator`**: `(delta_u128 × shares_u64) / SCALE` via u256, fits trivially.
- **`sqrt`**: Babylonian iteration, terminates per `z < y` strictly decreasing; input `amount_a × amount_b` u64×u64 → u128, fits with margin `2^65 - 2`.
- **`reserve_a += amount_in - lp_fee`**: lp_fee = amount_in × 5 / 10000 < amount_in for amount_in > 0, no underflow.
- **`reserve_b -= amount_out`**: guarded by `amount_out < reserve_b` assert.
- **k snapshot for flash**: `(reserve_a as u256) × (reserve_b as u256)`; max u64×u64 → u256 trivially fits.
- **Optimal-pair add_liquidity**: `b_opt = a_desired × reserve_b / reserve_a` u256, with explicit `<= U64_MAX` cast guard producing E_INSUFFICIENT_LIQUIDITY instead of opaque arithmetic abort.
- **Proportional remove_liquidity**: `(shares × reserve) / lp_supply` u256.
- **`min(lp_a, lp_b)` for new shares**: guards against integer rounding asymmetry between sides.

**Status**: ✅ PASS

### 4. Reentrancy

**Structurally impossible.** Sui `Coin<T>` has NO framework callback (verified independently — Trail of Bits 2025-09-10 blog confirms; SOP `feedback_sui_move_port_sop.md` §2 documents). All mutating functions hold `&mut Pool<A, B>` exclusive (Sui shared-object lock model). No external module call inside any state-mutating function.

**Flash safety without `locked` flag** (justification documented in pool.move module-doc):
- Hot-potato `FlashReceiptA<A,B>` / `FlashReceiptB<A,B>` have NO abilities → must be consumed by `flash_repay_*` in same TX (Move drop-rule enforced).
- Strict `coin::value(&coin) == amount + fee` at repay prevents under/overpay.
- `k_after >= k_before` invariant at repay catches any pool manipulation in the borrow window. Fees only INCREASE k; swaps preserve k modulo fees (also non-negative).
- `reserve_a/b` NOT decremented at borrow time — k_before snapshot taken at borrow is verified against reserves AT REPAY (which include any interleaved swap mutations).

**Adversary scenarios mentally walked through** (formal verification deferred to external R1):
1. Borrow A → swap A→B same pool → repay: borrower's swap moved reserves, k_after > k_before due to swap fee, repay credits flash fee; borrower spent (slippage + 2 fees), pool LPs gained. Safe.
2. Borrow A → add_liquidity using borrowed A → flash_repay → remove_liquidity: new LP joined mid-flash, debt = pre-flash-fee accumulator → flash fee accrues AFTER add; new LP claims pro-rata of post-flash-fee accumulator. New LP gets fraction of flash fee but borrower paid flash fee out-of-pocket. Net: small fee dilution to existing LPs (not exploit; borrower lost more than gained).
3. Two flash borrows from disjoint pools in same TX: each pool independently locked via `&mut Pool<X,Y>`; no cross-contamination.
4. Repay-with-wrong-side: prevented at compile time by distinct `FlashReceiptA<A,B>` vs `FlashReceiptB<A,B>` types.

**Status**: ✅ PASS

### 5. Edges

- **`amount_in = 0`**: caught by `assert amount_in > 0` (E_ZERO_AMOUNT).
- **`amount_out = 0`** (dust swap on huge pool): falls through min_out check; if min_out = 0, returns Coin<B>(0) — caller may pre-check.
- **`amount_out == reserve_b`**: blocked by strict `<` assert (E_INSUFFICIENT_LIQUIDITY); guarantees reserve never reaches zero from swap.
- **Flash borrow `amount = reserve`**: blocked by strict `<` assert (E_INSUFFICIENT_LIQUIDITY); guarantees borrow doesn't drain.
- **`add_liquidity` with amount_b_optimal = 0** (e.g., a_desired=1, reserve_a >> reserve_b): the optimal-pair branch yields (1, 0); caught by `assert amount_b > 0` (E_ZERO_AMOUNT).
- **`add_liquidity` with extreme ratio overflow**: u256 intermediate computed; `<= U64_MAX` cast guard fires E_INSUFFICIENT_LIQUIDITY.
- **`remove_liquidity` shares > lp_supply**: caught by `lp_supply >= shares` (E_INSUFFICIENT_LP).
- **`remove_liquidity` post-burn `lp_supply < MINIMUM_LIQUIDITY`**: dead-share floor assert (E_INSUFFICIENT_LIQUIDITY); see I-1.
- **`claim_lp_fees` second call (no new fees)**: `pending_from_accumulator` returns 0 (per_share_current == per_share_debt); returns zero coins. Idempotent.
- **`compute_flash_fee(0)`**: returns 1 (floor-up). Unreachable via `flash_borrow_*` due to `assert amount > 0`; testable via pure-math entry. See I-4.
- **Same-type pair `<T, T>`**: bytes_lt returns false (identical vectors) → assert_sorted aborts E_WRONG_ORDER.
- **Cross-tx flash**: impossible — hot-potato MUST be consumed in same TX.
- **`destroy_cap` with sealed factory**: aborts E_SEALED (idempotency).
- **`destroy_cap` with caps from different package** (test scenario only): aborts on UpgradeCap version/policy mismatch in `package::make_immutable`. On mainnet, only the deploy keypair holds these caps for seconds before consumption.

**Status**: ✅ PASS

### 6. Interactions

**External module calls from within state-mutating functions**: NONE. The pool module calls only `sui::balance`, `sui::coin`, `sui::clock`, `sui::event`, `sui::object`, `sui::transfer`, `sui::tx_context`, `std::ascii`, `std::type_name`, `std::vector`. Pool factory additionally calls `sui::package` (for `make_immutable`), `sui::table`, and `darbitex::pool` (for `create_pool`).

**Cross-package risk**: `darbitex::pool` is the only Move dep of `darbitex::pool_factory`; same package, `public(package)` boundary. No third-party code.

**Sui framework dep**: rev `6d4ec0b…` matches `sui` CLI 1.70.2 (deploy time will pin the same rev). Framework upgrade risk = standard Sui mainnet protocol upgrade risk (out of Darbitex's control; affects all Sui contracts equally).

**Aggregator / lending integration**: LP-as-NFT means Cetus/Aftermath aggregators cannot route LP tokens; Scallop/Suilend cannot accept LP as collateral. Trade-off documented in WARNING item (3). Future Darbitex satellites (lp-staking, lp-locker) will operate on LpPosition directly, mirroring Aptos pattern.

**Status**: ✅ PASS

### 7. Errors

| Code | Constant | Module | Use |
|------|----------|--------|-----|
| 1 | `E_ZERO_AMOUNT` | pool | Zero `amount_in`, zero seed in create_pool, zero shares, zero post-optimal-pair |
| 2 | `E_INSUFFICIENT_LIQUIDITY` | pool | sqrt initial_lp ≤ MIN, swap output ≥ reserve, flash borrow ≥ reserve, optimal-pair u64 cast guard, dead-share floor breach |
| 3 | `E_SLIPPAGE` | pool | swap output < min_out, add_liquidity shares < min, remove_liquidity amount < min |
| 5 | `E_DISPROPORTIONAL` | pool | optimal-pair invariant breach (mathematically guaranteed but explicit) |
| 6 | `E_WRONG_POOL` | pool | LpPosition / FlashReceipt pool_id mismatch |
| 7 | `E_INSUFFICIENT_LP` | pool | remove_liquidity shares > lp_supply |
| 9 | `E_K_VIOLATED` | pool | flash_repay k_after < k_before |
| 14 | `E_DEADLINE` | pool | entry wrapper deadline expired |
| 15 | `E_REPAY_AMOUNT` | pool | flash_repay coin value != amount + fee |
| 4 | `E_WRONG_ORDER` | pool_factory | assert_sorted bytes_lt = false |
| 5 | `E_ZERO` | pool_factory | create_canonical_pool zero amount |
| 6 | `E_DUPLICATE_PAIR` | pool_factory | create_canonical_pool pair already exists |
| 18 | `E_SEALED` | pool_factory | destroy_cap on already-sealed factory |

Codes 4 (factory) and 5 (pool ZERO_AMOUNT vs factory ZERO) deliberately differ between modules to keep error semantics module-local. Off-chain indexers must namespace by module.

**Status**: ✅ PASS

### 8. Events

7 event types in `pool`:
- `PoolCreated` — pool_id, type_a/b strings (TypeName), creator, amounts, initial_lp, timestamp_ms
- `Swapped` — pool_id, swapper, amount_in/out, a_to_b bool, lp_fee, timestamp_ms
- `LiquidityAdded` — pool_id, provider, position_id, amounts, shares_minted, timestamp_ms
- `LiquidityRemoved` — pool_id, provider, position_id, amounts, fees claimed, shares_burned, timestamp_ms
- `LpFeesClaimed` — pool_id, position_id, claimer, fees_a/b, timestamp_ms
- `FlashBorrowed` — pool_id, borrowed_is_a, amount, fee, timestamp_ms
- `FlashRepaid` — pool_id, borrowed_is_a, amount, fee, timestamp_ms

2 event types in `pool_factory`:
- `FactoryInitialized` — factory_id, deployer
- `FactorySealed` — factory_id, deployer, timestamp_ms

All event emits happen AFTER state mutation but BEFORE function return. No events are emitted speculatively before assertions pass.

`a_to_b: bool` on Swapped + `borrowed_is_a: bool` on FlashBorrowed/FlashRepaid let off-chain indexers reconstruct direction without needing type inspection.

**Status**: ✅ PASS

---

## Findings

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| **I-1** | INFO | `remove_liquidity` dead-share floor `assert lp_supply >= MINIMUM_LIQUIDITY` is unreachable through normal API — `lp_supply >= shares` (E_INSUFFICIENT_LP) trips first. Defense-in-depth invariant. | Documented |
| **I-2** | INFO | `remove_liquidity` / `claim_lp_fees` `pool_id` match check is tautological (only one pool per (A,B) by canonical-pair invariant; LpPosition<A,B> can only be redeemed at the unique Pool<A,B>). Defense-in-depth. | Documented |
| **I-3** | INFO | `accrue_fee` `lp_supply > 0` guard always true post-creation (lp_supply ≥ MINIMUM_LIQUIDITY = 1000). Defensive. | Documented |
| **I-4** | INFO | `compute_flash_fee(0) = 1` is unreachable via `flash_borrow_*` due to `assert amount > 0`. Pure-math testable but never hit through public flash entry. | Documented |
| **I-5** | INFO | `destroy_cap` field-ordering: cap destroyed → make_immutable → sealed=true. If make_immutable could abort (it cannot realistically), state would briefly be inconsistent. On mainnet, no realistic abort path. | Documented |

**0 HIGH / 0 MEDIUM / 0 LOW.**

---

## Refutations / Out-of-Scope

External auditors are asked to NOT spend time on the following — these are deliberate design choices:

### R1: "Use `Coin<LP_TYPE>` instead of Position NFT"
Position NFT is a deliberate cross-chain Darbitex identity choice (consistent with Aptos `darbitex_lp_locker_design.md` + `darbitex_lp_staking_vision.md` satellites that operate per-NFT). Coin LP would force per-share fee tracking via a global Table<address, debt> mapping, breaking fungibility benefits anyway. Position NFT enables claim-without-burn (LP cash flow without exit). **Reject.**

### R2: "Add an arbitrage smart-routing module / treasury / fee recipient"
Sui `public fun` is PTB-callable cross-package — bots can DIY arb routes via direct `pool::swap_*` chains in their own PTBs, bypassing any wrapper module. Treasury cut on routed swaps is therefore unenforceable on Sui. Pure utility deployment (100% LP) is the explicit thesis. **Reject.**

### R3: "Use multisig for deploy"
`destroy_cap` in Tx 2 is atomic with publish (single deploy script bundles both); after Tx 2 there are zero on-chain caps remaining. Multisig itself is admin surface — contradicts the zero-admin thesis. Hot-wallet deploy is sufficient because the Tx 1 → Tx 2 window is seconds. **Reject.**

### R4: "Add Display module / coin_registry interaction"
LP is NFT not Coin — `coin_registry` is N/A for non-coin-creating packages (per SOP §4). Sui `Display<LpPosition<A, B>>` could be added as a future satellite (post-seal, in a separate package) if wallet rendering becomes a bottleneck. Out of scope for AMM core. **Reject for core; out of scope.**

### R5: "Add V3 CLMM features (concentrated liquidity, ticks, fee tiers)"
Pure V2 (constant product) is the explicit design choice — battle-tested math, smaller attack surface, always-in-range LP, no active range management for retail LPs. The capital-inefficiency trade-off is accepted. CLMM exploits in 2025 (Cetus $223M) reinforce the V2 security thesis. **Reject.**

### R6: "Add pause / emergency admin / fee adjustment knob"
Sealed-package zero-admin is the thesis. Any admin path = attack surface. Bug = unrecoverable, by explicit user acceptance via WARNING item (8) and (10). **Reject.**

### R7: "Replace WARNING constant with off-chain documentation only"
On-chain WARNING with `read_warning()` view is deliberate — frontends, indexers, and wallet UIs can fetch + display the disclosure without trusting an off-chain doc URL. **Reject.**

---

## Production Readiness

- [x] Build clean (0 errors, only intentional W99001 lint)
- [x] Tests 21/21 PASS via `sui move test`
- [x] Self-audit R1 (pre-compaction) GREEN — `audit/SELF_AUDIT_R1.md`
- [x] Self-audit R2 (post-compaction) GREEN — `audit/SELF_AUDIT_R2.md`
- [x] On-chain WARNING with 11 known limitations + `read_warning()` view
- [x] Module-doc top-of-file banner pointing to WARNING
- [x] Sealing flow tested (`test_destroy_cap_seals` + `test_destroy_cap_twice_aborts`)
- [x] `Move.toml` pinned to Sui rev `6d4ec0b…` matching CLI 1.70.2
- [ ] External AI audit R1 — Gemini, Claude, Grok, others (THIS BUNDLE)
- [ ] Mainnet deploy script (Tx 1 publish + Tx 2 destroy_cap PTB) tested in devnet/testnet first
- [ ] Hot wallet provisioned with ~1 SUI gas for mainnet deploy
- [ ] `is_sealed == true` verification in deploy script before any public announcement

---

## External Auditor Plan

For R1 external review, this bundle is the single submittable artifact. Ranked priorities:

**Q1 (HIGHEST) — Flash safety without reentrancy lock.** Justification documented in §4. Adversary scenarios mentally walked but not formally verified. Please attempt:
- Borrow A → directional swap on same pool → repay (does anything net-drain?)
- Borrow A → add_liquidity using borrowed A → flash_repay → remove_liquidity (does new LP harvest unfair share?)
- Borrow A → swap A→B → swap B→A → repay (cumulative slippage where?)
- Two parallel flash borrows on different `Pool<X,Y>` and `Pool<Y,Z>` in same PTB
- PTB-level reentrancy: can borrower trigger another module's step that touches the pool unexpectedly before repay?

**Q2 — u256 promote sufficiency.** Verify each math hot path's intermediates fit u256 with adversarial inputs near u64::MAX.

**Q3 — Lex byte ordering on Move type names.** Edge cases: shared prefix with different lengths, hex address segments without padding, cross-package types from different addresses.

**Q4 — Sealing semantics post-`destroy_cap`.** Confirm no path mints OriginCap, no path bypasses `make_immutable`, factory.sealed flag is purely informational (cap-loss already prevents privileged ops).

**Q5 — LP fee accumulator precision under fragmentation.** Suggest fuzz cases for tiny fees + low lp_supply.

**Q6 — `add_liquidity` optimal-pair edge cases.** Verify `amount_b_optimal == 0` falls through cleanly; ratio > 2^64:1 produces clean E_INSUFFICIENT_LIQUIDITY not arithmetic abort.

**Q7 — Composability surface completeness.** Does the public surface miss any primitive that future Darbitex satellites (lp-locker, lp-staking, oracle adapter) would need?

**Q8 — Suggest fuzz cases.** Concrete numeric inputs for additional test coverage before mainnet deploy.

For each: track findings in `audit/AUDIT_TRACKING.md` (created post-R1 returns).

---

## Bundle Components

- This file (`audit/AUDIT-R1-BUNDLE.md`) — single submittable artifact for external R1
- `audit/SELF_AUDIT_R1.md` — pre-compaction internal review (per-function detail)
- `audit/SELF_AUDIT_R2.md` — post-compaction re-verification
- `sources/pool.move` (516 LOC) — INLINED BELOW
- `sources/pool_factory.move` (190 LOC) — INLINED BELOW
- `tests/pool_tests.move` (515 LOC, 21/21 PASS) — referenced; not security-critical, available in repo

---

## Source Code (verbatim, compile-green)

### `sources/pool.move`

```move
/// Darbitex pool — x*y=k AMM, 5 bps swap + 5 bps flash, 100% LP.
///
/// Canonical pool per pair (factory-enforced). LP = transferable Sui
/// object with per-share fee accumulator + per-position debt snapshot —
/// enables claim-without-burn (fee withdraw without touching principal).
/// Flash via typed hot-potato receipts (FlashReceiptA/B).
///
/// Reentrancy lock omitted: Sui Coin<T> has no callback. Flash safety =
/// hot-potato + strict repay equality + k-invariant (k_after >= k_before).
///
/// Reserve / balance invariant: `balance_X = reserve_X + cumulative
/// unclaimed fees`. Fees stay mixed in pool; claimed via per-share
/// accumulator. Math is decimal-blind (raw u64 amounts).
///
/// WARNING: Darbitex is an immutable AMM on Sui. After destroy_cap is
/// called the package is permanently immutable — no admin, no pause, no
/// upgrade, no fee adjustment. Bugs are unrecoverable. Audit this code
/// yourself before interacting. The full disclosure (11 known limitations
/// — including AI-only audit + ownerless-protocol + user-bears-all-loss
/// terms + unknown-future-limitation acknowledgment) is exposed on-chain
/// via `read_warning()` and printed in the WARNING constant below.
module darbitex::pool {
    use std::ascii::String;
    use std::type_name;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;

    // ===== Constants =====

    const SWAP_FEE_BPS: u64 = 5;
    const FLASH_FEE_BPS: u64 = 5;
    const BPS_DENOM: u64 = 10_000;
    const MINIMUM_LIQUIDITY: u64 = 1_000;
    const SCALE: u128 = 1_000_000_000_000;
    const U64_MAX: u64 = 18_446_744_073_709_551_615;

    // ===== Errors =====

    const E_ZERO_AMOUNT: u64 = 1;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 2;
    const E_SLIPPAGE: u64 = 3;
    const E_DISPROPORTIONAL: u64 = 5;
    const E_WRONG_POOL: u64 = 6;
    const E_INSUFFICIENT_LP: u64 = 7;
    const E_K_VIOLATED: u64 = 9;
    const E_DEADLINE: u64 = 14;
    const E_REPAY_AMOUNT: u64 = 15;

    // ===== On-chain disclosure =====
    // (WARNING constant elided in bundle — see source file for the full 11-item byte string.
    //  Same content is on-chain readable via read_warning() at end of module.)

    const WARNING: vector<u8> = b"... [11-item disclosure, see sources/pool.move line 54] ...";

    // ===== Structs =====

    /// `key`-only (no `store`): shared at create, never wrapped/transferred.
    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        lp_fee_per_share_a: u128,
        lp_fee_per_share_b: u128,
    }

    /// `key, store`: kiosk/escrow-able. Each add_liquidity mints fresh
    /// (no merging — debt snapshot would be ambiguous).
    public struct LpPosition<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
    }

    /// Hot-potato receipts — no abilities, must be consumed in same TX.
    /// Distinct A/B types prevent repay-with-wrong-side at compile time.
    public struct FlashReceiptA<phantom A, phantom B> {
        pool_id: ID, amount: u64, fee: u64, k_before: u256,
    }
    public struct FlashReceiptB<phantom A, phantom B> {
        pool_id: ID, amount: u64, fee: u64, k_before: u256,
    }

    // ===== Events =====

    public struct PoolCreated has copy, drop {
        pool_id: ID, type_a: String, type_b: String, creator: address,
        amount_a: u64, amount_b: u64, initial_lp: u64, timestamp_ms: u64,
    }
    public struct Swapped has copy, drop {
        pool_id: ID, swapper: address, amount_in: u64, amount_out: u64,
        a_to_b: bool, lp_fee: u64, timestamp_ms: u64,
    }
    public struct LiquidityAdded has copy, drop {
        pool_id: ID, provider: address, position_id: ID,
        amount_a: u64, amount_b: u64, shares_minted: u64, timestamp_ms: u64,
    }
    public struct LiquidityRemoved has copy, drop {
        pool_id: ID, provider: address, position_id: ID,
        amount_a: u64, amount_b: u64, fees_a: u64, fees_b: u64,
        shares_burned: u64, timestamp_ms: u64,
    }
    public struct LpFeesClaimed has copy, drop {
        pool_id: ID, position_id: ID, claimer: address,
        fees_a: u64, fees_b: u64, timestamp_ms: u64,
    }
    public struct FlashBorrowed has copy, drop {
        pool_id: ID, borrowed_is_a: bool, amount: u64, fee: u64, timestamp_ms: u64,
    }
    public struct FlashRepaid has copy, drop {
        pool_id: ID, borrowed_is_a: bool, amount: u64, fee: u64, timestamp_ms: u64,
    }

    // ===== Pure helpers =====

    /// Babylonian integer sqrt.
    public fun sqrt(x: u128): u128 {
        if (x == 0) return 0;
        let mut z = (x + 1) / 2;
        let mut y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; };
        y
    }

    /// x*y=k swap math with SWAP_FEE_BPS wedge. u256 intermediates absorb
    /// adversarial reserves near u64::MAX.
    public fun compute_amount_out(reserve_in: u64, reserve_out: u64, amount_in: u64): u64 {
        let in_after_fee = (amount_in as u256) * ((BPS_DENOM - SWAP_FEE_BPS) as u256);
        let num = in_after_fee * (reserve_out as u256);
        let den = (reserve_in as u256) * (BPS_DENOM as u256) + in_after_fee;
        ((num / den) as u64)
    }

    /// Flash fee floor-up to 1 raw unit so dust borrows still pay.
    public fun compute_flash_fee(amount: u64): u64 {
        let raw = (((amount as u256) * (FLASH_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        if (raw == 0) { 1 } else { raw }
    }

    // ===== Internal helpers =====

    fun accrue_fee<A, B>(pool: &mut Pool<A, B>, fee: u64, a_side: bool): u64 {
        if (fee > 0 && pool.lp_supply > 0) {
            let add = (fee as u128) * SCALE / (pool.lp_supply as u128);
            if (a_side) pool.lp_fee_per_share_a = pool.lp_fee_per_share_a + add
            else pool.lp_fee_per_share_b = pool.lp_fee_per_share_b + add;
        };
        fee
    }

    fun pending_from_accumulator(per_share_current: u128, per_share_debt: u128, shares: u64): u64 {
        if (per_share_current <= per_share_debt) return 0;
        let delta = per_share_current - per_share_debt;
        (((delta as u256) * (shares as u256) / (SCALE as u256)) as u64)
    }

    /// Transfer if non-zero, else destroy in place (avoids dust-coin spam).
    fun maybe_transfer<T>(coin: Coin<T>, recipient: address) {
        if (coin::value(&coin) > 0) transfer::public_transfer(coin, recipient)
        else coin::destroy_zero(coin);
    }

    // ===== Pool creation (package-only) =====

    /// MINIMUM_LIQUIDITY shares locked at creation (counted in lp_supply,
    /// never minted as a position) — anti-cornering on first depositor.
    /// remove_liquidity floor preserves the lockup forever.
    public(package) fun create_pool<A, B>(
        coin_a: Coin<A>, coin_b: Coin<B>, clock: &Clock, ctx: &mut TxContext,
    ): (ID, LpPosition<A, B>) {
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        let initial_lp_u128 = sqrt((amount_a as u128) * (amount_b as u128));
        assert!(initial_lp_u128 > (MINIMUM_LIQUIDITY as u128), E_INSUFFICIENT_LIQUIDITY);
        let initial_lp = (initial_lp_u128 as u64);
        let creator_shares = initial_lp - MINIMUM_LIQUIDITY;

        let pool = Pool<A, B> {
            id: object::new(ctx),
            balance_a: coin::into_balance(coin_a),
            balance_b: coin::into_balance(coin_b),
            reserve_a: amount_a,
            reserve_b: amount_b,
            lp_supply: initial_lp,
            lp_fee_per_share_a: 0,
            lp_fee_per_share_b: 0,
        };
        let pool_id = object::id(&pool);
        let creator = tx_context::sender(ctx);
        let position = LpPosition<A, B> {
            id: object::new(ctx),
            pool_id, shares: creator_shares, fee_debt_a: 0, fee_debt_b: 0,
        };
        let now = clock::timestamp_ms(clock);

        event::emit(PoolCreated {
            pool_id,
            type_a: type_name::with_defining_ids<A>().into_string(),
            type_b: type_name::with_defining_ids<B>().into_string(),
            creator, amount_a, amount_b, initial_lp, timestamp_ms: now,
        });
        event::emit(LiquidityAdded {
            pool_id, provider: creator, position_id: object::id(&position),
            amount_a, amount_b, shares_minted: creator_shares, timestamp_ms: now,
        });

        transfer::share_object(pool);
        (pool_id, position)
    }

    // ===== Swap =====

    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>, coin_in: Coin<A>, min_out: u64,
        clock: &Clock, ctx: &mut TxContext,
    ): Coin<B> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        let amount_out = compute_amount_out(pool.reserve_a, pool.reserve_b, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);

        // u256 promote — Sui SUI 9-dec closer to u64 overflow than Aptos APT 8-dec.
        let fee = (((amount_in as u256) * (SWAP_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        let lp_fee = accrue_fee(pool, fee, true);

        pool.reserve_a = pool.reserve_a + amount_in - lp_fee;
        pool.reserve_b = pool.reserve_b - amount_out;
        balance::join(&mut pool.balance_a, coin::into_balance(coin_in));
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount_out), ctx);

        event::emit(Swapped {
            pool_id: object::id(pool), swapper: tx_context::sender(ctx),
            amount_in, amount_out, a_to_b: true, lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        coin_out
    }

    public fun swap_b_to_a<A, B>(
        pool: &mut Pool<A, B>, coin_in: Coin<B>, min_out: u64,
        clock: &Clock, ctx: &mut TxContext,
    ): Coin<A> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        let amount_out = compute_amount_out(pool.reserve_b, pool.reserve_a, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < pool.reserve_a, E_INSUFFICIENT_LIQUIDITY);

        let fee = (((amount_in as u256) * (SWAP_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        let lp_fee = accrue_fee(pool, fee, false);

        pool.reserve_b = pool.reserve_b + amount_in - lp_fee;
        pool.reserve_a = pool.reserve_a - amount_out;
        balance::join(&mut pool.balance_b, coin::into_balance(coin_in));
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_a, amount_out), ctx);

        event::emit(Swapped {
            pool_id: object::id(pool), swapper: tx_context::sender(ctx),
            amount_in, amount_out, a_to_b: false, lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        coin_out
    }

    // ===== Liquidity =====

    /// Caller passes max amounts; function picks optimal pair against
    /// current reserves, returns unused leftover for caller to handle.
    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>, mut coin_a: Coin<A>, mut coin_b: Coin<B>,
        min_shares_out: u64, clock: &Clock, ctx: &mut TxContext,
    ): (LpPosition<A, B>, Coin<A>, Coin<B>) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        assert!(amount_a_desired > 0 && amount_b_desired > 0, E_ZERO_AMOUNT);

        // Ratios > 2^64:1 overflow u64 cast — explicit assert for clean error code.
        let b_opt_u256 = (amount_a_desired as u256) * (pool.reserve_b as u256) / (pool.reserve_a as u256);
        assert!(b_opt_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
        let amount_b_optimal = (b_opt_u256 as u64);
        let (amount_a, amount_b) = if (amount_b_optimal <= amount_b_desired) {
            (amount_a_desired, amount_b_optimal)
        } else {
            let a_opt_u256 = (amount_b_desired as u256) * (pool.reserve_a as u256) / (pool.reserve_b as u256);
            assert!(a_opt_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
            let amount_a_optimal = (a_opt_u256 as u64);
            assert!(amount_a_optimal <= amount_a_desired, E_DISPROPORTIONAL);
            (amount_a_optimal, amount_b_desired)
        };
        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        // min(lp_a, lp_b) guards against integer rounding asymmetry.
        let lp_a = ((amount_a as u256) * (pool.lp_supply as u256) / (pool.reserve_a as u256)) as u64;
        let lp_b = ((amount_b as u256) * (pool.lp_supply as u256) / (pool.reserve_b as u256)) as u64;
        let shares = if (lp_a < lp_b) lp_a else lp_b;
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(shares >= min_shares_out, E_SLIPPAGE);

        balance::join(&mut pool.balance_a, coin::into_balance(coin::split(&mut coin_a, amount_a, ctx)));
        balance::join(&mut pool.balance_b, coin::into_balance(coin::split(&mut coin_b, amount_b, ctx)));
        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.lp_supply = pool.lp_supply + shares;

        // Debt = current accumulator → new LP doesn't claim past fees.
        let pool_id = object::id(pool);
        let position = LpPosition<A, B> {
            id: object::new(ctx),
            pool_id, shares,
            fee_debt_a: pool.lp_fee_per_share_a,
            fee_debt_b: pool.lp_fee_per_share_b,
        };

        event::emit(LiquidityAdded {
            pool_id, provider: tx_context::sender(ctx),
            position_id: object::id(&position),
            amount_a, amount_b, shares_minted: shares,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (position, coin_a, coin_b)
    }

    /// Burn position; return proportional reserves PLUS accrued fees.
    /// Slippage floors apply to reserve payout only (not fee claims).
    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>, position: LpPosition<A, B>,
        min_amount_a: u64, min_amount_b: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let LpPosition { id, pool_id, shares, fee_debt_a, fee_debt_b } = position;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(pool.lp_supply >= shares, E_INSUFFICIENT_LP);

        let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, fee_debt_a, shares);
        let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, fee_debt_b, shares);
        let amount_a = ((shares as u256) * (pool.reserve_a as u256) / (pool.lp_supply as u256)) as u64;
        let amount_b = ((shares as u256) * (pool.reserve_b as u256) / (pool.lp_supply as u256)) as u64;
        assert!(amount_a >= min_amount_a, E_SLIPPAGE);
        assert!(amount_b >= min_amount_b, E_SLIPPAGE);

        pool.lp_supply = pool.lp_supply - shares;
        // Dead-share floor — preserves the anti-cornering invariant forever.
        assert!(pool.lp_supply >= MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.reserve_b = pool.reserve_b - amount_b;

        let coin_a = coin::from_balance(balance::split(&mut pool.balance_a, amount_a + claim_a), ctx);
        let coin_b = coin::from_balance(balance::split(&mut pool.balance_b, amount_b + claim_b), ctx);
        let position_id = object::uid_to_inner(&id);

        event::emit(LiquidityRemoved {
            pool_id, provider: tx_context::sender(ctx), position_id,
            amount_a, amount_b, fees_a: claim_a, fees_b: claim_b,
            shares_burned: shares, timestamp_ms: clock::timestamp_ms(clock),
        });
        object::delete(id);
        (coin_a, coin_b)
    }

    /// Harvest fees without burning the position. Idempotent (debt = current
    /// accumulator post-claim → second call returns zero coins).
    public fun claim_lp_fees<A, B>(
        pool: &mut Pool<A, B>, position: &mut LpPosition<A, B>,
        clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(object::id(pool) == position.pool_id, E_WRONG_POOL);
        let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, position.fee_debt_a, position.shares);
        let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, position.fee_debt_b, position.shares);
        position.fee_debt_a = pool.lp_fee_per_share_a;
        position.fee_debt_b = pool.lp_fee_per_share_b;

        let coin_a = if (claim_a > 0) coin::from_balance(balance::split(&mut pool.balance_a, claim_a), ctx)
                     else coin::zero<A>(ctx);
        let coin_b = if (claim_b > 0) coin::from_balance(balance::split(&mut pool.balance_b, claim_b), ctx)
                     else coin::zero<B>(ctx);

        event::emit(LpFeesClaimed {
            pool_id: position.pool_id, position_id: object::id(position),
            claimer: tx_context::sender(ctx), fees_a: claim_a, fees_b: claim_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_a, coin_b)
    }

    // ===== Flash =====
    //
    // Flash accounting: borrow does NOT decrement reserve_X — k_before
    // snapshot at borrow time is verified against post-repay reserves. Any
    // swap interleaved in the borrow window moves reserves but pays fees
    // that increase k → cannot violate k_after >= k_before. Repay only
    // credits the fee to LP accumulator; principal returns to balance_X.

    public fun flash_borrow_a<A, B>(
        pool: &mut Pool<A, B>, amount: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, FlashReceiptA<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_a, E_INSUFFICIENT_LIQUIDITY);
        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_a, amount), ctx);
        event::emit(FlashBorrowed {
            pool_id, borrowed_is_a: true, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_out, FlashReceiptA<A, B> { pool_id, amount, fee, k_before })
    }

    public fun flash_borrow_b<A, B>(
        pool: &mut Pool<A, B>, amount: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<B>, FlashReceiptB<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);
        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount), ctx);
        event::emit(FlashBorrowed {
            pool_id, borrowed_is_a: false, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_out, FlashReceiptB<A, B> { pool_id, amount, fee, k_before })
    }

    public fun flash_repay_a<A, B>(
        pool: &mut Pool<A, B>, coin: Coin<A>, receipt: FlashReceiptA<A, B>, clock: &Clock,
    ) {
        let FlashReceiptA { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(coin::value(&coin) == amount + fee, E_REPAY_AMOUNT);
        balance::join(&mut pool.balance_a, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, true);
        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);
        event::emit(FlashRepaid {
            pool_id, borrowed_is_a: true, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    public fun flash_repay_b<A, B>(
        pool: &mut Pool<A, B>, coin: Coin<B>, receipt: FlashReceiptB<A, B>, clock: &Clock,
    ) {
        let FlashReceiptB { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(coin::value(&coin) == amount + fee, E_REPAY_AMOUNT);
        balance::join(&mut pool.balance_b, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, false);
        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);
        event::emit(FlashRepaid {
            pool_id, borrowed_is_a: false, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ===== LP entry wrappers (deadline-guarded) =====
    //
    // No swap_entry / flash_entry — those are pure composable primitives,
    // PTB-callable directly by bots, satellites, and aggregators.

    public fun add_liquidity_entry<A, B>(
        pool: &mut Pool<A, B>, coin_a: Coin<A>, coin_b: Coin<B>,
        min_shares_out: u64, clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (position, leftover_a, leftover_b) =
            add_liquidity(pool, coin_a, coin_b, min_shares_out, clock, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(position, sender);
        maybe_transfer(leftover_a, sender);
        maybe_transfer(leftover_b, sender);
    }

    public fun remove_liquidity_entry<A, B>(
        pool: &mut Pool<A, B>, position: LpPosition<A, B>,
        min_amount_a: u64, min_amount_b: u64, clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) =
            remove_liquidity(pool, position, min_amount_a, min_amount_b, clock, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(coin_a, sender);
        transfer::public_transfer(coin_b, sender);
    }

    public fun claim_lp_fees_entry<A, B>(
        pool: &mut Pool<A, B>, position: &mut LpPosition<A, B>,
        clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) = claim_lp_fees(pool, position, clock, ctx);
        let sender = tx_context::sender(ctx);
        maybe_transfer(coin_a, sender);
        maybe_transfer(coin_b, sender);
    }

    // ===== Views (composability surface for satellites + frontends) =====

    public fun reserves<A, B>(pool: &Pool<A, B>): (u64, u64) { (pool.reserve_a, pool.reserve_b) }
    public fun lp_supply<A, B>(pool: &Pool<A, B>): u64 { pool.lp_supply }
    public fun position_shares<A, B>(pos: &LpPosition<A, B>): u64 { pos.shares }
    public fun position_pool_id<A, B>(pos: &LpPosition<A, B>): ID { pos.pool_id }

    /// On-chain disclosure (11 known limitations). Mirror of the WARNING
    /// constant; readable by frontends, indexers, and wallet UIs.
    public fun read_warning(): vector<u8> { WARNING }
}
```

### `sources/pool_factory.move`

```move
/// Darbitex pool factory.
///
/// Canonical-pool-per-pair via sorted Table<PairKey, ID>. OTW init creates
/// the shared FactoryRegistry + soulbound OriginCap. `destroy_cap` consumes
/// OriginCap + UpgradeCap → `package::make_immutable` + sealed=true. After
/// sealing the only on-chain action is permissionless create_canonical_pool
/// — zero admin surface.
///
/// WARNING: see `darbitex::pool::read_warning()` for the full 11-item
/// disclosure (immutability, manipulable price, LP-as-NFT, canonical-pair
/// asymmetry, no rescue, AI-only audit, ownerless-protocol, user-bears-all
/// terms, unknown-future-limitation acknowledgment, etc.). Factory-specific notes: (a) `assert_sorted` rejects
/// same-type pairs and wrong-order pairs; (b) `create_canonical_pool`
/// aborts on duplicate pair — first creator wins, picks initial price
/// ratio; (c) `destroy_cap` is one-shot — once sealed, no recovery from
/// any factory-level bug.
module darbitex::pool_factory {
    use std::ascii::{Self, String};
    use std::type_name;

    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::package::{Self, UpgradeCap};
    use sui::table::{Self, Table};

    use darbitex::pool::{Self, LpPosition};

    // ===== Errors =====

    const E_WRONG_ORDER: u64 = 4;
    const E_ZERO: u64 = 5;
    const E_DUPLICATE_PAIR: u64 = 6;
    const E_SEALED: u64 = 18;

    // ===== One-time witness =====

    public struct POOL_FACTORY has drop {}

    // ===== Structs =====

    public struct PairKey has copy, drop, store {
        type_a: String,
        type_b: String,
    }

    public struct FactoryRegistry has key {
        id: UID,
        pool_count: u64,
        pairs: Table<PairKey, ID>,
        sealed: bool,
    }

    /// Soulbound (no `store`): cannot be wrapped or public-transferred.
    public struct OriginCap has key { id: UID }

    // ===== Events =====

    public struct FactoryInitialized has copy, drop { factory_id: ID, deployer: address }
    public struct FactorySealed has copy, drop {
        factory_id: ID, deployer: address, timestamp_ms: u64,
    }

    // ===== Init (one-time, framework-enforced via OTW) =====

    fun init(_witness: POOL_FACTORY, ctx: &mut TxContext) {
        let factory = FactoryRegistry {
            id: object::new(ctx),
            pool_count: 0,
            pairs: table::new<PairKey, ID>(ctx),
            sealed: false,
        };
        let factory_id = object::id(&factory);
        let deployer = tx_context::sender(ctx);
        event::emit(FactoryInitialized { factory_id, deployer });
        transfer::share_object(factory);
        transfer::transfer(OriginCap { id: object::new(ctx) }, deployer);
    }

    // ===== Pair key derivation =====

    /// Lex byte compare. Identical vectors return false → strict `<` also
    /// rejects same-type pairs (canonical AMM cannot pair an asset with itself).
    fun bytes_lt(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = std::vector::length(a);
        let len_b = std::vector::length(b);
        let min_len = if (len_a < len_b) len_a else len_b;
        let mut i = 0;
        while (i < min_len) {
            let xa = *std::vector::borrow(a, i);
            let xb = *std::vector::borrow(b, i);
            if (xa < xb) return true;
            if (xa > xb) return false;
            i = i + 1;
        };
        len_a < len_b
    }

    /// Build sorted PairKey for (A, B). Aborts E_WRONG_ORDER if not strictly sorted.
    public fun assert_sorted<A, B>(): PairKey {
        let type_a = type_name::with_defining_ids<A>().into_string();
        let type_b = type_name::with_defining_ids<B>().into_string();
        let ok = {
            let bytes_a = ascii::as_bytes(&type_a);
            let bytes_b = ascii::as_bytes(&type_b);
            bytes_lt(bytes_a, bytes_b)
        };
        assert!(ok, E_WRONG_ORDER);
        PairKey { type_a, type_b }
    }

    // ===== Pool creation =====

    /// Caller supplies seeding tokens in canonical-sorted type order.
    /// Aborts E_DUPLICATE_PAIR if pair already exists. Pool shared internally
    /// inside pool::create_pool; LP position returned to caller.
    public fun create_canonical_pool<A, B>(
        factory: &mut FactoryRegistry,
        coin_a: Coin<A>, coin_b: Coin<B>,
        clock: &Clock, ctx: &mut TxContext,
    ): LpPosition<A, B> {
        let key = assert_sorted<A, B>();
        assert!(coin::value(&coin_a) > 0 && coin::value(&coin_b) > 0, E_ZERO);
        assert!(!table::contains(&factory.pairs, key), E_DUPLICATE_PAIR);

        let (pool_id, position) = pool::create_pool<A, B>(coin_a, coin_b, clock, ctx);
        table::add(&mut factory.pairs, key, pool_id);
        factory.pool_count = factory.pool_count + 1;
        position
    }

    public fun create_canonical_pool_entry<A, B>(
        factory: &mut FactoryRegistry,
        coin_a: Coin<A>, coin_b: Coin<B>,
        clock: &Clock, ctx: &mut TxContext,
    ) {
        let position = create_canonical_pool<A, B>(factory, coin_a, coin_b, clock, ctx);
        transfer::public_transfer(position, tx_context::sender(ctx));
    }

    // ===== Sealing =====

    /// Idempotency guard via `factory.sealed`. Post-call: package immutable,
    /// no upgrade authority anywhere.
    public fun destroy_cap(
        origin: OriginCap, factory: &mut FactoryRegistry, upgrade: UpgradeCap,
        clock: &Clock, ctx: &mut TxContext,
    ) {
        assert!(!factory.sealed, E_SEALED);
        let OriginCap { id } = origin;
        object::delete(id);
        package::make_immutable(upgrade);
        factory.sealed = true;
        event::emit(FactorySealed {
            factory_id: object::id(factory),
            deployer: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ===== Views =====

    /// Pool ID for (A, B). Sorts internally — caller need not pre-sort.
    public fun canonical_pool_id<A, B>(factory: &FactoryRegistry): Option<ID> {
        let type_a = type_name::with_defining_ids<A>().into_string();
        let type_b = type_name::with_defining_ids<B>().into_string();
        let a_first = {
            let bytes_a = ascii::as_bytes(&type_a);
            let bytes_b = ascii::as_bytes(&type_b);
            bytes_lt(bytes_a, bytes_b)
        };
        let key = if (a_first) PairKey { type_a, type_b }
                  else PairKey { type_a: type_b, type_b: type_a };
        if (table::contains(&factory.pairs, key)) option::some(*table::borrow(&factory.pairs, key))
        else option::none()
    }

    public fun pool_count(factory: &FactoryRegistry): u64 { factory.pool_count }
    public fun is_sealed(factory: &FactoryRegistry): bool { factory.sealed }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(POOL_FACTORY {}, ctx); }

    #[test_only]
    public fun mint_origin_cap_for_testing(ctx: &mut TxContext): OriginCap {
        OriginCap { id: object::new(ctx) }
    }
}
```

---

**End of bundle.**

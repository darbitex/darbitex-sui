# Darbitex Sui Audit R2 Bundle

**Self-audit**: Claude Opus 4.7 (1M)
**Date**: 2026-04-26
**Scope**: `sources/pool.move` (529 LOC), `sources/pool_factory.move` (190 LOC)
**Package**: `darbitex` v0.1.0 on Sui (mainnet rev `6d4ec0b…`)
**Status**: Self-audit GREEN through R3 round, R1 external pass GREEN (Gemini 3.1 Pro + Grok), this is the **R2 external pass** post-fix.

R2 is the second external audit round. R1 returned **GREEN** from two independent
auditors (Gemini 3.1 Pro + Grok) with **0 HIGH / 0 MEDIUM / 0 LOW**. Both
flagged a single convergent observation: missing on-chain getters for the LP
fee accumulator (`lp_fee_per_share_a/b`) + per-position debt
(`fee_debt_a/b`) — required for sealed-package composability with the planned
LP-staking + LP-locker satellites.

The user accepted Option A: add 3 read-only views before sealing. R2 asks
external auditors to re-validate the additions and re-walk anything they
believe the R1 round under-covered.

**Build evidence** (current source as of this bundle):
```
$ sui move build
BUILDING Darbitex
[0 errors, 4 W99001 lint INTENTIONAL per SOP §6 entry-wrapper self-transfers]

$ sui move test
Test result: OK. Total tests: 21; passed: 21; failed: 0
```

---

## What changed since R1 bundle

| File | R1 LOC | R2 LOC | Δ |
|------|--------|--------|---|
| `sources/pool.move` | 516 | 529 | +13 |
| `sources/pool_factory.move` | 190 | 190 | 0 |

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

**Nothing else changed.** Same struct fields, same error codes, same events,
same entry surface, same sealing flow, same tests.

`pending_from_accumulator` (the internal helper reused by `pending_fees`) was
audited unchanged in R1 — it is the same code path `claim_lp_fees` executes
internally to compute claim amounts before withdrawing real coins. The new
view simply returns that number without performing the withdrawal.

---

## Architecture summary (unchanged from R1)

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

## R1 external findings — disposition

| Source | ID | Severity | Title | Disposition |
|--------|----|----------|-------|-------------|
| Gemini 3.1 Pro | G-1 | INFO | Dust-fee accumulator rounding when `fee × SCALE < lp_supply` | Accepted as known MasterChef-pattern artifact. No security impact (LP-side donation rounding). May be added to WARNING constant before deploy. |
| Gemini + Grok | G-2 / K-1 | (no severity, observation) | Missing accumulator + debt views block on-chain LP-staking | **Resolved this round** (Option A: 3 views added). Re-validation requested below. |
| Grok | K-2 | INFO | Confirm full 11-item WARNING text mirrored in `read_warning()` | Resolved — verified `pool.move:54` carries all 11 items (PRICE SOURCE → UNKNOWN FUTURE LIMITATIONS). |

7 fuzz cases proposed by R1 auditors are tracked separately in
`audit/AUDIT_TRACKING.md`. They are pre-deploy nice-to-haves (test coverage),
not protocol-correctness blockers, and are independent of the R2 review.

---

## Self-Audit R3 (post-additions) — summary

Full text in `audit/SELF_AUDIT_R3.md`. Headlines:

- **Build**: 0 errors, 4 W99001 lint (unchanged).
- **Tests**: 21/21 PASS (no test was added or modified — the new views are read-only and reuse audited internal helpers, so behavior of all existing tests is bit-identical).
- **Findings**: 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO — additive read-only views with no mutation, no new abort path, no new arithmetic surface.
- **Per-fn risk**: All three new fns are pure getters or a thin composition of an existing audited helper.
- **Invariant re-check** (8 invariants from R1): all unchanged.
- **Composability impact (positive)**: unblocks future LP-staking and LP-locker satellites that need on-chain pending-fee reads. Critical because Sui sealing is irrevocable post-Tx-2.

---

## Self-Audit by Dimension (delta from R1)

The 8 dimensions (ABI / Args / Math / Reentrancy / Edges / Interactions /
Errors / Events) all carry forward from R1 unchanged except **ABI**, which
gets 3 new entries. Full R1 text is at `audit/AUDIT-R1-BUNDLE.md` and is not
duplicated here. Below is the delta.

### 1. ABI — new entries

Added to `pool` view section (`pool.move:513-525`):
- `pool::fee_per_share<A, B>(&Pool<A, B>) -> (u128, u128)`
- `pool::position_fee_debt<A, B>(&LpPosition<A, B>) -> (u128, u128)`
- `pool::pending_fees<A, B>(&Pool<A, B>, &LpPosition<A, B>) -> (u64, u64)`

All three:
- Take `&` (immutable) borrows — no exclusive lock, parallel-call safe.
- Return primitives only (tuples of `u64` / `u128`) — TS-SDK-safe.
- Generic over `phantom A, B` matching the pool/position they read.
- Have no abort path (no `assert!`, no division by zero possible:
  `pending_fees` calls `pending_from_accumulator` which short-circuits when
  `per_share_current <= per_share_debt`).

Existing R1 view surface preserved unchanged:
- `pool::reserves`, `pool::lp_supply`, `pool::position_shares`,
  `pool::position_pool_id`, `pool::read_warning`
- `pool_factory::canonical_pool_id`, `pool_factory::pool_count`,
  `pool_factory::is_sealed`

**Status**: ✅ PASS

### 2. Math — new path

`pending_fees` invokes `pending_from_accumulator` (audited in R1 §3) twice
with parameters drawn from the pool and position fields. Bounds analysis is
identical to the R1 analysis of the same helper:

- `delta = per_share_current - per_share_debt` (u128, max 3.4e38).
- `(delta as u256) * (shares as u256)` ≤ 6.1e57, fits u256 (max 1.16e77).
- Final `as u64` is mathematically bounded by `pool.balance_X - pool.reserve_X` (the un-claimed fee pool), itself ≤ u64::MAX by construction.

**Status**: ✅ PASS

### 4. Reentrancy — unchanged

The new views are read-only with `&` borrows; they cannot mutate state, cannot
interleave with mutations, and cannot be called inside an exclusive `&mut Pool`
reference window (Sui borrow checker rules). They add zero reentrancy surface.

**Status**: ✅ PASS

### 6. Interactions — unchanged

The new views call only `pending_from_accumulator` (same module, audited).
No new framework dep, no new cross-package call. The pool factory module is
unaffected.

**Status**: ✅ PASS

---

## Findings (R2 self-audit)

**0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO new.** R1's I-1..I-5 inherit unchanged.

---

## R2 External Auditor Plan

For R2 external review, this bundle is the single submittable artifact. The
R1 questions (Q1-Q8) all carry forward — answers are unchanged for those
sections, and external auditors are welcome to re-walk any of them. The R2
round adds the following targeted questions specific to the additions:

**R2-Q1 (HIGHEST) — `pending_fees` correctness vs `claim_lp_fees`.**
Confirm that `pending_fees(&pool, &position)` returns the same `(u64, u64)`
that `claim_lp_fees(&mut pool, &mut position)` would write into the returned
coins, ASSUMING no state-mutating call interleaves between the read and the
hypothetical claim. Both use `pending_from_accumulator` with identical
arguments. Look for any subtle divergence: rounding, ordering, ghost mutation.

**R2-Q2 — Side-channel from exposing `fee_per_share` + `position_fee_debt`.**
The internal accumulator and per-position debt were previously module-private.
Now they are publicly readable. Does any attack surface open up? Specifically:
- Can an MEV bot watching `fee_per_share` updates extract value beyond what's
  already extractable from observing `Swapped` events?
- Does exposing `position_fee_debt` reveal anything privacy-sensitive about
  an LP that wasn't already on-chain?

**R2-Q3 — View `&` borrow safety vs `&mut` operations in same PTB.**
Sui PTB sequencer can interleave a `pending_fees` read with a `swap_a_to_b`
mutation in the same transaction. Confirm the borrow checker enforces strict
ordering (read-then-mutate or mutate-then-read but not concurrent), and that
a stale read followed by a state-mutating call cannot create an exploit (e.g.,
"claim pending fees of X based on stale per-share, then immediately
add_liquidity").

**R2-Q4 — Composability completeness check.**
Given the R2 view surface as it stands, simulate building:
- A simple LP-staking satellite: stake `LpPosition`, accrue boosted rewards
  from a separate token, optionally auto-compound by claiming + re-adding LP.
- A simple LP-locker satellite: lock `LpPosition` for time T, frontend wants
  to display "pending fees so far" while locked.

Are any additional on-chain reads required? If yes, identify the missing
view(s). Note: this is the LAST chance to add views — once `destroy_cap`
runs, the package is permanently immutable.

**R2-Q5 — R1 carry-forward re-check.**
If you (the auditor) were not part of the R1 round, please re-walk Q1-Q8 from
the R1 bundle (`audit/AUDIT-R1-BUNDLE.md`) and report any disagreement with
the R1 GREEN verdict. Explicit redundancy is welcome — convergence across
multiple auditors is the project's primary defense in depth (no human
audit, no formal verification).

For each: track findings in `audit/AUDIT_TRACKING.md` (already populated with
R1 findings).

---

## Refutations / Out-of-Scope (unchanged from R1)

External auditors are asked to NOT spend time on the following — these are
deliberate design choices, not findings:

- **R-1**: Use `Coin<LP_TYPE>` instead of Position NFT.
- **R-2**: Add an arbitrage smart-routing module / treasury / fee recipient.
- **R-3**: Use multisig for deploy.
- **R-4**: Add Display module / coin_registry interaction.
- **R-5**: Add V3 CLMM features (concentrated liquidity, ticks, fee tiers).
- **R-6**: Add pause / emergency admin / fee adjustment knob.
- **R-7**: Replace WARNING constant with off-chain documentation only.

Full justifications in `audit/AUDIT-R1-BUNDLE.md` §Refutations.

---

## Production Readiness

- [x] Build clean (0 errors, only intentional W99001 lint)
- [x] Tests 21/21 PASS via `sui move test`
- [x] Self-audit R1 (pre-compaction) GREEN — `audit/SELF_AUDIT_R1.md`
- [x] Self-audit R2 (post-compaction) GREEN — `audit/SELF_AUDIT_R2.md`
- [x] External R1 GREEN — `audit/EXTERNAL_R1_GEMINI.md`, `audit/EXTERNAL_R1_GROK.md`
- [x] Self-audit R3 (post-G-2 view additions) GREEN — `audit/SELF_AUDIT_R3.md`
- [x] On-chain WARNING with 11 known limitations + `read_warning()` view
- [x] Module-doc top-of-file banner pointing to WARNING
- [x] Sealing flow tested (`test_destroy_cap_seals` + `test_destroy_cap_twice_aborts`)
- [x] `Move.toml` pinned to Sui rev `6d4ec0b…` matching CLI 1.70.2
- [x] LP composability surface (accumulator + debt + pending_fees) — locked in pre-seal
- [ ] **External R2 audit** — Gemini, Grok, others (THIS BUNDLE)
- [ ] Optional fuzz test additions (FUZZ-1..7 from R1; brings 21 → 28 tests)
- [ ] Mainnet deploy script (Tx 1 publish + Tx 2 destroy_cap PTB) tested in devnet/testnet first
- [ ] Hot wallet provisioned with ~1 SUI gas for mainnet deploy
- [ ] `is_sealed == true` verification in deploy script before any public announcement

---

## Bundle Components

- This file (`audit/AUDIT-R2-BUNDLE.md`) — single submittable artifact for external R2
- `audit/AUDIT-R1-BUNDLE.md` — original R1 bundle, full Q1-Q8 + per-dimension audit
- `audit/SELF_AUDIT_R1.md` — pre-compaction internal review (per-function detail)
- `audit/SELF_AUDIT_R2.md` — post-compaction re-verification
- `audit/SELF_AUDIT_R3.md` — post-view-addition re-verification (this round)
- `audit/EXTERNAL_R1_GEMINI.md` — Gemini 3.1 Pro R1 external report
- `audit/EXTERNAL_R1_GROK.md` — Grok R1 external report
- `audit/AUDIT_TRACKING.md` — consolidated finding triage
- `sources/pool.move` (529 LOC) — INLINED BELOW
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

    const WARNING: vector<u8> = b"DARBITEX is an immutable xyk AMM on Sui. After destroy_cap is called the package is permanently immutable - no admin authority, no pause, no upgrade, no fee adjustment. Bugs are unrecoverable. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) PRICE SOURCE - Pool reserves are the only price input. There is no oracle. Spot price is manipulable by sufficiently large swaps relative to depth. Standard xyk AMM property. (2) CAPITAL INEFFICIENCY - V2 full-range liquidity. Lower capital efficiency than V3 CLMM by design. The trade-off is V2 mathematical security plus always-in-range LP (positions never go out of range and never stop earning). (3) LP-AS-NFT - LP positions are Sui objects (LpPosition<A,B>) not Coin<T>. Cannot be used as collateral on Scallop or Suilend. Cannot be routed by Cetus or Aftermath aggregators. Trade-off accepted for per-position fee accounting and claim-without-burn capability. Wallet support varies. (4) FLASH LOAN SAFETY - flash_borrow_a/b returns Coin plus hot-potato receipt that MUST be consumed by flash_repay_a/b in the same TX. Strict repay equality (amount + fee) prevents under or overpay. The k_after >= k_before invariant verified at repay catches any pool manipulation in the borrow window. Reentrancy via Coin<T> is impossible in Sui by framework design. (5) MINIMUM LIQUIDITY - first 1000 LP shares locked at pool creation as anti-cornering protection on the first depositor. Permanently inaccessible. (6) NO TREASURY - 100 percent of swap fee plus flash fee accrue to LP via per-share accumulator. There is no protocol cut, no treasury recipient, no admin fee. (7) CANONICAL PAIR - one pool per (TypeA, TypeB) pair via the factory. The first creator picks the initial reserve ratio. Subsequent depositors take that ratio as truth. Initial creator has price discovery asymmetry until liquidity grows. (8) NO RESCUE - no admin emergency, no pause, no fund recovery. Loss of access to an LpPosition NFT or transfer to a wrong address has no recourse. (9) SEAL-AT-DEPLOY - the deploy keypair holds OriginCap plus UpgradeCap for seconds between Tx 1 (publish) and Tx 2 (destroy_cap). After Tx 2 these are destroyed and the deploy keypair has zero further authority over the package or any pool. (10) AUTHORSHIP AND AUDIT DISCLOSURE - Darbitex was built by a solo developer working with Claude (Anthropic AI). All audits performed are AI-based: multi-round Claude self-audit (R1 and R2) plus external AI review by Gemini, Claude, Grok, and other LLM auditors. NO professional human security audit firm has reviewed this code. Once destroy_cap is called the protocol is ownerless and permissionless - no team, no foundation, no legal entity, no responsible party, no support channel. All losses from bugs, exploits, oracle issues, market manipulation, user error, malicious counterparties, or any other cause whatsoever are borne entirely by users. By interacting with Darbitex (depositing liquidity, swapping, taking flash loans, transferring positions, or any other operation) you confirm that you have read and understood all 11 numbered limitations in this disclosure and accept full responsibility for any and all losses. (11) UNKNOWN FUTURE LIMITATIONS - This list reflects only the limitations identified at the time of audit. Future analysis, novel attack vectors, unforeseen interactions with other Sui protocols, framework changes, market dynamics, or regulatory developments may reveal additional weaknesses, risks, or limitations not enumerated here. Because Darbitex is permanently immutable, newly discovered limitations CANNOT be patched - they become additional risks users continue to bear. Treat the preceding 10 items as a non-exhaustive lower bound on known risks, not a complete enumeration. Users accept all unknown future limitations as a precondition of any interaction with the protocol.";

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

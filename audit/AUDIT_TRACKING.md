# Darbitex Sui — R1 Audit Tracking

Tracks every finding from the external R1 round. One row per finding, one decision per row.

| ID | Source | Sev | Title | Status | Action |
|----|--------|-----|-------|--------|--------|
| G-1 | Gemini 3.1 Pro | INFO | Dust-fee accumulator rounding | accepted as known | Document in WARNING (item 12) or accept silently |
| G-2 / K-1 | Gemini + Grok (both flag) | (none) | Missing accumulator + debt views block on-chain LP-staking satellites | **resolved (Option A)** | Added `fee_per_share`, `position_fee_debt`, `pending_fees` (`pool.move:513-525`). Re-audited in `SELF_AUDIT_R3.md`. 21/21 PASS. |
| K-2 | Grok | INFO | Confirm full 11-item WARNING text mirrored in `read_warning()` | **resolved** | Verified `pool.move:54` constant — all 11 items present (PRICE SOURCE → UNKNOWN FUTURE LIMITATIONS), `read_warning()` returns it. |
| FUZZ-1 | Gemini + Grok | (test) | Dust flash borrow on max-liquidity pool | pending | Add to `tests/pool_tests.move` |
| FUZZ-2 | Gemini + Grok | (test) | Extreme ratio (1, U64_MAX) add_liquidity → cast guard | pending | Add |
| FUZZ-3 | Gemini | (test) | Min-viable-swap dust check (reserve_out near MINIMUM_LIQUIDITY) | pending | Add |
| FUZZ-4 | Grok | (test) | Many small add/remove/claim sequences (accumulator precision) | pending | Add |
| FUZZ-5 | Grok | (test) | Flash borrow near reserve-1 with interleaved add/swap | pending | Add |
| FUZZ-6 | Grok | (test) | `remove_liquidity` exhausting shares down to MINIMUM_LIQUIDITY | pending | Add |
| FUZZ-7 | Grok | (test) | Cross-type edge cases for type_name (shared prefixes, varying lengths) | pending | Add |

**External R1 verdict:** **GREEN** (Gemini 3.1 Pro + Grok, two-of-two independent). 0 HIGH / 0 MEDIUM / 0 LOW. 1 INFO + 1 composability gap (duplicated finding) + 7 fuzz suggestions.

**External R2 verdict (post-G-2 fix):** **GREEN** (Gemini 3.1 Pro + Claude Opus 4.7 + Grok + Qwen + DeepSeek + Kimi K2.6, **six-of-six**). **0 HIGH / 0 MEDIUM / 0 LOW** from any auditor. INFO breakdown: Claude 4 (F1-F4), Qwen 2 (I-6=F2 dup; I-7 SDK doc), DeepSeek 0, **Kimi 1 NEW (Kimi-I1: flash_repay u64 add overflow)**. **All six converge on "composability complete, no more views, lock it in."** Deploy split: 5-of-6 (Gemini/Grok/Qwen/DeepSeek/Kimi) "deploy now/safe to seal"; Claude alone "fuzz-first."

| Finding | Source | Sev | Title | Action |
|---------|--------|-----|-------|--------|
| Kimi-I1 | Kimi R2 | INFO | `flash_repay_a/b` — `amount + fee` u64 add overflows at >99.95% of u64::MAX (~1.844e19 raw units) | **accepted (skip)** — non-exploitable DoS at unreachable amounts (>99.95% of token total supply concentrated in one pool side); user signoff 2026-04-26 |

| Finding | Source | Sev | Title | Action |
|---------|--------|-----|-------|--------|
| F1 | Claude R2 | INFO | `pending_fees` missing pool_id assert | leave as-is — unreachable post-seal |
| F2 / I-6 | Claude + Qwen R2 | INFO | `balance_a/b` views absent | leave as-is — design trade-off |
| F3 | Claude R2 | INFO | `total_pending_fees` absent | leave as-is — indexable from events |
| F4 | Claude R2 | INFO | FUZZ-1..7 unimplemented | Claude: deploy gate. Gemini/Grok/Qwen: nice-to-have |
| I-7 | Qwen R2 | INFO | Phantom type derivation in PTB / SDK | documentation note, not a code change |
| OP-1 | Claude R2 | (op) | Pre-seal UpgradeCap window allows compat-upgrade attack on factory bypass | ephemeral keypair, atomic Tx 1+2, burn after |

| Finding | Source | Sev | Title | Action |
|---------|--------|-----|-------|--------|
| F1 | Claude R2 | INFO | `pending_fees` missing pool_id assert (vs claim_lp_fees) | leave as-is per auditor — unreachable post-seal due to factory + private fields |
| F2 | Claude R2 | INFO | `balance_a/b` views absent (invariant not Move-verifiable) | leave as-is per auditor — RPC sufficient |
| F3 | Claude R2 | INFO | `total_pending_fees` aggregate view absent | leave as-is per auditor — indexable from events |
| F4 | Claude R2 | INFO | FUZZ-1..7 unimplemented | **deploy gate** per Claude — implement before mainnet `destroy_cap` |
| OP-1 | Claude R2 | (operational) | Pre-seal UpgradeCap window allows compat upgrade injecting new module that calls `pool::create_pool` directly | Use ephemeral deployer keypair, Tx 1 + Tx 2 atomic, burn keypair after |

---

## G-2 — Pre-seal composability decision (CRITICAL)

**The point of no return:** On Aptos, the equivalent gap (`feedback_core_composability_gap.md`) is "6-line fix deferred" because Aptos packages can sibling-redeploy. On Sui, `destroy_cap` runs in Tx 2 of the deploy script and `package::make_immutable` is irrevocable. **After seal, no satellite can ever access these fields.**

### What's currently exposed (`pool.move:506-515`)
```move
public fun reserves<A, B>(pool: &Pool<A, B>): (u64, u64)
public fun lp_supply<A, B>(pool: &Pool<A, B>): u64
public fun position_shares<A, B>(pos: &LpPosition<A, B>): u64
public fun position_pool_id<A, B>(pos: &LpPosition<A, B>): ID
public fun read_warning(): vector<u8>
```

### What's NOT exposed
- `pool.lp_fee_per_share_a / lp_fee_per_share_b` (u128 each) — global per-share accumulator
- `pos.fee_debt_a / fee_debt_b` (u128 each) — per-position debt snapshot
- A computed `(u64, u64)` "pending fees" helper

### What this blocks
- LP-staking satellite that displays APY based on actual unclaimed fees
- LP-staking auto-compound (claim → re-add) without redundant accumulator state
- LP-locker showing pending fees in a frontend pre-redemption
- Any third-party frontend that wants on-chain pending-fee read

### What this does NOT block
- Off-chain indexers — they read fields directly via JSON-RPC `getObject`, no view fn needed.
- Burn-and-claim style satellites — `claim_lp_fees` already exposed publicly; satellite can call it through PTB.
- Plain LP transfers / kiosk / lock-by-NFT-id style use cases.

### Cost of adding views
~6 lines (3 view fns), zero state change, zero gas at deploy, zero risk to invariants. Pure read-only.

### Recommended views (if accepted)
```move
public fun fee_per_share<A, B>(pool: &Pool<A, B>): (u128, u128) {
    (pool.lp_fee_per_share_a, pool.lp_fee_per_share_b)
}
public fun position_fee_debt<A, B>(pos: &LpPosition<A, B>): (u128, u128) {
    (pos.fee_debt_a, pos.fee_debt_b)
}
public fun pending_fees<A, B>(pool: &Pool<A, B>, pos: &LpPosition<A, B>): (u64, u64) {
    let pa = pending_from_accumulator(pool.lp_fee_per_share_a, pos.fee_debt_a, pos.shares);
    let pb = pending_from_accumulator(pool.lp_fee_per_share_b, pos.fee_debt_b, pos.shares);
    (pa, pb)
}
```

### Decision options

| Option | Implication |
|--------|-------------|
| **A — Add the 3 views, re-self-audit, redeploy bundle** | Best long-term composability. Adds ~10 min work. No security cost. |
| **B — Accept the gap; satellites must use indexer-fed flows or re-read via internal accumulator copy** | Permanent. Future LP-staking satellite gets harder. |
| **C — Add only `pending_fees(pool, pos)` (single helper)** | Compromise: satellites get the answer they need without exposing raw u128 internals. Most idiomatic. |

**Awaiting user sign-off (per `feedback_auditor_rec_signoff.md` — recommendation, not Tier-1 safety bug).**

---

## G-1 — Dust-fee rounding (INFO)

Standard MasterChef pattern. When `fee_raw × 1e12 < lp_supply`, accumulator delta rounds to 0 and dust stays in `balance_X`. No security threat (LP-side donation). Same behavior in every V2 + accumulator AMM.

**Action:** Append to `WARNING` constant or accept silently. Currently 11 disclosure items; this would be item 12.

---

## Q8 fuzz cases

Three concrete tests to add. All are deterministic, no randomness needed.

```move
#[test]
fun test_dust_flash_borrow() {
    // setup pool with reserves near u64::MAX/2 each
    // flash_borrow amount = 1 → compute_flash_fee == 1
    // repay value 2, succeeds
}

#[test]
fun test_extreme_ratio_add_liquidity() {
    // setup reserves (1, U64_MAX), add (U64_MAX, U64_MAX)
    // expect E_INSUFFICIENT_LIQUIDITY (not arithmetic abort)
}

#[test]
fun test_min_viable_swap_output() {
    // setup pool with reserve_out near MINIMUM_LIQUIDITY
    // swap 1 in, verify output > 0 OR clean failure (not silent zero)
}
```

**Action:** Add to `tests/pool_tests.move` regardless of G-2 decision. Brings test count 21 → 24.

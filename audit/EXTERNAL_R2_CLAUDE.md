# External R2 Audit — Claude Opus 4.7 (fresh web session)

**Auditor:** Claude Opus 4.7 (independent fresh session, delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW / 4 INFO. R1 verdict carries forward.

> "The code is ready to seal. R2 verdict GREEN. Carry forward to deploy with FUZZ-1..7 as the single remaining gate."

## Findings

| ID | Severity | Title | Recommendation |
|----|----------|-------|----------------|
| F1 | INFO | `pending_fees` lacks `pool_id` consistency check that `claim_lp_fees` has | Leave as-is. Unreachable due to factory + private fields. Adding assert costs RPC ergonomics. |
| F2 | INFO | `balance_a/b` views absent (`balance == reserve + unclaimed_fees` not on-chain-verifiable from Move) | Leave as-is. RPC clients can read raw fields. Not required for named satellites. |
| F3 | INFO | `total_pending_fees(&Pool)` aggregate view absent | Leave as-is. Indexable from events. |
| F4 | INFO | FUZZ-1..7 unimplemented | **Single recommended gate before `destroy_cap` on mainnet.** Not a sealing blocker per se, but high diagnostic value. |

## R2-Q1..Q5 verifications

### R2-Q1 — `pending_fees` ≡ `claim_lp_fees` payout
**Bit-identical confirmed.** Per-arg comparison table:

| Site | per_share arg | debt arg | shares arg |
|------|---------------|----------|------------|
| `claim_lp_fees` | `pool.lp_fee_per_share_a/b` | `position.fee_debt_a/b` | `position.shares` |
| `pending_fees` | `pool.lp_fee_per_share_a/b` | `pos.fee_debt_a/b` | `pos.shares` |

Mutation in `claim_lp_fees` happens AFTER the read, so the view reflects pre-claim state — correct semantics for satellites.

**Semantic divergence noted (F1):** `claim_lp_fees` aborts E_WRONG_POOL on `object::id(pool) != position.pool_id`; `pending_fees` does not. Unreachable post-seal: `LpPosition` fields are module-private, `create_pool` is `public(package)` factory-only, no new modules can be added post-seal. Type system handles `Pool<A,B>` vs `Pool<C,D>` mismatches at compile time. Considered LOW, kept INFO. Recommend leave as-is.

### R2-Q2 — Side-channel from exposing accumulator + debt
**No new attack surface.** `lp_fee_per_share` is monotonic and reconstructible from the `Swapped` event log (every event carries `lp_fee` + timestamp + lp_supply at-the-time). `fee_debt` set during `add_liquidity` and `claim_lp_fees`, both event-emitting with position_id. MEV: accumulator does not affect price (orthogonal to reserves), no front-running vector. Privacy: positions are object-IDs already indexed.

### R2-Q3 — `&` vs `&mut` borrow safety in PTBs
**Safe.** Sui runtime borrow checker enforces single-borrow-per-command. PTB commands sequenced (no concurrency in TX). Stale-read pattern cannot exploit: no mutating function in this module accepts a "pending amount" or "fee_per_share value" as input — all recompute from current `&mut Pool` state. Accumulator can only grow → "read pending → manipulate accumulator → claim more" attacks blocked because intervening mutation would *increase* not decrease the eventual claim, and increase is paid for by the corresponding swap/flash fee.

### R2-Q4 — Composability completeness
**Both satellites fully buildable on current surface.**

| Need | LP-staking | LP-locker | Available |
|------|-----------|-----------|-----------|
| Stake/lock = transfer LpPosition | ✅ has `store` | ✅ | yes |
| Track per-staker shares | `position_shares` | (n/a) | yes |
| Verify same pool | `position_pool_id` | `position_pool_id` | yes |
| Display pending UI | `pending_fees` | `pending_fees` | yes |
| Auto-compound | `claim_lp_fees` + `add_liquidity` | (n/a) | yes |
| Verify debt reset post-claim | `position_fee_debt` | (n/a) | yes |

Two optional views considered + **rejected by auditor**: `balance_a/b` and `total_pending_fees`. "Adding fields late risks reordering the ABI surface, and neither view is required for the named satellites... my honest take is **don't add anything else**. Lock it in."

### R2-Q5 — R1 carry-forward re-walk
R1 GREEN upheld. Items explicitly re-confirmed:
- `pending_from_accumulator` final `as u64` cast safe under both normal and adversarial-lp_supply scenarios — bounded by `balance_X ≤ u64::MAX` (Sui Coin invariant).
- `compute_amount_out` equivalent to standard UniV2 formula, u256 promotion correct, strict `< reserve_b` rejection rejects total drain.
- Flash k-invariant traced borrow → swap-in-window → repay; fee wedge guarantees `k_after_swap > k_before_swap`; flash repay fee accrues to accumulator without touching reserves; assert correctly enforces `k_after >= k_before`.
- Dead-share floor via strict `>` in create_pool + `>= MINIMUM_LIQUIDITY` post-decrement in remove_liquidity preserves anti-cornering forever.
- OriginCap soulbound (`key`-only, no `store`). Test-only mint helper `#[test_only]`-gated.
- `type_name::with_defining_ids` correctly disambiguates same-name types from different packages.
- FlashReceipt zero abilities → strict hot-potato consumption.
- No-reentrancy-via-Coin is framework-level: "If Sui ever adds Coin hooks, this assumption breaks." (Hypothetical future risk; not action item.)

## Operational note (NOT a code finding) — deployer keypair hygiene

> "Pre-seal, the deployer holds `UpgradeCap`. Sui upgrade rules permit adding new modules in a compatibility-preserving upgrade. So in principle, a compromised or malicious deployer could publish an upgrade adding a module that calls `pool::create_pool` directly, bypassing the factory. This would let them create duplicate `Pool<A,B>` instances."

**Mitigation (auditor's deploy runbook recommendation):**
- Tx 1 (publish) and Tx 2 (`destroy_cap`) executed from an **ephemeral keypair**.
- destroy_cap called **immediately after publish confirms**.
- Keypair **burned (or never reused) afterward**.
- Pre-Tx-2: keypair **MUST NOT be used for any other purpose**.

This is an op-procedure item, not a code-level finding.

## Recommendation

> "Bottom line: R2 verdict GREEN. Carry forward to deploy with FUZZ-1..7 as the single remaining gate."

Ordered pre-`destroy_cap` checklist (auditor's):
1. Implement FUZZ-1..7 (R1 backlog), particularly cross-position fee-accounting (no double-claim) + flash k-invariant under arbitrary swap interleaving.
2. Testnet rehearsal of Tx 1 + Tx 2 sequence with `is_sealed == true` verification.
3. Mainnet from ephemeral keypair, minimal SUI gas, keypair burn after.

## Cross-validation with Gemini 3.1 Pro R2

**Convergent (high-confidence signal):**
- Both verdict GREEN, 0 HIGH/MED/LOW, 0 new findings (Claude's F1-F4 are all "leave as-is" INFO).
- Both confirm `pending_fees ≡ claim_lp_fees` mathematically.
- Both confirm composability surface complete; **both auditors recommend AGAINST adding more views**.
- Both confirm side-channel non-issue (info already public via RPC).
- Both confirm framework-enforced borrow safety in PTBs.

**Divergent / additive:**
- Claude flags F1 (pending_fees missing pool_id assert) explicitly considered + rejected as escalation. Gemini didn't mention it.
- Claude adds operational deployer-keypair runbook recommendation (ephemeral key, burn after seal).
- Gemini doesn't flag fuzz as a deploy gate; Claude promotes FUZZ-1..7 to "single remaining gate."

**Net:** Three independent auditors converge GREEN. Disagreement is on rigor of pre-deploy fuzz (Gemini "Production Ready, deploy now" vs Claude "fuzz first"). Easy reconciliation: do FUZZ-1..7, deploy.

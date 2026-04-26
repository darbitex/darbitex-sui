# External R2 Audit — Qwen

**Auditor:** Qwen (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW / 2 INFO.

> "I endorse the GREEN verdict for mainnet sealing. The package is production-ready for sealing."

## Findings

| ID | Severity | Title |
|----|----------|-------|
| I-6 | INFO | `balance` vs `reserve` visibility — `pool::reserves()` returns accounting reserves; unclaimed fees in `balance_X` not directly exposed |
| I-7 | INFO | Phantom type derivation — frontends must extract `A`, `B` from full object type name |

**Both INFO duplicate prior auditor observations:**
- I-6 ≡ Claude's F2 (`balance_a/b` absent). Qwen frames as "standard AMM design trade-off, not a security issue."
- I-7 is new — integrator-documentation note for SDK consumers, not a code change.

**0 HIGH / 0 MEDIUM / 0 LOW.**

## R2-Q1..Q5 verifications

### R2-Q1 — `pending_fees` vs `claim_lp_fees`
**PASS.** "1:1 read-only projection of the claim amount. No rounding divergence, no ghost mutation, no ordering dependency."

### R2-Q2 — Side-channel exposure
**PASS.** "Fee accrual rate does not influence swap pricing or arbitrage opportunities. MEV bots extract value from reserve ratios, not LP fee accounting. Exposing the accumulator actually *reduces* indexer overhead by eliminating the need to reconstruct accrual rates from `Swapped` events." Privacy-wise: "already inferable by indexing `LiquidityAdded` and `LpFeesClaimed` events. The view simply provides a direct O(1) on-chain read."

### R2-Q3 — `&` vs `&mut` PTB safety
**PASS.** "Sui's PTB execution model linearizes commands. Sui's compiler/runtime enforces strict aliasing. Concurrent `&` + `&mut` to the same object in one PTB is impossible without explicit sequentialization. No TOCTOU or reentrancy vector exists."

### R2-Q4 — Composability completeness
**PASS.** Both satellites complete:
- **LP-staking:** `position_pool_id` + `pending_fees` + `reserves` + `lp_supply` + `fee_per_share` covers reward calc, validation, parameters, fee tracking. Auto-compound via existing entry fns.
- **LP-locker:** `pending_fees` + `position_fee_debt` + `fee_per_share` covers display + historical accrual reconstruction.

> "**No additional views are required pre-seal.**"

Mentions `balance_a/b` would benefit a TVL-including-unclaimed satellite (= I-6) but "`reserves` + `pending_fees` (aggregated) is sufficient for standard staking/locking logic."

### R2-Q5 — R1 carry-forward
**GREEN, no disagreements.** R1 findings (I-1 dust, G-2 views, K-2 warning) remain correctly dispositioned. Re-confirmed:
- `x*y=k` math uses u256 intermediates correctly
- Flash loans enforce hot-potato consumption + `k_after >= k_before`
- Sealing flow irrevocably deletes caps + `package::make_immutable`
- No admin/pause/upgrade post-seal
- Event emission + error codes consistent

## Cross-validation summary (Gemini + Claude + Grok + Qwen R2)

**4-of-4 R2 GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW from any auditor.

INFO findings consolidated (4 total, all "leave as-is"):
- F1 (Claude): pending_fees missing pool_id assert — unreachable post-seal.
- F2 / I-6 (Claude + Qwen): balance_a/b views absent — design trade-off.
- F3 (Claude): total_pending_fees absent — indexable from events.
- F4 (Claude): FUZZ-1..7 unimplemented — Claude flags as deploy gate; Gemini/Grok/Qwen treat as nice-to-have.
- I-7 (Qwen, NEW): phantom-type-name SDK integration note — documentation, not code.

**4-of-4 converge:** "no additional views required pre-seal," composability surface complete, ready to seal.

**Deploy recommendation split:**
- Gemini, Grok, Qwen: deploy now, fuzz nice-to-have
- Claude: fuzz first as remaining gate

# External R2 Audit — DeepSeek

**Auditor:** DeepSeek (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW / 0 new INFO.

> "All pre-seal composability requirements are now satisfied. The package is ready for final publishing."

## Findings

| ID | Severity | Title |
|----|----------|-------|
| — | — | None |

**Cleanest verdict among R2 auditors** — zero new findings of any severity. Notes existing R1 dust-rounding observation (already disclosed in WARNING) but flags nothing new.

## R2-Q1..Q5 verifications

### R2-Q1 — `pending_fees` vs `claim_lp_fees` correctness
**CORRECT.** "Bit-identical to the amounts that would be written into the output coins of a hypothetical `claim_lp_fees` executed immediately afterward. Composability satellites can confidently use this view to preview claimable fees."

### R2-Q2 — Side-channel exposure
**NO NEW ATTACK SURFACE.** `Swapped` event already emits fee amount; observers compute accumulator evolution deterministically. `position_fee_debt` already public via object field reads. Read-only, purely informational, no manipulation vector.

### R2-Q3 — `&` borrow safety in PTB
**SAFE.** Sui borrow checker prevents `&` + `&mut` coexistence. Stale read after view is "ordinary read-then-write ordering, not an exploit. No atomicity violation or double-spend can arise because the mutable operation will update the actual state correctly."

### R2-Q4 — Composability completeness for LP-staking + LP-locker
**SUFFICIENT.** Lists current surface that covers staking + locker:
- `fee_per_share`, `position_fee_debt`, `pending_fees` → preview rewards without claiming
- `claim_lp_fees` → harvest while keeping position (autocompound)
- `add/remove_liquidity` → adjust staked positions
- `reserves`, `lp_supply`, `position_shares`, `position_pool_id` → frontend/UI

> "No additional on-chain views are required to build a basic LP-staking satellite (e.g., a contract that holds `LpPosition` and occasionally auto-compounds) or an LP-locker that displays pending fees for a locked position."

### R2-Q5 — R1 carry-forward
**No disagreement with R1 GREEN.** Performed fresh full-coverage audit since R1 bundle not viewed. All Uniswap V2 patterns faithfully implemented. Only quirk = dust-fee rounding (already INFO in R1).

## Re-verified invariants

| Invariant | Status |
|-----------|--------|
| `balance_X = reserve_X + cumulative_unclaimed_fees` | ✓ |
| `x·y=k` (swap monotone non-decrease + flash k_after >= k_before) | ✓ |
| MINIMUM_LIQUIDITY lock (1000 shares unrecoverable + remove floor) | ✓ |
| Reentrancy impossible (Sui no Coin callback) | ✓ |
| Factory canonical pairing (lex-sort prevents duplicates + self-pairs) | ✓ |
| Sealing (destroy_cap one-shot, irreversible) | ✓ |
| Access control (create_pool is `public(package)`, factory-only) | ✓ |

## Recommendation

> "Proceed to mainnet deployment after the planned: expansion of test suite (FUZZ-1..7, no blocker), mainnet deploy script dry-run on devnet/testnet, verification of `is_sealed` flag before public announcement."

## Cross-validation summary (R2 — Gemini + Claude + Grok + Qwen + DeepSeek)

**5-of-5 R2 GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW from any auditor.

INFO consolidated:
- F1 (Claude only): pending_fees missing pool_id assert — leave as-is
- F2 / I-6 (Claude + Qwen): balance_a/b views absent — leave as-is
- F3 (Claude only): total_pending_fees absent — leave as-is
- F4 (Claude only): FUZZ-1..7 unimplemented — Claude: deploy gate. Others: nice-to-have.
- I-7 (Qwen only): phantom-type-name SDK doc note — not code
- DeepSeek: 0 new INFO. Mentions only the prior dust-rounding observation (already disclosed in WARNING).

**Composability surface verdict (5-of-5 unanimous):** complete, no more views needed, lock it in.

**Deploy verdict (4-of-5 say deploy now):** Gemini, Grok, Qwen, DeepSeek "deploy now, fuzz nice-to-have." Claude alone calls fuzz a deploy gate.

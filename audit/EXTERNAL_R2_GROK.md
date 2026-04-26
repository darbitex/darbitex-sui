# External R2 Audit — Grok

**Auditor:** Grok (xAI, delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** "No new HIGH/MEDIUM/LOW findings. The three added read-only views are correct, safe, and complete the intended LP composability surface."

> "Proceed to seal and mainnet deployment. The protocol is simple enough for the audit surface to provide high confidence, especially with multi-LLM convergence."

## Findings

| ID | Severity | Title |
|----|----------|-------|
| — | — | None |

**0 HIGH / 0 MEDIUM / 0 LOW.** Notes 3 INFO already acknowledged in self-audit (dust-fee rounding, intentional W99001 lints, LP-as-NFT limitation).

## R2-Q1..Q5 verifications

### R2-Q1 — `pending_fees` correctness vs `claim_lp_fees`
**Confirmed identical (pre-mutation).** Both call `pending_from_accumulator` with same args. claim_lp_fees additionally writes `position.fee_debt = pool.lp_fee_per_share` + emits event. View is pure snapshot. Bounds analysis: output ≤ `balance_X - reserve_X` by construction. No overflow, no underflow, no DBZ. No ghost mutation.

### R2-Q2 — Side-channel from exposing accumulator + debt
**No material new attack surface.** MEV: accumulator already inferable from `Swapped` events + reserve reads; new view is convenience, not new info. Position privacy: `fee_debt_*` already inferable on-chain by anyone reading the position object (which has `store`, is transferable). No new manipulation vectors. "Acceptable exposure. The trade-off for LP-staking/locker satellites is positive and was the explicit goal."

### R2-Q3 — `&` vs `&mut` borrow safety in PTBs
**Borrow checker provides strong static guarantees.** "Mutable borrow excludes any other borrows on overlapping places." PTB commands sequenced. No reentrancy vector added. Flash loans remain protected by hot-potato + k-invariant (Trail of Bits aligned). Stale-read-then-mutate cannot exploit because mutating fns recompute from current pool state.

### R2-Q4 — Composability completeness
**Sufficient for both satellites.**

LP-staking: stake (store ability ✅), pending_fees for rewards display + auto-compound, claim+add via existing fns, no extra views needed.

LP-locker: lock → time-escrow → display via pending_fees → unlock + optional claim. Three new views cover display + harvest cleanly.

> "**No missing views identified.** Adding more would be nice-to-have but not required for the stated use cases. This is the last pre-seal opportunity — surface looks locked-in and adequate."

### R2-Q5 — R1 carry-forward re-check
**No disagreements with prior GREEN.** Re-confirmed: x*y=k preserved across all paths, accumulator+reserve model holds, dust-rounding benign, hot-potato + PTB atomicity + k-invariant + no-Coin-callback = strong flash protection, all edges sound (MIN_LIQ lock, slippage, deadline, disproportional, canonical pair, sealed), entry surface clean, sealing one-shot, WARNING fully on-chain mirroring 11 items, factory canonical-pair sorting prevents duplicates.

## Production readiness

> "Code appears deploy-ready assuming:
> - Fuzz cases (FUZZ-1..7) are nice-to-have but not blockers.
> - Deploy script tested on devnet/testnet (publish → destroy_cap PTB, verify `is_sealed`).
> - Hot wallet gas provisioning.
> - Community/indexer/front-end integration of the new views."

> "Final Recommendation: **Proceed to seal and mainnet deployment.**"

> "Exemplary for an immutable deployment."

## Cross-validation summary (Gemini + Claude + Grok R2)

| Aspect | Gemini R2 | Claude R2 | Grok R2 |
|--------|-----------|-----------|---------|
| Verdict | GREEN | GREEN | GREEN |
| New HIGH/MED/LOW | 0 | 0 | 0 |
| New INFO | 0 | 4 (all "leave as-is" except F4) | 0 (notes 3 already-acknowledged) |
| pending_fees ≡ claim_lp_fees | ✓ | ✓ | ✓ |
| Side-channel safe | ✓ | ✓ | ✓ |
| PTB borrow safe | ✓ | ✓ | ✓ |
| Composability complete | ✓ "no more views" | ✓ "lock it in" | ✓ "no missing views" |
| R1 carry-forward upheld | ✓ | ✓ | ✓ |
| FUZZ-1..7 status | not flagged | **deploy gate** | "nice-to-have, not blocker" |
| Deploy recommendation | "Production Ready, deploy" | "GREEN, fuzz first" | "Proceed to seal" |

**Net:** 3/3 GREEN with zero new severity findings. 2/3 say deploy now without fuzz; 1/3 (Claude) recommends fuzz first as the single remaining gate. All three converge on "no more views, lock it in." Two operational items raised by Claude (deployer keypair hygiene) carry forward to deploy runbook.

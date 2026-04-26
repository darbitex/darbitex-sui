# External R2 Audit — Kimi K2.6 (Moonshot AI)

**Auditor:** Kimi K2.6 (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW / **1 NEW INFO** (the only auditor in 7 passes to flag a code-level edge case beyond R1's known dust-rounding).

> "The R2 bundle is safe to seal. The additive views correctly expose the fee accumulator state needed for post-seal LP-staking and LP-locker composability, with no regression in security, correctness, or gas behavior."

## Findings

| ID | Severity | Title | Recommendation |
|----|----------|-------|----------------|
| Kimi-I1 | INFO | `flash_repay_a/b` — `amount + fee` u64 add can overflow at extreme borrows (>99.95% of u64::MAX) | Optional 1-line u256 promote |

## I-1 detail

**Location:** `pool.move:438` (flash_repay_a) and `pool.move:454` (flash_repay_b)

**Code:**
```move
assert!(coin::value(&coin) == amount + fee, E_REPAY_AMOUNT);
```

`amount` and `fee` are both `u64`. The expression `amount + fee` traps on Move arithmetic overflow when:
- `amount + amount * 5 / 10000 > u64::MAX`
- `amount > u64::MAX × 10000 / 10005 ≈ 1.844e19` (≈ 99.95% of u64::MAX)

**Impact:**
- **Non-exploitable for theft.** Move overflow trap → entire PTB aborts → hot-potato receipt + borrowed coin revert atomically. No partial state.
- **Effect:** denial-of-flash for absurdly-large borrows. For SUI 9-dec, threshold = ~18.4 billion SUI raw units — ~99.95% of total SUI supply concentrated in one side of one pool. Not reachable on any realistic pool.

**Recommendation:** optional defensive u256 promote to match the codebase's existing u256-everywhere style:
```move
assert!((coin::value(&coin) as u256) == (amount as u256) + (fee as u256), E_REPAY_AMOUNT);
```

## R2-Q1..Q5 verifications

### R2-Q1 — `pending_fees` ≡ `claim_lp_fees`
**Confirmed identical.** Per-arg mapping table identical. "No rounding divergence, no ordering issue, no ghost mutation."

### R2-Q2 — Side-channel
**No material attack surface.** Accumulator already derivable from `Swapped` events; `position_fee_debt` is "when the position was last synced," inferable from tx history. "Composability benefit far outweighs negligible disclosure risk."

### R2-Q3 — `&` borrow safety in PTB
**Sui borrow checker enforces strict linearity; no stale-read exploit.** No mutating fn accepts a "pending amount" as input — all recompute. Optimistic-read attack blocked.

### R2-Q4 — Composability completeness
**Sufficient for both satellites.** Notes one nice-to-have (not blocking): `balance_excess(&pool) -> (u64, u64)` returning `(balance - reserve)` for "total unclaimed protocol fees" display. Derivable off-chain, "explicitly not requested." Not adding.

### R2-Q5 — R1 carry-forward
**R1 GREEN upheld** across all 8 dimensions. Re-confirms: `balance == reserve + cumulative_unclaimed_fees`, hot-potato + k-invariant flash, sealing one-shot, MIN_LIQ floor.

## Delta audit (the 3 new views)

| Criterion | `fee_per_share` | `position_fee_debt` | `pending_fees` |
|-----------|-----------------|---------------------|----------------|
| Immutability | `&Pool` | `&LpPosition` | `&Pool` + `&LpPosition` |
| Return type | Primitives | Primitives | Primitives |
| Abort paths | None | None | None (short-circuit on `<=`) |
| Arithmetic surface | Field access | Field access | Reuses R1-audited helper |
| TS-SDK safe | ✓ | ✓ | ✓ |
| Parallel-call safe | ✓ | ✓ | ✓ |

"All three functions are thin, pure getters. No new `use` statements, no new framework deps, no cross-module calls beyond the existing helper."

## Cross-validation summary (R2 — six auditors)

**6-of-6 R2 GREEN.** 0 HIGH / 0 MEDIUM / 0 LOW from any auditor.

| Auditor | New INFO contributions |
|---------|------------------------|
| Gemini 3.1 Pro R2 | 0 |
| Claude Opus 4.7 R2 | F1-F4 (all "leave as-is" per auditor) |
| Grok R2 | 0 |
| Qwen R2 | I-6 (= F2 dup), I-7 (SDK doc) |
| DeepSeek R2 | 0 |
| **Kimi R2** | **I-1 (NEW: flash-repay u64 add overflow at >99.95% u64::MAX)** |

**Kimi finding is genuinely new.** 5 prior auditors did not flag it. Trivial DoS only at impossibly-extreme borrow amounts, but pre-seal is the last chance to fix.

**Composability surface verdict (6-of-6 unanimous):** complete, no more views needed.

**Deploy verdict:** 5-of-6 say deploy now (FUZZ-1..7 nice-to-have); Claude alone says fuzz-first. Kimi says "safe to seal" with optional u256 patch.

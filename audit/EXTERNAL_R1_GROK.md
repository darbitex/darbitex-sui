# External R1 Audit — Grok

**Auditor:** Grok (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 516 LOC, `pool_factory.move` 190 LOC)
**Bundle:** `audit/AUDIT-R1-BUNDLE.md` (commit `161a9e8`)

## Verdict

**GREEN** for R1. "Code is high-quality for a self-audited core. No HIGH or MEDIUM findings surfaced."

## Findings

| ID | Severity | Title | Location |
|----|----------|-------|----------|
| K-1 | INFO/SUGGESTION | Pure view for `lp_fee_per_share_a/b` or `position_pending_fees` helper for satellites | `pool` view surface |
| K-2 | INFO | Confirm full 11-item WARNING text is complete + mirrored in `read_warning()` | `pool::WARNING` |

**0 HIGH / 0 MEDIUM / 0 LOW.** Self-audit I-1..I-5 endorsed as legitimate defense-in-depth.

## Per-finding detail

### K-1 — Pending-fees helper for satellites (matches Gemini G-2)

> "Consider adding a pure view for current `lp_fee_per_share_a/b` (or a `position_pending_fees` helper that takes `&Pool` + `&LpPosition`) if satellites need it without mut. **Not blocking.**"

Grok marks "not blocking", but Sui sealing is irrevocable — interpret "not blocking R1 audit" not "not blocking deploy decision".

### K-2 — WARNING text completeness check

> "Ensure the full 11-item text (including AI-only audit, ownerless, user-bears-loss, unknown-future-limitations) is complete and mirrored in the constant / `read_warning()`. This is critical for user acceptance."

**Action:** Verify the WARNING constant content matches the documented 11-item disclosure list end-to-end.

## Q1-Q8 answers (excerpts)

- **Q1 (flash safety):** "Textbook Sui hot-potato pattern (Trail of Bits 2025 confirms strength)." All four adversary scenarios (same-pool, add-during-flash, multi-pool, repay-with-wrong-side) confirmed safe. "No reentrancy lock needed — your documented rationale holds."
- **Q2 (u256 sufficiency):** "u256 promotion used judiciously where needed, intermediates safe." Final cast safety reaffirmed.
- **Q3 (lex byte ordering):** "Standard and robust for canonical pairing. Edge cases (shared prefixes, different lengths, hex address segments) handled by vector lex compare."
- **Q4 (sealing):** "Order is mostly safe (I-5 notes theoretical inconsistency window, but `make_immutable` aborts are unrealistic on mainnet). Post-seal: no caps remain, no upgrades."
- **Q5 (precision):** "Dust fees still accrue meaningfully" — disagrees mildly with Gemini G-1 framing. Both still recommend fuzz coverage.
- **Q6 (optimal-pair):** "amount_b_optimal == 0 case correctly hits E_ZERO_AMOUNT. Explicit u256 ratio checks + ≤ U64_MAX guard → clean E_INSUFFICIENT_LIQUIDITY (not opaque abort)."
- **Q7 (composability):** See K-1 — same finding as Gemini.
- **Q8 (fuzz):** Six concrete cases:
  1. Extreme ratios near 2^64:1 (u64 cast guards)
  2. Tiny fees on low lp_supply (lp_supply ≈ MINIMUM_LIQUIDITY=1000, fee=1)
  3. Add/remove/claim sequences with many small ops (accumulator precision)
  4. Flash borrow near reserve-1 interleaved with add/swap/remove (new-LP fee dilution)
  5. `remove_liquidity` exhausting shares down to MINIMUM_LIQUIDITY (dead-share floor)
  6. Cross-type edge cases for `type_name::with_defining_ids` (different package addresses, shared prefixes, varying lengths)

## Other observations

- "No `swap_entry` or `flash_entry` is intentional and correct — these are PTB-composable primitives."
- LP-NFT trade-off "deliberate and reasonable given thesis."
- Deploy recommendation: "Verify Tx1+Tx2 on devnet/testnet, confirm `is_sealed == true`, pin framework rev strictly."
- Optional: "Lightweight formal verification pass (Move Prover) on core invariants (k, reserves >= payouts, no drain)."
- Out-of-scope rejections R1-R7: "All reasonable given thesis. No strong pushback."

## Cross-validation with Gemini 3.1 Pro

**Convergent findings (high-confidence signal):**
- Both verdict GREEN, 0 HIGH/MED/LOW.
- Both flag missing accumulator/debt views (Gemini G-2 = Grok K-1).
- Both confirm flash safety + k-invariant proof.
- Both recommend dust-flash + extreme-ratio fuzz tests.
- Both confirm bytes_lt lex order correct.
- Both confirm sealing irrevocability (Gemini stronger: "mathematically impossible to call destroy_cap twice").

**Divergent:**
- Gemini flags G-1 (dust fee accumulator rounds to 0 on huge lp_supply) as INFO. Grok says "dust fees still accrue meaningfully" — softer framing on same math. Treat as Gemini-correct (dust DOES round to 0 when `fee × 1e12 < lp_supply`); Grok's wording was imprecise.

**Net:** Two-of-two independent confirmation strengthens GREEN verdict. Single new actionable finding (composability views) is duplicated across both.

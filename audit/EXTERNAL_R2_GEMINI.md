# External R2 Audit — Gemini 3.1 Pro

**Auditor:** Gemini 3.1 Pro (delivered via user)
**Date:** 2026-04-26
**Target:** `darbitex` v0.1.0 (`pool.move` 529 LOC, `pool_factory.move` 190 LOC) — post-Option-A view additions
**Bundle:** `audit/AUDIT-R2-BUNDLE.md`

## Verdict

**GREEN.** "The newly added view functions are structurally sound, introduce zero new attack vectors, and successfully complete the required composability surface."

> "The `darbitex` v0.1.0 core contracts are Production Ready. The additions perfectly resolve the composability blocker identified in R1 without widening the attack surface."

## Findings

| ID | Severity | Title |
|----|----------|-------|
| — | — | None |

**0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO new.** R1 disposition unchanged.

## R2-Q1..Q5 verifications

### R2-Q1 (HIGHEST) — `pending_fees` correctness vs `claim_lp_fees`
**Verified and Safe.** "Mathematically guaranteed to be bit-identical to the actual claimable amount, assuming no interleaved state mutation. There are no ghost mutations or hidden state dependencies." Both functions call the same `pending_from_accumulator` helper with identical arguments; only difference is one returns the value while the other consumes it via balance::split.

### R2-Q2 — Side-channel from exposing accumulator + debt
**No New Risk.** "In the Sui object model, the fields of a shared object (`Pool`) and an owned object (`LpPosition`) are already 100% public to the network via RPC reads. Any MEV bot or indexer could already read the exact `fee_debt_a` of any user's position by querying the object ID. Adding these getters simply bridges this existing public visibility into the Move execution layer, allowing smart contracts to read what off-chain actors already could."

### R2-Q3 — `&` borrow safety vs `&mut` in same PTB
**Secure by Framework Design.** Sui borrow checker prevents simultaneous `&` + `&mut` to the same object. Stale-read harmlessness: "`claim_lp_fees` does not accept user-provided fee inputs; it dynamically recalculates the exact pending fees based on the current, post-swap state of the pool's accumulator. An attacker cannot use a stale read to trick the claim function into over-paying. The read values are purely informational for the caller's internal logic."

### R2-Q4 — Composability completeness for LP-staking + LP-locker
**Complete and Unblocked.**
- **LP-Staking:** "Needs the position's principal (`position_shares()`), the pool binding (`position_pool_id()`), and the yield generated (`pending_fees()`). It has all three. After a claim, it can verify the debt reset using `position_fee_debt()`."
- **LP-Locker:** "Frontends displaying locked positions can easily map the NFT object ID to the pool and query `pending_fees()` to show real-time accrued value without needing indexer infrastructure."
- "**No additional views are necessary.** The API is lean, complete, and TS-SDK friendly."

### R2-Q5 — R1 carry-forward re-check
**R1 Verdict Upheld.** Re-confirmed: hot-potato + k-invariant flash safety, u256-promote arithmetic absorbs adversarial max-u64 inputs, canonical pair sorting + immutable sealing rigorously implemented.

## Recommendation

> "Production Ready. Proceed with the planned testnet deployment and subsequent mainnet sealing flow."

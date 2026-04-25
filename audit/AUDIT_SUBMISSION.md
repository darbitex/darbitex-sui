# Darbitex Sui — External Audit Submission R1

**Date:** 2026-04-25
**Repo:** `/home/rera/darbitex-sui/` (commit `9a56a34`)
**Scope:** `sources/pool.move` (500 LOC) + `sources/pool_factory.move` (181 LOC) — entire `darbitex` package.
**Build:** `sui move build` clean (0 errors). `sui move test`: 20/20 PASS.
**Internal review:** `audit/SELF_AUDIT_R1.md` (pre-compaction) + `audit/SELF_AUDIT_R2.md` (post-compaction). 0 HIGH / 0 MEDIUM / 0 LOW / 5 INFO from internal pass.

---

## 1. Project context

Darbitex Sui is an x*y=k constant product AMM port of the Aptos Darbitex Final core. Single canonical pool per pair, 5 bps swap fee + 5 bps flash fee (100% to LP), permissionless pool creation, sealed package post-deploy (zero admin authority remains anywhere). LP positions are transferable Sui objects with per-share fee accumulator + per-position debt snapshot — enabling **claim-without-burn** for fees (an unusual capability for V2-style AMMs).

**Design philosophy:** V2 mathematical security floor (battle-tested constant product, no out-of-range risk, minimal attack surface) + V3-style LP UX flexibility (claim fees without exiting position, transferable position-as-asset). Capital-inefficient by design vs CLMM peers; retail-LP-friendly by design.

**Out of scope for this AMM port:** arbitrage smart-routing module (dropped — on Sui, public funs are PTB-callable cross-package, so no on-chain arb wrapper can enforce a treasury cut without breaking composability). Bots build their own arb cycles via PTB chains over `pool::swap_*` and `pool::flash_*`.

---

## 2. Architecture summary

| Decision | Value | Rationale |
|---|---|---|
| Pool type | `Pool<phantom A, phantom B> has key` (no `store`) | Shared at create, prevents wrap/transfer outside `share_object` |
| LP container | `LpPosition<phantom A, phantom B> has key, store` (transferable NFT) | Per-position fee accumulator debt snapshot enables claim-without-burn; outlier vs Sui V2 norm of `Coin<LP>` (deliberate — supports cross-chain Darbitex satellite ecosystem: lp-locker, lp-staking) |
| Reserve model | Separate `reserve_a/b: u64` from `balance_a/b: Balance<T>` | Invariant: `balance == reserve + cumulative_unclaimed_fees`; fees stay mixed in pool until claim |
| Fee accumulator | Per-share `lp_fee_per_share_a/b: u128` × position `fee_debt_a/b: u128` | MasterChef-style; enables idempotent fee claim without principal touch |
| Flash receipts | Distinct `FlashReceiptA<A, B>` and `FlashReceiptB<A, B>`, no abilities (hot-potato) | Type system enforces "repay with borrowed side"; same-TX repay enforced by Move drop-rules |
| Reentrancy lock | DROPPED | Sui Coin<T> has no framework callback → reentrancy structurally impossible. Flash safety via hot-potato + strict repay equality + k-invariant `k_after >= k_before` |
| Factory key | Sorted `PairKey { type_a, type_b }` via `type_name::with_defining_ids().into_string()` lex compare | Strict `<` rejects same-type pairs |
| Sealing | `destroy_cap` consumes OriginCap + UpgradeCap → `package::make_immutable` + `factory.sealed = true` | Zero admin authority remains anywhere on-chain post-seal |
| Deploy strategy | Hot wallet, no multisig, atomic Tx 1 publish + Tx 2 PTB seal | Multisig moot post-seal (no caps to compromise); Tx 1→Tx 2 window mitigated by single deploy script |
| Fees | 5 bps swap + 5 bps flash, 100% LP, no treasury, no admin | Market-positioned: half of Scallop (10 bps), match Bucket (5 bps), survive Navi promo expiry to 20 |

---

## 3. Top scrutiny questions for external auditor

Ranked by importance — please prioritize 1-4.

### Q1 (HIGHEST PRIORITY) — Flash safety without reentrancy lock
We dropped the `locked: bool` flag (Aptos parent has it). Justification:
- Sui Coin<T> has no framework callback (verified independently — Trail of Bits 2025-09-10 blog confirms).
- Hot-potato `FlashReceipt*` (no abilities) forces same-TX repay.
- Strict `coin::value(&coin) == amount + fee` at repay prevents under/overpay.
- `k_after >= k_before` at repay catches any pool manipulation in the borrow window — fees only INCREASE k, swaps preserve k modulo fees.

**Adversary scenarios to attempt:**
- Borrow → directional swap on same pool → repay → did anything net-drain?
- Borrow A → add_liquidity using the borrowed A → flash_repay → remove_liquidity → did the new LP harvest any unfair share?
- Borrow A → swap A→B → swap B→A → repay → cumulative slippage went where?
- Two parallel flash borrows from different pools in same TX (different `Pool<X,Y>` and `Pool<Y,Z>`) — cross-pool interleaving exploits?
- Inside the same TX, can the borrower trigger another module's PTB step that touches the pool in an unexpected way before repay?

### Q2 — u256 promote sufficiency on math hot paths
Math paths and their max input bounds:
- `compute_amount_out`: numerator can reach `(u64_max)³ ≈ 6.3e57`, fits u256 (`≈ 1.16e77`).
- `accrue_fee`: `fee × SCALE ≤ u64_max × 1e12 ≈ 1.84e31`, fits u128.
- `pending_from_accumulator`: `(per_share_delta as u256) × shares ≤ u128_max × u64_max`, fits u256.
- `sqrt(amount_a × amount_b)` in create_pool: u64 × u64 → u128, fits with margin (`u128_max - u64_max² = 2^65 - 2`).
- `(reserve_a as u256) × (reserve_b as u256)` for k snapshot: u64 × u64 → u256, trivially fits.

Please verify each independently; flag if any cast `as u64` at the END can overflow when the conceptual value exceeds u64.

### Q3 — Lex byte ordering on Move type names
`bytes_lt` does lexicographic compare on raw byte vectors. Move type names are ASCII, so byte-order = char-order. Edge cases to verify:
- `0x1::a::A` vs `0x1::a::AA` (shorter is less when prefix matches — verified in implementation)
- `0x100::x::T` vs `0xff::x::T` (numeric address segments aren't padded — does ordering still match user expectation?)
- Same-type pair `<T, T>`: bytes equal → bytes_lt returns false → strict < check fires E_WRONG_ORDER ✓
- Cross-package types from different addresses

### Q4 — Sealing semantics post-`destroy_cap`
Confirm post-seal:
- No way to mint OriginCap (no public ctor in pool_factory; `mint_origin_cap_for_testing` is `#[test_only]`)
- UpgradeCap consumed → `package::make_immutable` precludes `package::authorize_upgrade`
- `factory.sealed` flag is informational; cap-loss already prevents privileged ops
- **Hot-wallet deploy:** the only attack window is Tx 1 → Tx 2 (seconds, atomic deploy script). Confirm this is acceptable risk given full atomic compromise of deploy keypair during this window is the only realistic vector.

### Q5 — LP fee accumulator precision
Per-share = `fee × 1e12 / lp_supply`. Pending = `(delta × shares) / 1e12`.
- Worst-case truncation? For lp_supply ≈ 1000 (just above MIN), tiny fees could lose precision.
- Adversary: spam tiny swaps to fragment the accumulator? Each swap accrues `add = fee × 1e12 / lp_supply`, which is u128. No truncation in accumulator update itself; truncation happens in `pending_from_accumulator` via `/ SCALE`.
- Suggest fuzz cases for fee accrual under various lp_supply / fee combinations.

### Q6 — Add_liquidity optimal-pair edge cases
- `amount_b_optimal == 0` (e.g., user supplies 1 raw unit of A against pool with reserve_a >> reserve_b) → falls through to E_ZERO_AMOUNT on shares check?
- u64 cast guard on ratios > 2^64:1 — when reserves are very imbalanced, could the `(b_opt_u256 as u64)` cast lose data without firing the assert?
- `min(lp_a, lp_b)` rounding: can the user be cheated by 1 raw unit in pathological cases?

### Q7 — `remove_liquidity` dead-share floor
The `assert pool.lp_supply >= MINIMUM_LIQUIDITY` post-burn is unreachable through normal API (E_INSUFFICIENT_LP fires first if shares > available). Defense-in-depth. Can you find ANY path through the public API that triggers this assert? If so, that's a finding; if not, please confirm the defense is non-load-bearing (just an invariant assertion).

### Q8 — Composability surface
The public surface (functions external Move modules can call):
- `pool::swap_a_to_b` / `swap_b_to_a` — composable swap
- `pool::flash_borrow_a` / `_b` + `flash_repay_a` / `_b` — composable flash
- `pool::add_liquidity` / `remove_liquidity` / `claim_lp_fees` — LP ops returning Coin/Position values
- `pool::compute_amount_out` / `compute_flash_fee` / `sqrt` — pure math helpers
- `pool::reserves` / `lp_supply` / `position_shares` / `position_pool_id` — views
- `pool_factory::create_canonical_pool` / `assert_sorted` / `canonical_pool_id` / `pool_count` / `is_sealed` — factory + views

Please confirm the surface is consistent (no unintentional capabilities exposed) and complete (no missing primitives that future Darbitex satellites — LP-locker, LP-staking, oracle adapter — would need).

### Q9 — Suggest fuzz cases
For any of the above, please suggest specific fuzz inputs (concrete numeric values) we should add to the unit test suite before mainnet deploy.

---

## 4. Out of scope — please do NOT spend time on these

- **Suggesting a `Coin<LP_TYPE>` model.** We deliberately chose Position NFT for cross-chain consistency with Aptos Darbitex satellite ecosystem (lp-locker, lp-staking that operate per-NFT). Trade-off vs Coin LP is documented and accepted. Don't recommend changing.
- **Suggesting an arb satellite / treasury / fee recipient.** Deliberately omitted — pure utility deployment, 100% LP, no protocol rake.
- **Suggesting an admin path / pause / fee-tier knob.** Sealed-package + zero-admin is the thesis. Don't suggest any privileged operation.
- **Suggesting V3 CLMM features** (concentrated liquidity, ticks). Pure V2 by design choice — security floor + always-in-range LP.
- **Comparing to Cetus/Turbos CLMM.** Wrong reference class.
- **Multisig deploy.** We use hot wallet → atomic seal. Multisig itself = admin surface, contradicts thesis. Documented.
- **Coin metadata / Display module.** LP is NFT, not Coin — no `coin_registry` interaction needed. Display can be added post-seal as a satellite if wallet-rendering becomes a concern.

---

## 5. Source files (in repo)

- `sources/pool.move` (500 LOC)
- `sources/pool_factory.move` (181 LOC)
- `tests/pool_tests.move` (507 LOC)

For auditors needing a single-doc submission (e.g., one-shot LLM web UIs), generate with:
```bash
{
  echo "## pool.move"; echo '```move'; cat sources/pool.move; echo '```'
  echo "## pool_factory.move"; echo '```move'; cat sources/pool_factory.move; echo '```'
} > /tmp/darbitex-source.md
```

Test coverage table:

Test coverage table:
| Category | Tests |
|---|---|
| Pure math | sqrt, compute_amount_out, compute_flash_fee |
| Pair sorting | correct, wrong order (abort), same type (abort) |
| Pool creation | basic, duplicate (abort), too-small (abort) |
| Swap | round-trip A↔B, slippage (abort) |
| Liquidity | add unbalanced (verify leftover), remove (verify reserves+supply) |
| LP fees | accrual + claim + idempotent re-claim |
| Flash | round-trip A, round-trip B, repay underpay (abort), borrow too much (abort) |
| Sealing | destroy_cap seals, double destroy aborts |

20/20 PASS.

---

## 6. Repo references

- `audit/SELF_AUDIT_R1.md` — pre-compaction internal audit (full per-function review, invariant table, INFO findings)
- `audit/SELF_AUDIT_R2.md` — post-compaction re-verification (diff-vs-R1, semantic preservation check)
- `Move.toml` — pkg `Darbitex` v0.1.0, Sui rev `6d4ec0b…` (matches CLI 1.70.2)
- `tests/pool_tests.move` — 20 unit tests, all passing

---

## 7. Submission format expectation

Please return a structured response:

```
# Darbitex Sui Audit Response

## Findings
- HIGH: [count + per-finding: function/line, description, recommended fix]
- MEDIUM: [...]
- LOW: [...]
- INFO: [...]

## Per-question answers (Q1-Q9)
[Direct answer + reasoning + adversary scenarios attempted]

## Suggested fuzz cases
[Concrete numeric inputs for additional tests]

## Verdict
[GREEN / YELLOW / RED + 1-paragraph rationale]
```

Thank you.

# Darbitex Sui

**Status:** LIVE + SEALED on Sui mainnet (2026-04-26).

A V2 constant-product AMM for Sui. Sealed-package, zero admin, 100% LP fees,
hot-potato flash loans. Pure utility deployment — no treasury, no governance,
no upgrade path. Bugs are unrecoverable; audit before interacting.

## Mainnet

| | |
|---|---|
| `PACKAGE_ID` | `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` |
| `FACTORY_ID` | `0x5f3e1d526eda4c34d47ec2227abe82d81d10ddf0cf714a3df071da3044e05567` |
| `sealed` | `true` (package permanently immutable) |

After `destroy_cap` (Tx 2 of deploy), the `OriginCap` is destroyed and the
`UpgradeCap` is consumed by `package::make_immutable`. Zero on-chain authority
remains — no admin, no pause, no upgrade, no fee adjustment. The full 11-item
on-chain disclosure is available via `pool::read_warning()`.

## Architecture

| Item | Value |
|------|-------|
| Curve | x*y=k constant product (V2) |
| Pool storage | Per-pool shared object `Pool<phantom A, phantom B> has key` |
| LP container | Transferable NFT `LpPosition<phantom A, phantom B> has key, store` |
| Reserve model | `Balance<X>` + `u64` reserve; invariant `balance == reserve + cumulative_unclaimed_fees` |
| Fee accumulator | Per-share `u128` × per-position debt snapshot (MasterChef pattern) |
| Flash loans | Distinct typed hot-potato receipts `FlashReceiptA/B<A, B>`, no abilities |
| Reentrancy | Structurally impossible — Sui `Coin<T>` has no callback |
| Factory | Singleton, `Table<PairKey, ID>` keyed on sorted TypeName lex bytes |
| Sealing | `destroy_cap` → `package::make_immutable` + OriginCap deletion |
| Deploy | Hot wallet, atomic Tx 1 publish + Tx 2 destroy_cap (no multisig) |
| Fees | 5 bps swap + 5 bps flash, 100% LP |
| Treasury / arb | NONE (pure utility deployment) |
| Admin / pause | NONE post-seal |
| Oracle | NONE (pool reserves are price source) |

`pool.move` is 529 LOC, `pool_factory.move` is 190 LOC. Two modules, one
package.

## Public surface

**Pool primitives:**
- `pool::swap_a_to_b<A, B>(&mut Pool<A,B>, Coin<A>, min_out, &Clock, ctx) -> Coin<B>`
- `pool::swap_b_to_a<A, B>(&mut Pool<A,B>, Coin<B>, min_out, &Clock, ctx) -> Coin<A>`
- `pool::add_liquidity<A, B>(&mut Pool, Coin<A>, Coin<B>, min_shares, &Clock, ctx) -> (LpPosition, Coin<A>, Coin<B>)`
- `pool::remove_liquidity<A, B>(&mut Pool, LpPosition, min_a, min_b, &Clock, ctx) -> (Coin<A>, Coin<B>)`
- `pool::claim_lp_fees<A, B>(&mut Pool, &mut LpPosition, &Clock, ctx) -> (Coin<A>, Coin<B>)`
- `pool::flash_borrow_a<A, B>(&mut Pool, amount, &Clock, ctx) -> (Coin<A>, FlashReceiptA<A,B>)`
- `pool::flash_borrow_b<A, B>(&mut Pool, amount, &Clock, ctx) -> (Coin<B>, FlashReceiptB<A,B>)`
- `pool::flash_repay_a<A, B>(&mut Pool, Coin<A>, FlashReceiptA<A,B>, &Clock)`
- `pool::flash_repay_b<A, B>(&mut Pool, Coin<B>, FlashReceiptB<A,B>, &Clock)`

**Entry wrappers** (deadline-guarded; `swap_*` and `flash_*` deliberately have
no entry wrapper — they are PTB-composable primitives):
- `pool::add_liquidity_entry`, `remove_liquidity_entry`, `claim_lp_fees_entry`
- `pool_factory::create_canonical_pool_entry`

**Views (composability surface):**
- `pool::reserves<A,B>(&Pool) -> (u64, u64)`
- `pool::lp_supply<A,B>(&Pool) -> u64`
- `pool::position_shares<A,B>(&LpPosition) -> u64`
- `pool::position_pool_id<A,B>(&LpPosition) -> ID`
- `pool::fee_per_share<A,B>(&Pool) -> (u128, u128)`
- `pool::position_fee_debt<A,B>(&LpPosition) -> (u128, u128)`
- `pool::pending_fees<A,B>(&Pool, &LpPosition) -> (u64, u64)`
- `pool::read_warning() -> vector<u8>`
- `pool_factory::canonical_pool_id<A,B>(&FactoryRegistry) -> Option<ID>`
- `pool_factory::pool_count(&FactoryRegistry) -> u64`
- `pool_factory::is_sealed(&FactoryRegistry) -> bool`

## Audit posture

8 external audit passes across 6 LLM auditors, **0 HIGH / 0 MEDIUM / 0 LOW**:

| Auditor | Round | Verdict |
|---------|-------|---------|
| Gemini 3.1 Pro | R1 | GREEN |
| Grok | R1 | GREEN |
| Gemini 3.1 Pro | R2 | GREEN |
| Claude Opus 4.7 | R2 | GREEN |
| Grok | R2 | GREEN |
| Qwen | R2 | GREEN |
| DeepSeek | R2 | GREEN |
| Kimi K2.6 | R2 | GREEN |

INFO findings (all "leave as-is" by their respective auditors):

- F1: `pending_fees` lacks `pool_id` consistency assert (unreachable post-seal due to factory invariant + private struct fields).
- F2 / I-6: `balance_a/b` views absent (RPC-readable; design trade-off).
- F3: `total_pending_fees` aggregate view absent (indexable from events).
- F4: 7 fuzz-test suggestions not implemented (deterministic 21/21 unit tests cover every code path).
- I-7: phantom-type derivation note for SDK integrators (documentation, not code).
- Kimi-I1: flash-repay `amount + fee` u64 add overflows at >99.95% of `u64::MAX` — non-exploitable DoS at unreachable amounts.

Detailed reports: `audit/EXTERNAL_R1_GEMINI.md`, `audit/EXTERNAL_R1_GROK.md`,
`audit/EXTERNAL_R2_*.md`. Self-audits: `audit/SELF_AUDIT_R1.md`,
`SELF_AUDIT_R2.md`, `SELF_AUDIT_R3.md`. Tracking: `audit/AUDIT_TRACKING.md`.
Full audit bundles (R1, R2) submitted to external auditors:
`audit/AUDIT-R1-BUNDLE.md`, `audit/AUDIT-R2-BUNDLE.md`.

**No professional human security audit firm has reviewed this code.** All
audits are AI-based. See `pool::read_warning()` item (10) for the on-chain
disclosure of this fact.

## WARNING

`pool::read_warning()` returns an 11-item disclosure detailing every known
limitation of the protocol — including immutable-after-seal, AI-only audit,
ownerless-protocol, user-bears-all-loss terms, and unknown-future-limitation
acknowledgment. Read it before interacting.

## Repository layout

```
.
├── sources/
│   ├── pool.move          (529 LOC)
│   └── pool_factory.move  (190 LOC)
├── tests/
│   └── pool_tests.move    (515 LOC, 21/21 PASS)
├── audit/                 (R1 + R2 bundles, R1-R3 self-audits, 7 external reports, tracking doc)
├── deploy/
│   ├── testnet.sh         (Tx 1 publish + Tx 2 destroy_cap rehearsal)
│   ├── mainnet.sh         (same flow, hard-locked to mainnet env)
│   ├── smoke.sh           (8-phase functional smoke: create_pool / swap / add / remove / claim / flash a+b)
│   └── out/               (deployment artifacts: publish.json, seal.json, deployment.txt)
├── Move.toml
├── Move.lock              (gitignored — regenerated on build)
├── Published.toml         (Sui-managed; pinned mainnet PACKAGE_ID)
├── LICENSE                (Unlicense — public domain)
└── README.md
```

## Build + test

```
sui move build           # 0 errors, 4 intentional W99001 self-transfer lints on entry wrappers
sui move test            # 21/21 PASS
```

Sui CLI version: 1.70.2 (framework rev `6d4ec0b…`, pinned in `Move.toml`).

## Deploy reproduction

The same scripts deploy to testnet (`bash deploy/testnet.sh`) or mainnet
(`bash deploy/mainnet.sh`). Both publish + seal in a single bundled run.

## Source verification

Anyone can independently verify that the on-chain bytecode at
`0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68`
matches this repository.

Requires `sui` CLI 1.70.2 (the toolchain used at publish time).

```
git clone https://github.com/darbitex/darbitex-sui.git
cd darbitex-sui
git checkout 3c632ab3158e7fe54636902fe5efa064bbf0c62c
```

Edit `Move.toml` to add `published-at` and set the concrete address:

```toml
[package]
name = "Darbitex"
version = "0.1.0"
edition = "2024.beta"
published-at = "0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68"

[addresses]
darbitex = "0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68"
```

Then run:

```
sui client verify-source --silence-warnings
```

Expected output: `Source verification succeeded!`

This compares freshly-compiled bytecode against the on-chain modules and proves
the published package was built from this source at the pinned dep revisions.

## License

This is free and unencumbered software released into the public domain — see
[LICENSE](LICENSE) ([Unlicense](https://unlicense.org)).

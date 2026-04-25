/// Darbitex pool — x*y=k AMM, 5 bps swap + 5 bps flash, 100% LP.
///
/// Canonical pool per pair (factory-enforced). LP = transferable Sui
/// object with per-share fee accumulator + per-position debt snapshot —
/// enables claim-without-burn (fee withdraw without touching principal).
/// Flash via typed hot-potato receipts (FlashReceiptA/B).
///
/// Reentrancy lock omitted: Sui Coin<T> has no callback. Flash safety =
/// hot-potato + strict repay equality + k-invariant (k_after >= k_before).
///
/// Reserve / balance invariant: `balance_X = reserve_X + cumulative
/// unclaimed fees`. Fees stay mixed in pool; claimed via per-share
/// accumulator. Math is decimal-blind (raw u64 amounts).
///
/// WARNING: Darbitex is an immutable AMM on Sui. After destroy_cap is
/// called the package is permanently immutable — no admin, no pause, no
/// upgrade, no fee adjustment. Bugs are unrecoverable. Audit this code
/// yourself before interacting. The full disclosure (10 known limitations
/// — including AI-only audit + ownerless-protocol + user-bears-all-loss
/// terms) is exposed on-chain via `read_warning()` and printed in the
/// WARNING constant below.
module darbitex::pool {
    use std::ascii::String;
    use std::type_name;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;

    // ===== Constants =====

    const SWAP_FEE_BPS: u64 = 5;
    const FLASH_FEE_BPS: u64 = 5;
    const BPS_DENOM: u64 = 10_000;
    const MINIMUM_LIQUIDITY: u64 = 1_000;
    const SCALE: u128 = 1_000_000_000_000;
    const U64_MAX: u64 = 18_446_744_073_709_551_615;

    // ===== Errors =====

    const E_ZERO_AMOUNT: u64 = 1;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 2;
    const E_SLIPPAGE: u64 = 3;
    const E_DISPROPORTIONAL: u64 = 5;
    const E_WRONG_POOL: u64 = 6;
    const E_INSUFFICIENT_LP: u64 = 7;
    const E_K_VIOLATED: u64 = 9;
    const E_DEADLINE: u64 = 14;
    const E_REPAY_AMOUNT: u64 = 15;

    // ===== On-chain disclosure =====

    const WARNING: vector<u8> = b"DARBITEX is an immutable xyk AMM on Sui. After destroy_cap is called the package is permanently immutable - no admin authority, no pause, no upgrade, no fee adjustment. Bugs are unrecoverable. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) PRICE SOURCE - Pool reserves are the only price input. There is no oracle. Spot price is manipulable by sufficiently large swaps relative to depth. Standard xyk AMM property. (2) CAPITAL INEFFICIENCY - V2 full-range liquidity. Lower capital efficiency than V3 CLMM by design. The trade-off is V2 mathematical security plus always-in-range LP (positions never go out of range and never stop earning). (3) LP-AS-NFT - LP positions are Sui objects (LpPosition<A,B>) not Coin<T>. Cannot be used as collateral on Scallop or Suilend. Cannot be routed by Cetus or Aftermath aggregators. Trade-off accepted for per-position fee accounting and claim-without-burn capability. Wallet support varies. (4) FLASH LOAN SAFETY - flash_borrow_a/b returns Coin plus hot-potato receipt that MUST be consumed by flash_repay_a/b in the same TX. Strict repay equality (amount + fee) prevents under or overpay. The k_after >= k_before invariant verified at repay catches any pool manipulation in the borrow window. Reentrancy via Coin<T> is impossible in Sui by framework design. (5) MINIMUM LIQUIDITY - first 1000 LP shares locked at pool creation as anti-cornering protection on the first depositor. Permanently inaccessible. (6) NO TREASURY - 100 percent of swap fee plus flash fee accrue to LP via per-share accumulator. There is no protocol cut, no treasury recipient, no admin fee. (7) CANONICAL PAIR - one pool per (TypeA, TypeB) pair via the factory. The first creator picks the initial reserve ratio. Subsequent depositors take that ratio as truth. Initial creator has price discovery asymmetry until liquidity grows. (8) NO RESCUE - no admin emergency, no pause, no fund recovery. Loss of access to an LpPosition NFT or transfer to a wrong address has no recourse. (9) SEAL-AT-DEPLOY - the deploy keypair holds OriginCap plus UpgradeCap for seconds between Tx 1 (publish) and Tx 2 (destroy_cap). After Tx 2 these are destroyed and the deploy keypair has zero further authority over the package or any pool. (10) AUTHORSHIP AND AUDIT DISCLOSURE - Darbitex was built by a solo developer working with Claude (Anthropic AI). All audits performed are AI-based: multi-round Claude self-audit (R1 and R2) plus external AI review by Gemini, Cerebras Qwen3, and Grok. NO professional human security audit firm has reviewed this code. Once destroy_cap is called the protocol is ownerless and permissionless - no team, no foundation, no legal entity, no responsible party, no support channel. All losses from bugs, exploits, oracle issues, market manipulation, user error, malicious counterparties, or any other cause whatsoever are borne entirely by users. By interacting with Darbitex (depositing liquidity, swapping, taking flash loans, transferring positions, or any other operation) you confirm that you have read and understood all 10 numbered limitations in this disclosure and accept full responsibility for any and all losses.";

    // ===== Structs =====

    /// `key`-only (no `store`): shared at create, never wrapped/transferred.
    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        lp_fee_per_share_a: u128,
        lp_fee_per_share_b: u128,
    }

    /// `key, store`: kiosk/escrow-able. Each add_liquidity mints fresh
    /// (no merging — debt snapshot would be ambiguous).
    public struct LpPosition<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
    }

    /// Hot-potato receipts — no abilities, must be consumed in same TX.
    /// Distinct A/B types prevent repay-with-wrong-side at compile time.
    public struct FlashReceiptA<phantom A, phantom B> {
        pool_id: ID, amount: u64, fee: u64, k_before: u256,
    }
    public struct FlashReceiptB<phantom A, phantom B> {
        pool_id: ID, amount: u64, fee: u64, k_before: u256,
    }

    // ===== Events =====

    public struct PoolCreated has copy, drop {
        pool_id: ID, type_a: String, type_b: String, creator: address,
        amount_a: u64, amount_b: u64, initial_lp: u64, timestamp_ms: u64,
    }
    public struct Swapped has copy, drop {
        pool_id: ID, swapper: address, amount_in: u64, amount_out: u64,
        a_to_b: bool, lp_fee: u64, timestamp_ms: u64,
    }
    public struct LiquidityAdded has copy, drop {
        pool_id: ID, provider: address, position_id: ID,
        amount_a: u64, amount_b: u64, shares_minted: u64, timestamp_ms: u64,
    }
    public struct LiquidityRemoved has copy, drop {
        pool_id: ID, provider: address, position_id: ID,
        amount_a: u64, amount_b: u64, fees_a: u64, fees_b: u64,
        shares_burned: u64, timestamp_ms: u64,
    }
    public struct LpFeesClaimed has copy, drop {
        pool_id: ID, position_id: ID, claimer: address,
        fees_a: u64, fees_b: u64, timestamp_ms: u64,
    }
    public struct FlashBorrowed has copy, drop {
        pool_id: ID, borrowed_is_a: bool, amount: u64, fee: u64, timestamp_ms: u64,
    }
    public struct FlashRepaid has copy, drop {
        pool_id: ID, borrowed_is_a: bool, amount: u64, fee: u64, timestamp_ms: u64,
    }

    // ===== Pure helpers =====

    /// Babylonian integer sqrt.
    public fun sqrt(x: u128): u128 {
        if (x == 0) return 0;
        let mut z = (x + 1) / 2;
        let mut y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; };
        y
    }

    /// x*y=k swap math with SWAP_FEE_BPS wedge. u256 intermediates absorb
    /// adversarial reserves near u64::MAX.
    public fun compute_amount_out(reserve_in: u64, reserve_out: u64, amount_in: u64): u64 {
        let in_after_fee = (amount_in as u256) * ((BPS_DENOM - SWAP_FEE_BPS) as u256);
        let num = in_after_fee * (reserve_out as u256);
        let den = (reserve_in as u256) * (BPS_DENOM as u256) + in_after_fee;
        ((num / den) as u64)
    }

    /// Flash fee floor-up to 1 raw unit so dust borrows still pay.
    public fun compute_flash_fee(amount: u64): u64 {
        let raw = (((amount as u256) * (FLASH_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        if (raw == 0) { 1 } else { raw }
    }

    // ===== Internal helpers =====

    fun accrue_fee<A, B>(pool: &mut Pool<A, B>, fee: u64, a_side: bool): u64 {
        if (fee > 0 && pool.lp_supply > 0) {
            let add = (fee as u128) * SCALE / (pool.lp_supply as u128);
            if (a_side) pool.lp_fee_per_share_a = pool.lp_fee_per_share_a + add
            else pool.lp_fee_per_share_b = pool.lp_fee_per_share_b + add;
        };
        fee
    }

    fun pending_from_accumulator(per_share_current: u128, per_share_debt: u128, shares: u64): u64 {
        if (per_share_current <= per_share_debt) return 0;
        let delta = per_share_current - per_share_debt;
        (((delta as u256) * (shares as u256) / (SCALE as u256)) as u64)
    }

    /// Transfer if non-zero, else destroy in place (avoids dust-coin spam).
    fun maybe_transfer<T>(coin: Coin<T>, recipient: address) {
        if (coin::value(&coin) > 0) transfer::public_transfer(coin, recipient)
        else coin::destroy_zero(coin);
    }

    // ===== Pool creation (package-only) =====

    /// MINIMUM_LIQUIDITY shares locked at creation (counted in lp_supply,
    /// never minted as a position) — anti-cornering on first depositor.
    /// remove_liquidity floor preserves the lockup forever.
    public(package) fun create_pool<A, B>(
        coin_a: Coin<A>, coin_b: Coin<B>, clock: &Clock, ctx: &mut TxContext,
    ): (ID, LpPosition<A, B>) {
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        let initial_lp_u128 = sqrt((amount_a as u128) * (amount_b as u128));
        assert!(initial_lp_u128 > (MINIMUM_LIQUIDITY as u128), E_INSUFFICIENT_LIQUIDITY);
        let initial_lp = (initial_lp_u128 as u64);
        let creator_shares = initial_lp - MINIMUM_LIQUIDITY;

        let pool = Pool<A, B> {
            id: object::new(ctx),
            balance_a: coin::into_balance(coin_a),
            balance_b: coin::into_balance(coin_b),
            reserve_a: amount_a,
            reserve_b: amount_b,
            lp_supply: initial_lp,
            lp_fee_per_share_a: 0,
            lp_fee_per_share_b: 0,
        };
        let pool_id = object::id(&pool);
        let creator = tx_context::sender(ctx);
        let position = LpPosition<A, B> {
            id: object::new(ctx),
            pool_id, shares: creator_shares, fee_debt_a: 0, fee_debt_b: 0,
        };
        let now = clock::timestamp_ms(clock);

        event::emit(PoolCreated {
            pool_id,
            type_a: type_name::with_defining_ids<A>().into_string(),
            type_b: type_name::with_defining_ids<B>().into_string(),
            creator, amount_a, amount_b, initial_lp, timestamp_ms: now,
        });
        event::emit(LiquidityAdded {
            pool_id, provider: creator, position_id: object::id(&position),
            amount_a, amount_b, shares_minted: creator_shares, timestamp_ms: now,
        });

        transfer::share_object(pool);
        (pool_id, position)
    }

    // ===== Swap =====

    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>, coin_in: Coin<A>, min_out: u64,
        clock: &Clock, ctx: &mut TxContext,
    ): Coin<B> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        let amount_out = compute_amount_out(pool.reserve_a, pool.reserve_b, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);

        // u256 promote — Sui SUI 9-dec closer to u64 overflow than Aptos APT 8-dec.
        let fee = (((amount_in as u256) * (SWAP_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        let lp_fee = accrue_fee(pool, fee, true);

        pool.reserve_a = pool.reserve_a + amount_in - lp_fee;
        pool.reserve_b = pool.reserve_b - amount_out;
        balance::join(&mut pool.balance_a, coin::into_balance(coin_in));
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount_out), ctx);

        event::emit(Swapped {
            pool_id: object::id(pool), swapper: tx_context::sender(ctx),
            amount_in, amount_out, a_to_b: true, lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        coin_out
    }

    public fun swap_b_to_a<A, B>(
        pool: &mut Pool<A, B>, coin_in: Coin<B>, min_out: u64,
        clock: &Clock, ctx: &mut TxContext,
    ): Coin<A> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        let amount_out = compute_amount_out(pool.reserve_b, pool.reserve_a, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < pool.reserve_a, E_INSUFFICIENT_LIQUIDITY);

        let fee = (((amount_in as u256) * (SWAP_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        let lp_fee = accrue_fee(pool, fee, false);

        pool.reserve_b = pool.reserve_b + amount_in - lp_fee;
        pool.reserve_a = pool.reserve_a - amount_out;
        balance::join(&mut pool.balance_b, coin::into_balance(coin_in));
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_a, amount_out), ctx);

        event::emit(Swapped {
            pool_id: object::id(pool), swapper: tx_context::sender(ctx),
            amount_in, amount_out, a_to_b: false, lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        coin_out
    }

    // ===== Liquidity =====

    /// Caller passes max amounts; function picks optimal pair against
    /// current reserves, returns unused leftover for caller to handle.
    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>, mut coin_a: Coin<A>, mut coin_b: Coin<B>,
        min_shares_out: u64, clock: &Clock, ctx: &mut TxContext,
    ): (LpPosition<A, B>, Coin<A>, Coin<B>) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        assert!(amount_a_desired > 0 && amount_b_desired > 0, E_ZERO_AMOUNT);

        // Ratios > 2^64:1 overflow u64 cast — explicit assert for clean error code.
        let b_opt_u256 = (amount_a_desired as u256) * (pool.reserve_b as u256) / (pool.reserve_a as u256);
        assert!(b_opt_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
        let amount_b_optimal = (b_opt_u256 as u64);
        let (amount_a, amount_b) = if (amount_b_optimal <= amount_b_desired) {
            (amount_a_desired, amount_b_optimal)
        } else {
            let a_opt_u256 = (amount_b_desired as u256) * (pool.reserve_a as u256) / (pool.reserve_b as u256);
            assert!(a_opt_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
            let amount_a_optimal = (a_opt_u256 as u64);
            assert!(amount_a_optimal <= amount_a_desired, E_DISPROPORTIONAL);
            (amount_a_optimal, amount_b_desired)
        };
        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        // min(lp_a, lp_b) guards against integer rounding asymmetry.
        let lp_a = ((amount_a as u256) * (pool.lp_supply as u256) / (pool.reserve_a as u256)) as u64;
        let lp_b = ((amount_b as u256) * (pool.lp_supply as u256) / (pool.reserve_b as u256)) as u64;
        let shares = if (lp_a < lp_b) lp_a else lp_b;
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(shares >= min_shares_out, E_SLIPPAGE);

        balance::join(&mut pool.balance_a, coin::into_balance(coin::split(&mut coin_a, amount_a, ctx)));
        balance::join(&mut pool.balance_b, coin::into_balance(coin::split(&mut coin_b, amount_b, ctx)));
        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.lp_supply = pool.lp_supply + shares;

        // Debt = current accumulator → new LP doesn't claim past fees.
        let pool_id = object::id(pool);
        let position = LpPosition<A, B> {
            id: object::new(ctx),
            pool_id, shares,
            fee_debt_a: pool.lp_fee_per_share_a,
            fee_debt_b: pool.lp_fee_per_share_b,
        };

        event::emit(LiquidityAdded {
            pool_id, provider: tx_context::sender(ctx),
            position_id: object::id(&position),
            amount_a, amount_b, shares_minted: shares,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (position, coin_a, coin_b)
    }

    /// Burn position; return proportional reserves PLUS accrued fees.
    /// Slippage floors apply to reserve payout only (not fee claims).
    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>, position: LpPosition<A, B>,
        min_amount_a: u64, min_amount_b: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let LpPosition { id, pool_id, shares, fee_debt_a, fee_debt_b } = position;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(pool.lp_supply >= shares, E_INSUFFICIENT_LP);

        let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, fee_debt_a, shares);
        let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, fee_debt_b, shares);
        let amount_a = ((shares as u256) * (pool.reserve_a as u256) / (pool.lp_supply as u256)) as u64;
        let amount_b = ((shares as u256) * (pool.reserve_b as u256) / (pool.lp_supply as u256)) as u64;
        assert!(amount_a >= min_amount_a, E_SLIPPAGE);
        assert!(amount_b >= min_amount_b, E_SLIPPAGE);

        pool.lp_supply = pool.lp_supply - shares;
        // Dead-share floor — preserves the anti-cornering invariant forever.
        assert!(pool.lp_supply >= MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.reserve_b = pool.reserve_b - amount_b;

        let coin_a = coin::from_balance(balance::split(&mut pool.balance_a, amount_a + claim_a), ctx);
        let coin_b = coin::from_balance(balance::split(&mut pool.balance_b, amount_b + claim_b), ctx);
        let position_id = object::uid_to_inner(&id);

        event::emit(LiquidityRemoved {
            pool_id, provider: tx_context::sender(ctx), position_id,
            amount_a, amount_b, fees_a: claim_a, fees_b: claim_b,
            shares_burned: shares, timestamp_ms: clock::timestamp_ms(clock),
        });
        object::delete(id);
        (coin_a, coin_b)
    }

    /// Harvest fees without burning the position. Idempotent (debt = current
    /// accumulator post-claim → second call returns zero coins).
    public fun claim_lp_fees<A, B>(
        pool: &mut Pool<A, B>, position: &mut LpPosition<A, B>,
        clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(object::id(pool) == position.pool_id, E_WRONG_POOL);
        let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, position.fee_debt_a, position.shares);
        let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, position.fee_debt_b, position.shares);
        position.fee_debt_a = pool.lp_fee_per_share_a;
        position.fee_debt_b = pool.lp_fee_per_share_b;

        let coin_a = if (claim_a > 0) coin::from_balance(balance::split(&mut pool.balance_a, claim_a), ctx)
                     else coin::zero<A>(ctx);
        let coin_b = if (claim_b > 0) coin::from_balance(balance::split(&mut pool.balance_b, claim_b), ctx)
                     else coin::zero<B>(ctx);

        event::emit(LpFeesClaimed {
            pool_id: position.pool_id, position_id: object::id(position),
            claimer: tx_context::sender(ctx), fees_a: claim_a, fees_b: claim_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_a, coin_b)
    }

    // ===== Flash =====
    //
    // Flash accounting: borrow does NOT decrement reserve_X — k_before
    // snapshot at borrow time is verified against post-repay reserves. Any
    // swap interleaved in the borrow window moves reserves but pays fees
    // that increase k → cannot violate k_after >= k_before. Repay only
    // credits the fee to LP accumulator; principal returns to balance_X.

    public fun flash_borrow_a<A, B>(
        pool: &mut Pool<A, B>, amount: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<A>, FlashReceiptA<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_a, E_INSUFFICIENT_LIQUIDITY);
        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_a, amount), ctx);
        event::emit(FlashBorrowed {
            pool_id, borrowed_is_a: true, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_out, FlashReceiptA<A, B> { pool_id, amount, fee, k_before })
    }

    public fun flash_borrow_b<A, B>(
        pool: &mut Pool<A, B>, amount: u64, clock: &Clock, ctx: &mut TxContext,
    ): (Coin<B>, FlashReceiptB<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);
        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount), ctx);
        event::emit(FlashBorrowed {
            pool_id, borrowed_is_a: false, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
        (coin_out, FlashReceiptB<A, B> { pool_id, amount, fee, k_before })
    }

    public fun flash_repay_a<A, B>(
        pool: &mut Pool<A, B>, coin: Coin<A>, receipt: FlashReceiptA<A, B>, clock: &Clock,
    ) {
        let FlashReceiptA { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(coin::value(&coin) == amount + fee, E_REPAY_AMOUNT);
        balance::join(&mut pool.balance_a, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, true);
        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);
        event::emit(FlashRepaid {
            pool_id, borrowed_is_a: true, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    public fun flash_repay_b<A, B>(
        pool: &mut Pool<A, B>, coin: Coin<B>, receipt: FlashReceiptB<A, B>, clock: &Clock,
    ) {
        let FlashReceiptB { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(coin::value(&coin) == amount + fee, E_REPAY_AMOUNT);
        balance::join(&mut pool.balance_b, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, false);
        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);
        event::emit(FlashRepaid {
            pool_id, borrowed_is_a: false, amount, fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ===== LP entry wrappers (deadline-guarded) =====
    //
    // No swap_entry / flash_entry — those are pure composable primitives,
    // PTB-callable directly by bots, satellites, and aggregators.

    public fun add_liquidity_entry<A, B>(
        pool: &mut Pool<A, B>, coin_a: Coin<A>, coin_b: Coin<B>,
        min_shares_out: u64, clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (position, leftover_a, leftover_b) =
            add_liquidity(pool, coin_a, coin_b, min_shares_out, clock, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(position, sender);
        maybe_transfer(leftover_a, sender);
        maybe_transfer(leftover_b, sender);
    }

    public fun remove_liquidity_entry<A, B>(
        pool: &mut Pool<A, B>, position: LpPosition<A, B>,
        min_amount_a: u64, min_amount_b: u64, clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) =
            remove_liquidity(pool, position, min_amount_a, min_amount_b, clock, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(coin_a, sender);
        transfer::public_transfer(coin_b, sender);
    }

    public fun claim_lp_fees_entry<A, B>(
        pool: &mut Pool<A, B>, position: &mut LpPosition<A, B>,
        clock: &Clock, deadline_ms: u64, ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) = claim_lp_fees(pool, position, clock, ctx);
        let sender = tx_context::sender(ctx);
        maybe_transfer(coin_a, sender);
        maybe_transfer(coin_b, sender);
    }

    // ===== Views (composability surface for satellites + frontends) =====

    public fun reserves<A, B>(pool: &Pool<A, B>): (u64, u64) { (pool.reserve_a, pool.reserve_b) }
    public fun lp_supply<A, B>(pool: &Pool<A, B>): u64 { pool.lp_supply }
    public fun position_shares<A, B>(pos: &LpPosition<A, B>): u64 { pos.shares }
    public fun position_pool_id<A, B>(pos: &LpPosition<A, B>): ID { pos.pool_id }

    /// On-chain disclosure (9 known limitations). Mirror of the WARNING
    /// constant; readable by frontends, indexers, and wallet UIs.
    public fun read_warning(): vector<u8> { WARNING }
}

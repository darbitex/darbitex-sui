/// Darbitex — pool primitive.
///
/// One canonical pool per pair (enforced at factory). x*y=k constant
/// product. 5 bps swap fee, 5 bps flash fee, 100% LP. LP positions are
/// transferable Sui objects with a global fee accumulator + per-position
/// debt snapshot. Flash loan primitive (typed hot-potato receipts) is
/// exposed for composable arb / liquidation flows. Zero admin surface.
///
/// All amounts are raw u64 (smallest unit of each Coin<T>). Math is
/// decimal-blind — exchange rate emerges from reserve ratio. LP shares =
/// sqrt(reserve_a * reserve_b) in raw units.
///
/// Reentrancy lock omitted: Sui Coin<T> has no framework callback,
/// reentrancy via coin operations is structurally impossible. Flash
/// safety is enforced by (a) hot-potato receipt with no abilities forcing
/// same-TX repay, (b) strict repay-amount equality, and (c) k-invariant
/// check at repay (`k_after >= k_before`) which catches any pool state
/// manipulation in the borrow window.
///
/// Reserve accounting model: `balance_a/b` (the actual Coin store) =
/// `reserve_a/b` (AMM state, what swap math operates on) + cumulative
/// unclaimed LP fees. Fees stay mixed in the pool's balance; they are
/// withdrawn via `claim_lp_fees` against the per-share accumulator.
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

    // ===== Structs =====

    /// Pool state. `key` only — not `store` — to prevent wrapping or
    /// transfer outside `share_object` at creation.
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

    /// LP position. Each `add_liquidity` mints a fresh one (no merging).
    /// `key, store` so it can sit in user wallets, kiosks, or escrow.
    public struct LpPosition<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
        fee_debt_a: u128,
        fee_debt_b: u128,
    }

    /// Hot-potato receipt for flash-borrowed A. No abilities — must be
    /// consumed by `flash_repay_a` in the same TX. Type system enforces
    /// repayment with `Coin<A>` (cannot mix with B-side receipt).
    public struct FlashReceiptA<phantom A, phantom B> {
        pool_id: ID,
        amount: u64,
        fee: u64,
        k_before: u256,
    }

    /// Hot-potato receipt for flash-borrowed B. Symmetric to A.
    public struct FlashReceiptB<phantom A, phantom B> {
        pool_id: ID,
        amount: u64,
        fee: u64,
        k_before: u256,
    }

    // ===== Events =====

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        type_a: String,
        type_b: String,
        creator: address,
        amount_a: u64,
        amount_b: u64,
        initial_lp: u64,
        timestamp_ms: u64,
    }

    public struct Swapped has copy, drop {
        pool_id: ID,
        swapper: address,
        amount_in: u64,
        amount_out: u64,
        a_to_b: bool,
        lp_fee: u64,
        timestamp_ms: u64,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: ID,
        provider: address,
        position_id: ID,
        amount_a: u64,
        amount_b: u64,
        shares_minted: u64,
        timestamp_ms: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        provider: address,
        position_id: ID,
        amount_a: u64,
        amount_b: u64,
        fees_a: u64,
        fees_b: u64,
        shares_burned: u64,
        timestamp_ms: u64,
    }

    public struct LpFeesClaimed has copy, drop {
        pool_id: ID,
        position_id: ID,
        claimer: address,
        fees_a: u64,
        fees_b: u64,
        timestamp_ms: u64,
    }

    public struct FlashBorrowed has copy, drop {
        pool_id: ID,
        borrowed_is_a: bool,
        amount: u64,
        fee: u64,
        timestamp_ms: u64,
    }

    public struct FlashRepaid has copy, drop {
        pool_id: ID,
        borrowed_is_a: bool,
        amount: u64,
        fee: u64,
        timestamp_ms: u64,
    }

    // ===== Pure helpers =====

    /// Babylonian integer sqrt for initial LP share computation.
    public fun sqrt(x: u128): u128 {
        if (x == 0) return 0;
        let mut z = (x + 1) / 2;
        let mut y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        };
        y
    }

    /// x*y=k swap math with `SWAP_FEE_BPS` wedge. u256 intermediates
    /// prevent overflow on adversarial reserves near u64::MAX.
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
    ): u64 {
        let amount_in_after_fee = (amount_in as u256) * ((BPS_DENOM - SWAP_FEE_BPS) as u256);
        let numerator = amount_in_after_fee * (reserve_out as u256);
        let denominator = (reserve_in as u256) * (BPS_DENOM as u256) + amount_in_after_fee;
        ((numerator / denominator) as u64)
    }

    /// Flash fee = `amount * FLASH_FEE_BPS / BPS_DENOM`, floor-up to 1
    /// raw unit so dust borrows still pay a unit.
    public fun compute_flash_fee(amount: u64): u64 {
        let fee_raw = (((amount as u256) * (FLASH_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        if (fee_raw == 0) { 1 } else { fee_raw }
    }

    // ===== Internal helpers =====

    /// Credit `fee` to the LP per-share accumulator on the side the fee
    /// was collected. Returns the fee value for event attribution.
    fun accrue_fee<A, B>(pool: &mut Pool<A, B>, fee: u64, a_side: bool): u64 {
        if (fee > 0 && pool.lp_supply > 0) {
            let add = (fee as u128) * SCALE / (pool.lp_supply as u128);
            if (a_side) {
                pool.lp_fee_per_share_a = pool.lp_fee_per_share_a + add;
            } else {
                pool.lp_fee_per_share_b = pool.lp_fee_per_share_b + add;
            };
        };
        fee
    }

    /// Compute `(per_share_current - per_share_debt) * shares / SCALE`
    /// in u256 to avoid overflow, return u64.
    fun pending_from_accumulator(
        per_share_current: u128,
        per_share_debt: u128,
        shares: u64,
    ): u64 {
        if (per_share_current <= per_share_debt) return 0;
        let delta = per_share_current - per_share_debt;
        let product = (delta as u256) * (shares as u256);
        let scaled = product / (SCALE as u256);
        (scaled as u64)
    }

    /// Transfer `coin` to `recipient` if non-zero, else destroy in place
    /// to avoid leaving zero-value Coin objects on user wallets.
    fun maybe_transfer<T>(coin: Coin<T>, recipient: address) {
        if (coin::value(&coin) > 0) {
            transfer::public_transfer(coin, recipient);
        } else {
            coin::destroy_zero(coin);
        };
    }

    // ===== Pool creation (package-only) =====

    /// Atomic pool + initial LP position creation. Called only by
    /// `pool_factory::create_canonical_pool`. Pool is shared internally;
    /// returns the pool ID + initial LP position to the factory.
    ///
    /// `MINIMUM_LIQUIDITY` shares are locked at creation (counted in
    /// `lp_supply` but never minted as a position) so the first depositor
    /// cannot corner via a later-stage ratio squeeze. `remove_liquidity`
    /// asserts `lp_supply >= MINIMUM_LIQUIDITY` post-burn to enforce.
    public(package) fun create_pool<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        clock: &Clock,
        ctx: &mut TxContext,
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
            pool_id,
            shares: creator_shares,
            fee_debt_a: 0,
            fee_debt_b: 0,
        };
        let position_id = object::id(&position);

        let now = clock::timestamp_ms(clock);
        event::emit(PoolCreated {
            pool_id,
            type_a: type_name::with_defining_ids<A>().into_string(),
            type_b: type_name::with_defining_ids<B>().into_string(),
            creator,
            amount_a,
            amount_b,
            initial_lp,
            timestamp_ms: now,
        });
        event::emit(LiquidityAdded {
            pool_id,
            provider: creator,
            position_id,
            amount_a,
            amount_b,
            shares_minted: creator_shares,
            timestamp_ms: now,
        });

        transfer::share_object(pool);
        (pool_id, position)
    }

    // ===== Swap =====

    /// Swap exact `Coin<A>` for at least `min_out` of `Coin<B>`.
    /// Composable primitive — usable directly in PTBs.
    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        coin_in: Coin<A>,
        min_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<B> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let amount_out = compute_amount_out(pool.reserve_a, pool.reserve_b, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE);
        assert!(amount_out < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);

        let fee = (((amount_in as u256) * (SWAP_FEE_BPS as u256) / (BPS_DENOM as u256)) as u64);
        let lp_fee = accrue_fee(pool, fee, true);

        pool.reserve_a = pool.reserve_a + amount_in - lp_fee;
        pool.reserve_b = pool.reserve_b - amount_out;

        balance::join(&mut pool.balance_a, coin::into_balance(coin_in));
        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount_out), ctx);

        event::emit(Swapped {
            pool_id: object::id(pool),
            swapper: tx_context::sender(ctx),
            amount_in,
            amount_out,
            a_to_b: true,
            lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        coin_out
    }

    /// Swap exact `Coin<B>` for at least `min_out` of `Coin<A>`.
    public fun swap_b_to_a<A, B>(
        pool: &mut Pool<A, B>,
        coin_in: Coin<B>,
        min_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
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
            pool_id: object::id(pool),
            swapper: tx_context::sender(ctx),
            amount_in,
            amount_out,
            a_to_b: false,
            lp_fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        coin_out
    }

    // ===== Liquidity =====

    /// Add liquidity. Caller passes max amounts; function picks the
    /// optimal pair against current reserves and returns the unused
    /// leftover as `Coin<A>` / `Coin<B>` for caller to handle. Mints a
    /// fresh LpPosition.
    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        mut coin_a: Coin<A>,
        mut coin_b: Coin<B>,
        min_shares_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (LpPosition<A, B>, Coin<A>, Coin<B>) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        assert!(amount_a_desired > 0 && amount_b_desired > 0, E_ZERO_AMOUNT);

        // u64 cast guard: ratios > 2^64:1 overflow u64. Explicit assert
        // produces E_INSUFFICIENT_LIQUIDITY instead of opaque arithmetic abort.
        let amount_b_optimal_u256 =
            (amount_a_desired as u256) * (pool.reserve_b as u256)
                / (pool.reserve_a as u256);
        assert!(amount_b_optimal_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
        let amount_b_optimal = (amount_b_optimal_u256 as u64);
        let (amount_a, amount_b) = if (amount_b_optimal <= amount_b_desired) {
            (amount_a_desired, amount_b_optimal)
        } else {
            let amount_a_optimal_u256 =
                (amount_b_desired as u256) * (pool.reserve_a as u256)
                    / (pool.reserve_b as u256);
            assert!(amount_a_optimal_u256 <= (U64_MAX as u256), E_INSUFFICIENT_LIQUIDITY);
            let amount_a_optimal = (amount_a_optimal_u256 as u64);
            assert!(amount_a_optimal <= amount_a_desired, E_DISPROPORTIONAL);
            (amount_a_optimal, amount_b_desired)
        };

        assert!(amount_a > 0 && amount_b > 0, E_ZERO_AMOUNT);

        // Shares minted proportionally; min as guard against integer
        // rounding asymmetry between the two sides.
        let lp_a = (
            ((amount_a as u256) * (pool.lp_supply as u256) / (pool.reserve_a as u256)) as u64
        );
        let lp_b = (
            ((amount_b as u256) * (pool.lp_supply as u256) / (pool.reserve_b as u256)) as u64
        );
        let shares = if (lp_a < lp_b) { lp_a } else { lp_b };
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(shares >= min_shares_out, E_SLIPPAGE);

        // Split out the exact deposit amounts; remainder returns to caller.
        let coin_a_in = coin::split(&mut coin_a, amount_a, ctx);
        let coin_b_in = coin::split(&mut coin_b, amount_b, ctx);
        balance::join(&mut pool.balance_a, coin::into_balance(coin_a_in));
        balance::join(&mut pool.balance_b, coin::into_balance(coin_b_in));

        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.lp_supply = pool.lp_supply + shares;

        let debt_a = pool.lp_fee_per_share_a;
        let debt_b = pool.lp_fee_per_share_b;
        let pool_id = object::id(pool);

        let position = LpPosition<A, B> {
            id: object::new(ctx),
            pool_id,
            shares,
            fee_debt_a: debt_a,
            fee_debt_b: debt_b,
        };
        let position_id = object::id(&position);

        event::emit(LiquidityAdded {
            pool_id,
            provider: tx_context::sender(ctx),
            position_id,
            amount_a,
            amount_b,
            shares_minted: shares,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        (position, coin_a, coin_b)
    }

    /// Burn LpPosition and return proportional reserves PLUS accumulated
    /// LP fees in one shot. `min_amount_a/b` are slippage floors on the
    /// proportional reserve payout (not fee claims).
    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        position: LpPosition<A, B>,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let LpPosition { id, pool_id, shares, fee_debt_a, fee_debt_b } = position;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(pool.lp_supply >= shares, E_INSUFFICIENT_LP);

        let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, fee_debt_a, shares);
        let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, fee_debt_b, shares);

        let amount_a = (
            ((shares as u256) * (pool.reserve_a as u256) / (pool.lp_supply as u256)) as u64
        );
        let amount_b = (
            ((shares as u256) * (pool.reserve_b as u256) / (pool.lp_supply as u256)) as u64
        );

        assert!(amount_a >= min_amount_a, E_SLIPPAGE);
        assert!(amount_b >= min_amount_b, E_SLIPPAGE);

        pool.lp_supply = pool.lp_supply - shares;
        // Dead-share floor: never let total LP supply drop below the
        // initial-creation lockup, preserving the anti-cornering invariant.
        assert!(pool.lp_supply >= MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.reserve_b = pool.reserve_b - amount_b;

        let coin_a = coin::from_balance(
            balance::split(&mut pool.balance_a, amount_a + claim_a),
            ctx,
        );
        let coin_b = coin::from_balance(
            balance::split(&mut pool.balance_b, amount_b + claim_b),
            ctx,
        );

        let position_id = object::uid_to_inner(&id);
        event::emit(LiquidityRemoved {
            pool_id,
            provider: tx_context::sender(ctx),
            position_id,
            amount_a,
            amount_b,
            fees_a: claim_a,
            fees_b: claim_b,
            shares_burned: shares,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        object::delete(id);
        (coin_a, coin_b)
    }

    /// Harvest accumulated LP fees without touching position's shares.
    /// Resets debt snapshot to current per_share so future accumulation
    /// starts from zero.
    public fun claim_lp_fees<A, B>(
        pool: &mut Pool<A, B>,
        position: &mut LpPosition<A, B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(object::id(pool) == position.pool_id, E_WRONG_POOL);

        let claim_a = pending_from_accumulator(
            pool.lp_fee_per_share_a, position.fee_debt_a, position.shares,
        );
        let claim_b = pending_from_accumulator(
            pool.lp_fee_per_share_b, position.fee_debt_b, position.shares,
        );

        position.fee_debt_a = pool.lp_fee_per_share_a;
        position.fee_debt_b = pool.lp_fee_per_share_b;

        let coin_a = if (claim_a > 0) {
            coin::from_balance(balance::split(&mut pool.balance_a, claim_a), ctx)
        } else {
            coin::zero<A>(ctx)
        };
        let coin_b = if (claim_b > 0) {
            coin::from_balance(balance::split(&mut pool.balance_b, claim_b), ctx)
        } else {
            coin::zero<B>(ctx)
        };

        event::emit(LpFeesClaimed {
            pool_id: position.pool_id,
            position_id: object::id(position),
            claimer: tx_context::sender(ctx),
            fees_a: claim_a,
            fees_b: claim_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        (coin_a, coin_b)
    }

    // ===== Flash loan =====
    //
    // Reserve accounting: flash_borrow does NOT decrement `reserve_a/b`
    // when the borrowed amount physically leaves the balance. The
    // `k_before` snapshot taken at borrow time is checked against the
    // post-repay reserves at flash_repay; any swap interleaved within
    // the same TX will move the reserves but cannot violate `k_after >=
    // k_before` (each swap pays a fee that increases k). flash_repay
    // therefore must NOT add the principal back into reserve_a/b — the
    // principal returns to `balance_a/b` only, and the reserves remain
    // whatever the interleaved swaps moved them to. Only the flash fee
    // is routed to LP via `accrue_fee`.

    /// Flash-borrow `amount` of A. Returns the borrowed Coin + a
    /// `FlashReceiptA` hot-potato that MUST be consumed by
    /// `flash_repay_a` in the same TX.
    public fun flash_borrow_a<A, B>(
        pool: &mut Pool<A, B>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, FlashReceiptA<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_a, E_INSUFFICIENT_LIQUIDITY);

        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);

        let coin_out = coin::from_balance(balance::split(&mut pool.balance_a, amount), ctx);

        event::emit(FlashBorrowed {
            pool_id,
            borrowed_is_a: true,
            amount,
            fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        let receipt = FlashReceiptA<A, B> { pool_id, amount, fee, k_before };
        (coin_out, receipt)
    }

    /// Flash-borrow `amount` of B. Symmetric to A.
    public fun flash_borrow_b<A, B>(
        pool: &mut Pool<A, B>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<B>, FlashReceiptB<A, B>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount < pool.reserve_b, E_INSUFFICIENT_LIQUIDITY);

        let k_before = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        let fee = compute_flash_fee(amount);
        let pool_id = object::id(pool);

        let coin_out = coin::from_balance(balance::split(&mut pool.balance_b, amount), ctx);

        event::emit(FlashBorrowed {
            pool_id,
            borrowed_is_a: false,
            amount,
            fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        let receipt = FlashReceiptB<A, B> { pool_id, amount, fee, k_before };
        (coin_out, receipt)
    }

    /// Repay A-side flash. Caller supplies `Coin<A>` of exact value
    /// `amount + fee`. Strict equality prevents silent over-payment
    /// drift; under-payment aborts. k-invariant verified post-deposit.
    public fun flash_repay_a<A, B>(
        pool: &mut Pool<A, B>,
        coin: Coin<A>,
        receipt: FlashReceiptA<A, B>,
        clock: &Clock,
    ) {
        let FlashReceiptA { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        let repay_total = amount + fee;
        assert!(coin::value(&coin) == repay_total, E_REPAY_AMOUNT);

        balance::join(&mut pool.balance_a, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, true);

        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);

        event::emit(FlashRepaid {
            pool_id,
            borrowed_is_a: true,
            amount,
            fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    /// Repay B-side flash. Symmetric to A.
    public fun flash_repay_b<A, B>(
        pool: &mut Pool<A, B>,
        coin: Coin<B>,
        receipt: FlashReceiptB<A, B>,
        clock: &Clock,
    ) {
        let FlashReceiptB { pool_id, amount, fee, k_before } = receipt;
        assert!(object::id(pool) == pool_id, E_WRONG_POOL);
        let repay_total = amount + fee;
        assert!(coin::value(&coin) == repay_total, E_REPAY_AMOUNT);

        balance::join(&mut pool.balance_b, coin::into_balance(coin));
        let _ = accrue_fee(pool, fee, false);

        let k_after = (pool.reserve_a as u256) * (pool.reserve_b as u256);
        assert!(k_after >= k_before, E_K_VIOLATED);

        event::emit(FlashRepaid {
            pool_id,
            borrowed_is_a: false,
            amount,
            fee,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ===== LP-management entry wrappers (deadline-guarded) =====
    //
    // No swap_entry / flash_entry — those are pure composable primitives,
    // callable directly in PTBs by bots and aggregators.

    public fun add_liquidity_entry<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        min_shares_out: u64,
        clock: &Clock,
        deadline_ms: u64,
        ctx: &mut TxContext,
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
        pool: &mut Pool<A, B>,
        position: LpPosition<A, B>,
        min_amount_a: u64,
        min_amount_b: u64,
        clock: &Clock,
        deadline_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) =
            remove_liquidity(pool, position, min_amount_a, min_amount_b, clock, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(coin_a, sender);
        transfer::public_transfer(coin_b, sender);
    }

    public fun claim_lp_fees_entry<A, B>(
        pool: &mut Pool<A, B>,
        position: &mut LpPosition<A, B>,
        clock: &Clock,
        deadline_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) < deadline_ms, E_DEADLINE);
        let (coin_a, coin_b) = claim_lp_fees(pool, position, clock, ctx);
        let sender = tx_context::sender(ctx);
        maybe_transfer(coin_a, sender);
        maybe_transfer(coin_b, sender);
    }

    // ===== Views =====

    public fun reserves<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (pool.reserve_a, pool.reserve_b)
    }

    public fun lp_supply<A, B>(pool: &Pool<A, B>): u64 {
        pool.lp_supply
    }

    public fun position_shares<A, B>(pos: &LpPosition<A, B>): u64 {
        pos.shares
    }

    public fun position_pool_id<A, B>(pos: &LpPosition<A, B>): ID {
        pos.pool_id
    }
}

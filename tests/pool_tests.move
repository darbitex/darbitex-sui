#[test_only]
module darbitex::pool_tests {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::package::{Self, UpgradeCap};
    use sui::test_scenario::{Self as ts, Scenario};
    use std::unit_test;

    use darbitex::pool::{Self, Pool, LpPosition};
    use darbitex::pool_factory::{Self, FactoryRegistry, OriginCap};

    public struct TEST_A has drop {}
    public struct TEST_B has drop {}

    const DEPLOYER: address = @0xCAFE;

    // ===== Helpers =====

    fun start(): Scenario {
        let mut sc = ts::begin(DEPLOYER);
        pool_factory::init_for_testing(ts::ctx(&mut sc));
        sc
    }

    fun take_factory(sc: &mut Scenario): FactoryRegistry {
        ts::next_tx(sc, DEPLOYER);
        ts::take_shared<FactoryRegistry>(sc)
    }

    fun take_pool(sc: &mut Scenario): Pool<TEST_A, TEST_B> {
        ts::next_tx(sc, DEPLOYER);
        ts::take_shared<Pool<TEST_A, TEST_B>>(sc)
    }

    /// Create pool with reserves (a, b). Returns LP position to DEPLOYER.
    fun create_pool_with(
        factory: &mut FactoryRegistry,
        amount_a: u64,
        amount_b: u64,
        clk: &Clock,
        sc: &mut Scenario,
    ) {
        let coin_a = coin::mint_for_testing<TEST_A>(amount_a, ts::ctx(sc));
        let coin_b = coin::mint_for_testing<TEST_B>(amount_b, ts::ctx(sc));
        let pos = pool_factory::create_canonical_pool<TEST_A, TEST_B>(
            factory, coin_a, coin_b, clk, ts::ctx(sc),
        );
        transfer::public_transfer(pos, DEPLOYER);
    }

    // ===== Pure math =====

    #[test]
    fun test_sqrt() {
        assert!(pool::sqrt(0) == 0, 0);
        assert!(pool::sqrt(1) == 1, 1);
        assert!(pool::sqrt(4) == 2, 2);
        assert!(pool::sqrt(100) == 10, 3);
        assert!(pool::sqrt(1_000_000) == 1000, 4);
        assert!(pool::sqrt(2) == 1, 5);
        assert!(pool::sqrt(99) == 9, 6);
    }

    #[test]
    fun test_compute_amount_out() {
        // Pool 100k/100k, swap 10k A:
        //   amount_in_after_fee = 10000 * 9995 = 99_950_000
        //   numerator = 99_950_000 * 100_000 = 9_995_000_000_000
        //   denominator = 100_000 * 10000 + 99_950_000 = 1_099_950_000
        //   out = 9086 (floor)
        assert!(pool::compute_amount_out(100_000, 100_000, 10_000) == 9086, 0);
        // Tiny swap rounds to 0
        assert!(pool::compute_amount_out(1_000_000, 1_000_000, 1) == 0, 1);
    }

    #[test]
    fun test_read_warning() {
        let w = pool::read_warning();
        // Non-empty + contains the "DARBITEX" prefix as a sanity check
        assert!(std::vector::length(&w) > 0, 0);
        assert!(*std::vector::borrow(&w, 0) == 68u8, 1);  // 'D'
    }

    #[test]
    fun test_compute_flash_fee() {
        // Dust borrows floor up to 1
        assert!(pool::compute_flash_fee(0) == 1, 0);
        assert!(pool::compute_flash_fee(1) == 1, 1);
        assert!(pool::compute_flash_fee(1000) == 1, 2);
        assert!(pool::compute_flash_fee(2000) == 1, 3);
        assert!(pool::compute_flash_fee(10_000) == 5, 4);
        assert!(pool::compute_flash_fee(1_000_000) == 500, 5);
    }

    // ===== Pair sorting =====

    #[test]
    fun test_assert_sorted_correct() {
        let _key = pool_factory::assert_sorted<TEST_A, TEST_B>();
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool_factory::E_WRONG_ORDER)]
    fun test_assert_sorted_wrong_order() {
        let _key = pool_factory::assert_sorted<TEST_B, TEST_A>();
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool_factory::E_WRONG_ORDER)]
    fun test_assert_sorted_same_type() {
        let _key = pool_factory::assert_sorted<TEST_A, TEST_A>();
    }

    // ===== Pool creation =====

    #[test]
    fun test_create_pool_basic() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);

        assert!(pool_factory::pool_count(&factory) == 1, 0);

        let pool = take_pool(&mut sc);
        let (ra, rb) = pool::reserves(&pool);
        assert!(ra == 100_000, 1);
        assert!(rb == 100_000, 2);
        // sqrt(100k * 100k) = 100k. lp_supply = 100k. dead = 1k. creator = 99k.
        assert!(pool::lp_supply(&pool) == 100_000, 3);

        ts::next_tx(&mut sc, DEPLOYER);
        let pos = ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(&sc);
        assert!(pool::position_shares(&pos) == 99_000, 4);

        // canonical_pool_id lookup works for both orderings
        let id1 = pool_factory::canonical_pool_id<TEST_A, TEST_B>(&factory);
        let id2 = pool_factory::canonical_pool_id<TEST_B, TEST_A>(&factory);
        assert!(option::is_some(&id1), 5);
        assert!(option::is_some(&id2), 6);
        assert!(*option::borrow(&id1) == *option::borrow(&id2), 7);

        unit_test::destroy(pos);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool_factory::E_DUPLICATE_PAIR)]
    fun test_create_pool_duplicate() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        // Second create on the same pair must abort
        create_pool_with(&mut factory, 50_000, 50_000, &clk, &mut sc);

        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool::E_INSUFFICIENT_LIQUIDITY)]
    fun test_create_pool_too_small() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        // sqrt(31 * 31) = 31, NOT > MINIMUM_LIQUIDITY (1000) → abort
        create_pool_with(&mut factory, 31, 31, &clk, &mut sc);

        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Swap =====

    #[test]
    fun test_swap_round_trip() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Swap 10k A → expect 9086 B
        let coin_a_in = coin::mint_for_testing<TEST_A>(10_000, ts::ctx(&mut sc));
        let coin_b_out = pool::swap_a_to_b(&mut pool, coin_a_in, 9000, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&coin_b_out) == 9086, 0);

        let (ra, rb) = pool::reserves(&pool);
        // reserve_a = 100k + 10k - 5 (fee) = 109_995
        // reserve_b = 100k - 9086 = 90_914
        assert!(ra == 109_995, 1);
        assert!(rb == 90_914, 2);

        // Swap back B → A
        let coin_a_back = pool::swap_b_to_a(&mut pool, coin_b_out, 0, &clk, ts::ctx(&mut sc));
        // Should get LESS than 10k (slippage + double fee)
        assert!(coin::value(&coin_a_back) < 10_000, 3);

        unit_test::destroy(coin_a_back);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool::E_SLIPPAGE)]
    fun test_swap_slippage() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Demand min_out = 10000 but actual is 9087 → abort E_SLIPPAGE
        let coin_a = coin::mint_for_testing<TEST_A>(10_000, ts::ctx(&mut sc));
        let coin_b = pool::swap_a_to_b(&mut pool, coin_a, 10_000, &clk, ts::ctx(&mut sc));

        unit_test::destroy(coin_b);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Liquidity =====

    #[test]
    fun test_add_liquidity_unbalanced() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        // Pool 100k/100k (1:1 ratio)
        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Add 10k A + 20k B desired. Optimal at 1:1 → use (10k, 10k), leftover B = 10k
        let coin_a = coin::mint_for_testing<TEST_A>(10_000, ts::ctx(&mut sc));
        let coin_b = coin::mint_for_testing<TEST_B>(20_000, ts::ctx(&mut sc));
        let (pos, leftover_a, leftover_b) =
            pool::add_liquidity(&mut pool, coin_a, coin_b, 0, &clk, ts::ctx(&mut sc));

        assert!(coin::value(&leftover_a) == 0, 0);
        assert!(coin::value(&leftover_b) == 10_000, 1);

        // Shares minted = 10k * 100k / 100k = 10k
        assert!(pool::position_shares(&pos) == 10_000, 2);

        let (ra, rb) = pool::reserves(&pool);
        assert!(ra == 110_000, 3);
        assert!(rb == 110_000, 4);
        assert!(pool::lp_supply(&pool) == 110_000, 5);

        unit_test::destroy(pos);
        unit_test::destroy(leftover_a);
        unit_test::destroy(leftover_b);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_remove_liquidity() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        ts::next_tx(&mut sc, DEPLOYER);
        let pos = ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(&sc);
        // creator_shares = 99k. removing all 99k → 99k * 100k / 100k = 99k each side
        let (coin_a, coin_b) =
            pool::remove_liquidity(&mut pool, pos, 99_000, 99_000, &clk, ts::ctx(&mut sc));

        assert!(coin::value(&coin_a) == 99_000, 0);
        assert!(coin::value(&coin_b) == 99_000, 1);

        // After: lp_supply == MINIMUM_LIQUIDITY (1k dead). reserves == 1k each.
        assert!(pool::lp_supply(&pool) == 1_000, 2);
        let (ra, rb) = pool::reserves(&pool);
        assert!(ra == 1_000, 3);
        assert!(rb == 1_000, 4);

        unit_test::destroy(coin_a);
        unit_test::destroy(coin_b);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // NOTE: dead-share floor (`lp_supply >= MINIMUM_LIQUIDITY` post-burn) is a
    // defense-in-depth invariant that is unreachable through the normal API
    // — `remove_liquidity` can never burn more than (lp_supply -
    // MINIMUM_LIQUIDITY) without first failing the `lp_supply >= shares`
    // check. The assert exists as a compile-checked safety net; not unit-tested.

    // ===== LP fee accumulator =====

    #[test]
    fun test_lp_fee_accrual_and_claim() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Swap 10k A → fee = 5 A goes to LP accumulator
        let coin_a = coin::mint_for_testing<TEST_A>(10_000, ts::ctx(&mut sc));
        let coin_b = pool::swap_a_to_b(&mut pool, coin_a, 0, &clk, ts::ctx(&mut sc));
        unit_test::destroy(coin_b);

        // Creator claims fees: holds 99k of 100k shares → ~99% of 5 A = 4.x A
        ts::next_tx(&mut sc, DEPLOYER);
        let mut pos = ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(&sc);
        let (claim_a, claim_b) = pool::claim_lp_fees(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));

        // Expected: 5 * 99000 / 100000 = 4 (integer)
        assert!(coin::value(&claim_a) == 4, 0);
        assert!(coin::value(&claim_b) == 0, 1);

        // Second claim — debt updated, no further fees. Returns zero coins.
        let (claim_a2, claim_b2) = pool::claim_lp_fees(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&claim_a2) == 0, 2);
        assert!(coin::value(&claim_b2) == 0, 3);

        unit_test::destroy(claim_a);
        unit_test::destroy(claim_b);
        unit_test::destroy(claim_a2);
        unit_test::destroy(claim_b2);
        unit_test::destroy(pos);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Flash =====

    #[test]
    fun test_flash_round_trip_a() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Flash borrow 10k A → fee = 5
        let (borrowed, receipt) =
            pool::flash_borrow_a(&mut pool, 10_000, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&borrowed) == 10_000, 0);

        // Add fee from outside, repay
        let mut repay = coin::mint_for_testing<TEST_A>(5, ts::ctx(&mut sc));
        coin::join(&mut repay, borrowed);
        pool::flash_repay_a(&mut pool, repay, receipt, &clk);

        // Reserves unchanged (flash doesn't touch reserve_a/b)
        let (ra, rb) = pool::reserves(&pool);
        assert!(ra == 100_000, 1);
        assert!(rb == 100_000, 2);

        // Fee accrued to LP — claim verifies
        ts::next_tx(&mut sc, DEPLOYER);
        let mut pos = ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(&sc);
        let (claim_a, claim_b) = pool::claim_lp_fees(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));
        // 5 fee * 99000/100000 = 4
        assert!(coin::value(&claim_a) == 4, 3);
        assert!(coin::value(&claim_b) == 0, 4);

        unit_test::destroy(claim_a);
        unit_test::destroy(claim_b);
        unit_test::destroy(pos);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_flash_round_trip_b() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        let (borrowed, receipt) =
            pool::flash_borrow_b(&mut pool, 10_000, &clk, ts::ctx(&mut sc));
        let mut repay = coin::mint_for_testing<TEST_B>(5, ts::ctx(&mut sc));
        coin::join(&mut repay, borrowed);
        pool::flash_repay_b(&mut pool, repay, receipt, &clk);

        let (ra, rb) = pool::reserves(&pool);
        assert!(ra == 100_000, 0);
        assert!(rb == 100_000, 1);

        ts::next_tx(&mut sc, DEPLOYER);
        let pos = ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(&sc);
        unit_test::destroy(pos);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool::E_REPAY_AMOUNT)]
    fun test_flash_repay_underpay() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        let (borrowed, receipt) =
            pool::flash_borrow_a(&mut pool, 10_000, &clk, ts::ctx(&mut sc));
        // Repay only the principal (no fee) → must abort
        pool::flash_repay_a(&mut pool, borrowed, receipt, &clk);

        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool::E_INSUFFICIENT_LIQUIDITY)]
    fun test_flash_borrow_too_much() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_with(&mut factory, 100_000, 100_000, &clk, &mut sc);
        let mut pool = take_pool(&mut sc);

        // Borrow >= reserve_a → abort
        let (borrowed, receipt) =
            pool::flash_borrow_a(&mut pool, 100_000, &clk, ts::ctx(&mut sc));

        unit_test::destroy(borrowed);
        unit_test::destroy(receipt);
        ts::return_shared(pool);
        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Sealing =====

    #[test]
    fun test_destroy_cap_seals() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        ts::next_tx(&mut sc, DEPLOYER);
        let origin = ts::take_from_sender<OriginCap>(&sc);
        let pkg_id = object::id_from_address(@0x1);
        let upgrade = package::test_publish(pkg_id, ts::ctx(&mut sc));

        assert!(!pool_factory::is_sealed(&factory), 0);
        pool_factory::destroy_cap(origin, &mut factory, upgrade, &clk, ts::ctx(&mut sc));
        assert!(pool_factory::is_sealed(&factory), 1);

        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex::pool_factory::E_SEALED)]
    fun test_destroy_cap_twice_aborts() {
        let mut sc = start();
        let mut factory = take_factory(&mut sc);
        let clk = clock::create_for_testing(ts::ctx(&mut sc));

        ts::next_tx(&mut sc, DEPLOYER);
        let origin1 = ts::take_from_sender<OriginCap>(&sc);
        let pkg_id = object::id_from_address(@0x1);
        let upgrade1 = package::test_publish(pkg_id, ts::ctx(&mut sc));
        pool_factory::destroy_cap(origin1, &mut factory, upgrade1, &clk, ts::ctx(&mut sc));

        // Second destroy on already-sealed factory must abort. Synthesize a
        // fresh OriginCap + UpgradeCap pair via test-only helpers — on mainnet
        // this is impossible (no public OriginCap constructor) but the test
        // verifies the seal-flag guard fires regardless of cap source.
        let origin2 = pool_factory::mint_origin_cap_for_testing(ts::ctx(&mut sc));
        let upgrade2 = package::test_publish(pkg_id, ts::ctx(&mut sc));
        pool_factory::destroy_cap(origin2, &mut factory, upgrade2, &clk, ts::ctx(&mut sc));

        ts::return_shared(factory);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}

/// Darbitex — pool factory.
///
/// Maintains the canonical-pool-per-pair invariant via a sorted-pair
/// `Table<PairKey, ID>`. Sealing pattern: `OriginCap` (soulbound) +
/// `UpgradeCap` consumed by `destroy_cap`, which calls
/// `package::make_immutable` and sets `factory.sealed = true`. After
/// sealing, the only on-chain action remaining is permissionless
/// `create_canonical_pool<A, B>` calls — there is no admin surface.
module darbitex::pool_factory {
    use std::ascii::{Self, String};
    use std::type_name;

    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::package::{Self, UpgradeCap};
    use sui::table::{Self, Table};

    use darbitex::pool::{Self, LpPosition};

    // ===== Errors =====

    const E_WRONG_ORDER: u64 = 4;
    const E_ZERO: u64 = 5;
    const E_DUPLICATE_PAIR: u64 = 6;
    const E_SEALED: u64 = 18;

    // ===== One-time witness =====

    public struct POOL_FACTORY has drop {}

    // ===== Structs =====

    /// Canonical pair key. Constructed via `assert_sorted<A, B>()`
    /// which enforces lexicographic ordering of TypeName strings.
    public struct PairKey has copy, drop, store {
        type_a: String,
        type_b: String,
    }

    /// Singleton shared registry. Tracks every canonical pool created
    /// through the factory and enforces the 1-pool-per-pair invariant.
    public struct FactoryRegistry has key {
        id: UID,
        pool_count: u64,
        pairs: Table<PairKey, ID>,
        sealed: bool,
    }

    /// Soulbound deployer cap. No `store` ability — cannot be wrapped
    /// or transferred via `transfer::public_transfer`. Consumed by
    /// `destroy_cap` to seal the package.
    public struct OriginCap has key {
        id: UID,
    }

    // ===== Events =====

    public struct FactoryInitialized has copy, drop {
        factory_id: ID,
        deployer: address,
    }

    public struct FactorySealed has copy, drop {
        factory_id: ID,
        deployer: address,
        timestamp_ms: u64,
    }

    // ===== Init (one-time, framework-enforced) =====

    /// Runs exactly once at publish. Creates the shared FactoryRegistry
    /// and transfers OriginCap to the deployer.
    fun init(_witness: POOL_FACTORY, ctx: &mut TxContext) {
        let factory = FactoryRegistry {
            id: object::new(ctx),
            pool_count: 0,
            pairs: table::new<PairKey, ID>(ctx),
            sealed: false,
        };
        let factory_id = object::id(&factory);
        let cap = OriginCap { id: object::new(ctx) };
        let deployer = tx_context::sender(ctx);

        event::emit(FactoryInitialized { factory_id, deployer });

        transfer::share_object(factory);
        transfer::transfer(cap, deployer);
    }

    // ===== Pair key derivation =====

    /// Lexicographic byte compare for two byte vectors. Returns true
    /// iff `a < b`. Identical vectors return false (so strict `<` also
    /// rejects same-type pairs in `assert_sorted`).
    fun bytes_lt(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = std::vector::length(a);
        let len_b = std::vector::length(b);
        let min_len = if (len_a < len_b) { len_a } else { len_b };
        let mut i = 0;
        while (i < min_len) {
            let xa = *std::vector::borrow(a, i);
            let xb = *std::vector::borrow(b, i);
            if (xa < xb) return true;
            if (xa > xb) return false;
            i = i + 1;
        };
        len_a < len_b
    }

    /// Build a sorted PairKey for `(A, B)`. Aborts `E_WRONG_ORDER` if
    /// `type_name(A) >= type_name(B)`. Strict `<` also rejects same-type
    /// pairs (canonical AMM cannot pair an asset with itself).
    public fun assert_sorted<A, B>(): PairKey {
        let type_a = type_name::with_defining_ids<A>().into_string();
        let type_b = type_name::with_defining_ids<B>().into_string();
        let ok = {
            let bytes_a = ascii::as_bytes(&type_a);
            let bytes_b = ascii::as_bytes(&type_b);
            bytes_lt(bytes_a, bytes_b)
        };
        assert!(ok, E_WRONG_ORDER);
        PairKey { type_a, type_b }
    }

    // ===== Pool creation =====

    /// Atomic canonical pool creation. Caller supplies seeding tokens
    /// in canonical-sorted type order. Aborts `E_DUPLICATE_PAIR` if the
    /// pair already has a canonical pool. Returns the LP position to
    /// the caller (the underlying `Pool<A, B>` is shared internally
    /// inside `pool::create_pool`).
    public fun create_canonical_pool<A, B>(
        factory: &mut FactoryRegistry,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): LpPosition<A, B> {
        let key = assert_sorted<A, B>();
        assert!(coin::value(&coin_a) > 0 && coin::value(&coin_b) > 0, E_ZERO);
        assert!(!table::contains(&factory.pairs, key), E_DUPLICATE_PAIR);

        let (pool_id, position) = pool::create_pool<A, B>(coin_a, coin_b, clock, ctx);
        table::add(&mut factory.pairs, key, pool_id);
        factory.pool_count = factory.pool_count + 1;

        position
    }

    /// Wallet-friendly entry wrapper. Transfers the LP position to
    /// sender after creating the pool.
    public fun create_canonical_pool_entry<A, B>(
        factory: &mut FactoryRegistry,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let position = create_canonical_pool<A, B>(factory, coin_a, coin_b, clock, ctx);
        transfer::public_transfer(position, tx_context::sender(ctx));
    }

    // ===== Sealing =====

    /// Burn OriginCap + UpgradeCap, mark factory sealed.
    /// Post-call: package is `make_immutable`, no upgrade authority
    /// exists anywhere in the system. Idempotency guarded by
    /// `factory.sealed` flag (subsequent calls abort `E_SEALED`).
    public fun destroy_cap(
        origin: OriginCap,
        factory: &mut FactoryRegistry,
        upgrade: UpgradeCap,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!factory.sealed, E_SEALED);

        let OriginCap { id } = origin;
        object::delete(id);
        package::make_immutable(upgrade);
        factory.sealed = true;

        event::emit(FactorySealed {
            factory_id: object::id(factory),
            deployer: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ===== Views =====

    /// Look up the canonical pool ID for `(A, B)`. Returns `None` if
    /// the pair has not been created. Caller does NOT need to pre-sort
    /// types — the function sorts internally.
    public fun canonical_pool_id<A, B>(factory: &FactoryRegistry): Option<ID> {
        let type_a = type_name::with_defining_ids<A>().into_string();
        let type_b = type_name::with_defining_ids<B>().into_string();
        let a_first = {
            let bytes_a = ascii::as_bytes(&type_a);
            let bytes_b = ascii::as_bytes(&type_b);
            bytes_lt(bytes_a, bytes_b)
        };
        let key = if (a_first) {
            PairKey { type_a, type_b }
        } else {
            PairKey { type_a: type_b, type_b: type_a }
        };
        if (table::contains(&factory.pairs, key)) {
            option::some(*table::borrow(&factory.pairs, key))
        } else {
            option::none()
        }
    }

    public fun pool_count(factory: &FactoryRegistry): u64 {
        factory.pool_count
    }

    public fun is_sealed(factory: &FactoryRegistry): bool {
        factory.sealed
    }

    // ===== Test-only =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(POOL_FACTORY {}, ctx);
    }

    #[test_only]
    public fun mint_origin_cap_for_testing(ctx: &mut TxContext): OriginCap {
        OriginCap { id: object::new(ctx) }
    }
}

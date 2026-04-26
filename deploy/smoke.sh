#!/usr/bin/env bash
# Darbitex Sui — testnet smoke test
# Exercises: create_pool, swap a↔b, add_liquidity, claim_lp_fees, remove_liquidity, flash a+b.

set -euo pipefail

cd "$(dirname "$0")/.."
source deploy/out/deployment.txt

OUT_DIR="deploy/out/smoke"
mkdir -p "$OUT_DIR"

A_TYPE="0xf093da7b398511579503e3b23747c1abaaf2673a0419813bf89fb545e04379f4::eth_faucet::ETH_FAUCET"
B_TYPE="0xf093da7b398511579503e3b23747c1abaaf2673a0419813bf89fb545e04379f4::usdt_faucet::USDT_FAUCET"

# Helper: pick first object owned by ADDR of given Coin<T>.
pick_coin() {
    local coin_t="$1"
    sui client objects --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
target_addr, target_mod, target_name = sys.argv[1], sys.argv[2], sys.argv[3]
for o in data:
    t = o.get('data', {}).get('Move', {}).get('type_', {})
    if isinstance(t, dict) and 'Coin' in t:
        s = t['Coin']['struct']
        if s.get('address','') == target_addr and s.get('module','') == target_mod and s.get('name','') == target_name:
            obj_id = '0x' + ''.join(f'{b:02x}' for b in o['data']['Move']['contents'][:32])
            balance = int.from_bytes(bytes(o['data']['Move']['contents'][32:40]), 'little')
            print(f'{obj_id} {balance}')
            sys.exit(0)
" "${coin_t%::*::*}" "${coin_t#*::}" 2>&1 | sed -E 's/^([^:]+)::.*::([A-Z_]+)$/\1 \2/'
}

# Resolve coin objects.
A_OBJ_RAW=$(sui client objects --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for o in data:
    t = o.get('data', {}).get('Move', {}).get('type_', {})
    if isinstance(t, dict) and 'Coin' in t:
        s = t['Coin']['struct']
        if s.get('module','') == 'eth_faucet' and s.get('name','') == 'ETH_FAUCET':
            obj_id = '0x' + ''.join(f'{b:02x}' for b in o['data']['Move']['contents'][:32])
            balance = int.from_bytes(bytes(o['data']['Move']['contents'][32:40]), 'little')
            print(f'{obj_id} {balance}')
            break
")
B_OBJ_RAW=$(sui client objects --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for o in data:
    t = o.get('data', {}).get('Move', {}).get('type_', {})
    if isinstance(t, dict) and 'Coin' in t:
        s = t['Coin']['struct']
        if s.get('module','') == 'usdt_faucet' and s.get('name','') == 'USDT_FAUCET':
            obj_id = '0x' + ''.join(f'{b:02x}' for b in o['data']['Move']['contents'][:32])
            balance = int.from_bytes(bytes(o['data']['Move']['contents'][32:40]), 'little')
            print(f'{obj_id} {balance}')
            break
")

read -r A_COIN_ID A_COIN_BAL <<< "$A_OBJ_RAW"
read -r B_COIN_ID B_COIN_BAL <<< "$B_OBJ_RAW"

echo "PACKAGE_ID = $PACKAGE_ID"
echo "FACTORY_ID = $FACTORY_ID"
echo "A_COIN     = $A_COIN_ID  bal=$A_COIN_BAL  (ETH_FAUCET)"
echo "B_COIN     = $B_COIN_ID  bal=$B_COIN_BAL  (USDT_FAUCET)"
echo

if [[ -z "$A_COIN_ID" || -z "$B_COIN_ID" ]]; then
    echo "ERROR: missing test-coin objects"
    exit 1
fi

# ---------- Phase B1: create_canonical_pool ----------
echo "==> B1: create_canonical_pool_entry — seed 100M ETH + 4M USDT"
sui client ptb \
    --split-coins "@${A_COIN_ID}" "[100000000]" --assign eth_seed \
    --split-coins "@${B_COIN_ID}" "[4000000]" --assign usdt_seed \
    --move-call "${PACKAGE_ID}::pool_factory::create_canonical_pool_entry" "<${A_TYPE}, ${B_TYPE}>" \
        "@${FACTORY_ID}" eth_seed.0 usdt_seed.0 "@0x6" \
    --gas-budget 200000000 --json > "$OUT_DIR/b1_create.json"
echo "  done — saved $OUT_DIR/b1_create.json"

# Extract POOL_ID + first POSITION_ID from event log.
POOL_ID=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for ev in d.get('events',[]):
    if ev.get('type','').endswith('::pool::PoolCreated'):
        print(ev['parsedJson']['pool_id']); break
" "$OUT_DIR/b1_create.json")

POSITION_ID_1=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for ev in d.get('events',[]):
    if ev.get('type','').endswith('::pool::LiquidityAdded'):
        print(ev['parsedJson']['position_id']); break
" "$OUT_DIR/b1_create.json")

echo "  POOL_ID    = $POOL_ID"
echo "  POSITION#1 = $POSITION_ID_1"
echo

if [[ -z "$POOL_ID" || -z "$POSITION_ID_1" ]]; then
    echo "ERROR: missing POOL_ID or POSITION_ID_1"
    exit 1
fi

# ---------- Phase B2: swap_a_to_b — 1M ETH → USDT ----------
echo "==> B2: swap_a_to_b 1M ETH"
sui client ptb \
    --split-coins "@${A_COIN_ID}" "[1000000]" --assign eth_in \
    --move-call "${PACKAGE_ID}::pool::swap_a_to_b" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" eth_in.0 0 "@0x6" --assign usdt_out \
    --transfer-objects "[usdt_out]" "@${DEPLOYER}" \
    --gas-budget 200000000 --json > "$OUT_DIR/b2_swap_ab.json"
B2_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b2_swap_ab.json")
echo "  status: $B2_STATUS"
echo

# ---------- Phase B3: swap_b_to_a — 100K USDT → ETH ----------
echo "==> B3: swap_b_to_a 100K USDT"
sui client ptb \
    --split-coins "@${B_COIN_ID}" "[100000]" --assign usdt_in \
    --move-call "${PACKAGE_ID}::pool::swap_b_to_a" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" usdt_in.0 0 "@0x6" --assign eth_out \
    --transfer-objects "[eth_out]" "@${DEPLOYER}" \
    --gas-budget 200000000 --json > "$OUT_DIR/b3_swap_ba.json"
B3_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b3_swap_ba.json")
echo "  status: $B3_STATUS"
echo

# ---------- Phase B4: add_liquidity_entry ----------
echo "==> B4: add_liquidity_entry — add 10M ETH + 400K USDT"
DEADLINE=$(python3 -c "import time; print(int(time.time()*1000) + 3600000)")
sui client ptb \
    --split-coins "@${A_COIN_ID}" "[10000000]" --assign eth_add \
    --split-coins "@${B_COIN_ID}" "[400000]" --assign usdt_add \
    --move-call "${PACKAGE_ID}::pool::add_liquidity_entry" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" eth_add.0 usdt_add.0 0 "@0x6" "${DEADLINE}" \
    --gas-budget 200000000 --json > "$OUT_DIR/b4_add.json"
B4_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b4_add.json")
POSITION_ID_2=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for ev in d.get('events',[]):
    if ev.get('type','').endswith('::pool::LiquidityAdded'):
        print(ev['parsedJson']['position_id']); break
" "$OUT_DIR/b4_add.json")
echo "  status: $B4_STATUS"
echo "  POSITION#2 = $POSITION_ID_2"
echo

# ---------- Phase B5: flash_borrow_a + flash_repay_a ----------
echo "==> B5: flash a — borrow 1M ETH, repay 1M+500"
sui client ptb \
    --split-coins "@${A_COIN_ID}" "[500]" --assign eth_fee \
    --move-call "${PACKAGE_ID}::pool::flash_borrow_a" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" 1000000 "@0x6" --assign borrow_a \
    --merge-coins borrow_a.0 "[eth_fee.0]" \
    --move-call "${PACKAGE_ID}::pool::flash_repay_a" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" borrow_a.0 borrow_a.1 "@0x6" \
    --gas-budget 200000000 --json > "$OUT_DIR/b5_flash_a.json"
B5_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b5_flash_a.json")
echo "  status: $B5_STATUS"
echo

# ---------- Phase B6: flash_borrow_b + flash_repay_b ----------
echo "==> B6: flash b — borrow 100K USDT, repay 100K+50"
sui client ptb \
    --split-coins "@${B_COIN_ID}" "[50]" --assign usdt_fee \
    --move-call "${PACKAGE_ID}::pool::flash_borrow_b" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" 100000 "@0x6" --assign borrow_b \
    --merge-coins borrow_b.0 "[usdt_fee.0]" \
    --move-call "${PACKAGE_ID}::pool::flash_repay_b" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" borrow_b.0 borrow_b.1 "@0x6" \
    --gas-budget 200000000 --json > "$OUT_DIR/b6_flash_b.json"
B6_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b6_flash_b.json")
echo "  status: $B6_STATUS"
echo

# ---------- Phase B7: claim_lp_fees_entry on POSITION#1 ----------
echo "==> B7: claim_lp_fees_entry on POSITION#1"
DEADLINE=$(python3 -c "import time; print(int(time.time()*1000) + 3600000)")
sui client ptb \
    --move-call "${PACKAGE_ID}::pool::claim_lp_fees_entry" "<${A_TYPE}, ${B_TYPE}>" \
        "@${POOL_ID}" "@${POSITION_ID_1}" "@0x6" "${DEADLINE}" \
    --gas-budget 200000000 --json > "$OUT_DIR/b7_claim.json"
B7_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b7_claim.json")
echo "  status: $B7_STATUS"
echo

# ---------- Phase B8: remove_liquidity_entry on POSITION#2 ----------
echo "==> B8: remove_liquidity_entry on POSITION#2"
if [[ -n "$POSITION_ID_2" ]]; then
    DEADLINE=$(python3 -c "import time; print(int(time.time()*1000) + 3600000)")
    sui client ptb \
        --move-call "${PACKAGE_ID}::pool::remove_liquidity_entry" "<${A_TYPE}, ${B_TYPE}>" \
            "@${POOL_ID}" "@${POSITION_ID_2}" 0 0 "@0x6" "${DEADLINE}" \
        --gas-budget 200000000 --json > "$OUT_DIR/b8_remove.json"
    B8_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('effects',{}).get('status',{}).get('status',''))" "$OUT_DIR/b8_remove.json")
    echo "  status: $B8_STATUS"
else
    echo "  skipped (no POSITION#2)"
fi
echo

# ---------- Final pool state ----------
echo "==> Final pool state"
sui client object "$POOL_ID" --json > "$OUT_DIR/pool_final.json"
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=d.get('content',{})
print(f\"  reserves    = ({c.get('reserve_a','?')}, {c.get('reserve_b','?')})\")
print(f\"  lp_supply   = {c.get('lp_supply','?')}\")
print(f\"  fee_per_share_a = {c.get('lp_fee_per_share_a','?')}\")
print(f\"  fee_per_share_b = {c.get('lp_fee_per_share_b','?')}\")
" "$OUT_DIR/pool_final.json"
echo

echo "=== smoke test complete ==="

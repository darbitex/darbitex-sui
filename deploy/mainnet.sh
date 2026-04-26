#!/usr/bin/env bash
# Darbitex Sui — MAINNET deploy + seal
# Two-tx atomic flow: publish package, then destroy_cap → make_immutable + sealed=true.
# IRREVERSIBLE. Run only after explicit user GO.

set -euo pipefail

cd "$(dirname "$0")/.."

ENV=$(sui client active-env)
# Mainnet env can be aliased "mainnet" or unnamed "0" pointing at fullnode.mainnet.sui.io.
ACTIVE_URL=$(sui client envs --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for env in data.get('envs', data):
    if isinstance(env, dict) and env.get('alias') == sys.argv[1] or env == sys.argv[1]:
        if isinstance(env, dict): print(env.get('url','')); sys.exit(0)
" "$ENV" 2>/dev/null || true)
# Fallback: just check fragile sui client envs text output.
if ! sui client envs 2>&1 | grep -q "fullnode.mainnet.sui.io.*\*"; then
    echo "ERROR: active env '$ENV' is NOT mainnet. Run: sui client switch --env 0"
    sui client envs 2>&1
    exit 1
fi

ADDR=$(sui client active-address)
echo "================================================"
echo "  DARBITEX SUI — MAINNET DEPLOY"
echo "  This will publish + seal IRREVERSIBLY."
echo "================================================"
echo "Active env:     $ENV (mainnet)"
echo "Active address: $ADDR"
echo "Working dir:    $(pwd)"
echo "Source LOC:     pool.move 529 + pool_factory.move 190"
echo
echo "Pre-flight gas check..."
sui client gas 2>&1 | head -10
echo

OUT_DIR="deploy/out/mainnet"
mkdir -p "$OUT_DIR"
PUBLISH_JSON="$OUT_DIR/publish.json"
SEAL_JSON="$OUT_DIR/seal.json"
DEPLOY_INFO="$OUT_DIR/deployment.txt"

# ---------- Tx 1: publish ----------

echo "==> Tx 1/2: sui client publish"
sui client publish --gas-budget 500000000 --json --skip-dependency-verification > "$PUBLISH_JSON"
echo "  publish JSON saved to $PUBLISH_JSON"

read -r PACKAGE_ID FACTORY_ID ORIGIN_CAP_ID UPGRADE_CAP_ID <<< "$(python3 - "$PUBLISH_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pkg = factory = origin = upgrade = ""
for ch in data.get("objectChanges", []):
    if ch.get("type") == "published":
        pkg = ch["packageId"]
    elif ch.get("type") == "created":
        ot = ch.get("objectType", "")
        if "::pool_factory::FactoryRegistry" in ot:
            factory = ch["objectId"]
        elif "::pool_factory::OriginCap" in ot:
            origin = ch["objectId"]
        elif "::package::UpgradeCap" in ot:
            upgrade = ch["objectId"]
print(pkg, factory, origin, upgrade)
PY
)"

if [[ -z "$PACKAGE_ID" || -z "$FACTORY_ID" || -z "$ORIGIN_CAP_ID" || -z "$UPGRADE_CAP_ID" ]]; then
    echo "ERROR: failed to extract IDs."
    echo "  PACKAGE_ID=$PACKAGE_ID"
    echo "  FACTORY_ID=$FACTORY_ID"
    echo "  ORIGIN_CAP_ID=$ORIGIN_CAP_ID"
    echo "  UPGRADE_CAP_ID=$UPGRADE_CAP_ID"
    exit 1
fi

echo "  PACKAGE_ID    = $PACKAGE_ID"
echo "  FACTORY_ID    = $FACTORY_ID"
echo "  ORIGIN_CAP_ID = $ORIGIN_CAP_ID"
echo "  UPGRADE_CAP_ID= $UPGRADE_CAP_ID"
echo

# ---------- Tx 2: destroy_cap ----------

echo "==> Tx 2/2: destroy_cap PTB (IRREVERSIBLE)"
sui client ptb \
    --move-call "${PACKAGE_ID}::pool_factory::destroy_cap" \
        "@${ORIGIN_CAP_ID}" \
        "@${FACTORY_ID}" \
        "@${UPGRADE_CAP_ID}" \
        "@0x6" \
    --gas-budget 100000000 \
    --json > "$SEAL_JSON"
echo "  seal JSON saved to $SEAL_JSON"

SEAL_STATUS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("effects",{}).get("status",{}).get("status",""))' "$SEAL_JSON")
if [[ "$SEAL_STATUS" != "success" ]]; then
    echo "ERROR: destroy_cap PTB failed — status=$SEAL_STATUS"
    python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get("effects",{}).get("status",{}),indent=2))' "$SEAL_JSON"
    exit 1
fi
echo "  destroy_cap PTB: success"
echo

# ---------- Verify ----------

echo "==> Verifying is_sealed == true"
sui client object "$FACTORY_ID" --json > "$OUT_DIR/factory.json"
SEAL_FLAG=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("content",{}).get("sealed",""))' "$OUT_DIR/factory.json")
if [[ "$SEAL_FLAG" != "True" ]]; then
    echo "ERROR: factory.sealed is '$SEAL_FLAG', expected True"
    exit 1
fi
echo "  factory.sealed = True ✓"
echo

cat > "$DEPLOY_INFO" <<EOF
# Darbitex Sui — MAINNET deployment
# $(date -u +%Y-%m-%dT%H:%M:%SZ)

ENV=mainnet
DEPLOYER=$ADDR
PACKAGE_ID=$PACKAGE_ID
FACTORY_ID=$FACTORY_ID
ORIGIN_CAP_ID=$ORIGIN_CAP_ID  # destroyed
UPGRADE_CAP_ID=$UPGRADE_CAP_ID  # consumed by package::make_immutable
SEALED=true
EOF
echo "==> Deployment info saved to $DEPLOY_INFO"
cat "$DEPLOY_INFO"
echo
echo "================================================"
echo "  DEPLOY COMPLETE — DARBITEX SUI IS LIVE"
echo "================================================"

#!/usr/bin/env bash
# Darbitex Sui — testnet deploy + seal rehearsal
# Phase A: publish package, capture object IDs, seal via destroy_cap PTB, verify.

set -euo pipefail

cd "$(dirname "$0")/.."

ENV=$(sui client active-env)
if [[ "$ENV" != "testnet" ]]; then
    echo "ERROR: active env is '$ENV', expected 'testnet'. Run: sui client switch --env testnet"
    exit 1
fi

ADDR=$(sui client active-address)
echo "Active address: $ADDR"
echo "Active env:     $ENV"
echo

OUT_DIR="deploy/out"
mkdir -p "$OUT_DIR"
PUBLISH_JSON="$OUT_DIR/publish.json"
SEAL_JSON="$OUT_DIR/seal.json"
DEPLOY_INFO="$OUT_DIR/deployment.txt"

# ---------- Phase A1: publish ----------

echo "==> Tx 1: sui client publish"
sui client publish --gas-budget 500000000 --json --skip-dependency-verification > "$PUBLISH_JSON"
echo "  publish JSON saved to $PUBLISH_JSON"

# Extract object IDs via python (no jq dependency).
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
    echo "ERROR: failed to extract one or more IDs from publish output."
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

# ---------- Phase A2: destroy_cap ----------

echo "==> Tx 2: destroy_cap PTB"
# Signature: destroy_cap(origin: OriginCap, factory: &mut FactoryRegistry, upgrade: UpgradeCap, clock: &Clock, ctx)
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

# ---------- Phase A3: verify ----------

echo "==> Verifying is_sealed == true"
sui client object "$FACTORY_ID" --json > "$OUT_DIR/factory.json"
SEAL_FLAG=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("content",{}).get("sealed",""))' "$OUT_DIR/factory.json")
if [[ "$SEAL_FLAG" != "True" ]]; then
    echo "ERROR: factory.sealed is '$SEAL_FLAG', expected True"
    exit 1
fi
echo "  factory.sealed = True ✓"
echo

# ---------- Save deployment info ----------

cat > "$DEPLOY_INFO" <<EOF
# Darbitex Sui — testnet deployment
# $(date -u +%Y-%m-%dT%H:%M:%SZ)

ENV=testnet
DEPLOYER=$ADDR
PACKAGE_ID=$PACKAGE_ID
FACTORY_ID=$FACTORY_ID
ORIGIN_CAP_ID=$ORIGIN_CAP_ID  # destroyed
UPGRADE_CAP_ID=$UPGRADE_CAP_ID  # destroyed (make_immutable)
SEALED=true
EOF
echo "==> Deployment info saved to $DEPLOY_INFO"
cat "$DEPLOY_INFO"

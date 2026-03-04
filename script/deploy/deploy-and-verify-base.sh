#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source ".env"
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env var: ${name}" >&2
    exit 1
  fi
}

require_var BASE_RPC_URL
require_var BASESCAN_API_KEY
require_var PRIVATE_KEY
require_var RESOLVER_ADDRESS
require_var OWNER_ADDRESS

echo "[deploy] chain check is enforced in script/Deploy.s.sol (must be 8453)"
echo "[deploy] deploying and verifying on BaseScan"

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "${BASE_RPC_URL}" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.basescan.org/api" \
  --etherscan-api-key "${BASESCAN_API_KEY}"

BROADCAST_JSON="broadcast/Deploy.s.sol/8453/run-latest.json"
if [[ -f "${BROADCAST_JSON}" ]]; then
  if command -v jq >/dev/null 2>&1; then
    DEPLOYED_ADDRESS="$(jq -r '.transactions[] | select(.transactionType=="CREATE") | .contractAddress' "${BROADCAST_JSON}" | tail -n 1)"
    if [[ -n "${DEPLOYED_ADDRESS}" && "${DEPLOYED_ADDRESS}" != "null" ]]; then
      echo "[deploy] deployed escrow address: ${DEPLOYED_ADDRESS}"
    fi
  else
    echo "[deploy] broadcast log: ${BROADCAST_JSON}"
  fi
fi

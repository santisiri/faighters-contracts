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

require_var BASESCAN_API_KEY
require_var RESOLVER_ADDRESS
require_var OWNER_ADDRESS

CONTRACT_ADDRESS="${1:-${ESCROW_ADDRESS:-}}"
if [[ -z "${CONTRACT_ADDRESS}" ]]; then
  echo "usage: $0 <escrow_contract_address>" >&2
  echo "or set ESCROW_ADDRESS in .env" >&2
  exit 1
fi

CONSTRUCTOR_ARGS="$(cast abi-encode "constructor(address,address)" "${RESOLVER_ADDRESS}" "${OWNER_ADDRESS}")"

echo "[verify] verifying ${CONTRACT_ADDRESS} on BaseScan"
forge verify-contract \
  --chain-id 8453 \
  --watch \
  --constructor-args "${CONSTRUCTOR_ARGS}" \
  --verifier etherscan \
  --verifier-url "https://api.basescan.org/api" \
  --etherscan-api-key "${BASESCAN_API_KEY}" \
  "${CONTRACT_ADDRESS}" \
  src/FaightersEscrow.sol:FaightersEscrow

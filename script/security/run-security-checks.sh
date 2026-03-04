#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

echo "[security] running invariant/stateful fuzz checks with ffi enabled"
forge test --ffi --match-path "test/invariant/FaightersEscrowInvariant.t.sol" -vv

echo "[security] running slither static analysis"
SLITHER_BIN=""
if command -v slither >/dev/null 2>&1; then
  SLITHER_BIN="$(command -v slither)"
else
  USER_SLITHER_BIN="$(python3 -c 'import os,site; print(os.path.join(site.USER_BASE, "bin", "slither"))')"
  if [[ -x "${USER_SLITHER_BIN}" ]]; then
    SLITHER_BIN="${USER_SLITHER_BIN}"
  fi
fi

if [[ -z "${SLITHER_BIN}" ]]; then
  echo "slither not found. install with: pip3 install --user --break-system-packages slither-analyzer"
  exit 1
fi

"${SLITHER_BIN}" . \
  --filter-paths "lib|test|script|out|cache" \
  --exclude naming-convention,solc-version,low-level-calls

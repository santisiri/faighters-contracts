# Base Deployment and Verification

## 1. Prepare Environment
1. Copy template:
   - `cp .env.example .env`
2. Fill:
   - `BASE_RPC_URL`
   - `BASESCAN_API_KEY`
   - `ETHERSCAN_API_KEY` (set this to the same BaseScan API key value for Foundry trace decoding)
   - `PRIVATE_KEY`
   - `RESOLVER_ADDRESS`
   - `OWNER_ADDRESS`

## 2. Deploy + Verify (Single Command)
```bash
./script/deploy/deploy-and-verify-base.sh
```

This runs:
- `forge script script/Deploy.s.sol:Deploy --broadcast`
- BaseScan verification through `--verifier etherscan --verifier-url https://api.basescan.org/api`

## Trace Configuration Note

Foundry uses the generic "Etherscan" verifier and trace-enrichment path even on Base. That means:

- `BASESCAN_API_KEY` is used by the deployment and verify scripts.
- `ETHERSCAN_API_KEY` should also be set to the same BaseScan API key if you want clean verbose traces in fork tests.

If `ETHERSCAN_API_KEY` is not set, deployment still works, but `forge test -vv` on Base forks may emit:

```text
WARN evm::traces::external: etherscan config not found
```

## 3. Verify Existing Deployment
```bash
./script/deploy/verify-base.sh <ESCROW_ADDRESS>
```

Or set `ESCROW_ADDRESS` in `.env` and run:
```bash
./script/deploy/verify-base.sh
```

## 4. Post-Deploy Validation
1. Confirm owner:
   - `cast call "$ESCROW_ADDRESS" "owner()(address)" --rpc-url "$BASE_RPC_URL"`
2. Confirm resolver:
   - `cast call "$ESCROW_ADDRESS" "resolver()(address)" --rpc-url "$BASE_RPC_URL"`
3. Confirm paused state:
   - `cast call "$ESCROW_ADDRESS" "paused()(bool)" --rpc-url "$BASE_RPC_URL"`
4. Confirm house-cut fee split:
   - `cast call "$ESCROW_ADDRESS" "ownerFeeBps()(uint256)" --rpc-url "$BASE_RPC_URL"`
   - `cast call "$ESCROW_ADDRESS" "resolverFeeBps()(uint256)" --rpc-url "$BASE_RPC_URL"`

## 5. Security Checks
Run before production cutover:
```bash
./script/security/run-security-checks.sh
```

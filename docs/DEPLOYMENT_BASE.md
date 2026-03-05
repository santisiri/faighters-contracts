# Base Deployment and Verification

## 1. Prepare Environment
1. Copy template:
   - `cp .env.example .env`
2. Fill:
   - `BASE_RPC_URL`
   - `BASESCAN_API_KEY`
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

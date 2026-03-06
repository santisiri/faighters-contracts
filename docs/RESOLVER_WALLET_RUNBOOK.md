# FaightersEscrow Resolver Wallet Runbook

## 1. Roles and Wallets
- `OWNER_ADDRESS`: admin wallet (recommended multisig). Controls `setResolver`, `pause`, `unpause`, and `emergencyWithdraw`.
- `RESOLVER_ADDRESS`: operational wallet that calls `createFightFor`, `joinFightFor`, `resolveFight`, and resolver-side `cancelFight`.
- `ESCROW_ADDRESS`: deployed `FaightersEscrow` contract.

Do not use the same private key for owner and resolver in production.

## 2. Required Environment
Use `.env` (copy from `.env.example`) with:
- `BASE_RPC_URL`
- `ESCROW_ADDRESS`
- `OWNER_ADDRESS`
- `RESOLVER_ADDRESS`
- `RESOLVER_PRIVATE_KEY`

Optional for deployment/verification:
- `BASESCAN_API_KEY`
- `ETHERSCAN_API_KEY` (set equal to `BASESCAN_API_KEY` for Base fork trace decoding)
- `PRIVATE_KEY` (deployer)

## 3. Shift Start Checklist (Resolver Operator)
1. Confirm resolver address on-chain:
   - `cast call "$ESCROW_ADDRESS" "resolver()(address)" --rpc-url "$BASE_RPC_URL"`
2. Confirm contract not paused:
   - `cast call "$ESCROW_ADDRESS" "paused()(bool)" --rpc-url "$BASE_RPC_URL"`
3. Ensure resolver wallet has enough ETH for gas on Base.
4. Confirm backend quote service is healthy for `minSairiOut`.
5. If running fork tests or debugging verbose traces, ensure `ETHERSCAN_API_KEY` is present. Without it, Foundry can still execute the tests but external traces from Base contracts are less decoded.

## 4. Fight Preflight Checks
Before any state-changing call:
1. Fetch fight:
   - `cast call "$ESCROW_ADDRESS" "getFight(bytes32)(bytes32,address,uint256,uint256,uint256,address,address,bool,bool,bool,address)" "$FIGHT_ID" --rpc-url "$BASE_RPC_URL"`
2. Validate:
   - `resolved == false`
   - players/winner are expected addresses
   - if deadlines are set, current timestamp has not passed deadline
3. For non-SAIRI resolves with non-zero burn input, compute `minSairiOut` from quote/TWAP with 1% slippage buffer.

## 5. Resolver Procedures

### 5.1 Create Fight On Behalf of User
User must have approved escrow for token spend.

Without deadlines:
```bash
cast send "$ESCROW_ADDRESS" \
  "createFightFor(bytes32,address,uint256,address)" \
  "$FIGHT_ID" "$TOKEN" "$STAKE_AMOUNT" "$PLAYER_A" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

With deadlines:
```bash
cast send "$ESCROW_ADDRESS" \
  "createFightForWithDeadlines(bytes32,address,uint256,address,uint256,uint256)" \
  "$FIGHT_ID" "$TOKEN" "$STAKE_AMOUNT" "$PLAYER_A" "$JOIN_DEADLINE" "$RESOLVE_DEADLINE" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

### 5.2 Join Fight On Behalf of User
User must have approved escrow for token spend.
```bash
cast send "$ESCROW_ADDRESS" \
  "joinFightFor(bytes32,address)" \
  "$FIGHT_ID" "$PLAYER_B" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

### 5.3 Resolve Fight (SAIRI)
```bash
cast send "$ESCROW_ADDRESS" \
  "resolveFight(bytes32,address)" \
  "$FIGHT_ID" "$WINNER" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

### 5.4 Resolve Fight (WETH/USDC/USDT)
```bash
cast send "$ESCROW_ADDRESS" \
  "resolveFight(bytes32,address,uint256)" \
  "$FIGHT_ID" "$WINNER" "$MIN_SAIRI_OUT" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

### 5.5 Cancel Fight (Resolver Path)
```bash
cast send "$ESCROW_ADDRESS" \
  "cancelFight(bytes32)" \
  "$FIGHT_ID" \
  --private-key "$RESOLVER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

## 6. Owner Emergency Procedures

### 6.1 Pause Protocol
1. Owner pauses:
   - `cast send "$ESCROW_ADDRESS" "pause()" --private-key "$OWNER_PRIVATE_KEY" --rpc-url "$BASE_RPC_URL"`
2. Announce incident and stop resolver jobs.
3. Investigate and patch.
4. Owner unpauses when safe:
   - `cast send "$ESCROW_ADDRESS" "unpause()" --private-key "$OWNER_PRIVATE_KEY" --rpc-url "$BASE_RPC_URL"`

### 6.2 Resolver Key Rotation
1. Generate new resolver wallet.
2. Owner sets new resolver:
   - `cast send "$ESCROW_ADDRESS" "setResolver(address)" "$NEW_RESOLVER" --private-key "$OWNER_PRIVATE_KEY" --rpc-url "$BASE_RPC_URL"`
3. Verify:
   - `cast call "$ESCROW_ADDRESS" "resolver()(address)" --rpc-url "$BASE_RPC_URL"`
4. Switch backend signer and disable old key.

### 6.3 Emergency Withdraw
`emergencyWithdraw` only withdraws surplus beyond unresolved-fight reserved liabilities.
```bash
cast send "$ESCROW_ADDRESS" \
  "emergencyWithdraw(address)" \
  "$TOKEN" \
  --private-key "$OWNER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

### 6.4 House-Cut Fee Split Configuration
Owner can configure what portion of the 30% house cut is paid to owner/resolver (remaining portion is burned).

- Values are basis points of the house cut (not total pot).
- Must satisfy: `ownerFeeBps + resolverFeeBps <= 10000`.

Example: 500 / 500 means each gets 5% of house cut.

```bash
cast send "$ESCROW_ADDRESS" \
  "setHouseFeeBps(uint256,uint256)" \
  500 500 \
  --private-key "$OWNER_PRIVATE_KEY" \
  --rpc-url "$BASE_RPC_URL"
```

## 7. Logging and Audit Requirements
For each resolver transaction, record:
- `fightId`
- function called
- token and stake/winner/minOut
- tx hash
- block number
- backend decision reference (AI judge artifact ID)

Retain logs in append-only storage.

## 8. Operational Safety Rules
1. Never resolve a fight without a persisted judge decision.
2. Set non-zero `minSairiOut` for non-SAIRI resolves when burn input is non-zero.
3. If swap failures spike, pause new resolutions and investigate pool/fee routing.
4. If there is any wallet compromise suspicion, rotate resolver immediately and pause if needed.

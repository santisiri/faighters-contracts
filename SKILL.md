---
name: faighters-escrow-deploy
description: Install tooling, validate, deploy, verify, and post-check the FaightersEscrow Foundry project on Base mainnet. Use when the task is to bootstrap this repo, run tests, prepare environment variables, confirm signer and wallet funding, deploy with the existing scripts, verify on BaseScan, or perform resolver/owner operational checks.
---

# FaightersEscrow Deploy Skill

Use this skill when the user wants to:

- install the toolchain for this repository
- clone or bootstrap the repo
- run tests or security checks
- prepare `.env`
- deploy `FaightersEscrow` to Base mainnet
- verify the deployment on BaseScan
- perform post-deploy owner/resolver checks

Keep execution procedural. Ask for missing required information instead of guessing.

## Load Only What You Need

Read these files first:

- `README.md`
- `.env.example`
- `foundry.toml`
- `script/Deploy.s.sol`
- `script/deploy/deploy-and-verify-base.sh`
- `script/deploy/verify-base.sh`

Read these when needed:

- `docs/DEPLOYMENT_BASE.md` for deployment flow
- `docs/RESOLVER_WALLET_RUNBOOK.md` for post-deploy owner/resolver operations
- `docs/CONTRACT_REFERENCE.md` for function-level behavior
- `docs/GOVERNANCE.md` for role and authority boundaries
- `script/security/run-security-checks.sh` for invariant and Slither flow

## Non-Negotiable Rules

- Never print private keys, seed phrases, or secrets.
- Never commit `.env`.
- Never broadcast a mainnet deployment without explicit user confirmation.
- Stop if required inputs are missing.
- Stop if validation fails and diagnose before deployment.
- Prefer dry-run or non-broadcast validation before `--broadcast`.

## Repo Facts

- Network: Base mainnet
- Chain ID: `8453`
- Contract: `src/FaightersEscrow.sol:FaightersEscrow`
- Constructor args:
  - `resolver`
  - `owner`
- Existing deploy script:
  - `./script/deploy/deploy-and-verify-base.sh`
- Existing verify script:
  - `./script/deploy/verify-base.sh`

## Required Inputs

Ask the user for any missing values:

- repo URL, if the repo is not already present
- target branch
- `BASE_RPC_URL`
- `BASESCAN_API_KEY`
- deploy signer access
  - usually `PRIVATE_KEY`
- `RESOLVER_ADDRESS`
- `OWNER_ADDRESS`

Optional but commonly needed:

- `ESCROW_ADDRESS`
- `RESOLVER_PRIVATE_KEY`
- `OWNER_PRIVATE_KEY`

Important:

- `ETHERSCAN_API_KEY` should be set to the same value as `BASESCAN_API_KEY`
- this is needed for clean external trace decoding on Base fork tests

## Step 1: Tooling Check

Check for:

- `git`
- `curl`
- `bash` or `zsh`
- `forge`
- `cast`
- `anvil`
- `jq`

Optional:

- `python3`
- `pip3`
- `slither`

Suggested commands:

```bash
git --version
curl --version
forge --version
cast --version
anvil --version
jq --version
python3 --version
pip3 --version
slither --version
```

If Foundry is missing:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

If `jq` is missing, continue, but note that deploy address extraction from broadcast logs will be less convenient.

If `slither` is missing, do not block deploy by default unless the user asked for full security checks.

## Step 2: Repo Bootstrap

If the repo is not already present:

```bash
git clone <REPO_URL>
cd faighters
git checkout <BRANCH>
git submodule update --init --recursive
```

If already present:

```bash
git status --short
git branch --show-current
git submodule update --init --recursive
```

Build before doing anything else:

```bash
forge build
```

Stop if build fails.

## Step 3: Environment Setup

Initialize environment:

```bash
cp .env.example .env
```

Populate `.env` with:

```dotenv
BASE_RPC_URL=
BASE_CHAIN_ID=8453
BASESCAN_API_KEY=
ETHERSCAN_API_KEY=
PRIVATE_KEY=
RESOLVER_ADDRESS=
OWNER_ADDRESS=
ESCROW_ADDRESS=
RESOLVER_PRIVATE_KEY=
```

Rules:

- `ETHERSCAN_API_KEY` must equal `BASESCAN_API_KEY`
- do not echo secret values back to the user
- if the user does not want to use a local private key, determine whether another signer flow is actually available in the environment
- if no workable signing path exists, stop and explain what is missing

## Step 4: Signer and Wallet Checks

Before deployment, confirm the user has an operational Web3 wallet or signer for Base mainnet.

Determine:

- who is the deployer
- who is the resolver
- who is the owner
- whether owner is an EOA or multisig

If using a local deployer private key, derive the address:

```bash
cast wallet address --private-key "$PRIVATE_KEY"
```

Check deployer Base ETH balance:

```bash
cast balance "<DEPLOYER_ADDRESS>" --rpc-url "$BASE_RPC_URL"
```

Check resolver Base ETH balance:

```bash
cast balance "$RESOLVER_ADDRESS" --rpc-url "$BASE_RPC_URL"
```

If the owner is an EOA that will execute direct admin actions, check owner balance too:

```bash
cast balance "$OWNER_ADDRESS" --rpc-url "$BASE_RPC_URL"
```

Operational expectations:

- deployer must have enough Base ETH to deploy and verify
- resolver must have enough Base ETH for `resolveFight`, `cancelFight`, `createFightFor`, and `joinFightFor`
- owner must have enough Base ETH for `pause`, `unpause`, `setResolver`, `setHouseFeeBps`, and `emergencyWithdraw` if those actions will be sent directly

If balances are low, stop and tell the user before broadcasting.

## Step 5: Validation Before Deploy

Minimum validation:

```bash
forge test -vv
```

If `BASE_RPC_URL` is configured, run fork tests:

```bash
forge test -vv --match-path test/fork/FaightersEscrowBaseFork.t.sol
```

If the user wants the security battery and dependencies exist:

```bash
./script/security/run-security-checks.sh
```

Interpretation:

- unit test failures: stop
- fork test failures: stop unless the user explicitly accepts the risk and the failure is known, understood, and unrelated to the target deploy path
- invariant failures: stop
- missing optional tooling such as Slither: report it and ask whether to proceed

## Step 6: Pre-Broadcast Dry Run

Run the deploy script without broadcast first:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL"
```

Confirm:

- constructor args are correct
- chain is Base mainnet
- no obvious script/config errors appear

Then ask for explicit confirmation before continuing.

## Step 7: Deploy and Verify

Use the repo’s existing deployment path:

```bash
./script/deploy/deploy-and-verify-base.sh
```

If verification is needed later for an existing address:

```bash
./script/deploy/verify-base.sh <ESCROW_ADDRESS>
```

The deploy script expects:

- `BASE_RPC_URL`
- `BASESCAN_API_KEY`
- `PRIVATE_KEY`
- `RESOLVER_ADDRESS`
- `OWNER_ADDRESS`

## Step 8: Extract Deployment Result

Preferred source:

- `broadcast/Deploy.s.sol/8453/run-latest.json`

If `jq` is installed:

```bash
jq -r '.transactions[] | select(.transactionType=="CREATE") | .contractAddress' \
  broadcast/Deploy.s.sol/8453/run-latest.json | tail -n 1
```

Capture and report:

- deployed contract address
- deployment transaction hash
- verification status
- BaseScan link

## Step 9: Post-Deploy Checks

Run:

```bash
cast call "$ESCROW_ADDRESS" "owner()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$ESCROW_ADDRESS" "resolver()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$ESCROW_ADDRESS" "paused()(bool)" --rpc-url "$BASE_RPC_URL"
cast call "$ESCROW_ADDRESS" "ownerFeeBps()(uint256)" --rpc-url "$BASE_RPC_URL"
cast call "$ESCROW_ADDRESS" "resolverFeeBps()(uint256)" --rpc-url "$BASE_RPC_URL"
```

Expected defaults unless changed after deploy:

- `ownerFeeBps = 500`
- `resolverFeeBps = 500`

If values do not match expectations, stop and report clearly.

## Step 10: Operational Facts You Must Preserve

- `owner` and `resolver` should be different addresses
- `owner` should ideally be a multisig
- resolver has adjudication authority over fight outcomes
- `pause` is an emergency control
- `emergencyWithdraw` only withdraws surplus, not liabilities reserved for unresolved fights
- supported tokens are hardcoded
- router address is hardcoded
- winner/house split is hardcoded at `70 / 30`
- only the subdivision of the house cut between owner, resolver, and burn is configurable

## Failure Handling

If something fails, classify it:

### Missing input

Examples:

- missing API key
- missing signer access
- missing resolver/owner address

Action:

- ask the user for the missing value
- do not continue

### Environment/tooling

Examples:

- Foundry missing
- submodules not initialized
- invalid `.env`

Action:

- install or fix the toolchain
- rerun the failed step

### Validation

Examples:

- `forge build` fails
- tests fail
- security checks fail

Action:

- stop
- summarize the failure precisely
- do not deploy until the user approves a fix or the issue is resolved

### Deployment/verification

Examples:

- RPC failure
- insufficient funds
- verification timeout

Action:

- report exact command and failure point
- preserve artifacts
- only retry once the cause is understood

## Final Output Format

At the end of a successful run, report:

- tooling status and versions
- branch and commit used
- whether tests passed
- whether fork tests passed
- whether security checks ran
- deployer, owner, and resolver addresses
- deployer/resolver/owner funding status
- deployment transaction hash
- contract address
- verification status
- BaseScan link
- post-deploy check outputs
- any remaining operational follow-up

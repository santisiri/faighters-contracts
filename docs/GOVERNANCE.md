# FaightersEscrow Governance Reference

This document explains which parts of `FaightersEscrow` are governed, by whom, and with what limits.

It is intended for:

- protocol operators
- multisig signers
- backend/resolver operators
- auditors
- frontend and backend integrators

## 1. Governance Model at a Glance

`FaightersEscrow` does not implement token voting, DAO modules, or an on-chain timelock by itself.

Its governance model is role-based:

- `owner`: protocol administration and emergency controls
- `resolver`: operational adjudication and settlement authority
- `playerA` / `playerB`: per-fight participants who control their own approvals and deposits

In production terms, governance is currently centralized around the `owner` and `resolver` roles.

## 2. The Three Governance Layers

### 2.1 Protocol governance

This is the authority attached to `owner`.

It controls:

- who the resolver is
- how the 30% house cut is split between owner, resolver, and burn
- whether lifecycle actions are paused
- whether non-reserved surplus can be withdrawn
- who the owner is going forward

### 2.2 Adjudication governance

This is the authority attached to `resolver`.

It controls:

- which player is declared winner
- whether an unresolved fight is cancelled
- when backend-assisted create/join flows are executed
- what `minSairiOut` protection is supplied for non-SAIRI resolutions

This is the most trust-sensitive role in the system.

### 2.3 Constitutional policy

Some economic and infrastructure choices are hardcoded.

They are not owner-configurable and cannot be changed without redeploying or upgrading the system:

- supported tokens
- Base token addresses
- Uniswap router address
- Uniswap fee tier
- `WINNER_PCT = 70`
- `HOUSE_PCT = 30`
- burn sink address

## 3. Governance Surface Inventory

### 3.1 Owner-governed functions

The following functions are directly subject to governance through the `owner` role:

- `setResolver(address)`
- `setHouseFeeBps(uint256,uint256)`
- `pause()`
- `unpause()`
- `emergencyWithdraw(address)`
- inherited `transferOwnership(address)`
- inherited `renounceOwnership()`

Effectively, the `owner` governs the protocol's control plane.

### 3.2 Resolver-governed functions

The following functions are subject to resolver discretion:

- `createFightFor(bytes32,address,uint256,address)`
- `createFightForWithDeadlines(bytes32,address,uint256,address,uint256,uint256)`
- `joinFightFor(bytes32,address)`
- `resolveFight(bytes32,address)`
- `resolveFight(bytes32,address,uint256)`
- resolver-side `cancelFight(bytes32)`

The resolver does not change protocol policy, but it does control operational outcomes.

### 3.3 Player-governed actions

Users retain direct control over their own funds and direct participation paths:

- `createFight(...)`
- `createFightWithDeadlines(...)`
- `joinFight(...)`
- player-A-only pre-join `cancelFight(...)`

This is not protocol governance in the usual sense, but it is still an important source of authority in the runtime model.

## 4. Power Matrix

| Surface | Who controls it now | Can be changed after deployment? | How |
|---|---|---|---|
| Resolver address | Owner | Yes | `setResolver` |
| Owner / resolver fee split from house cut | Owner | Yes | `setHouseFeeBps` |
| Pause state | Owner | Yes | `pause` / `unpause` |
| Surplus withdrawals | Owner | Yes | `emergencyWithdraw` |
| Winner selection | Resolver | Per fight | `resolveFight` |
| Resolver-side cancellations | Resolver | Per fight | `cancelFight` |
| Backend-assisted create/join execution | Resolver | Per fight | `createFightFor*`, `joinFightFor` |
| `minSairiOut` value | Resolver | Per fight | resolution call argument |
| Join / resolve deadlines | Fight creator or resolver backend at creation time | Only at creation | `createFightWithDeadlines`, `createFightForWithDeadlines` |
| Supported tokens | Nobody | No | redeploy / upgrade |
| Router address | Nobody | No | redeploy / upgrade |
| Pool fee tier | Nobody | No | redeploy / upgrade |
| Winner/house split 70/30 | Nobody | No | redeploy / upgrade |
| Burn address | Nobody | No | redeploy / upgrade |

## 5. What Governance Can and Cannot Do

### 5.1 What owner governance can do

- replace a compromised resolver
- change the operator economics inside the house cut
- freeze lifecycle activity during an incident
- recover surplus tokens that are not needed to back open fight liabilities
- transfer governance to a new owner address or multisig

### 5.2 What owner governance cannot do

- directly choose winners
- directly rewrite an existing fight's stake amount or participants
- directly withdraw user liabilities from unresolved fights through `emergencyWithdraw`
- change supported token addresses
- change router / pool fee constants
- change the 70/30 base split

### 5.3 What resolver governance can do

- decide and submit fight outcomes
- cancel unresolved fights
- submit transactions on behalf of users if those users approved token allowance
- choose the slippage floor used for non-SAIRI swap-and-burn

### 5.4 What resolver governance cannot do

- pause the protocol
- rotate itself
- change fee policy
- withdraw surplus
- change any hardcoded constants

## 6. Economic Governance

The contract exposes one mutable economic surface:

- `ownerFeeBps`
- `resolverFeeBps`

These values are basis points of the house cut, not basis points of the total pot.

Important consequence:

- the overall pot split remains fixed at `70% winner / 30% house cut`
- governance only decides how the house cut is subdivided

Current default economics:

- owner receives `5%` of house cut
- resolver receives `5%` of house cut
- remaining `90%` of house cut is burned, directly or after swap to SAIRI

This means governance currently controls operator incentives, but not the top-level winner/house split.

## 7. Governance-Sensitive Risk Areas

### 7.1 Resolver centralization

The largest governance risk in this design is resolver trust.

The resolver can:

- determine winners
- decide when to settle
- decide when to cancel unresolved fights

That makes resolver selection, key management, and replacement procedure core governance matters.

### 7.2 Emergency powers

The owner can pause the lifecycle at any time.

This is necessary for incident response, but it is also a governance power that should be clearly assigned and operationally documented.

### 7.3 Surplus withdrawal

`emergencyWithdraw` is bounded by `reservedTokenBalance`, which materially limits governance abuse. That is a strong design decision because it prevents owner governance from draining assets backing open fights.

### 7.4 Hardcoded infrastructure assumptions

Because token addresses, router address, and fee tier are immutable in this version, governance cannot react on-chain if:

- a preferred liquidity pool changes
- router assumptions become stale
- a supported token contract changes behavior

Those are upgrade-governance issues, not runtime-governance issues.

## 8. Recommended Production Governance Structure

### 8.1 Owner

Recommended:

- use a multisig as `owner`
- keep owner cold relative to resolver
- do not use the owner as the day-to-day resolver signer

Reason:

- owner controls pause, resolver rotation, economics, and surplus recovery

### 8.2 Resolver

Recommended:

- use a dedicated hot operational wallet
- isolate it from treasury and owner permissions
- rotate it immediately on compromise
- monitor it closely because it carries adjudication authority

### 8.3 Separation of duties

Recommended:

- `owner` and `resolver` should always be different addresses
- deployer should not be reused as resolver in production
- operational runbooks should require clear approval for resolver rotation and pause actions

## 9. Suggested Governance Policy

If formal governance is introduced around this contract, these actions should usually be governed explicitly:

- appointing or replacing resolver
- changing fee split
- pausing and unpausing protocol
- transferring ownership
- authorizing surplus recovery

These actions should usually not be left ambiguous in operations:

- what evidence is needed for resolver-side cancellation
- how winners are determined off-chain
- how `minSairiOut` is quoted and approved
- when pause may be used
- who can initiate resolver rotation

## 10. What Would Require V2 Governance

These features are governance-worthy but require a new version if you want them to be adjustable:

- token allowlist management
- router replacement
- configurable pool fee tiers
- configurable burn address
- configurable winner / house split
- configurable payout asset for operator fees
- timelocked governance actions
- multi-resolver or committee-based settlement

## 11. Practical Interpretation

If you ask, "what is governed here?", the clean answer is:

- `owner` governs protocol policy and emergency controls
- `resolver` governs adjudication and operations
- some economics and infrastructure are constitutionally fixed in code

That is the actual governance model of `FaightersEscrow` today.

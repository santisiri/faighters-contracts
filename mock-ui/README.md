# FaightersEscrow Mock UI

This is a static interactive simulator for understanding how `FaightersEscrow` behaves.

## Run locally

From repository root:

```bash
python3 -m http.server 8787
```

Open:

- [http://localhost:8787/mock-ui/](http://localhost:8787/mock-ui/)

You can also open `mock-ui/index.html` directly in a browser for quick demo use.

## What it simulates

- Role checks: `owner`, `resolver`, player callers
- Pause/unpause gates
- Configurable house-cut fee split (`setHouseFeeBps`) for owner/resolver funding
- Fight creation and joining
- Optional `joinDeadline` / `resolveDeadline`
- Resolve flow:
  - SAIRI direct burn path
  - non-SAIRI swap-and-burn path with `minSairiOut` and slippage checks
- Cancel rules
- Reserved liabilities and surplus withdrawal logic
- Event stream and invariant watch panel

## Important note

This is a **teaching/simulation UI**, not a wallet-connected dApp. It models the contract logic and state transitions in browser memory.

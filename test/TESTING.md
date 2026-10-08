# Additional launch tests

Run `forge build --offline` and `forge test --offline`. No new dependencies or configuration are required.

`LaunchFailurePaths.t.sol` supplements the existing deployment and audit tests with authorization checks,
failed-launch rollback and same-salt retry, minimum-output checks, malformed payees, rounding dust,
failed ETH/token transfers, distributor restrictions, and curve/hook/escrow failures. Its claim/redeem
property runs 1,000 cases and checks conservation, absence of round-trip profit, and the tax rounding bound.

`LaunchInvariant.t.sol` runs two campaigns, each with 256 sequences of 64 calls and unexpected handler
reverts treated as failures. Explicit selector lists prevent the runner from directly mutating mocks or
ghost state. Deterministic handler sequences also exercise the modeled operations.

- The token campaign interleaves three holders' claims, redemptions, direct donations, owner releases,
  redeem-policy changes, and bridge mint/burn operations. Independent flow totals check both inventories
  and claim/redeem counters. The campaign starts fully backed and includes future bridge supply in its
  ceiling; every operation must preserve that backing. After every sequence, all remaining holders and
  bridgeable supply actually claim. Launch configuration must remain frozen.
- The fee campaign interleaves direct ETH, `addFees`, funded escrow receipts, collection, splitting,
  refused payments, removed-payee retries, duplicate payees, owner changes, and timelock recovery.
  Lifetime allocations must equal each payee's receipts plus its outstanding credit. A separate ETH
  conservation equation includes escrow, contract funds, recipient balances, and recoveries. Timelock
  recovery is allowed to leave credits unfunded; it must not erase them.

The existing fixed-rate Pons mock is reused for offline adapter behavior. It does not model Pons pricing,
CREATE2 branding, graduation swaps, or the live IMDSTR distributor implementation. The restricted-transfer
test injects a dependency revert; it is not a replacement for verifying actual distributor permissions.
The global ceiling and bridge amounts in the invariant harness describe a closed test economy, not a
production supply estimate.

Live validation remains in `PonsLaunch.fork.t.sol`, guarded by `ROBINHOOD_RPC_URL`. The fork launch,
claim/distributor, and fee-split runs are still owed for this test contribution; an offline pass does not
establish live compatibility. The optional vanity miner also skips without its launch configuration.

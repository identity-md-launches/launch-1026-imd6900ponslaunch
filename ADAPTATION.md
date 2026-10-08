# Launch adaptation

The deliverable remains one `IMD6900PonsLaunch` contract. Its nonpayable constructor and argument order are unchanged:

1. Owner: `0x35da9c0303507ddf708e87f2568eddf12c47a059`
2. Pons factory: `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`
3. IMDSTR: `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F`
4. Timelock: `0x16D3f65B708883DF042d98E1C7a49B32A33E2A14`

The constructor still makes no external calls. Brand constants, 590 bps creator tax, forced creator fee recipient,
disabled buyback, default 70% pot / 30% current-owner payees and the timelock's unrestricted ETH recovery role remain.
No extra application, token, proxy, initializer, dependency or manifest was added. Build configuration and vendored
libraries were not changed. No transactions were broadcast.

## Changes and evidence

All five actionable imported findings reproduced against the original contract before production edits. The two
supplied proof tests were copied to scratch: repeated splitting left 0.25 ETH instead of the refused 0.5 ETH, and
renunciation sent 0.3 ETH to zero. Additional scratch reproductions found no reserve left for original holders after
a release and bridge-in, only 90M coin against 100M circulating IMDSTR after recirculation, and adoption of a changed
economics digest without the owner pinning it. These original failing tests are superseded by submitted regressions.

| Finding / requirement | Change and reason | Submitted checks |
|---|---|---|
| `8b95681e2507fce3edb311cad84f70fe1aa5568447ee72f66616f1464fb64fc2` — refused shares | `src/IMD6900PonsLaunch.sol`: assign credits per payee, exclude all unpaid credits from new fees, and retry without reallocating them. `split(address)` retries an old payee after removal; it cannot redirect the payment. Credits are debited before calls and restored on failure. | `test_RefusedFeesSurviveRepeatedSplitsAndNewFees`, `test_RemovedPayeeKeepsItsOwnCredit`, `testFuzz_RefusedCreditAndRoundingAreConserved`, `test_SplitReentrancyCannotSpendACreditTwice` |
| `1b2a857118521e5bdceb5988c45dc3549ef0c0a6d859c95602142b804e94de74` — bridgeable supply | Same source: add an owner-set global `claimSupplyCeiling`, changeable only before launch. `claimReserve()` uses `max(ceiling, local totalSupply) - held IMDSTR`. Unset means releases disabled, not zero claims. Both coin release paths use this reserve. No global supply number is guessed. | `test_ReleaseReservesForFutureBridgeIns`, `test_ReleaseAsEthAlsoReservesForBridgeIns`, `test_CeilingOnlyOwnerBoundedAndFrozenAtLaunch`, `test_UnsetCeilingDisablesBothTokenReleasePaths`, `test_LocalSupplyAbovePinnedCeilingIncreasesReserve`, `test_UnderfundedCeilingAllowsClaimsButNoReleases` |
| `4071328c0cd98520d07f1bacaa4267fafcf23683d5648d9f58bbcc5b738fb420` — zero-address ops | Same source: reject ownership renunciation. Transfers and handovers remain available; the ops default still follows the current owner. Unpaid credits continue to belong to the previous payee. | `test_RenunciationCannotBurnDefaultOpsFees`, `test_DefaultOpsFollowsOwnershipButOldCreditDoesNot` |
| `c05e90b2dfa7338ad7ce37c1f4d50ff23a174654d50d53d2b9aa84bd07b10ef0` — recycled claim rights | Same source: `releaseImdstr` checks remaining coin against the reserve **after** the transfer, atomically reverting an under-backed release. It still requires redeem to be closed. It does not presume that an ordinary transfer burns or bridges tokens. | `test_ReleaseImdstrCannotRecirculateUnbackedClaimRights`, existing redeem/release test, unset/underfunded ceiling tests |
| `c9562396a584b9fddbb00ff9c5cadeeea4afeb7e395cb68bca580dbd41a32cf8` — vacuous economics pin | Same source: require a nonzero digest stored through existing `setMeta`; remove the launch-time preview fallback. `src/IPons.sol` clarifies the pin's timing. | `test_LaunchRequiresEconomicsPinnedBeforehand`, `test_ChangedEconomicsRevertsWithoutLosingOpeningFunds`, live `test_fork_ChangedFeePolicyRejectsPreviouslyPinnedEconomics` |
| Launch must refuse any address other than the mined one | Same source: reject zero `expectedToken`, which previously opted out of checking. The existing launch signature and explicit partial-buy/refund option remain. | `test_LaunchRequiresAnExplicitExpectedAddress`, existing wrong-address and partial-buy/refund tests, live mined-address test |

The additional ETH-credit accounting preserves the timelock's ability to recover **all** held ETH, including assigned
shares. Recovery does not cancel those debts. When it leaves credits unfunded, payouts are limited to available ETH;
future receipts first fund the outstanding credits. This avoids an underflow or silent redistribution after recovery.
`test_TimelockMayRecoverRetainedFeesAndFutureFeesRestoreCredits` and
`test_FullTimelockRecoveryDoesNotUnderflowSplit` check partial/full recovery and replenishment. Existing owner-access
and recovery checks still pass. Rounding dust stays unassigned for the next split. `Split`/the no-argument return value
now report newly allocated ETH before rounding; `Paid` records actual transfers, including retries.

`test/IMD6900PonsLaunch.t.sol` shares its setup through an abstract `LaunchFixture`, permits changing the mock factory's
economics, and pins the mock's known closed 100M supply and reviewed economics before launch. Existing launch calls
now supply a predicted address. Its deployment test also checks the EIP-170 runtime bound. New regressions live in
`test/LaunchAudit.t.sol`; mock addresses and minting are test scaffolding only.

`test/PonsLaunch.fork.t.sol` pins real Pons economics during setup and exercises the live policy-change rejection.
The original local-supply-based release assertion was replaced with the safe, unset-ceiling case: the test does not
pretend Robinhood supply is the global ceiling. The fork still covers launch, first buy, claims with distributor
permissions, fee split, withdrawal before launch and changed branding.

`README.md` and source NatSpec now explain retained credits, supply configuration and inventory limits, mandatory
economics/address pins, actual owner powers and the post-graduation sweep dependency.

## Informational findings and limits

- `4f6f7455e0ba2c8dcdd817b9b411e078adc2f69d23dd9ca9e53e649e7ef461ff`: confirmed. The owner can immediately set
  itself as the sole beneficiary and receive all fees through the split. `test_OwnerCanRouteAllFeesToItself_TrustAssumption`
  reproduces it; the existing handoff test covers successor routing. These requested powers remain. Documentation no
  longer claims that the team cannot receive ETH directly through its chosen split or redirect future creator fees.
- `e5f86909026d5880845f20e76d778dd95e74827f440fbe91c76b53a5d7ab675f`: confirmed by the verified Pons source's
  `sweepPoolFees`, `_requiresTrustedOperator` and `_convertPendingMemecoin`. A creator cannot convert pending memecoin
  fees; the operator needs a nonzero conversion minimum. `test_PoolConversionFailureStillClaimsBookedEscrow` reproduces
  this adapter's failure handling with a mocked hook revert and real mock-escrow ETH. It is not a live graduated-pool
  swap test. The external operator restriction is preserved; documentation now describes harvest as an attempted sweep
  followed by a claim of already-credited ETH. Operators must arrange Pons conversion before expecting those fees.
- `d4e509499fd018e786e09bf57e71adbb448fb6f31ef0a7da6c15a065c320486b`: a prior coverage statement, not a defect.
  This pass read the project sources/tests, protected deployment floor, pinned references and relevant vendored
  ownership, transfer and reentrancy implementations. Verified dependency source corroborates OFT bridge mint/burn
  semantics and the Pons economics check. It does not make the earlier audit's balances or supply figures current.

No actionable finding was dismissed as non-reproducing. The informational findings required accurate documentation,
not removal of the approved owner or external Pons roles.

The global ceiling is an owner trust assumption, **not an on-chain cross-chain supply oracle**. It must include all
potential bridged claims; the local-supply lower bound alone is insufficient. It is frozen at launch, and omitting it
permanently disables releases. The contract still launches and swaps 1:1 without that setting. The opening buy may
not fund every potential holder: setting a ceiling prevents withdrawing needed reserves but does not fill a deficit.
The owner must obtain/deposit enough coin before asserting full backing. The existing claim path remains available
against actual inventory, with no new claim pause or holder restrictions.

Read-only external checks used the repository's public Robinhood RPC (chain ID 4663), plus verified source from
[Sourcify's Pons factory record](https://sourcify.dev/server/v2/contract/4663/0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e?fields=sources)
and [IMDSTR record](https://sourcify.dev/server/v2/contract/4663/0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F?fields=sources).
Those source downloads are review data, not build dependencies. No keys were read or used. Slither and Mythril were
not run; this adaptation is not a replacement for the subsequent independent audit.

## Validation

- `forge build`: passed with the project's unchanged configuration and vendored dependencies. Forge emitted lint
  warnings (including intentional caller-controlled payouts, calls in the bounded payee loop and guarded event
  ordering); no compiler errors. No force-send or new external execution capability was introduced.
- `forge test`: **42 passed, 0 failed**, including 256 fuzz cases for refused-credit conservation. Two opt-in entries
  skipped with an empty environment: the live-fork setup and vanity miner.
- `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract PonsLaunchForkTest`:
  **8 passed, 0 failed**, including the real Pons policy-change mismatch.
- `forge build --sizes`: runtime **16,797 bytes**; creation bytecode **17,154 bytes** (17,282 with four ABI address
  arguments). Both fit their admission limits. `test_FitsOneTransaction`, `test_DeploysOnAFreshChain` and
  `test_PassesTheAdmissionScan` pass; the scan covers creation and deployed code, skipping PUSH operands.
- ABI inspection confirms exactly four `address` constructor arguments in the original order, nonpayable.
- Diff checks confirm no modifications to protected configuration, dependencies or repository control paths.

# IMD6900 on Pons: Identity.MD 6900, launched by the IMD swarm on Robinhood Chain

`IMD6900PonsLaunch` launches Identity.MD 6900 (IMD6900), the brand IMD6900 carries on Ethereum, as a Pons coin on
Robinhood Chain. It is packed so the IMD swarm can deploy it with IMD's `evm_contracts` launch: one contract, four
constructor arguments, a constructor that calls nothing.

It replaces Robinhood's old IMDSTR market:
- The team pulls IMDSTR's old pool first and sends the ETH to this contract.
- The contract launches the coin and spends that ETH on the opening buy, before anyone else can trade it.
- The coin it buys backs a 1:1 swap for the old IMDSTR.
- From then on, the contract is the coin's fee distributor.

## What it does

1. **Holds the opening buy's ETH.** Anyone can send it with a plain transfer. Until the launch, the owner can take
   any of it back with `withdrawEth(to, amount)`, so sending commits nothing.

2. **Carries the brand.** Pons writes the coin's details into it once, at the launch, and nothing can change them
   afterwards. `meta()` returns what would launch now; the owner can correct it with `setMeta` until the launch.

   | | |
   |---|---|
   | name | Identity.MD 6900 |
   | symbol | IMD6900 |
   | logo | https://imd6900.pages.dev/logo.png (the cyborg pepe, hosted by us so it outlives an avatar change) |
   | description | Identity.MD 6900 on Robinhood Chain: the identity.md machine strategy, the meme branch of the IMD swarm. |
   | twitter | https://x.com/IMD6900 |
   | website | https://imd6900.pages.dev |
   | creator tax | 5.9% (with Pons' 1% base fee, 6.9% all in: the Ethereum pool's rate; permanent) |
   | creator fees to | this contract, always (`launch` forces it) |

3. **Launches at a mined address.**
   - As far as Pons is concerned, this contract is the coin's deployer. The coin's vanity address is therefore mined
     for this contract's address, once the swarm has deployed it (`test/MineVanity.t.sol`).
   - `launch(salt, expectedToken, buyEth, minTokensOut)` refuses unless the coin lands at `expectedToken`, so a salt
     mined for other details can never launch the coin somewhere else. A zero expected address is rejected.
   - Before launch, store a reviewed, nonzero `expectedEconomics` in `setMeta`. Obtain it from Pons'
     `previewLaunchEconomics(launchConfigId, address(0))`; launch passes that stored digest unchanged, so a changed
     fee policy or config reverts instead of silently accepting new terms.
   - The opening buy spends `buyEth`; with 0, it spends all the ETH held, including any sent with the call. Whatever
     isn't spent goes back to the owner.
   - As the coin's deployer, the contract pays no snipe tax.

4. **Distributes the fees.**
   - Pons pays the coin's creator fees here: the creator's 70% of the 1% base fee, plus the whole 5.9% tax.
   - The perps pool and its hook pay theirs in with `addFees()`.
   - Anyone can call `harvest(graduatedPoolId)`: it attempts to book Pons' fees, claims credited ETH from Pons'
     escrow, and splits new ETH to the payees. After graduation, token-denominated pool fees require Pons' sweep
     operator to convert them with a nonzero minimum output. A `SweepFailed` event does not stop the escrow claim.
   - Default payees: 70% to PonsPotBridge (`0xc39e…9EDd`, which bridges the ETH to the Ethereum launch hook and into
     IMD6900's NFT pot), 30% ops (the owner).
   - `setPayees` (owner, up to 8 payees, shares summing to 10,000 bps) brings the perps pool in once it exists. The
     plan: 70% pot, 10% perps, 20% ops.
   - A payee that refuses ETH keeps its own `pendingEth` credit for the next split; repeated calls cannot give it
     to other payees. After a payee is removed, anyone can retry `split(payee)`, which pays only that original
     address. `split()` returns new ETH allocated before rounding; dust waits for a later split.
   - Ops follows ownership transfers. Ownership cannot be renounced, preventing a zero-address ops payee.
   - `handOff` passes the creator fees to a successor distributor.

5. **Post-launch ETH uses the split or timelock recovery.** `withdrawEth` closes at launch. The owner still controls
   payees immediately and may allocate 100% to itself, or redirect future Pons creator fees with `handOff`.
   These are explicit trust assumptions, not timelocked actions. The Robinhood timelock retains unrestricted
   `recoverEth(to, amount)` authority over held ETH, including refused shares. Recovery does not erase unpaid
   credits: later fees first replenish those credits before any surplus is split under the current payees.

6. **Backs the 1:1 swap.**
   - `claim(amount)`: old IMDSTR in, the coin out, 1:1. The IMDSTR stays here.
   - `redeem(amount, minOut)`: only while the owner opens it, the coin back to IMDSTR, less a toll (69% to start,
     never above 90%).
   - IMDSTR moves only to and from Robinhood distributors, so claiming opens once the Robinhood timelock calls
     `setDistributor(this, true)`.
   - IMDSTR is an OFT: its Robinhood `totalSupply` can grow when Ethereum holders bridge in. Before launch the
     owner can call `setClaimSupplyCeiling(supply)` with the verified global ceiling in token base units, including
     all bridgeable and in-flight supply. It cannot be changed after launch. No guessed ceiling is supplied.
   - `claimReserve()` uses the greater of that ceiling and current Robinhood supply, less IMDSTR held here.
     `release` / `releaseAsEth` may take only coin above this reserve. If the ceiling is unset, releases of both
     coin and IMDSTR are disabled; claims still work. A ceiling below actual global supply is unsafe even if it
     exceeds local supply, so the owner must verify it before setting it.
   - `releaseImdstr` requires redeem to be closed and enough coin remaining to back the claim rights restored
     by the transfer. Sending claimed IMDSTR out is not assumed to burn or bridge it.
   - A reserve ceiling does not create inventory. The opening buy can acquire less than all potential claims;
     then no coin is releasable and claims remain limited by inventory. Acquire and deposit enough coin before
     promising universal backing. Compare coin held with `claimReserve()` to measure the shortfall when configured.

## The launch (`evm_contracts`, Robinhood Chain, chain id 4663)

One contract, `IMD6900PonsLaunch`, with four constructor arguments, in order:

| | | |
|---|---|---|
| `owner` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` | the team wallet: sends the ETH, launches, can take the ETH back before the launch |
| `factory` | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` | Pons V2's launch factory on Robinhood Chain |
| `imdstr` | `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` | Robinhood's IMDSTR, the old token that swaps 1:1 |
| `timelock` | `0x16D3f65B708883DF042d98E1C7a49B32A33E2A14` | the Robinhood timelock: the only way ETH leaves after the launch besides the split |

## After the swarm's launch (the owner)

1. Pull IMDSTR's old pool (the Robinhood timelock's pull op), then send the ETH to the contract.
2. Check the brand in `meta()` and review Pons' launch terms. Read `previewLaunchEconomics(launchConfigId, address(0))`
   from the configured Pons factory, put the digest in `meta().expectedEconomics`, and call `setMeta` from the owner.
   Recheck after any launch-config change. Separately verify the global IMDSTR ceiling and set it with
   `setClaimSupplyCeiling` before launch if releases will be needed; otherwise they remain disabled permanently.
3. Mine the coin's address for the deployed contract (with `ROBINHOOD_RPC_URL` set):
   `LAUNCH=<address> PREFIX=6900 forge test --match-test test_mine -vv`
4. From the owner: `launch(salt, coin, 0, minTokensOut)`.
5. From the Robinhood timelock: `IMDSTR.setDistributor(<this>, true)`, which opens claims.
6. Once the perps pool exists: `setPayees` to bring it in, and `pool.setFeeSink(<this>)`. Run `harvest` on a timer;
   anyone may call it.

## Admission (what IMD checks, and the tests that check it first)

`forge test` runs offline; the fork tests run with `ROBINHOOD_RPC_URL`.

- `test_DeploysOnAFreshChain`: the constructor stores four addresses and calls nothing, so it deploys where neither
  Pons nor IMDSTR exists.
- `test_FitsOneTransaction`: checks initcode against EIP-3860's 49,152 bytes and deployment with calldata against
  EIP-7825's 2^24 gas. The runtime must also fit EIP-170's 24,576 bytes.
- `test_PassesTheAdmissionScan`: neither the creation code nor the runtime shows CALLCODE, DELEGATECALL or
  SELFDESTRUCT (PUSH data skipped).
  - The constructor stores no strings, so no storage-slot constants trail the creation code as raw data.
  - Payees are paid with a plain call (no force-send, which would need SELFDESTRUCT).
- `test/IMD6900PonsLaunch.t.sol` runs against a stand-in Pons. It covers:
  - ETH comes in and goes back before the launch.
  - The brand is bounded, and frozen at the launch.
  - The launch spends the ETH, refunds the rest, and refuses an address it wasn't mined for.
  - Fees split 70/30 by default and as set; a refusing payee keeps its share.
  - The timelock recovers ETH; the owner can't after the launch.
  - Claims, releases, redeems and the fee hand-off.
- `test/LaunchAudit.t.sol` covers retained shares across retries and payee changes, timelock recovery, rounding,
  reentrancy, ownership, future bridge-ins, recirculated IMDSTR, unset/underfunded ceilings and economics pins.
- `test/PonsLaunch.fork.t.sol` runs against the live Pons on Robinhood:
  - The coin launches at the mined address as Identity.MD 6900 / IMD6900.
  - 2 ETH buys ~526M coins (~53% of the supply) ahead of the next buyer.
  - After 3 ETH of buys, `harvest` sends 70% of the ~0.198 ETH in fees to the pot bridge and 30% to ops.
  - Claims run 1:1 once the contract is a distributor.
  - No release is allowed without a verified global supply ceiling.
  - The ETH comes back if the team doesn't launch.
  - A changed brand mines a different address.
  - A changed live Pons fee policy rejects the previously stored economics digest.

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.

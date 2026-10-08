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
     mined for other details can never launch the coin somewhere else.
   - The opening buy spends `buyEth`; with 0, it spends all the ETH held, including any sent with the call. Whatever
     isn't spent goes back to the owner.
   - As the coin's deployer, the contract pays no snipe tax.

4. **Distributes the fees.**
   - Pons pays the coin's creator fees here: the creator's 70% of the 1% base fee, plus the whole 5.9% tax.
   - The perps pool and its hook pay theirs in with `addFees()`.
   - Anyone can call `harvest(graduatedPoolId)`: it books Pons' fees (`sweepFees`), claims them from Pons' escrow,
     and splits all the ETH held to the payees.
   - Default payees: 70% to PonsPotBridge (`0xc39e…9EDd`, which bridges the ETH to the Ethereum launch hook and into
     IMD6900's NFT pot), 30% ops (the owner).
   - `setPayees` (owner, up to 8 payees, shares summing to 10,000 bps) brings the perps pool in once it exists. The
     plan: 70% pot, 10% perps, 20% ops.
   - A payee that refuses ETH keeps its share here for the next split.
   - `handOff` passes the creator fees to a successor distributor.

5. **Only the timelock can take ETH out after the launch.** After the launch, ETH leaves only through `split` or
   through the Robinhood timelock's `recoverEth(to, amount)`, which is public for the whole 12h delay. The team
   wallet can never take it directly.

6. **Backs the 1:1 swap.**
   - `claim(amount)`: old IMDSTR in, the coin out, 1:1. The IMDSTR stays here.
   - `redeem(amount, minOut)`: only while the owner opens it, the coin back to IMDSTR, less a toll (69% to start,
     never above 90%).
   - IMDSTR moves only to and from Robinhood distributors, so claiming opens once the Robinhood timelock calls
     `setDistributor(this, true)`.
   - `release` / `releaseAsEth`: the owner takes only the coin beyond one for every IMDSTR outside this contract, so
     it can never reach coin a holder could claim. `releaseImdstr` sends the claimed IMDSTR on while `redeem` is
     closed.

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
2. Check `meta()`; correct it with `setMeta` if needed (it is permanent once launched).
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
- `test_FitsOneTransaction`: initcode is 16.4 KB, under EIP-3860's 49,152 bytes. The deploy takes ~4.0M gas with
  calldata, under EIP-7825's 2^24.
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
- `test/PonsLaunch.fork.t.sol` runs against the live Pons on Robinhood:
  - The coin launches at the mined address as Identity.MD 6900 / IMD6900.
  - 2 ETH buys ~526M coins (~53% of the supply) ahead of the next buyer.
  - After 3 ETH of buys, `harvest` sends 70% of the ~0.198 ETH in fees to the pot bridge and 30% to ops.
  - Claims run 1:1 once the contract is a distributor.
  - The release stops at one coin per IMDSTR.
  - The ETH comes back if the team doesn't launch.
  - A changed brand mines a different address.

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.

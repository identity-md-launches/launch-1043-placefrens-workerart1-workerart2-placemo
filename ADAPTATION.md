# Worker Frens launch adaptation

## Scope and result

The launch deploys four contracts through their constructors, in this order, with the factory as `msg.sender` and no
call after:

| Order | Contract | Constructor arguments |
| --- | --- | --- |
| 1 | `PlaceFrens` (`src/FrensPlacement.sol`) | none |
| 2 | `WorkerArt1` (`src/art/WorkerArt.sol`) | none |
| 3 | `WorkerArt2` (`src/art/WorkerArt.sol`) | none |
| 4 | `PlaceModules` (`src/FrensPlacement.sol`) | `$contract:PlaceFrens`, `$contract:WorkerArt1`, `$contract:WorkerArt2` |

All constructors are nonpayable. Every contract with a role belongs to the team wallet
`0x35dA9C0303507ddf708E87F2568EdDf12c47a059` (the collection's owner and governor, the gate's owner); the launch
contracts keep no role. The keeper, relayer and job payee are the brief's pinned values. No manifest, launch token, new
dependency or broadcast was introduced; `foundry.toml`, `remappings`, `lib/` and the art are untouched.

This round is a revision after an independent review. The review's required findings and the imported audit's
reproduced findings are fixed below; three of them had to change the collection, the swapper and the gate, which the
brief had asked to keep byte for byte because their CREATE2 addresses follow from their code. The addresses therefore
moved, with new salts mined so the collection and the swapper still start `0x6900…`:

| | before | now |
| --- | --- | --- |
| IMD6900Frens (Worker Frens) | `0x69006841041E7519fbE54BfF3F506FBDCAbabF09` | `0x69007Ce82E0BF7981780585afF7c597415903547` |
| FrenSwapper | `0x6900d1D4BcF96143C6013AF72F319Ad401e7928a` | `0x6900453deFAc8Bb12eabdcf57CCC5a14E7628AeE` |
| FrenMinter | `0xb83843b6a056f0B4394F7cB83fe018600AEFc245` | `0xBbb2796c9C54330788915990Ba36FDDe6dC198cF` |
| FrenWorkerGate | `0x7701fdCcd014A6ab87f9b59e37786F6c07dbD39E` | `0x3F8d1553Cb71C8B5af013Ce985591d9B9BCD9ce2` |
| FrenPrices | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` | unchanged |

The addresses of the first plan were never deployed, so nothing refers to them on chain. The reasons each byte had to
change are in the next section; the acceptance criteria put a reproduced finding above keeping the code as it was.

## Changes

### `src/frens/IMD6900Frens.sol` (the collection; runtime 24,463 bytes, 113 under EIP-170)

1. **The last fren out stays out** (`_beforeTokenTransfer`, new error `LastFrenOut`). A transfer of a fren into the
   treasury (recycle, or a direct transfer) reverts when it is the last fren out in the world. Required by the review's
   empty-world finding `8e1b7913…` and the audit's `992a6ec3…`: with every fren in the treasury the floor had no owner,
   and the next mint, at the curve's price (0.69 $IMD), took every fee that had arrived meanwhile. The suggested
   quote()-only fix (`out == 0` priced as one share) does not close it: whatever price p the entrant pays, its fren is
   then worth V + p - 0.5 (its own payment joins a floor it wholly owns) and it recycles for V - 0.5 more than it paid;
   `buyTreasury` in that state had the same profit (pay 2V, own 3V). The only sound fix inside the floor's design
   (shares belong to frens out) is to keep one fren out always, so the state cannot arise after the first mint. Before
   the first mint only the governor can mint. Tests: `test_LastFrenOutStaysOut`,
   `test_Fix_LastFrenOutStaysOutSoFeesHaveAnOwner`; `test_UnrevealedFrenSellsAtTheFloor` and
   `test_Audit_OwnerOrGovernorCanBlockAllPeerTransfers` now mint a second fren before recycling, and
   `test_EmptyWorldFloorIsNotFree` (which recycled the only fren) became `test_LastFrenOutStaysOut`.
2. **quote() counts $IMD that arrived since the last buy** (`_unswept()`, shared with `_buyFloor`). Review `f82e06ba…`:
   the mint's own buy swept such $IMD into the floor right after the quote, so a mint just before the sweep recycled at
   a profit. Test `test_QuoteCountsUnsweptImd`; the fork test `test_RefundsJoinTheFloor` still passes.
3. **A lapsed job payment is released** (`_reclaimLapsed`, `_jobsToFloor`, new `releaseLapsedJob`). Review `aed78db6…`
   and audit `0640f0a6…`: a payment approved and never taken stayed approved for good once the request was revealed in
   full, its 0.5 $IMD outside the books. `reveal()` now, when it completes the request, undoes an approval whose deadline
   has passed and credits the 0.5 to the floor; one still valid at the reveal stays IMD's to take (undoing it would fail
   a settlement racing the reveal) and anyone releases it with `releaseLapsedJob` once it lapses. `approveJob` shares the
   same path. Tests: `test_RevealReleasesALapsedPayment`, `test_ReleaseLapsedJobAfterTheReveal`,
   `test_Fix_LapsedJobApprovalIsReleasedByTheReveal`.
4. **NatSpec**: the tier is a snapshot of the minter's bag after paying; only the PoolManager's $IMD is guarded against
   (review `332d19fa…`, see dispositions). Comments only; `bytecode_hash = "none"`, so they change no byte.

### `src/frens/FrenSwapper.sol`

1. **Pulls from `msg.sender`, not the stored `frens`** (`imdToImd6900`). The verifier's static analysis rejected the
   previous attempt on Slither's `arbitrary-send-erc20` (high/high) for `safeTransferFrom(imd, frens, …)`. After the
   `OnlyFrens` check `msg.sender == frens`, so the behaviour is identical; the finding is gone (Slither 0.11.6 run below).
2. **The average moves in proportion to the buy** (`_average`, new constant `FULL_BUY = 50e18`). Review `929ebd85…`:
   any nonzero buy took a full 1/64 step, so dust (1e9 wei of $IMD a block) steered the average that prices every mint.
   Now a buy of 50 $IMD or more (the collection's default `maxImdPerBuy`) takes a full step and a smaller one
   `imdIn / 50 $IMD` of it, still once a block. Steering it means buying the floor a full buy a block at the pushed
   price, every buy going into the holders' reserve. Tests: `test/frens/FrenSwapperAverage.t.sol`; the live-pool fork
   tests still pass.

### `src/frens/FrenWorkerGate.sol`

**The window never overshoots 420** (`spend`, new error `WindowFull(left)`). Review `cdf43704…`: a request of up to 69
at 419 minted was accepted. Test `test_WindowNeverOvershoots`.

### `src/FrensPlacement.sol` (`PlaceModules`, unpinned launch code)

1. **The art must be the exact chunks** (`_chunkHash`, from `WorkerArtIndex.CHUNK_HASHES` as the renderer parses it).
   Review `301734e0…`: a mis-ordered manifest launched a renderer that drew nothing. Now `PlaceFailed()`.
   Test `test_Fix_LaunchRefusesTheWrongArt`.
2. **A pre-placed swapper is taken only at the pool's price** (`_soundSwapper`). Review `1796fede…` and audit
   `ca830bfe…`: anyone could place the exact swapper at its planned address in a block whose pool price they pushed, and
   the launch adopted its skewed average. `PlaceModules` now adopts the swapper it finds only if its average is within
   2x of `spotRate()` (nothing seeded: nothing to check); otherwise it creates its own with a plain `CREATE` from itself,
   an address nobody else can occupy, seeded at the launch block's price, and that one is the frens' swapper
   (`swapper()`). Replacing rather than reverting keeps a pre-placed skewed swapper from griefing the launch into failing
   for the price of one deployment, every time the plan is republished. The same-block front-run of the launch itself
   needs a private relay (README). Tests: `test_Fix_LaunchReplacesASwapperSeededOffASkewedPrice`,
   `test_Fix_LaunchAdoptsASwapperSeededAtThePoolsPrice`, `test_Fix_LaunchsOwnSwapperStartsAtThePoolsPrice`.

`PlaceModules`' initcode is 45,254 bytes (under 49,152) and its creation 9.6M gas (under 2^24); the fresh-chain trace
(`test_FreshChainCallsOnlyContractsCreatedByTheLaunch`, `test_DeploysOnAFreshChain`) and the admission scan
(`test_PassesTheAdmissionScan`) pass unchanged.

### `src/FrensCode.sol`, `src/FrensPlan.sol`, `script/placement/addresses.json`

Regenerated by `forge build && python3 script/placement/gen.py --remine` from the changed sources; new salts mined for
`0x6900…`. `test_CodeIsWhatTheSourcesBuild` and `test_PlanFollowsFromTheCode` prove the data is the sources' own and the
addresses follow from it. `script/placement/gen.py` now also parses the `address<TAB>salt` line this Foundry's
`cast create2` prints (the old `Address:` / `Salt:` form still works).

### `script/frens/DeployFrens.s.sol`

- `setup()` pauses the floor's buys (`setParams(buyDelayBlocks, 0, 0)`) while the collection is not an IMD6900
  distributor, and new `resume()` restores the defaults once it is (it refuses before). Review `2f2114a1…`: a floor buy
  before the timelock's batch filled the reserve with IMD6900 the collection could not pay out, and every `recycle` and
  `buyTreasury` reverted until the batch landed. The README's manual pause is now the script's.
- `placed()` reads the frens, swapper, minter and gate from the launch's `PlaceModules` (`MODULES`) when given, so a
  swapper the launch created itself (above) is the one wired; `FrensPlan`'s addresses otherwise; env overrides as before.

### Tests and docs

- `test/FrensLaunchReview.t.sol`: the three tests that asserted the defects now assert the fixes (`test_Fix_*`), plus
  the wrong-art and swapper-replacement cases; the trust-assumption tests stay.
- `test/frens/FrenSwapperAverage.t.sol` (new), `test/frens/IMD6900Frens.t.sol`, `test/frens/FrenWorkerGate.t.sol`,
  `test/FrensPlacement.t.sol` (the fork road now checks the pause and `resume()`): listed above.
- `README.md`: the addresses, the floor's rules, the swapper fallback, the ordered post-launch steps with `resume()`.

## Review findings

Reproduced and fixed: `1796fede…` (swapper seed), `929ebd85…` (dust-steered average), `2f2114a1…` (pre-batch reserve),
`aed78db6…` (lapsed approval), `f82e06ba…` (unswept $IMD), `301734e0…` (wrong art), `cdf43704…` (window overshoot).

Fixed at the root, proof disputed: `8e1b7913…` (empty world). The defect is closed by `LastFrenOut` (above). The proof
asserts that the sole holder's `recycle` succeeds and then that a mint and recycle in the empty world returns no more
than paid; the first is the step the fix refuses, and the second cannot hold under any price once the state exists (the
arithmetic above). `.imd-responses.json` carries the full reasoning.

Disputed, documented: `332d19fa…` (borrowed bag). Reproduced as described, but the proof requires a request stored at
tier 1 with count 69 while `maxMint[1]` is 6, and it requires the lending call not to revert, so neither a refusal nor a
lower tier can pass it. On substance the tier is a snapshot of what the wallet holds after paying; `balanceOf` cannot
tell a lent identity.md NFT from an owned one, and the one guard the code can give (none of the PoolManager's $IMD) is
there. The NatSpec that promised more is corrected. **Open for the requester**: if renting a bag for one call must not
reach a tier, the mint needs a holding period or custody, which is a redesign the brief did not ask for.

Not changed, recorded: `418fbe76…` (one-step `setGovernor`): the requester's documented handover; `handover()` is
rehearsed on a fork by `test_fork_TheWholeRoad`. `9e7b154f…` (the governor's swapper choice can spend the floor's $IMD):
trust assumption, below.

## Imported audit findings

- `f338bd7a…` setup after deployment: reproduced, kept by the brief (the team wallet runs `setup()`; the renderer is
  created after the collection). `setup()` now also pauses the buys. Trust assumption below.
- `4def4296…` transfer validator / mint closure: reproduced, kept (ERC-721C is the collection's design; the brief asks
  for it as it is; the security adapter says a power the brief asks for stays and is documented). `recycle()` to the
  floor never passes the validator. Trust assumption below.
- `992a6ec3…` empty world: fixed (`LastFrenOut`).
- `0640f0a6…` lapsed approval: fixed.
- `ca830bfe…` swapper seed and dust pace: fixed (the launch's own swapper; proportional steps).
- `364f15a2…` coverage: the fork suites ran this round (below).

## Trust assumptions and open items

- **Governor** (team wallet, then the Ethereum timelock): opens and closes the mint; sets the swapper and the gate with
  no validation, and the floor-buy caps. A swapper of its choosing can take the floor's waiting $IMD through `buyFloor`
  (the IMD6900 reserve has no such path); a swap that reverts leaves that buy's approval to the swapper in place
  (harmless for `FrenSwapper`, `onlyFrens`). `setGovernor` is one step and the owner cannot reassign it.
- **Owner** (team wallet): the renderer until `freezeArt`, the royalty (at most 10%, always to the floor), and the
  transfer validator, which can block holder-to-holder transfers (never the floor's moves).
- **Until `setup()`** the collection has no renderer, swapper or gate and unsealed traits; until the timelock's batch
  the floor waits in $IMD (buys paused by `setup()`; `resume()` after).
- **Tier**: a snapshot of the bag after paying; a bag lent for one call from anywhere but the PoolManager counts.
- **Launch block**: a push of the pool's price in the launch's own block would seed the launch's swapper off it; send the
  launch through a private relay and read `rateAverage()` against `spotRate()` after.
- **Static analysis** (Slither 0.11.6 on `src/`, `lib/`, `test/` and `script/` filtered): the rejected attempt's
  `arbitrary-send-erc20` is gone. Two high-impact / medium-confidence items remain by design: `arbitrary-send-eth` in
  `buyFloorWithEth` (ETH goes to the governor-set swapper, which must receive it) and `reentrancy-balance` in
  `_buyFloor` (balances are read after the swap on purpose; `nonReentrant` guards every entry). The rest are
  medium/low: `incorrect-equality` on `== 0` / `== block.number` checks, `unused-return` on v4 `settle()`/`getSlot0`,
  `uninitialized-local` on accumulators, `missing-zero-check` on constructor arguments the plan fixes.
- The deployer's gas-price policy and the live chunks' hashes beyond this fork's block were not checked here.

## Validation

With the unchanged `foundry.toml` (solc 0.8.30, via-IR, 200 runs, cancun, `bytecode_hash = "none"`), Foundry 1.8.3:

- `forge build --offline`: passes (the existing lint warnings remain).
- `forge test --offline`: 132 passed, 0 failed, 5 skipped (the fork suites without `MAINNET_RPC_URL`).
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract Fork` (block ~26,148,355):
  24 passed, 1 failed. The failure, `IMD6900FrensValidator.fork.t.sol` `test_LiveValidatorGuardsTrades`
  ("OpenSea can sell frens"), fails identically on the untouched commit: Limit Break's live validator answers
  `CallerOrFromMustBeWhitelisted` to the zone-authorized conduit transfer at this block. It is live validator state, not
  this code; it is left for the requester (the collection's security level on the validator is set by its owner).
  The passing 24 include the renderer's byte-for-byte reference renders, the whole road with the pause and `resume()`,
  the swapper and minter on the live pools, and Permit2/x402 settlement.
- The three review proofs, copied under `test/scratch/`: `Proof_1796fede0e5a` passes; `Proof_8e1b79136fd1` and
  `Proof_332d19fad01d` fail for the reasons disputed above.
- Launch limits (`test_FitsOneTransaction`): PlaceFrens 40,822 bytes / 9.3M gas, WorkerArt1 28,472 / 6.4M,
  WorkerArt2 21,869 / 4.9M, PlaceModules 45,254 / 9.6M; all under 49,152 bytes and 2^24 gas. IMD6900Frens runtime
  24,463 bytes.

No external dependency was installed into the repository (Slither was installed on this machine only, for the check
above). Nothing here requires `.imd/reads` or `test/scratch/`.

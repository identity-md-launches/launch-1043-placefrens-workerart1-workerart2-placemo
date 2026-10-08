# IMD6900 Frens: deployed by the IMD swarm on Ethereum, at 0x6900…

The IMD6900 Frens collection, packed so the IMD swarm can deploy it with IMD's `evm_contracts` launch: two contracts,
constructors only, nothing called after. The frens and their floor's swapper land at addresses fixed in advance that
start `0x6900`, and the collection draws with the art the swarm already deployed (FrenRenderer
`0xC92495Adc59d711A89A91cc8D90d8F7d92D075ba`).

| | where it lands on Ethereum |
|---|---|
| IMD6900Frens, the collection (ERC-721, 2222 frens) | `0x69008979a4d59615449961eBC8E40138398e5A23` |
| FrenSwapper, the floor's buys | `0x690009b258b05B8Ab3B607e0409497Eb35D0110f` |
| FrenMinter, minting with ETH | `0xf0C22b6Beb97cAd7A991e078fbBb28873798539C` |
| FrenWorkerGate, the workers' window | `0xdD380c91AE33B7819EFce08BC036aD93627A1103` |
| FrenPrices, the price curve as code | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` |

## How the addresses are fixed

IMD deploys a launch from its own deployer, so nothing it creates directly has an address anyone knows in advance. The
launch's two contracts (`src/FrensPlacement.sol`) therefore create the frens through the standard CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`, the same on every chain), where an address depends only on a salt and
the exact creation code:

- `src/FrensCode.sol`: the five contracts' creation code, as data: exactly what forge builds from `src/frens/` with
  `foundry.toml`'s settings. However IMD compiles the launch itself, the children are these bytes.
- `src/FrensPlan.sol`: their constructor arguments, the mined salts and the addresses that follow.
- `script/placement/gen.py` writes both: `forge build && python3 script/placement/gen.py`.

Anyone can put these exact bytes at these addresses (it is then the very same contract: the team wallet's, with the
same arguments), and the launch takes a contract already there as it is. Where the CREATE2 deployer doesn't exist
(IMD first runs a launch on a fresh chain) the launch creates the same contracts with its own CREATE2 instead, wired the
same, at other addresses.

## The launch (`evm_contracts`, Ethereum, chain id 1)

Two contracts, in order:

1. `PlaceFrens` (no constructor arguments): creates the price table and the collection, for the team wallet
   `0x35dA9C0303507ddf708E87F2568EdDf12c47a059` (owner and governor), with the swarm's keeper and relayer.
2. `PlaceModules` with one argument, `$contract:PlaceFrens`: creates the swapper, the ETH minter and the workers' gate
   for the frens PlaceFrens placed.

Read the addresses from them: `PlaceFrens.frens()`, `prices()`; `PlaceModules.swapper()`, `minter()`, `gate()`.

## After the launch

1. The team wallet sets the collection up (`setup()`: the swarm's art, the swapper and the gate, the launch's trait
   rules, sealed):
   `forge script script/frens/DeployFrens.s.sol --sig "setup()" --rpc-url … --account imdstr-deployer --broadcast`
2. Until IMD6900 whitelists the new address, the floor's buys are paused and the floor waits in $IMD:
   `setParams(1, 0, 0)` from the team wallet. Minting, selling to the floor and buying back all work meanwhile.
3. The Ethereum timelock's batch for the new address (`script/frens/FrensTimelockBatch.s.sol`): the frens become an
   IMD6900 distributor, the swapper trades on the IMD6900/$IMD pool without its fee. Once it lands,
   `setParams(1, 50e18, 0.5 ether)` turns the floor's buys back on and the waiting $IMD becomes IMD6900.
4. The curve's first frens to IMD6900 (`firstFrens`), the opening (`setMintOpen(true)`, then the gate's
   `openPublic()`), and the governor to the timelock (`handover`).

## Admission (what IMD checks, and the tests that check it first)

`forge test` (offline; the fork tests run with `MAINNET_RPC_URL`):

- `test_CodeIsWhatTheSourcesBuild`: `FrensCode` is byte for byte what the sources build.
- `test_PlanFollowsFromTheCode`: every address in `FrensPlan` follows from the code, the arguments and the salt; the
  frens and the swapper start `0x6900`.
- `test_LandsWhereThePlanSays`, `test_SameAddressesWhoeverRunsIt`: the same addresses whoever deploys the launch.
- `test_TakesWhatSomeonePlacedFirst`: the launch still works if someone placed the bytes first.
- `test_DeploysOnAFreshChain`: no CREATE2 deployer and nothing the frens name: the same contracts, wired the same.
- `test_FitsOneTransaction`: each initcode under EIP-3860's 49,152 bytes (40,503 and 21,755), each launch transaction
  under EIP-7825's 2^24 gas (about 8.6M and 4.3M, calldata included), both together too.
- `test_PriceTableIsTheCurve`: the price table deployed is the curve (`script/frens/price/prices.bin`), but for seven
  prices one unit (0.0001 $IMD) up.
- `test_PassesTheAdmissionScan`: no code the launch creates or runs shows CALLCODE, DELEGATECALL or SELFDESTRUCT
  (PUSH data skipped), the price table included (seven prices are 0.0001 $IMD up so its bytes read clean). The two
  launch contracts pass it built with or without via-IR, optimized or not.
- `test/FrensPlacement.t.sol` `FrensPlacementForkTest`, on a mainnet fork: the launch lands at `0x6900…`, the team
  wallet sets it up with the swarm's art, mints the first frens to IMD6900 with ETH, opens; a public minter pays in ETH,
  two frens reveal and draw, one sells to the floor in $IMD; the timelock's batch lands and the floor buys IMD6900; the
  governor goes to the timelock.
- `test/frens/`: the collection's own tests (minting, tiers, reveals, the floor, Permit2 and x402 payments, the
  transfer validator, the workers' gate).

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.

# Worker Frens: deployed by the IMD swarm on Ethereum, at 0x6900…

Worker Frens (wFREN) is a 2222-piece collection of on-chain pixel frens. Five AI agents build each one, layer by layer.
This repository packs it so the IMD swarm can deploy the whole collection with IMD's `evm_contracts` launch: four
contracts deployed through their constructors. The factory makes no initialization calls; the team wallet then
performs the setup described below before minting. The collection and its swapper land at addresses fixed in advance
that start `0x6900`.

| | where it lands on Ethereum |
|---|---|
| Worker Frens, the collection (ERC-721, 2222 frens) | `0x69007Ce82E0BF7981780585afF7c597415903547` |
| FrenSwapper, the floor's buys | `0x6900453deFAc8Bb12eabdcf57CCC5a14E7628AeE` (or the launch's own: `PlaceModules.swapper()`, see below) |
| FrenMinter, minting with ETH | `0xBbb2796c9C54330788915990Ba36FDDe6dC198cF` |
| FrenWorkerGate, the workers' and WL's window | `0x3F8d1553Cb71C8B5af013Ce985591d9B9BCD9ce2` |
| FrenPrices, the price curve as code | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` |
| WorkerFrensRenderer, the art | follows from the launch's two art chunks (`PlaceModules.renderer()`) |

The addresses moved from the plan's first version when the launch review's fixes changed the collection's, the swapper's and
the gate's code (`ADAPTATION.md` lists them); the price table's didn't change.

## The collection

- **Name.** The collection is named Worker Frens, symbol wFREN, and each token is "Worker Fren #N".
- **The art, all on chain.** `WorkerFrensRenderer` draws each fren as an 84x84 8-bit bitmap inside an SVG: its
  background through a window its seed picks, then its face, coat, hat and held item. It reads nine data contracts,
  and checks each one's code hash on every read:
  - the IMD swarm's seven FrenArtChunk contracts, already on Ethereum: each character's 13 faces, the 2 hats and 14 of
    the 15 items, as the artist drew them;
  - `WorkerArt1` and `WorkerArt2`, which this launch deploys: the artist's lab coat (3 coats x 6 shirts), the redrawn
    item06, 12 backgrounds and the palettes. The backgrounds are Clean Lab and Messy Lab in blue, green and red, Tube
    in blue, green, red and yellow, and Wireframe in green and red.

  The 12 backgrounds carry more colours than one 256-colour bitmap palette holds, so the palette is split. Indices
  1-145 are the shared colours, the same for every fren. 146-255 are the fren's background's own: each background
  carries its own palette for that range.
  - An unrevealed fren shows a greyed-out card that flicks through random frens in front of the green tube.
  - `script/art/` holds the art as packed (`data/`, from the art kit's `export_v3.py`) and `chunks.py`, which writes
    `src/art/`.
- **The workers' and WL's window.** Once the mint opens, the next 420 frens (the cheapest left on the curve) go only to
  wallets holding window credits:
  - identity.md holders get one credit per NFT (`claim`);
  - wallets on the owner's WL get the amount listed for them (`claimWl(amount, proof, to)`).

  The WL is a Merkle root over `keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))))`, OpenZeppelin's
  standard tree. The owner sets it (`setWlRoot`) and can replace it at any time. A wallet whose amount goes up later
  claims the difference. The window closes when 420 are minted or when the owner opens the public mint.
- **Every job is paid by its own mint.** Each mint sets 0.50 $IMD aside for its agents' job. The collection's job payee
  is the relayer's payer wallet, which pays IMD. The keeper then takes the request's 0.50 back from the collection
  through IMD's x402 proxy, before the reveal voucher is signed. A payment IMD never took before its deadline is undone
  when the request's reveal completes (or by anyone, `releaseLapsedJob`, if it lapses after), and its 0.50 feeds the floor.
- **The floor.** Every fren out in the world owns an equal share of the floor (the IMD6900 reserve and the $IMD waiting
  to be bought into it); `recycle` sells a fren to the treasury for its share, `buyTreasury` buys one back at twice it.
  A mint never costs less than the floor it joins ($IMD that arrived since the last buy counted), so minting and selling
  straight back never pays. The last fren out in the world stays out (`LastFrenOut`): with every fren in the treasury the
  floor would have no owner, and whoever minted next would take every fee that arrived meanwhile.

## How the addresses are fixed

IMD deploys a launch from its own deployer, so nothing it creates directly has an address anyone knows in advance. The
launch's two contracts (`src/FrensPlacement.sol`) therefore create everything through the standard CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`, the same on every chain), where an address depends only on a salt and
the exact creation code:

- `src/FrensCode.sol` holds the creation code as data, exactly what forge builds from `src/frens/` with
  `foundry.toml`'s settings.
- `src/FrensPlan.sol` holds the constructor arguments, the mined salts and the addresses they give. The renderer has
  a salt but no planned address, because its constructor takes the art chunks' addresses, which come from IMD's
  deployer.
- Regenerate both with `forge build && python3 script/placement/gen.py`. It keeps salts that still fit; `--remine`
  mines new ones.

Anyone can put these exact bytes at these addresses, and the launch takes the contract as it is, with one check: the
swapper's slow price average is seeded from the IMD6900/$IMD pool's price in the block that creates it, so one placed in
a block whose price was pushed would make the frens value their floor off that price. `PlaceModules` takes the swapper
at `0x6900453d…` only if its average is the pool's price at the launch (within 2x); otherwise it leaves it there and
creates its own with a plain CREATE (nobody else can put anything at that address), seeded at the launch block's price,
and that one is the frens' swapper: read `PlaceModules.swapper()`, which `setup()` does. The launch itself should go
through a private relay, so nobody can push the price in the launch's own block. On a chain without the CREATE2 deployer
(IMD's fresh-chain run) the launch creates the same contracts with its own CREATE2. `PlaceModules` also refuses to place
the renderer over anything but the two exact art chunks (`PlaceFailed`): a renderer over other code would draw nothing.

## The launch (`evm_contracts`, Ethereum, chain id 1)

1. `PlaceFrens` (no constructor arguments): the price table and the collection, for the team wallet
   `0x35dA9C0303507ddf708E87F2568EdDf12c47a059` (owner and governor).
2. `WorkerArt1` (no constructor arguments): the first half of the new art, as its code.
3. `WorkerArt2` (no constructor arguments): the second half.
4. `PlaceModules`, with three arguments, `$contract:PlaceFrens`, `$contract:WorkerArt1`, `$contract:WorkerArt2`: the
   swapper, the ETH minter, the gate and the renderer.

## After the launch (the team wallet)

1. `setup()` points the collection at the launch's renderer, wires the swapper and the gate (both read from the launch's
   `PlaceModules`), then sets and seals the trait rules. While the collection isn't an IMD6900 distributor yet (the
   batch below) it also pauses the floor's buys (`setParams(_, 0, 0)`): IMD6900 bought before that could never be paid
   out, and every `recycle` and `buyTreasury` would fail on it. The floor waits in $IMD meanwhile.
   `MODULES=<the launch's PlaceModules> forge script script/frens/DeployFrens.s.sol --sig "setup()" --rpc-url … --account imdstr-deployer --broadcast`
2. The WL: `gate.setWlRoot(root)`.
3. The Ethereum timelock's batch for the new address (`script/frens/FrensTimelockBatch.s.sol`): the collection becomes
   an IMD6900 distributor and the swapper trades fee-free. Once it has landed, `resume()` (same script, same env) turns
   the floor's buys back on at the defaults (50 $IMD and 0.25 ETH a buy, one buy a block); it refuses to before.
4. Open: `setMintOpen(true)` starts the workers' and WL's window, and the gate's `openPublic()` ends it early.

## Tests

`forge test` runs offline; the fork tests run with `MAINNET_RPC_URL`.

- `test/FrensLaunchReview.t.sol`: the protected factory's CREATE2 deployment pattern, the team wallet's roles, a trace
  of the fresh-chain constructor calls, and the audit's and the review's findings against the exact placed collection:
  the fixed ones asserted fixed (the last fren out stays out, a lapsed job payment is released, the launch replaces a
  swapper seeded off a pushed price and refuses the wrong art), the trust assumptions that stay asserted as they are
  (the transfer validator, the governor closing the mint). `ADAPTATION.md` lists each.
- `test/FrensPlacement.t.sol`:
  - the code is the sources' own, and the plan follows from it;
  - the addresses are the same whoever deploys, and the launch deploys on a fresh chain;
  - each launch contract fits IMD's limits:

    | | initcode | gas |
    |---|---|---|
    | PlaceFrens | 40.8 KB | 9.3M |
    | WorkerArt1 | 28.5 KB | 6.4M |
    | WorkerArt2 | 21.9 KB | 4.9M |
    | PlaceModules | 45.3 KB | 9.6M |
  - IMD's admission scan is clean for every contract. The art chunks are framed (a PUSH32 byte before every 32 bytes),
    and the renderer keeps its index and code hashes as hex text;
  - every new art entry reads back as exactly `script/art/data`'s bytes, and other code at a chunk's address draws
    nothing;
  - on a mainnet fork:
    - the renderer draws exactly the art kit's reference renders (`script/art/data/expected.json`): seven frens across
      the background kinds and three unrevealed cards, byte for byte;
    - a revealed fren's `tokenURI` reads for about 4M gas, an unrevealed one's for about 13M (under 2^24);
    - the whole road: setup (the floor's buys paused), the first frens with ETH, the opening, an ETH mint, two reveals,
      the floor in $IMD, the timelock batch, `resume()`, the floor in IMD6900, the handover. The metadata reads
      "Worker Fren #N" and says nothing of IMD.
- `test/frens/FrenWorkerGate.t.sol`: the workers' credits, and the WL (listed amounts, once, raised amounts, owner-only
  root, the shared 420, never more than 420).
- `test/frens/FrenSwapperAverage.t.sol`: the swapper's slow average moves a full step for a full buy, next to nothing
  for dust.
- `test/frens/`: the collection's own tests (minting, tiers, reveals, the floor, the last fren out, unswept $IMD, lapsed
  job payments, Permit2 and x402 payments, the transfer validator).

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.

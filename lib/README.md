# Vendored libraries

Only the files this repository imports, so it builds offline.

- `v4-core/`: Uniswap v4 core interfaces, types and libraries (MIT, `v4-core/licenses/MIT_LICENSE`), but
  `libraries/Position.sol` (BUSL-1.1, `v4-core/licenses/BUSL_LICENSE`): `StateLibrary` imports it, for position reads
  nothing here makes, so none of its code is in any contract this deploys.
- `solady/`: `Ownable`, `ERC721`, `ReentrancyGuard`, `SafeTransferLib`, `Base64` (MIT, github.com/Vectorized/solady).
- `openzeppelin-contracts/`: `SignatureChecker`, `Math` and their imports, `IERC20` for the tests (MIT, `openzeppelin-contracts/LICENSE`).
- `forge-std/`: tests and scripts only (MIT / Apache-2.0).

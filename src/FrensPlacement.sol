// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensCode} from "./FrensCode.sol";
import {FrensPlan} from "./FrensPlan.sol";

/// @dev Creates a contract through the standard CREATE2 deployer, so where it lands depends only on the salt and the
///      code (FrensPlan's addresses), not on who runs the launch. Where that deployer doesn't exist (IMD first runs a
///      launch on a fresh chain) it creates the same contract with this contract's own CREATE2: another address, the
///      same contract. If the planned address already holds the contract (anyone can place these exact bytes there,
///      and it is then the very contract this would create), it is used as it is.
abstract contract Placer {
    error PlaceFailed();

    function _place(bytes32 salt, bytes memory init) internal returns (address a) {
        address deployer = FrensPlan.CREATE2_DEPLOYER;
        if (deployer.code.length == 0) {
            assembly ("memory-safe") {
                a := create2(0, add(init, 32), mload(init), salt)
            }
            if (a == address(0)) revert PlaceFailed();
            return a;
        }
        a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(init))))));
        if (a.code.length != 0) return a;
        (bool ok,) = deployer.call(abi.encodePacked(salt, init));
        if (!ok || a.code.length == 0) revert PlaceFailed();
    }
}

/// @title PlaceFrens - the IMD swarm's launch of Worker Frens, part one: the price table and the collection
/// @dev The launch, in order: PlaceFrens, WorkerArt1, WorkerArt2 (src/art/WorkerArt.sol: the new art, as code), then
///      PlaceModules.
/// @notice Its constructor creates the frens' price curve (FrenPrices) and the collection (IMD6900Frens, named Worker
///         Frens) at FrensPlan's addresses (0x6900… for the frens), for the team wallet (owner and governor), with the
///         swarm's keeper and relayer. It calls nothing that existed before it but the CREATE2 deployer, and only if it is
///         there. After the launch the owner wires the frens (script/frens/DeployFrens.s.sol setup()).
contract PlaceFrens is Placer {
    address public immutable prices;
    address public immutable frens;

    constructor() {
        address p = _place(FrensPlan.PRICES_SALT, FrensCode.PRICES);
        prices = p;
        frens = _place(
            FrensPlan.FRENS_SALT,
            abi.encodePacked(
                FrensCode.FRENS,
                abi.encode(
                    FrensPlan.OWNER,
                    FrensPlan.IMD,
                    FrensPlan.IMD6900,
                    FrensPlan.IDENTITY,
                    FrensPlan.PERMIT2,
                    FrensPlan.X402_PROXY,
                    FrensPlan.IMD_PAY_TO,
                    FrensPlan.KEEPER,
                    FrensPlan.RELAYER,
                    p
                )
            )
        );
    }
}

/// @title PlaceModules - the IMD swarm's launch of Worker Frens, part four: the frens' swapper, minter, gate and renderer
/// @notice Its constructor creates, for the frens PlaceFrens placed: the floor's swapper (FrenSwapper, 0x6900…), the
///         ETH mint (FrenMinter), the workers' and WL's window (FrenWorkerGate, the team wallet's) and the art
///         (WorkerFrensRenderer, over the swarm's art already on chain and the two new chunks the launch deploys before
///         this). The launch passes it PlaceFrens and the chunks (`$contract:PlaceFrens`, `$contract:WorkerArt1`,
///         `$contract:WorkerArt2`). All but the renderer land at FrensPlan's addresses; the renderer's follows from the
///         chunks' (read it here: `renderer()`).
contract PlaceModules is Placer {
    address public immutable frens;
    address public immutable swapper;
    address public immutable minter;
    address public immutable gate;
    address public immutable renderer;

    constructor(PlaceFrens placed, address art1, address art2) {
        address f = placed.frens();
        frens = f;
        swapper = _place(
            FrensPlan.SWAPPER_SALT,
            abi.encodePacked(
                FrensCode.SWAPPER,
                abi.encode(FrensPlan.POOL_MANAGER, FrensPlan.IMD, FrensPlan.IMD6900, f, FrensPlan.PAIR_HOOK, FrensPlan.POOL4_HOOK)
            )
        );
        minter = _place(
            FrensPlan.MINTER_SALT,
            abi.encodePacked(FrensCode.MINTER, abi.encode(FrensPlan.POOL_MANAGER, f, FrensPlan.POOL4_HOOK, FrensPlan.PAIR_HOOK))
        );
        gate = _place(
            FrensPlan.GATE_SALT,
            abi.encodePacked(FrensCode.GATE, abi.encode(FrensPlan.OWNER, f, FrensPlan.IDENTITY, FrensPlan.IMD6900))
        );
        renderer = _place(FrensPlan.RENDERER_SALT, abi.encodePacked(FrensCode.RENDERER, abi.encode(art1, art2)));
    }
}

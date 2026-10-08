// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FrensCode} from "../src/FrensCode.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {Placer, PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenPrices} from "../src/frens/FrenPrices.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
import {WorkerFrensRenderer} from "../src/frens/WorkerFrensRenderer.sol";
import {WorkerArt1, WorkerArt2} from "../src/art/WorkerArt.sol";
import {WorkerArtIndex} from "../src/art/WorkerArtIndex.sol";
import {DeployFrens} from "../script/frens/DeployFrens.s.sol";
import {FrensTimelockBatch} from "../script/frens/FrensTimelockBatch.s.sol";
import {FrensRules} from "./frens/FrensRules.sol";

interface ITransferRule {
    function isDistributor(address) external view returns (bool);
}

interface IOwned {
    function owner() external view returns (address);
}

/// @dev What IMD's launch does with `evm_contracts`: the contracts in order from its own deployer, constructors only,
///      a later one given earlier ones' addresses (`$contract:PlaceFrens`, `$contract:WorkerArt1`, …), nothing called after
contract ImdStyleDeployer {
    PlaceFrens public placeFrens;
    address public art1;
    address public art2;
    PlaceModules public placeModules;

    function launch() external {
        placeFrens = new PlaceFrens();
        art1 = address(new WorkerArt1());
        art2 = address(new WorkerArt2());
        placeModules = new PlaceModules(placeFrens, art1, art2);
    }
}

/// @dev The renderer with its art reads open, for the tests
contract RendererProbe is WorkerFrensRenderer {
    constructor(address a1, address a2) WorkerFrensRenderer(a1, a2) {}

    function entry(uint256 i) external view returns (bytes memory) {
        return _entry(i);
    }
}

/// @notice The IMD swarm's launch of the frens (src/FrensPlacement.sol), offline: its code is the sources' own, it
///         lands where FrensPlan says whoever runs it, it deploys on a fresh chain, it fits IMD's limits and passes
///         its admission scan.
contract FrensPlacementTest is Test {
    /// @dev The standard CREATE2 deployer's code (Arachnid's deterministic-deployment-proxy)
    bytes constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    uint256 constant TX_GAS_CAP = 1 << 24; // EIP-7825
    uint256 constant INITCODE_CAP = 49_152; // EIP-3860

    function setUp() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
    }

    function _launch(address imdDeployer) internal returns (PlaceFrens pf, PlaceModules pm) {
        (pf, pm,) = _launchAll(imdDeployer);
    }

    function _launchAll(address imdDeployer) internal returns (PlaceFrens pf, PlaceModules pm, ImdStyleDeployer d) {
        vm.prank(imdDeployer);
        d = new ImdStyleDeployer();
        d.launch();
        (pf, pm) = (d.placeFrens(), d.placeModules());
    }

    function _create2(bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), FrensPlan.CREATE2_DEPLOYER, salt, keccak256(init))))
            )
        );
    }

    function _frensInit(address prices) internal pure returns (bytes memory) {
        return abi.encodePacked(
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
                prices
            )
        );
    }

    /* ── the code and the plan ──────────────────────────────────── */

    function test_CodeIsWhatTheSourcesBuild() public pure {
        assertEq(keccak256(FrensCode.PRICES), keccak256(type(FrenPrices).creationCode), "FrenPrices");
        assertEq(keccak256(FrensCode.FRENS), keccak256(type(IMD6900Frens).creationCode), "IMD6900Frens");
        assertEq(keccak256(FrensCode.SWAPPER), keccak256(type(FrenSwapper).creationCode), "FrenSwapper");
        assertEq(keccak256(FrensCode.MINTER), keccak256(type(FrenMinter).creationCode), "FrenMinter");
        assertEq(keccak256(FrensCode.GATE), keccak256(type(FrenWorkerGate).creationCode), "FrenWorkerGate");
        assertEq(
            keccak256(FrensCode.RENDERER), keccak256(type(WorkerFrensRenderer).creationCode), "WorkerFrensRenderer"
        );
    }

    function test_PlanFollowsFromTheCode() public pure {
        assertEq(FrensPlan.PRICES_AT, _create2(FrensPlan.PRICES_SALT, FrensCode.PRICES), "prices");
        assertEq(FrensPlan.FRENS_AT, _create2(FrensPlan.FRENS_SALT, _frensInit(FrensPlan.PRICES_AT)), "frens");
        address f = FrensPlan.FRENS_AT;
        bytes memory swapperArgs = abi.encode(
            FrensPlan.POOL_MANAGER, FrensPlan.IMD, FrensPlan.IMD6900, f, FrensPlan.PAIR_HOOK, FrensPlan.POOL4_HOOK
        );
        assertEq(
            FrensPlan.SWAPPER_AT,
            _create2(FrensPlan.SWAPPER_SALT, abi.encodePacked(FrensCode.SWAPPER, swapperArgs)),
            "swapper"
        );
        bytes memory minterArgs = abi.encode(FrensPlan.POOL_MANAGER, f, FrensPlan.POOL4_HOOK, FrensPlan.PAIR_HOOK);
        assertEq(
            FrensPlan.MINTER_AT,
            _create2(FrensPlan.MINTER_SALT, abi.encodePacked(FrensCode.MINTER, minterArgs)),
            "minter"
        );
        bytes memory gateArgs = abi.encode(FrensPlan.OWNER, f, FrensPlan.IDENTITY, FrensPlan.IMD6900);
        assertEq(FrensPlan.GATE_AT, _create2(FrensPlan.GATE_SALT, abi.encodePacked(FrensCode.GATE, gateArgs)), "gate");
        assertEq(uint160(FrensPlan.FRENS_AT) >> 144, 0x6900, "the frens start 0x6900");
        assertEq(uint160(FrensPlan.SWAPPER_AT) >> 144, 0x6900, "the swapper starts 0x6900");
    }

    /// @dev The price table the launch deploys is the curve (prices.bin), but for seven prices 0.0001 $IMD up so its
    ///      bytes read clean to the admission scan (prices-swarm.bin)
    function test_PriceTableIsTheCurve() public {
        (PlaceFrens pf,) = _launch(makeAddr("IMD's deployer"));
        bytes memory code = pf.prices().code;
        bytes memory curve = vm.readFileBinary("script/frens/price/prices.bin");
        bytes memory swarm = vm.readFileBinary("script/frens/price/prices-swarm.bin");
        assertEq(code, abi.encodePacked(hex"00", swarm), "the code: a STOP, then prices-swarm.bin");
        uint256 nudged;
        for (uint256 n; n < 2222; ++n) {
            uint256 a =
                uint256(uint8(curve[3 * n])) << 16 | uint256(uint8(curve[3 * n + 1])) << 8 | uint8(curve[3 * n + 2]);
            uint256 b =
                uint256(uint8(swarm[3 * n])) << 16 | uint256(uint8(swarm[3 * n + 1])) << 8 | uint8(swarm[3 * n + 2]);
            if (a != b) {
                assertEq(b, a + 1, "one unit up");
                ++nudged;
            }
        }
        assertEq(nudged, 7);
    }

    /// @dev The script's addresses and the plan's are the same
    function test_PlanMatchesTheScript() public {
        DeployFrens s = new DeployFrens();
        assertEq(FrensPlan.OWNER, s.DEPLOYER());
        assertEq(FrensPlan.IMD, s.IMD());
        assertEq(FrensPlan.IMD6900, s.IMD6900());
        assertEq(FrensPlan.IDENTITY, s.IDENTITY());
        assertEq(FrensPlan.PERMIT2, s.PERMIT2());
        assertEq(FrensPlan.X402_PROXY, s.X402_PROXY());
        assertEq(FrensPlan.IMD_PAY_TO, s.IMD_PAY_TO());
        assertEq(FrensPlan.KEEPER, s.KEEPER());
        assertEq(FrensPlan.RELAYER, s.RELAYER());
        assertEq(FrensPlan.POOL_MANAGER, s.POOL_MANAGER());
        assertEq(FrensPlan.PAIR_HOOK, s.PAIR_HOOK());
        assertEq(FrensPlan.POOL4_HOOK, s.POOL4_HOOK());
    }

    /* ── where it lands ─────────────────────────────────────────── */

    function test_LandsWhereThePlanSays() public {
        (PlaceFrens pf, PlaceModules pm, ImdStyleDeployer d) = _launchAll(makeAddr("IMD's deployer"));
        assertEq(pf.prices(), FrensPlan.PRICES_AT);
        assertEq(pf.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        assertEq(pm.minter(), FrensPlan.MINTER_AT);
        assertEq(pm.gate(), FrensPlan.GATE_AT);
        // the renderer: where the art chunks the launch deployed put it
        bytes memory rendererInit = abi.encodePacked(FrensCode.RENDERER, abi.encode(d.art1(), d.art2()));
        assertEq(pm.renderer(), _create2(FrensPlan.RENDERER_SALT, rendererInit), "renderer");
        _checkWiring(pf, pm);
    }

    function test_SameAddressesWhoeverRunsIt() public {
        uint256 snap = vm.snapshotState();
        (PlaceFrens a,) = _launch(makeAddr("one deployer"));
        address frensA = a.frens();
        vm.revertToState(snap);
        (PlaceFrens b,) = _launch(makeAddr("another deployer"));
        assertTrue(address(a) != address(b), "different launch contracts");
        assertEq(b.frens(), frensA, "the same frens");
        assertEq(frensA, FrensPlan.FRENS_AT);
    }

    /// @dev Anyone can put these exact bytes at the planned addresses first (it is then the very contract the launch
    ///      would make, the team wallet's): the launch takes it as it is
    function test_TakesWhatSomeonePlacedFirst() public {
        (bool ok,) = FrensPlan.CREATE2_DEPLOYER.call(abi.encodePacked(FrensPlan.PRICES_SALT, FrensCode.PRICES));
        assertTrue(ok);
        (ok,) = FrensPlan.CREATE2_DEPLOYER.call(abi.encodePacked(FrensPlan.FRENS_SALT, _frensInit(FrensPlan.PRICES_AT)));
        assertTrue(ok);
        assertGt(FrensPlan.FRENS_AT.code.length, 0);
        (PlaceFrens pf, PlaceModules pm) = _launch(makeAddr("IMD's deployer"));
        assertEq(pf.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        _checkWiring(pf, pm);
    }

    /// @dev IMD first runs a launch on a fresh chain, where neither the CREATE2 deployer nor anything the frens name
    ///      exists: the launch makes the same contracts from its own CREATE2, wired the same
    function test_DeploysOnAFreshChain() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, "");
        assertEq(FrensPlan.IMD.code.length + FrensPlan.POOL_MANAGER.code.length + FrensPlan.IMD6900.code.length, 0);
        (PlaceFrens pf, PlaceModules pm) = _launch(makeAddr("IMD's deployer"));
        assertTrue(pf.frens() != FrensPlan.FRENS_AT, "its own addresses there");
        assertGt(pf.frens().code.length, 0);
        _checkWiring(pf, pm);
    }

    function _checkWiring(PlaceFrens pf, PlaceModules pm) internal view {
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        assertEq(pf.prices().code.length, 1 + 3 * 2222, "the price table is the contract's code");
        bytes memory table = pf.prices().code;
        for (uint256 n; n < 2222; n += 101) {
            uint256 units = uint256(uint8(table[1 + 3 * n])) << 16 | uint256(uint8(table[2 + 3 * n])) << 8
                | uint8(table[3 + 3 * n]);
            assertEq(f.priceOf(n), units * 1e14, "its prices are the table's");
        }
        assertEq(f.priceOf(0), 0.6901e18, "the curve's first price");
        assertEq(f.owner(), FrensPlan.OWNER, "the collection: the team wallet");
        assertEq(f.governor(), FrensPlan.OWNER, "the mechanics: the team wallet, until the timelock");
        assertEq(f.keeper(), FrensPlan.KEEPER);
        assertEq(f.relayer(), FrensPlan.RELAYER);
        assertEq(f.imdPayTo(), FrensPlan.IMD_PAY_TO);
        assertEq(f.imd(), FrensPlan.IMD);
        assertEq(f.imd6900(), FrensPlan.IMD6900);
        assertFalse(f.mintOpen());
        assertFalse(f.traitsSealed());
        assertEq(f.swapper(), address(0), "wired by the team wallet after");
        assertEq(FrenSwapper(payable(pm.swapper())).frens(), address(f));
        assertEq(address(FrenMinter(payable(pm.minter())).frens()), address(f));
        assertEq(FrenMinter(payable(pm.minter())).imd(), FrensPlan.IMD);
        assertEq(FrenWorkerGate(pm.gate()).frens(), address(f));
        assertEq(IOwned(pm.gate()).owner(), FrensPlan.OWNER);
        assertGt(WorkerFrensRenderer(pm.renderer()).art1().code.length, 0, "the art chunks");
        assertGt(WorkerFrensRenderer(pm.renderer()).art2().code.length, 0);
        assertEq(f.name(), "Worker Frens");
        assertEq(f.symbol(), "wFREN");
        assertEq(
            f.imdPayTo(),
            0xC94400e90bB652AFA02740bFf50824E14069c133,
            "every mint's job money pays the relayer's payer back"
        );
        assertEq(pm.frens(), address(f));
    }

    /* ── IMD's limits ───────────────────────────────────────────── */

    /// @dev Each of the launch's four contracts: initcode within EIP-3860, its creation within EIP-7825's 2^24 gas (with
    ///      a creation transaction's own cost on top: 21,000, 32,000, and its calldata at EIP-7623's floor, 40 a byte)
    function test_FitsOneTransaction() public {
        bytes[4] memory init = [
            type(PlaceFrens).creationCode,
            type(WorkerArt1).creationCode,
            type(WorkerArt2).creationCode,
            abi.encodePacked(type(PlaceModules).creationCode, abi.encode(address(1), address(2), address(3)))
        ];
        string[4] memory names = ["PlaceFrens", "WorkerArt1", "WorkerArt2", "PlaceModules"];
        uint256[4] memory used;
        uint256 g = gasleft();
        PlaceFrens pf = new PlaceFrens();
        used[0] = g - gasleft();
        g = gasleft();
        address a1 = address(new WorkerArt1());
        used[1] = g - gasleft();
        g = gasleft();
        address a2 = address(new WorkerArt2());
        used[2] = g - gasleft();
        g = gasleft();
        new PlaceModules(pf, a1, a2);
        used[3] = g - gasleft();
        for (uint256 i; i < 4; ++i) {
            uint256 txGas = used[i] + 53_000 + 40 * init[i].length;
            emit log_named_uint(string.concat(names[i], ": initcode bytes"), init[i].length);
            emit log_named_uint(string.concat(names[i], ": gas"), txGas);
            assertLt(init[i].length, INITCODE_CAP, names[i]);
            assertLt(txGas, TX_GAS_CAP, names[i]);
        }
        assertEq(a1.code.length, 23_332, "the first chunk: a STOP, then its art in 707 frames of 33 bytes");
    }

    function test_PassesTheAdmissionScan() public {
        (PlaceFrens pf, PlaceModules pm, ImdStyleDeployer d) = _launchAll(makeAddr("IMD's deployer"));
        _scan(type(PlaceFrens).creationCode, "PlaceFrens creation code");
        _scan(type(WorkerArt1).creationCode, "WorkerArt1 creation code");
        _scan(type(WorkerArt2).creationCode, "WorkerArt2 creation code");
        _scan(type(PlaceModules).creationCode, "PlaceModules creation code");
        _scan(address(pf).code, "PlaceFrens");
        _scan(d.art1().code, "WorkerArt1");
        _scan(d.art2().code, "WorkerArt2");
        _scan(address(pm).code, "PlaceModules");
        _scan(pf.prices().code, "the price table");
        _scan(pf.frens().code, "IMD6900Frens");
        _scan(pm.swapper().code, "FrenSwapper");
        _scan(pm.minter().code, "FrenMinter");
        _scan(pm.gate().code, "FrenWorkerGate");
        _scan(pm.renderer().code, "WorkerFrensRenderer");
        _scan(FrensCode.RENDERER, "WorkerFrensRenderer creation code");
        _scan(FrensCode.PRICES, "FrenPrices creation code");
        _scan(FrensCode.FRENS, "IMD6900Frens creation code");
        _scan(FrensCode.SWAPPER, "FrenSwapper creation code");
        _scan(FrensCode.MINTER, "FrenMinter creation code");
        _scan(FrensCode.GATE, "FrenWorkerGate creation code");
    }

    /* ── the new art ────────────────────────────────────────────── */

    /// @dev Every entry in the launch's two chunks reads back as exactly the art kit's bytes (script/art/data); the
    ///      swarm's entries are on Ethereum (the fork tests read those)
    function test_NewArtReadsBackExactly() public {
        RendererProbe r = new RendererProbe(address(new WorkerArt1()), address(new WorkerArt2()));
        string memory d = "script/art/data/";
        assertEq(r.entry(WorkerArtIndex.COAT), vm.readFileBinary(string.concat(d, "layers/coat.bin")), "the coat");
        assertEq(r.entry(WorkerArtIndex.ITEM0 + 5), vm.readFileBinary(string.concat(d, "layers/item5.bin")), "item06");
        for (uint256 b; b < 12; ++b) {
            assertEq(
                r.entry(WorkerArtIndex.BG0 + b),
                vm.readFileBinary(string.concat(d, "layers/bg", vm.toString(b), ".bin")),
                "a background"
            );
        }
        assertEq(
            r.entry(WorkerArtIndex.PALETTE), vm.readFileBinary(string.concat(d, "shared.bin")), "the shared palette"
        );
        string[12] memory pals = [
            "cleanlab_blue",
            "cleanlab_green",
            "cleanlab_red",
            "messylab_blue",
            "messylab_green",
            "messylab_red",
            "tubeblue",
            "tubegreen",
            "tubered",
            "tubeyellow",
            "wireframe_green",
            "wireframe_red"
        ];
        for (uint256 b; b < 12; ++b) {
            assertEq(
                r.entry(WorkerArtIndex.BGPAL0 + b),
                vm.readFileBinary(string.concat(d, "bgpal/", pals[b], ".bin")),
                "its palette"
            );
        }
        assertEq(WorkerArtIndex.TABLES, vm.readFileBinary(string.concat(d, "tables.bin")), "the tables");
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        r.entry(WorkerArtIndex.ENTRIES);
    }

    /// @dev Other code at a chunk's address draws nothing: every read checks the chunk's code hash
    function test_RefusesOtherArt() public {
        RendererProbe r = new RendererProbe(address(new WorkerArt2()), address(new WorkerArt1())); // swapped
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.entry(WorkerArtIndex.COAT);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        r.entry(0); // the swarm's chunks aren't on this chain
    }

    function test_Attributes() public {
        WorkerFrensRenderer r = new WorkerFrensRenderer(address(1), address(2));
        // pepe, Laser Eyes, Gold lens, Gold coat, Purple shirt, Bobo Hat, Wireframe Red, Bunsen Burner
        uint24 combo = uint24(0 | 12 << 2 | 3 << 6 | 2 << 8 | 5 << 10 | 2 << 13 | 11 << 15 | 15 << 19);
        assertEq(
            r.attributes(combo),
            '[{"trait_type":"Character","value":"Cyborg Pepe"},{"trait_type":"Face","value":"Laser Eyes"},{"trait_type":"Eye","value":"Gold"},{"trait_type":"Coat","value":"Gold"},{"trait_type":"Shirt","value":"Purple"},{"trait_type":"Hat","value":"Bobo Hat"},{"trait_type":"Item","value":"Bunsen Burner"},{"trait_type":"Background","value":"Wireframe Red"}]'
        );
        assertEq(_bgName(r, 0), "Clean Lab Blue");
        assertEq(_bgName(r, 4), "Messy Lab Green");
        assertEq(_bgName(r, 9), "Tube Yellow");
    }

    function _bgName(WorkerFrensRenderer r, uint256 bg) internal pure returns (string memory) {
        bytes memory a = bytes(r.attributes(uint24(bg << 15)));
        bytes memory key = bytes('"Background","value":"');
        uint256 s;
        for (uint256 i; i + key.length <= a.length; ++i) {
            if (keccak256(_cut(a, i, key.length)) == keccak256(key)) s = i + key.length;
        }
        uint256 e = s;
        while (a[e] != '"') ++e;
        return string(_cut(a, s, e - s));
    }

    function _cut(bytes memory b, uint256 s, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[s + i];
        }
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }
}

/// @notice On a mainnet fork, the whole road: IMD's launch puts the frens at 0x6900… (Ethereum has the CREATE2
///         deployer), the renderer draws exactly what the art kit's reference draws (the swarm's chunks already there,
///         the launch's two new ones), the team wallet sets the frens up, mints the curve's first frens to IMD6900 with
///         ETH, opens the mint, a public minter pays in ETH, a fren reveals and draws, and the floor waits in $IMD until
///         the timelock's batch whitelists the new address.
contract FrensPlacementForkTest is Test, FrensRules {
    DeployFrens s;
    PlaceFrens pf;
    PlaceModules pm;
    IMD6900Frens frens;
    FrenMinter minter;
    FrenWorkerGate gate;
    address constant OWNER = FrensPlan.OWNER;
    uint256 relayerKey = uint256(keccak256("a test relayer"));

    function setUp() public {
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        assertGt(FrensPlan.CREATE2_DEPLOYER.code.length, 0, "Ethereum has the CREATE2 deployer");
        s = new DeployFrens();
        ImdStyleDeployer d = new ImdStyleDeployer();
        d.launch();
        (pf, pm) = (d.placeFrens(), d.placeModules());
        vm.setEnv("MODULES", vm.toString(address(pm)));
        frens = IMD6900Frens(payable(pf.frens()));
        minter = FrenMinter(payable(pm.minter()));
        gate = FrenWorkerGate(pm.gate());
        vm.deal(OWNER, 5 ether);
    }

    function test_fork_LandsAt6900() public view {
        assertEq(address(frens), FrensPlan.FRENS_AT);
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        assertEq(address(minter), FrensPlan.MINTER_AT);
        assertEq(address(gate), FrensPlan.GATE_AT);
        assertEq(uint160(address(frens)) >> 144, 0x6900);
        assertEq(frens.name(), "Worker Frens");
    }

    /// @dev The art kit's reference renders (export_v3.py: script/art/data/expected.json), byte for byte: revealed frens
    ///      over every background kind, both new and swarm layers, and unrevealed cards
    function test_fork_DrawsLikeTheReference() public {
        WorkerFrensRenderer r = WorkerFrensRenderer(pm.renderer());
        string memory j = vm.readFile("script/art/data/expected.json");
        for (uint256 i; i < 7; ++i) {
            string memory k = string.concat(".revealed[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(j, string.concat(k, ".combo")));
            uint256 seed = vm.parseJsonUint(j, string.concat(k, ".seed"));
            bytes32 want = vm.parseJsonBytes32(j, string.concat(k, ".bmpSha256"));
            assertEq(sha256(r.bmp(combo, seed)), want, "a fren as the reference draws it");
            uint256 g = gasleft();
            string memory uri = r.tokenURI(7, combo, seed);
            g -= gasleft();
            emit log_named_uint("tokenURI gas", g);
            assertLt(g, 5_000_000, "a revealed fren reads cheaply");
            assertEq(sha256(_bmpIn(uri)), want, "its metadata shows that bitmap");
        }
        for (uint256 i; i < 3; ++i) {
            string memory k = string.concat(".pending[", vm.toString(i), "]");
            uint256 id = vm.parseJsonUint(j, string.concat(k, ".tokenId"));
            uint256 g = gasleft();
            string memory uri = r.pendingURI(id);
            g -= gasleft();
            emit log_named_uint("pendingURI gas", g);
            assertLt(g, 1 << 24, "an unrevealed card reads within one transaction's gas (EIP-7825)");
            assertEq(sha256(_bmpIn(uri)), vm.parseJsonBytes32(j, string.concat(k, ".bmpSha256")), "an unrevealed card");
        }
    }

    /// @dev Every background, every character, every item draws (each layer's chunk is the one the index names)
    function test_fork_DrawsEveryLayer() public view {
        WorkerFrensRenderer r = WorkerFrensRenderer(pm.renderer());
        for (uint256 i; i < 16; ++i) {
            uint24 combo = uint24(
                (i % 3) | (i % 13) << 2 | (i % 4) << 6 | (i % 3) << 8 | (i % 6) << 10 | (i % 12) << 15 | i << 19
            );
            assertEq(r.bmp(combo, i * 7919).length, 54 + 1024 + 84 * 84);
        }
        for (uint256 h = 1; h < 3; ++h) {
            assertEq(r.canvas(uint24(h << 13), 1).length, 84 * 84);
        }
        assertEq(r.palette(11).length, 1024);
    }

    function test_fork_SetupDrawsWithTheLaunchsArt() public {
        s.setup();
        assertEq(frens.renderer(), pm.renderer());
        assertEq(frens.swapper(), pm.swapper());
        assertEq(frens.workerGate(), address(gate));
        assertTrue(frens.traitsSealed());
        // a new address: not an IMD6900 distributor until the timelock's batch, so setup() paused the floor's buys
        assertFalse(ITransferRule(s.IMD6900()).isDistributor(address(frens)));
        assertEq(frens.maxImdPerBuy(), 0, "floor buys paused until the batch");
        assertEq(frens.maxEthPerBuy(), 0);
        vm.expectRevert(bytes("not an IMD6900 distributor yet: the batch hasn't landed"));
        s.resume();
        // the launch rules, as the other tests set them
        IMD6900Frens ref = new IMD6900Frens(
            address(this),
            s.IMD(),
            s.IMD6900(),
            s.IDENTITY(),
            s.PERMIT2(),
            s.X402_PROXY(),
            s.IMD_PAY_TO(),
            s.KEEPER(),
            s.RELAYER(),
            pf.prices()
        );
        _rules(ref, [uint16(1598), 312, 312]);
        for (uint8 t; t < 8; ++t) {
            for (uint8 v; v < [3, 13, 4, 3, 6, 3, 12, 16][t]; ++v) {
                assertEq(frens.ruleOf(t, v).cap, ref.ruleOf(t, v).cap, "cap");
                assertEq(frens.ruleOf(t, v).minTier, ref.ruleOf(t, v).minTier, "tier");
            }
        }
        assertEq(abi.encode(frens.pairRules()), abi.encode(ref.pairRules()), "pair rules");
    }

    /// @dev Day one at a new address: IMD6900 hasn't whitelisted it (a timelock op), so the floor's buys are paused
    ///      and the floor waits in $IMD; everything else works. Then the batch lands and the $IMD becomes IMD6900.
    function test_fork_TheWholeRoad() public {
        s.setup();
        assertFalse(ITransferRule(s.IMD6900()).isDistributor(address(frens)), "no whitelist yet");
        assertEq(frens.maxImdPerBuy() + frens.maxEthPerBuy(), 0, "setup paused the floor's buys until the batch");

        // the curve's first frens to IMD6900, paid in ETH (FrenMinter buys their $IMD on POOL4)
        uint256 ethBefore = OWNER.balance;
        s.firstFrens(frens, minter, 6, 0.05 ether);
        assertEq(frens.totalMinted(), 6);
        assertEq(frens.balanceOf(s.IMD6900()), 6, "to IMD6900");
        assertGt(OWNER.balance, ethBefore - 0.05 ether, "the ETH not needed came back");
        assertEq(IERC20(s.IMD()).allowance(OWNER, address(frens)), 0);
        assertEq(frens.reserve(), 0);
        assertGt(frens.floorImd(), 0, "the floor waits in $IMD");

        // an unrevealed fren: the card, under the new name, no IMD in the words
        WorkerFrensRenderer art = WorkerFrensRenderer(pm.renderer());
        _checkMeta(frens.tokenURI(1), "Worker Fren #1", _image(art.pendingURI(1)));

        // the opening: the workers' window, then the public, who pay in ETH
        vm.startPrank(OWNER);
        frens.setMintOpen(true);
        gate.openPublic();
        vm.stopPrank();
        address buyer = makeAddr("a public minter");
        vm.deal(buyer, 1 ether);
        deal(s.IMD(), buyer, 70e18); // tier 2: more than one a request (paying in ETH doesn't touch it)
        uint256 cost = frens.quote(2);
        (uint256 ethIn,) = minter.quoteEth(2);
        vm.prank(buyer);
        (uint256 id, uint256 spent) = minter.mintWithEth{value: ethIn * 102 / 100}(2, cost);
        assertEq(spent, ethIn);
        assertEq(frens.balanceOf(buyer), 2);
        assertEq(frens.totalMinted(), 8);

        // a reveal (a test relayer signs, as the swarm's relayer does): the renderer draws it
        (address keeper, address payTo) = (s.KEEPER(), s.IMD_PAY_TO()); // not in the call: they'd use up the prank
        vm.prank(OWNER);
        frens.setRoles(keeper, vm.addr(relayerKey), payTo);
        uint24[] memory combos = new uint24[](2);
        (combos[0], combos[1]) = (_combo(PEPE, 1, 1, 0, 1, 0, 3, 1), _combo(MUMU, 2, 0, 1, 2, 0, 7, 3)); // tier 2's
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s_) =
            vm.sign(relayerKey, frens.voucherDigest(id, combos, "job-1", keccak256("out"), deadline));
        frens.reveal(id, combos, "job-1", keccak256("out"), deadline, abi.encodePacked(r, s_, v), 2);
        assertEq(frens.comboOf(7), combos[0]);
        // revealed: its own drawing, under the new name
        assertEq(_bmpIn(frens.tokenURI(7)), art.bmp(combos[0], frens.seedOf(7)));
        _checkMeta(frens.tokenURI(7), "Worker Fren #7", _image(art.tokenURI(7, combos[0], frens.seedOf(7))));

        // sell one to the floor, in $IMD
        vm.prank(buyer);
        (uint256 paid6900, uint256 paidImd) = frens.recycle(7);
        assertEq(paid6900, 0);
        assertGt(paidImd, 0, "sold for the floor, in $IMD");

        // the timelock's batch for the new address: the floor's buys back on, the waiting $IMD becomes IMD6900
        FrensTimelockBatch b = new FrensTimelockBatch();
        (address[] memory targets,, bytes[] memory datas) = b.batch(address(frens), pm.swapper(), false);
        address timelock = b.TIMELOCK();
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(timelock);
            (bool ok,) = targets[i].call(datas[i]);
            assertTrue(ok, "a batch call failed");
        }
        s.resume();
        assertEq(frens.maxImdPerBuy(), 50e18, "the floor's buys are back on");
        vm.roll(block.number + 2);
        frens.buyFloor(0);
        assertGt(frens.reserve(), 0, "now in IMD6900");

        // the handover: the mechanics to the timelock, the collection stays the team wallet's
        s.handover(frens);
        assertEq(frens.governor(), s.TIMELOCK());
        assertEq(frens.owner(), OWNER);
    }

    /// @dev The metadata names the fren as given, says nothing of IMD, and shows exactly `image`
    function _checkMeta(string memory uri, string memory name, string memory image) internal pure {
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        string memory json = _json(uri);
        assertTrue(_has(json, string.concat('"name":"', name, '"')), "the new name");
        assertFalse(_has(json, "IMD"), "no IMD in the metadata");
        assertEq(keccak256(bytes(_image(uri))), keccak256(bytes(image)), "the renderer's image");
        assertGt(bytes(image).length, 1000);
    }

    /// @dev The bitmap inside a metadata URI's image: JSON, then SVG, then BMP, each base64
    function _bmpIn(string memory uri) internal pure returns (bytes memory) {
        bytes memory img = bytes(_image(uri));
        bytes memory svgPrefix = bytes("data:image/svg+xml;base64,");
        bytes memory svg = Base64.decode(string(_from(img, svgPrefix.length)));
        bytes memory key = bytes("data:image/bmp;base64,");
        uint256 from = _find(svg, key, 0) + key.length;
        uint256 e = _find(svg, bytes('"'), from);
        bytes memory b64 = new bytes(e - from);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = svg[from + i];
        }
        return Base64.decode(string(b64));
    }

    function _from(bytes memory b, uint256 at) internal pure returns (bytes memory out) {
        out = new bytes(b.length - at);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[at + i];
        }
    }

    function _json(string memory uri) internal pure returns (string memory) {
        bytes memory u = bytes(uri);
        bytes memory b64 = new bytes(u.length - 29);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = u[29 + i];
        }
        return string(Base64.decode(string(b64)));
    }

    /// @dev The "image" field of a data-URI metadata
    function _image(string memory uri) internal pure returns (string memory) {
        bytes memory j = bytes(_json(uri));
        bytes memory key = bytes('"image":"');
        uint256 s = _find(j, key, 0) + key.length;
        uint256 e = _find(j, bytes('"'), s);
        bytes memory out = new bytes(e - s);
        for (uint256 i; i < out.length; ++i) {
            out[i] = j[s + i];
        }
        return string(out);
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        return _find(bytes(hay), bytes(needle), 0) != type(uint256).max;
    }

    function _find(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 k; k < needle.length && ok; ++k) {
                ok = hay[i + k] == needle[k];
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _prefix(string memory str, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }
}

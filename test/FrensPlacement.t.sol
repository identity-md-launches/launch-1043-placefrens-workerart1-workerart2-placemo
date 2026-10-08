// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FrensCode} from "../src/FrensCode.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {Placer, PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenPrices} from "../src/frens/FrenPrices.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
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
///      a later one given an earlier one's address (`$contract:PlaceFrens`), nothing called after
contract ImdStyleDeployer {
    PlaceFrens public placeFrens;
    PlaceModules public placeModules;

    function launch() external {
        placeFrens = new PlaceFrens();
        placeModules = new PlaceModules(placeFrens);
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
        vm.prank(imdDeployer);
        ImdStyleDeployer d = new ImdStyleDeployer();
        d.launch();
        (pf, pm) = (d.placeFrens(), d.placeModules());
    }

    function _create2(bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FrensPlan.CREATE2_DEPLOYER, salt, keccak256(init))))));
    }

    function _frensInit(address prices) internal pure returns (bytes memory) {
        return abi.encodePacked(
            FrensCode.FRENS,
            abi.encode(
                FrensPlan.OWNER, FrensPlan.IMD, FrensPlan.IMD6900, FrensPlan.IDENTITY, FrensPlan.PERMIT2, FrensPlan.X402_PROXY,
                FrensPlan.IMD_PAY_TO, FrensPlan.KEEPER, FrensPlan.RELAYER, prices
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
    }

    function test_PlanFollowsFromTheCode() public pure {
        assertEq(FrensPlan.PRICES_AT, _create2(FrensPlan.PRICES_SALT, FrensCode.PRICES), "prices");
        assertEq(FrensPlan.FRENS_AT, _create2(FrensPlan.FRENS_SALT, _frensInit(FrensPlan.PRICES_AT)), "frens");
        address f = FrensPlan.FRENS_AT;
        bytes memory swapperArgs =
            abi.encode(FrensPlan.POOL_MANAGER, FrensPlan.IMD, FrensPlan.IMD6900, f, FrensPlan.PAIR_HOOK, FrensPlan.POOL4_HOOK);
        assertEq(FrensPlan.SWAPPER_AT, _create2(FrensPlan.SWAPPER_SALT, abi.encodePacked(FrensCode.SWAPPER, swapperArgs)), "swapper");
        bytes memory minterArgs = abi.encode(FrensPlan.POOL_MANAGER, f, FrensPlan.POOL4_HOOK, FrensPlan.PAIR_HOOK);
        assertEq(FrensPlan.MINTER_AT, _create2(FrensPlan.MINTER_SALT, abi.encodePacked(FrensCode.MINTER, minterArgs)), "minter");
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
            uint256 a = uint256(uint8(curve[3 * n])) << 16 | uint256(uint8(curve[3 * n + 1])) << 8 | uint8(curve[3 * n + 2]);
            uint256 b = uint256(uint8(swarm[3 * n])) << 16 | uint256(uint8(swarm[3 * n + 1])) << 8 | uint8(swarm[3 * n + 2]);
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
        (PlaceFrens pf, PlaceModules pm) = _launch(makeAddr("IMD's deployer"));
        assertEq(pf.prices(), FrensPlan.PRICES_AT);
        assertEq(pf.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        assertEq(pm.minter(), FrensPlan.MINTER_AT);
        assertEq(pm.gate(), FrensPlan.GATE_AT);
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
            uint256 units = uint256(uint8(table[1 + 3 * n])) << 16 | uint256(uint8(table[2 + 3 * n])) << 8 | uint8(table[3 + 3 * n]);
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
        assertEq(pm.frens(), address(f));
    }

    /* ── IMD's limits ───────────────────────────────────────────── */

    function test_FitsOneTransaction() public {
        bytes memory initFrens = type(PlaceFrens).creationCode;
        bytes memory initModules = abi.encodePacked(type(PlaceModules).creationCode, abi.encode(address(1)));
        assertLt(initFrens.length, INITCODE_CAP, "PlaceFrens' initcode");
        assertLt(initModules.length, INITCODE_CAP, "PlaceModules' initcode");
        uint256 g = gasleft();
        PlaceFrens pf = new PlaceFrens();
        uint256 gasFrens = g - gasleft();
        g = gasleft();
        new PlaceModules(pf);
        uint256 gasModules = g - gasleft();
        // a creation transaction's own cost on top: 21,000, 32,000, and its calldata at EIP-7623's floor (40 a byte)
        uint256 txFrens = gasFrens + 53_000 + 40 * initFrens.length;
        uint256 txModules = gasModules + 53_000 + 40 * initModules.length;
        emit log_named_uint("PlaceFrens: gas", txFrens);
        emit log_named_uint("PlaceModules: gas", txModules);
        assertLt(txFrens, TX_GAS_CAP, "PlaceFrens in one transaction");
        assertLt(txModules, TX_GAS_CAP, "PlaceModules in one transaction");
        assertLt(gasFrens + gasModules + 100_000, TX_GAS_CAP, "even both in one transaction, from a factory");
    }

    function test_PassesTheAdmissionScan() public {
        (PlaceFrens pf, PlaceModules pm) = _launch(makeAddr("IMD's deployer"));
        _scan(type(PlaceFrens).creationCode, "PlaceFrens creation code");
        _scan(type(PlaceModules).creationCode, "PlaceModules creation code");
        _scan(address(pf).code, "PlaceFrens");
        _scan(address(pm).code, "PlaceModules");
        _scan(pf.prices().code, "the price table");
        _scan(pf.frens().code, "IMD6900Frens");
        _scan(pm.swapper().code, "FrenSwapper");
        _scan(pm.minter().code, "FrenMinter");
        _scan(pm.gate().code, "FrenWorkerGate");
        _scan(FrensCode.PRICES, "FrenPrices creation code");
        _scan(FrensCode.FRENS, "IMD6900Frens creation code");
        _scan(FrensCode.SWAPPER, "FrenSwapper creation code");
        _scan(FrensCode.MINTER, "FrenMinter creation code");
        _scan(FrensCode.GATE, "FrenWorkerGate creation code");
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
///         deployer), the team wallet sets them up with the swarm's art, mints the curve's first frens to IMD6900 with
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
        assertEq(frens.name(), "IMD6900 Frens");
    }

    function test_fork_SetupDrawsWithTheSwarmsArt() public {
        s.setup();
        assertEq(frens.renderer(), s.SWARM_RENDERER());
        assertEq(frens.swapper(), pm.swapper());
        assertEq(frens.workerGate(), address(gate));
        assertTrue(frens.traitsSealed());
        // the launch rules, as the other tests set them
        IMD6900Frens ref = new IMD6900Frens(
            address(this), s.IMD(), s.IMD6900(), s.IDENTITY(), s.PERMIT2(), s.X402_PROXY(), s.IMD_PAY_TO(), s.KEEPER(),
            s.RELAYER(), pf.prices()
        );
        _rules(ref, [uint16(1598), 312, 312]);
        for (uint8 t; t < 8; ++t) {
            for (uint8 v; v < [3, 13, 4, 3, 6, 3, 10, 16][t]; ++v) {
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
        vm.prank(OWNER);
        frens.setParams(1, 0, 0); // floor buys paused until the batch

        // the curve's first frens to IMD6900, paid in ETH (FrenMinter buys their $IMD on POOL4)
        uint256 ethBefore = OWNER.balance;
        s.firstFrens(frens, minter, 6, 0.05 ether);
        assertEq(frens.totalMinted(), 6);
        assertEq(frens.balanceOf(s.IMD6900()), 6, "to IMD6900");
        assertGt(OWNER.balance, ethBefore - 0.05 ether, "the ETH not needed came back");
        assertEq(IERC20(s.IMD()).allowance(OWNER, address(frens)), 0);
        assertEq(frens.reserve(), 0);
        assertGt(frens.floorImd(), 0, "the floor waits in $IMD");

        // an unrevealed fren: the swarm renderer's card
        assertEq(bytes(frens.tokenURI(1)).length > 100, true);
        assertEq(_prefix(frens.tokenURI(1), 29), "data:application/json;base64,");

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

        // a reveal (a test relayer signs, as the swarm's relayer does): the swarm's art draws it
        (address keeper, address payTo) = (s.KEEPER(), s.IMD_PAY_TO()); // not in the call: they'd use up the prank
        vm.prank(OWNER);
        frens.setRoles(keeper, vm.addr(relayerKey), payTo);
        uint24[] memory combos = new uint24[](2);
        (combos[0], combos[1]) = (_combo(PEPE, 1, 1, 0, 1, 0, 3, 1), _combo(MUMU, 2, 0, 1, 2, 0, 7, 3)); // tier 2's
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(relayerKey, frens.voucherDigest(id, combos, "job-1", keccak256("out"), deadline));
        frens.reveal(id, combos, "job-1", keccak256("out"), deadline, abi.encodePacked(r, s_, v), 2);
        assertEq(frens.comboOf(7), combos[0]);
        string memory uri = frens.tokenURI(7);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        assertGt(bytes(uri).length, 1000, "the swarm's drawing");

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
        vm.prank(OWNER);
        frens.setParams(1, 50e18, 0.5 ether);
        vm.roll(block.number + 2);
        frens.buyFloor(0);
        assertGt(frens.reserve(), 0, "now in IMD6900");

        // the handover: the mechanics to the timelock, the collection stays the team wallet's
        s.handover(frens);
        assertEq(frens.governor(), s.TIMELOCK());
        assertEq(frens.owner(), OWNER);
    }

    function _prefix(string memory str, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[i];
        return string(out);
    }
}

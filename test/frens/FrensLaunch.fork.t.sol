// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFrens} from "../../script/frens/DeployFrens.s.sol";
import {FrensTimelockBatch} from "../../script/frens/FrensTimelockBatch.s.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenPrices} from "../../src/frens/FrenPrices.sol";
import {FrensLaunch} from "../../src/frens/FrensLaunch.sol";
import {FrenSwapper} from "../../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../../src/frens/FrenWorkerGate.sol";
import {FrenArt, FrenRenderer} from "../../src/frens/FrenRenderer.sol";
import {FrensRules} from "./FrensRules.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @dev What IMD's launch factory does with `evm_contracts`: the contracts in order, one transaction, constructors only
///      (static arguments, `$owner`, `$contract:EarlierName`), nothing called after. It keeps no role in anything.
contract ImdStyleFactory {
    struct Set {
        address prices;
        address launch;
        address frens;
        address swapper;
        address minter;
        address gate;
    }

    function deployAll(address owner, DeployFrens s, uint256 handoverDelay) external returns (Set memory d) {
        d.prices = address(new FrenPrices());
        d.launch = address(new FrensLaunch(owner, s.TIMELOCK(), s.IMD6900(), s.IMD(), handoverDelay));
        d.frens = address(
            new IMD6900Frens(
                owner, d.launch, s.IMD(), s.IMD6900(), s.IDENTITY(), s.PERMIT2(), s.X402_PROXY(), s.IMD_PAY_TO(),
                address(0), address(0), d.prices
            )
        );
        d.swapper = address(new FrenSwapper(s.POOL_MANAGER(), s.IMD(), s.IMD6900(), d.frens, s.PAIR_HOOK(), s.POOL4_HOOK()));
        d.minter = address(new FrenMinter(s.POOL_MANAGER(), d.frens, s.POOL4_HOOK(), s.PAIR_HOOK()));
        d.gate = address(new FrenWorkerGate(owner, d.frens, s.IDENTITY(), s.IMD6900()));
    }
}

/// @notice On a mainnet fork, the launch exactly as IMD runs it: the six contracts deployed in one transaction by a
///         factory that ends up with no role, then the team wallet drives FrensLaunch: setup, the strategy's first 140,
///         the timelock batch, the opening, the handover. Nothing is ever the deployer's.
contract FrensLaunchForkTest is Test, FrensRules {
    DeployFrens s;
    ImdStyleFactory factory;
    ImdStyleFactory.Set d;
    IMD6900Frens frens;
    FrensLaunch launch;
    address team = address(uint160(uint256(keccak256("frens team wallet")))); // fresh: well-known keys carry 7702 code
    address keeper = address(uint160(uint256(keccak256("frens keeper"))));
    address relayer = vm.addr(uint256(keccak256("frens relayer key")));
    uint256 deployGas;
    address payTo; // cached: a call in a pranked call's arguments uses up the prank

    uint256 constant TX_GAS_CAP = 1 << 24; // EIP-7825
    uint256 constant HANDOVER_DELAY = 7 days;

    function setUp() public {
        string memory rpc_ = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        s = new DeployFrens();
        factory = new ImdStyleFactory();
        uint256 g = gasleft();
        d = factory.deployAll(team, s, HANDOVER_DELAY);
        deployGas = g - gasleft();
        frens = IMD6900Frens(payable(d.frens));
        launch = FrensLaunch(payable(d.launch));
        vm.deal(team, 10 ether);
        payTo = s.IMD_PAY_TO();
    }

    function _setup() internal {
        vm.prank(team);
        launch.setup(frens, d.swapper, d.minter, d.gate, keeper, relayer, payTo);
    }

    /// @dev The Ethereum timelock's batch, with the addresses the launch deployed
    function _batch() internal {
        FrensTimelockBatch b = new FrensTimelockBatch();
        (address[] memory targets,, bytes[] memory datas) = b.batch(d.frens, d.swapper);
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(b.TIMELOCK());
            (bool ok,) = targets[i].call(datas[i]);
            assertTrue(ok, "a batch call failed");
        }
    }

    /* ── the deploy ─────────────────────────────────────────────── */

    function test_deploy_fitsOneTransaction() public {
        emit log_named_uint("six contracts, one transaction: gas", deployGas);
        // the six contracts' creation, plus a transaction's base cost and generous calldata, under the per-tx gas cap
        assertLt(deployGas + 21_000 + 1_000_000, TX_GAS_CAP, "IMD deploys the set in one transaction");
        assertEq(d.prices.code.length, 1 + 3 * 2222, "the price table is the contract's code");
    }

    function test_deploy_nothingIsTheDeployers() public view {
        assertEq(frens.owner(), team, "the collection: the team wallet");
        assertEq(frens.governor(), d.launch, "the mechanics: FrensLaunch, until the timelock");
        assertEq(IOwned(d.gate).owner(), team, "the workers' window: the team wallet");
        assertTrue(frens.owner() != address(factory) && frens.governor() != address(factory));
        assertTrue(IOwned(d.gate).owner() != address(factory));
        assertEq(launch.team(), team);
        assertEq(launch.timelock(), s.TIMELOCK());
        assertEq(launch.handoverBy(), block.timestamp + HANDOVER_DELAY);
    }

    /* ── setup ──────────────────────────────────────────────────── */

    function test_setup_wiresAndSealsTheLaunchRules() public {
        _setup();
        assertEq(frens.swapper(), d.swapper);
        assertEq(frens.workerGate(), d.gate);
        assertTrue(frens.traitsSealed());
        IMD6900Frens ref = new IMD6900Frens(
            address(this), address(this), s.IMD(), s.IMD6900(), s.IDENTITY(), s.PERMIT2(), s.X402_PROXY(), s.IMD_PAY_TO(),
            keeper, relayer, d.prices
        );
        _rules(ref, [uint16(1598), 312, 312]);
        for (uint8 t; t < 8; ++t) {
            for (uint8 v; v < [3, 13, 4, 3, 6, 3, 10, 16][t]; ++v) {
                IMD6900Frens.Rule memory a = frens.ruleOf(t, v);
                IMD6900Frens.Rule memory b = ref.ruleOf(t, v);
                assertEq(a.cap, b.cap, "cap");
                assertEq(a.minTier, b.minTier, "tier");
            }
        }
        assertEq(abi.encode(frens.pairRules()), abi.encode(ref.pairRules()), "pair rules");
    }

    function test_setup_onlyTheTeam_once_onlyItsOwnModules() public {
        vm.expectRevert(FrensLaunch.Unauthorized.selector);
        launch.setup(frens, d.swapper, d.minter, d.gate, keeper, relayer, payTo);

        // a swapper built for some other frens is refused
        FrenSwapper other = new FrenSwapper(s.POOL_MANAGER(), s.IMD(), s.IMD6900(), address(0xBEEF), s.PAIR_HOOK(), s.POOL4_HOOK());
        vm.prank(team);
        vm.expectRevert(FrensLaunch.NotOurs.selector);
        launch.setup(frens, address(other), d.minter, d.gate, keeper, relayer, payTo);

        _setup();
        vm.prank(team);
        vm.expectRevert(FrensLaunch.AlreadySetUp.selector);
        launch.setup(frens, d.swapper, d.minter, d.gate, keeper, relayer, payTo);
    }

    /* ── the strategy's first frens, the batch, the opening ─────── */

    function test_first_mints140ToTheStrategy_andReturnsTheRest() public {
        _setup();
        _batch();
        uint256 ethBefore = team.balance;
        vm.prank(team);
        launch.first{value: 0.47 ether}(140);
        assertEq(frens.totalMinted(), 140);
        assertEq(frens.balanceOf(s.IMD6900()), 140, "all 140 to IMD6900");
        assertGt(frens.reserve(), 0, "their price, less the jobs, bought the floor");
        assertEq(d.launch.balance, 0, "no ETH left in FrensLaunch");
        assertEq(IERC20(s.IMD()).balanceOf(d.launch), 0, "no $IMD left in FrensLaunch");
        assertGt(team.balance, ethBefore - 0.47 ether, "what the ETH didn't need came back");
        assertFalse(frens.mintOpen(), "still closed");
    }

    function test_open_onlyOnceTheFloorCanPayOut() public {
        _setup();
        vm.prank(team);
        vm.expectRevert(FrensLaunch.FloorNotLive.selector);
        launch.open();

        _batch();
        vm.prank(team);
        launch.open();
        assertTrue(frens.mintOpen());
        assertTrue(FrenWorkerGate(d.gate).workerWindow(), "the workers' window first");

        // the strategy's own mint path is closed now: requestMintFor checks the gate
        vm.prank(team);
        vm.expectRevert(FrensLaunch.Closed.selector);
        launch.first{value: 0.1 ether}(1);
    }

    function test_publicMint_afterTheTeamOpensThePublic() public {
        _setup();
        _batch();
        vm.startPrank(team);
        launch.open();
        FrenWorkerGate(d.gate).openPublic();
        vm.stopPrank();
        address minter = address(uint160(uint256(keccak256("a public minter"))));
        deal(s.IMD(), minter, 10e18);
        vm.startPrank(minter);
        IERC20(s.IMD()).approve(d.frens, type(uint256).max);
        frens.requestMint(1, type(uint256).max);
        vm.stopPrank();
        assertEq(frens.balanceOf(minter), 1);
    }

    /* ── govern and the handover ────────────────────────────────── */

    function test_govern_passesCalls_butNeverTheGovernor() public {
        _setup();
        vm.prank(team);
        launch.govern(abi.encodeCall(IMD6900Frens.setParams, (2, 50e18, 0.5 ether)));
        assertEq(frens.buyDelayBlocks(), 2);

        vm.prank(team);
        vm.expectRevert(FrensLaunch.UseHandover.selector);
        launch.govern(abi.encodeCall(IMD6900Frens.setGovernor, (team)));

        vm.expectRevert(FrensLaunch.Unauthorized.selector);
        launch.govern(abi.encodeCall(IMD6900Frens.setParams, (3, 50e18, 0.5 ether)));
    }

    function test_handover_teamAnytime_anyoneAfterTheDeadline_thenNothing() public {
        _setup();
        vm.expectRevert(FrensLaunch.Unauthorized.selector);
        launch.handover();

        vm.warp(launch.handoverBy());
        launch.handover(); // anyone, past the deadline
        assertEq(frens.governor(), s.TIMELOCK());
        assertTrue(launch.handedOver());

        vm.startPrank(team);
        vm.expectRevert(FrensLaunch.Closed.selector);
        launch.open();
        vm.expectRevert(FrensLaunch.Closed.selector);
        launch.govern(abi.encodeCall(IMD6900Frens.setParams, (2, 50e18, 0.5 ether)));
        vm.expectRevert(FrensLaunch.Closed.selector);
        launch.handover();
        vm.stopPrank();
        vm.expectRevert(); // FrensLaunch isn't the governor any more
        vm.prank(d.launch);
        frens.setMintOpen(true);
    }

    function test_handover_byTheTeam_beforeTheDeadline() public {
        _setup();
        vm.prank(team);
        launch.handover();
        assertEq(frens.governor(), s.TIMELOCK());
    }

    /* ── the art: the owner's (team), from any deploy ───────────── */

    function test_art_theTeamPointsTheFrensAtArtAnyoneDeployed() public {
        _setup();
        FrenArt art = new FrenArt();
        FrenRenderer r = s.writeArt(art);
        vm.prank(team);
        frens.setRenderer(address(r));
        assertEq(frens.renderer(), address(r));

        vm.prank(address(factory));
        vm.expectRevert();
        frens.setRenderer(address(0xBEEF));
    }
}

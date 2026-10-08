// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {FrensCode} from "../src/FrensCode.sol";
import {Placer, PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {WorkerArt1, WorkerArt2} from "../src/art/WorkerArt.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
import {WorkerFrensRenderer} from "../src/frens/WorkerFrensRenderer.sol";
import {FrensRules} from "./frens/FrensRules.sol";
import {MockToken, NoZeroToken, MockPermit2, MockSwapper} from "./frens/IMD6900Frens.t.sol";

/// @dev The supplied protected probe's constructor-only CREATE2 deployment interface,
///      compiled with this project's pinned compiler. No initialization or forwarding.
contract FrensReviewFactory {
    address private immutable controller = msg.sender;

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        require(msg.sender == controller, "not the harness");
        require(code.length > 0 && code.length <= 49_152, "invalid init code");
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }
}

abstract contract FrensReviewBase is Test {
    bytes internal constant DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function _launch(FrensReviewFactory factory) internal returns (PlaceFrens pf, PlaceModules pm) {
        pf = PlaceFrens(_deploy(factory, "FrensPlacement.sol:PlaceFrens", "", 1));
        address art1 = _deploy(factory, "WorkerArt.sol:WorkerArt1", "", 2);
        address art2 = _deploy(factory, "WorkerArt.sol:WorkerArt2", "", 3);
        pm = PlaceModules(_deploy(factory, "FrensPlacement.sol:PlaceModules", abi.encode(address(pf), art1, art2), 4));
        assertEq(WorkerFrensRenderer(pm.renderer()).art1(), art1);
        assertEq(WorkerFrensRenderer(pm.renderer()).art2(), art2);
    }

    function _deploy(FrensReviewFactory factory, string memory artifact, bytes memory args, uint256 salt)
        internal
        returns (address deployed)
    {
        bytes memory init = abi.encodePacked(vm.getCode(artifact), args);
        deployed = factory.deploy(init, bytes32(salt));
        assertEq(deployed, vm.computeCreate2Address(bytes32(salt), keccak256(init), address(factory)));
        assertLe(deployed.code.length, 24_576, artifact);
    }

    function _checkDependencies(PlaceFrens pf, PlaceModules pm) internal view {
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        assertEq(pm.frens(), address(f));
        assertEq(f.owner(), FrensPlan.OWNER);
        assertEq(f.governor(), FrensPlan.OWNER);
        assertEq(f.keeper(), FrensPlan.KEEPER);
        assertEq(f.relayer(), FrensPlan.RELAYER);
        assertEq(f.priceOf(0), 0.6901e18);
        assertEq(f.name(), "Worker Frens");
        assertEq(f.symbol(), "wFREN");
        assertEq(f.SUPPLY(), 2222);
        assertEq(FrenSwapper(payable(pm.swapper())).frens(), address(f));
        assertEq(address(FrenMinter(payable(pm.minter())).frens()), address(f));
        assertEq(FrenWorkerGate(pm.gate()).frens(), address(f));
        assertEq(FrenWorkerGate(pm.gate()).owner(), FrensPlan.OWNER);
    }
}

contract FrensFactoryReviewTest is FrensReviewBase {
    function test_ProtectedFactoryDeploysAllFourInOrder() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, DEPLOYER_CODE);
        FrensReviewFactory factory = new FrensReviewFactory();
        (PlaceFrens pf, PlaceModules pm) = _launch(factory);
        assertEq(pf.prices(), FrensPlan.PRICES_AT);
        assertEq(pf.frens(), FrensPlan.FRENS_AT);
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        assertEq(pm.minter(), FrensPlan.MINTER_AT);
        assertEq(pm.gate(), FrensPlan.GATE_AT);
        _checkDependencies(pf, pm);

        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        address swapper = pm.swapper();
        address gate = pm.gate();
        address[3] memory launchers = [address(factory), address(pf), address(pm)];
        for (uint256 i; i < launchers.length; ++i) {
            vm.prank(launchers[i]);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setModules(swapper, gate);
            vm.prank(launchers[i]);
            vm.expectRevert(Ownable.Unauthorized.selector);
            FrenWorkerGate(gate).setWlRoot(bytes32(uint256(1)));
        }
    }

    function test_FreshChainCallsOnlyContractsCreatedByTheLaunch() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, "");
        assertEq(FrensPlan.CREATE2_DEPLOYER.code.length, 0);
        FrensReviewFactory factory = new FrensReviewFactory();
        vm.startStateDiffRecording();
        (PlaceFrens pf, PlaceModules pm) = _launch(factory);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        address[] memory created = new address[](10);
        uint256 count;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            assertFalse(a.kind == VmSafe.AccountAccessKind.DelegateCall);
            assertFalse(a.kind == VmSafe.AccountAccessKind.CallCode);
            assertFalse(a.kind == VmSafe.AccountAccessKind.SelfDestruct);
            if (a.kind == VmSafe.AccountAccessKind.Create) {
                assertFalse(a.reverted);
                created[count++] = a.account;
            } else if (a.kind == VmSafe.AccountAccessKind.Call || a.kind == VmSafe.AccountAccessKind.StaticCall) {
                // The test invokes the factory and cheatcodes; constructors may only call new dependencies.
                if (a.accessor == address(this) && (a.account == address(factory) || a.account == address(vm))) {
                    continue;
                }
                bool found;
                for (uint256 j; j < count; ++j) {
                    if (a.account == created[j]) found = true;
                }
                assertTrue(found, "called an account not created in this launch");
            }
        }
        assertEq(count, 10, "four applications and six nested contracts");
        assertNotEq(pf.frens(), FrensPlan.FRENS_AT);
        assertNotEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        _checkDependencies(pf, pm);
    }

    /// @dev Audit f338bd7a: this is the brief's explicit team-wallet setup boundary.
    function test_Audit_ConstructorLeavesTheDocumentedTeamSetup() public {
        FrensReviewFactory factory = new FrensReviewFactory();
        (PlaceFrens pf, PlaceModules pm) = _launch(factory);
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        assertEq(f.renderer(), address(0));
        assertEq(f.swapper(), address(0));
        assertEq(f.workerGate(), address(0));
        assertFalse(f.traitsSealed());
        assertFalse(f.mintOpen());
        assertFalse(f.artFrozen());
        assertEq(FrenWorkerGate(pm.gate()).wlRoot(), bytes32(0));
        vm.prank(FrensPlan.OWNER);
        vm.expectRevert(IMD6900Frens.TraitsNotSealed.selector);
        f.requestMintFor(address(123), 1, type(uint256).max);
        // Before the first mint, tokenURI fails for a nonexistent token, not in the renderer.
        vm.expectRevert(bytes4(keccak256("TokenDoesNotExist()")));
        f.tokenURI(1);
    }
}

contract FrensRejectingValidator {
    error TransfersBlocked();

    function setTokenTypeOfCollection(address, uint16) external pure {}

    function validateTransfer(address, address, address, uint256) external pure {
        revert TransfersBlocked();
    }
}

/// @dev Model the explicit ERC20 allowances the collection accounts for. Solady's
///      default mock instead returns infinity for the canonical Permit2 address.
contract FrensAllowanceToken is MockToken {
    constructor() MockToken("IMD") {}

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}

/// @dev Only the pool slot0 read needed to reproduce constructor-dependent state.
contract FrensSlot0Stub {
    uint160 public sqrtPriceX96;

    function setPrice(uint160 price) external {
        sqrtPriceX96 = price;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }
}

/// @notice The audit's and the review's findings against the exact placed collection and price table (only external
///         assets, payments and swaps are mocked): the ones fixed, asserted fixed; the trust assumptions that stay,
///         asserted as they are. ADAPTATION.md lists each.
contract FrensAuditReviewTest is FrensReviewBase, FrensRules {
    PlaceFrens private pf;
    IMD6900Frens private frens;
    MockToken private imd;
    MockToken private reserveToken;
    MockPermit2 private permit2;
    MockSwapper private swapper;
    address private alice;
    address private bob;
    uint256 private constant RELAYER_KEY = 0xA11CE;

    function setUp() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, DEPLOYER_CODE);
        imd = MockToken(FrensPlan.IMD);
        reserveToken = MockToken(FrensPlan.IMD6900);
        permit2 = MockPermit2(FrensPlan.PERMIT2);
        vm.etch(address(imd), address(new FrensAllowanceToken()).code);
        vm.etch(address(reserveToken), address(new NoZeroToken()).code);
        vm.etch(FrensPlan.IDENTITY, address(new MockToken("identity")).code);
        vm.etch(address(permit2), address(new MockPermit2()).code);
        pf = PlaceFrens(deployCode("FrensPlacement.sol:PlaceFrens"));
        frens = IMD6900Frens(payable(pf.frens()));
        assertEq(address(frens), FrensPlan.FRENS_AT);
        swapper = new MockSwapper(reserveToken, imd);
        address relayer = vm.addr(RELAYER_KEY);
        vm.startPrank(FrensPlan.OWNER);
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setModules(address(swapper), address(0));
        frens.setRoles(address(0), relayer, address(0));
        frens.setMintOpen(true);
        vm.stopPrank();
        alice = makeAddr("review alice");
        bob = makeAddr("review bob");
        imd.mint(alice, 10_000e18);
        imd.mint(bob, 10_000e18);
        vm.prank(alice);
        imd.approve(address(frens), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(frens), type(uint256).max);
    }

    function _mint(address to) private returns (uint256) {
        vm.prank(to);
        return frens.requestMint(1, type(uint256).max);
    }

    /// @dev Audit 4def4296: both privileged roles can freeze peer transfers, including OTC.
    function test_Audit_OwnerOrGovernorCanBlockAllPeerTransfers() public {
        _mint(alice);
        _mint(bob); // two out: alice's can be recycled at the end
        address governor = makeAddr("review governor");
        vm.prank(FrensPlan.OWNER);
        frens.setGovernor(governor);
        FrensRejectingValidator validator = new FrensRejectingValidator();
        address[2] memory roles = [FrensPlan.OWNER, governor];
        for (uint256 i; i < roles.length; ++i) {
            vm.prank(roles[i]);
            frens.setTransferValidator(address(validator));
            vm.prank(alice);
            vm.expectRevert(FrensRejectingValidator.TransfersBlocked.selector);
            frens.transferFrom(alice, bob, 1);
            vm.prank(alice);
            vm.expectRevert(FrensRejectingValidator.TransfersBlocked.selector);
            frens.safeTransferFrom(alice, bob, 1);
            vm.prank(alice);
            frens.approve(bob, 1);
            vm.prank(bob);
            vm.expectRevert(FrensRejectingValidator.TransfersBlocked.selector);
            frens.transferFrom(alice, bob, 1);
            vm.prank(roles[i]);
            frens.setTransferValidator(address(0));
        }
        vm.prank(FrensPlan.OWNER);
        frens.setTransferValidator(address(validator));
        vm.prank(alice);
        frens.recycle(1);
        assertEq(frens.ownerOf(1), address(frens), "recycling still bypasses the validator");
    }

    function test_Audit_GovernorCanCloseMintAgain() public {
        _mint(alice);
        vm.prank(FrensPlan.OWNER);
        frens.setMintOpen(false);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        frens.requestMint(1, type(uint256).max);
    }

    /// @dev Audit 992a6ec3 / review 8e1b7913, fixed: the last fren out never enters the treasury, so the floor always
    ///      has an owner. Fees arriving are that holder's, the next mint pays the floor it joins, and selling straight
    ///      back to the floor never pays.
    function test_Fix_LastFrenOutStaysOutSoFeesHaveAnOwner() public {
        _mint(alice);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.LastFrenOut.selector);
        frens.recycle(1);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.LastFrenOut.selector);
        frens.transferFrom(alice, address(frens), 1);
        assertEq(frens.totalMinted(), frens.inTreasury() + 1, "one out");
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(frens).call{value: 1 ether}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.25 ether, 0);
        (uint256 floor6900, uint256 floorImd) = frens.floorPerFren();
        uint256 value = floor6900 * 1e18 / swapper.floorRate() + floorImd;
        assertGe(value, 750e18, "the fees are alice's fren's");
        assertGe(frens.quote(1), value, "the next mint pays the floor it joins, not the curve");
        uint256 before = imd.balanceOf(bob);
        _mint(bob);
        uint256 paid = before - imd.balanceOf(bob);
        vm.prank(bob);
        (uint256 got6900, uint256 gotImd) = frens.recycle(2);
        assertLe(got6900 * 1e18 / swapper.floorRate() + gotImd, paid, "selling straight back never pays");
        assertGt(frens.reserve(), 0, "the floor stays with alice's fren");
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.LastFrenOut.selector);
        frens.recycle(1);
    }

    /// @dev Audit 0640f0a6 / review aed78db6, fixed: a payment approved and never taken in time is undone by the
    ///      reveal that completes the request, and its 0.50 $IMD feeds the floor
    function test_Fix_LapsedJobApprovalIsReleasedByTheReveal() public {
        uint256 id = _mint(alice);
        uint256 expiry = vm.getBlockTimestamp() + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("review", bytes32("scope"), "1", bytes32("q"), bytes32("p"), "job.open", expiry);
        vm.prank(FrensPlan.KEEPER);
        (bytes32 digest,) = frens.approveJob(id, 42, expiry, q);
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18);
        vm.warp(expiry + 1);
        uint24[] memory combos = new uint24[](1);
        combos[0] = _combo(PEPE, 1, 0, 0, 0, 0, 0, 0);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 hash = frens.voucherDigest(id, combos, "review", bytes32("out"), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_KEY, hash);
        uint256 waiting = frens.floorImd();
        frens.reveal(id, combos, "review", bytes32("out"), deadline, abi.encodePacked(r, s, v), 1);
        assertGt(frens.seedOf(1), 0);
        assertEq(permit2.nonceBitmap(address(frens), 0), 0, "payment was never taken");
        assertEq(
            imd.allowance(address(frens), address(permit2)), 0, "no payment stays approved after a complete reveal"
        );
        assertEq(frens.isValidSignature(digest, ""), bytes4(0xffffffff));
        assertEq(frens.floorImd(), waiting + 0.5e18, "its 0.50 is the floor's");
        assertEq(imd.balanceOf(address(frens)), frens.floorImd() + frens.jobBudget(), "the books add up");
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloor(0); // and the floor buys it in
        assertEq(frens.floorImd(), 0);
    }

    function _skewedPool(uint160 price) internal returns (FrensSlot0Stub pool) {
        pool = new FrensSlot0Stub();
        vm.etch(FrensPlan.POOL_MANAGER, address(pool).code);
        pool = FrensSlot0Stub(FrensPlan.POOL_MANAGER);
        pool.setPrice(price);
    }

    function _prePlaceSwapper() internal returns (FrenSwapper placed) {
        bytes memory init = abi.encodePacked(
            FrensCode.SWAPPER,
            abi.encode(
                FrensPlan.POOL_MANAGER,
                FrensPlan.IMD,
                FrensPlan.IMD6900,
                address(frens),
                FrensPlan.PAIR_HOOK,
                FrensPlan.POOL4_HOOK
            )
        );
        vm.prank(bob);
        (bool ok,) = FrensPlan.CREATE2_DEPLOYER.call(abi.encodePacked(FrensPlan.SWAPPER_SALT, init));
        assertTrue(ok);
        placed = FrenSwapper(payable(FrensPlan.SWAPPER_AT));
    }

    /// @dev Audit ca830bfe / review 1796fede, fixed in the launch: the exact swapper pre-placed in a block whose pool
    ///      price was pushed carries that price as its average; PlaceModules leaves it where it is and creates its own
    ///      (seeded at the launch block's price) instead of wiring the frens to value their floor off it. A plain
    ///      CREATE from PlaceModules: nobody can have put a swapper there first, so the launch can't be griefed into
    ///      failing by pre-placing one.
    function test_Fix_LaunchReplacesASwapperSeededOffASkewedPrice() public {
        _mint(alice); // a reserve for quote() to value
        FrensSlot0Stub pool = _skewedPool(uint160((uint256(1) << 96) / 26)); // IMD6900 100x dearer, for one block
        FrenSwapper placed = _prePlaceSwapper();
        assertApproxEqAbs(placed.rateAverage(), 676e18, 1);
        pool.setPrice(uint160((uint256(1) << 96) / 265)); // the price is back: about 70,225
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(placed.spotRate(), 100 * placed.floorRate(), "the pre-placed swapper values IMD6900 100x off");
        PlaceModules pm = new PlaceModules(pf, address(new WorkerArt1()), address(new WorkerArt2()));
        FrenSwapper own = FrenSwapper(payable(pm.swapper()));
        assertTrue(address(own) != FrensPlan.SWAPPER_AT, "not the skewed one");
        assertEq(address(own), vm.computeCreateAddress(address(pm), 1), "the launch's own, from PlaceModules itself");
        assertEq(own.frens(), address(frens));
        assertEq(own.averagedAt(), vm.getBlockNumber());
        assertEq(own.rateAverage(), own.spotRate(), "seeded at the launch block's price");
        assertGe(own.floorRate() * 2, own.spotRate(), "the launch's swapper prices IMD6900 at the pool's price");
        assertApproxEqAbs(placed.rateAverage(), 676e18, 1, "the skewed one is left alone, wired to nothing");
        // the frens wired to it value the floor at the pool's price (here under the curve: the curve's price)
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(own), address(0));
        assertEq(frens.quote(1), frens.priceOf(frens.totalMinted()));
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(placed), address(0)); // wired to the skewed one, the floor would count 100x over
        assertEq(frens.quote(1), frens.reserve() * 1e18 / placed.floorRate());
        assertGt(frens.quote(1), 20 * frens.priceOf(frens.totalMinted()));
    }

    /// @dev The same swapper pre-placed at the pool's price (within 2x of it at the launch) is the one the launch takes
    function test_Fix_LaunchAdoptsASwapperSeededAtThePoolsPrice() public {
        FrensSlot0Stub pool = _skewedPool(uint160((uint256(1) << 96) / 265));
        FrenSwapper placed = _prePlaceSwapper();
        uint256 seeded = placed.rateAverage();
        assertApproxEqAbs(seeded, 70_225e18, 1e18);
        pool.setPrice(uint160((uint256(1) << 96) / 200)); // drifted since: 40,000, within 2x
        vm.roll(vm.getBlockNumber() + 1);
        PlaceModules pm = new PlaceModules(pf, address(new WorkerArt1()), address(new WorkerArt2()));
        assertEq(pm.swapper(), address(placed));
        assertEq(placed.rateAverage(), seeded);
        assertEq(placed.spotRate(), 40_000e18);
    }

    /// @dev The swapper the launch creates itself starts at the pool's price of its own block: always within the band
    function test_Fix_LaunchsOwnSwapperStartsAtThePoolsPrice() public {
        _skewedPool(uint160((uint256(1) << 96) / 265));
        PlaceModules pm = new PlaceModules(pf, address(new WorkerArt1()), address(new WorkerArt2()));
        FrenSwapper s = FrenSwapper(payable(pm.swapper()));
        assertEq(address(s), FrensPlan.SWAPPER_AT);
        assertEq(s.averagedAt(), vm.getBlockNumber());
        assertEq(s.rateAverage(), s.spotRate(), "seeded at the price of the launch's block");
        assertEq(s.floorRate(), s.spotRate());
    }

    /// @dev Review 301734e0, fixed in the launch: the renderer draws only the exact chunks WorkerArtIndex was generated
    ///      from; PlaceModules refuses any other art (the two the other way round included) instead of placing a
    ///      renderer that draws nothing
    function test_Fix_LaunchRefusesTheWrongArt() public {
        address a1 = address(new WorkerArt1());
        address a2 = address(new WorkerArt2());
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceModules(pf, a2, a1);
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceModules(pf, a1, address(pf));
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceModules(pf, a1, makeAddr("no code"));
        PlaceModules pm = new PlaceModules(pf, a1, a2);
        assertEq(WorkerFrensRenderer(pm.renderer()).art1(), a1);
    }
}

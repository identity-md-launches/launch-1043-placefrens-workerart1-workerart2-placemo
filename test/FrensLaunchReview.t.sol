// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {FrensCode} from "../src/FrensCode.sol";
import {PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
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

/// @notice Reproductions, not claims of remediation. These exercise the exact placed
///         collection and price table; only external assets/payments/swaps are mocked.
///         ADAPTATION.md explains why the pinned source and addresses prevent fixes.
contract FrensAuditReviewTest is FrensReviewBase, FrensRules {
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
        PlaceFrens pf = PlaceFrens(deployCode("FrensPlacement.sol:PlaceFrens"));
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

    /// @dev Audit 992a6ec3: fees arriving after every holder recycles can be extracted by the next mint.
    function test_Audit_EmptyWorldMintExtractsTheReserve() public {
        _mint(alice);
        vm.prank(alice);
        frens.recycle(1);
        assertEq(frens.totalMinted(), frens.inTreasury());
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(frens).call{value: 1 ether}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.25 ether, 0);
        (uint256 floor6900, uint256 floorImd) = frens.floorPerFren();
        uint256 value = floor6900 * 1e18 / swapper.floorRate() + floorImd;
        assertEq(value, 750e18);
        assertEq(frens.quote(1), frens.priceOf(1));
        assertLt(frens.quote(1), value);
        uint256 before = imd.balanceOf(bob);
        _mint(bob);
        uint256 paid = before - imd.balanceOf(bob);
        vm.prank(bob);
        (uint256 got6900, uint256 gotImd) = frens.recycle(2);
        assertGt(got6900 * 1e18 / swapper.floorRate() + gotImd, paid);
        assertGe(got6900, floor6900);
        assertEq(frens.reserve(), 0);
        assertEq(frens.floorImd(), 0);
        vm.prank(bob);
        (uint256 treasury6900, uint256 treasuryImd) = frens.buyTreasury(1, 0, 0);
        assertEq(treasury6900 + treasuryImd, 0, "free only after the reserve was emptied");
        assertEq(frens.ownerOf(1), bob);
    }

    /// @dev Audit 0640f0a6: the expired approval remains in the books after a complete reveal.
    function test_Audit_ExpiredJobApprovalRemainsAfterFullReveal() public {
        uint256 id = _mint(alice);
        uint256 expiry = vm.getBlockTimestamp() + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("review", bytes32("scope"), "1", bytes32("q"), bytes32("p"), "job.open", expiry);
        vm.prank(FrensPlan.KEEPER);
        (bytes32 digest,) = frens.approveJob(id, 42, expiry, q);
        vm.warp(expiry + 1);
        uint24[] memory combos = new uint24[](1);
        combos[0] = _combo(PEPE, 1, 0, 0, 0, 0, 0, 0);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 hash = frens.voucherDigest(id, combos, "review", bytes32("out"), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_KEY, hash);
        frens.reveal(id, combos, "review", bytes32("out"), deadline, abi.encodePacked(r, s, v), 1);
        assertGt(frens.seedOf(1), 0);
        q.expiresAt = deadline;
        vm.prank(FrensPlan.KEEPER);
        vm.expectRevert(IMD6900Frens.BadJob.selector);
        frens.approveJob(id, 43, deadline, q);
        assertEq(permit2.nonceBitmap(address(frens), 0), 0, "payment was never taken");
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18);
        assertEq(imd.balanceOf(address(frens)) - frens.floorImd() - frens.jobBudget(), 0.5e18);
        assertEq(frens.isValidSignature(digest, ""), bytes4(0x1626ba7e));
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyFloor(0);
    }

    /// @dev Audit ca830bfe: the exact planned swapper can be pre-placed with a skewed average.
    function test_Audit_LaunchAcceptsSwapperSeededAtManipulatedSpot() public {
        _mint(alice); // Give quote() a real reserve and one holder before installing the pool stub.
        FrensSlot0Stub pool = new FrensSlot0Stub();
        vm.etch(FrensPlan.POOL_MANAGER, address(pool).code);
        pool = FrensSlot0Stub(FrensPlan.POOL_MANAGER);
        pool.setPrice(uint160((uint256(1) << 96) / 26));
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
        FrenSwapper placed = FrenSwapper(payable(FrensPlan.SWAPPER_AT));
        uint256 seeded = placed.rateAverage();
        assertApproxEqAbs(seeded, 676e18, 1);
        uint256 seededAt = placed.averagedAt();
        pool.setPrice(uint160((uint256(1) << 96) / 265));
        vm.roll(vm.getBlockNumber() + 1);
        FrensReviewFactory factory = new FrensReviewFactory();
        (, PlaceModules pm) = _launch(factory);
        assertEq(pm.swapper(), address(placed));
        assertEq(placed.rateAverage(), seeded);
        assertEq(placed.averagedAt(), seededAt);
        assertEq(placed.floorRate(), seeded);
        assertGt(placed.spotRate(), 100 * placed.floorRate());
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(placed), address(0));
        uint256 normalFloor = frens.reserve() * 1e18 / placed.spotRate();
        assertEq(frens.quote(1), frens.reserve() * 1e18 / seeded);
        assertGt(frens.quote(1), 100 * normalFloor);
    }
}

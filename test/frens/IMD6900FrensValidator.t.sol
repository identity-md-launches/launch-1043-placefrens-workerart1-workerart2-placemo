// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./FrensRules.sol";
import {MockToken, NoZeroToken, MockPermit2} from "./IMD6900Frens.t.sol";
import {Relay, Fulfilment, IValidator} from "./IMD6900FrensValidator.fork.t.sol";

/// @dev A stand-in for Limit Break's transfer validator in authorization mode, as the frens meet it on mainnet: an
///      authorizer (a marketplace's zone) names the operator allowed to move one token of one collection, the
///      validator keeps that in transient storage for the rest of the transaction, and a transfer passes when its
///      caller is the holder (OTC) or that operator for that token. Everything else is blocked.
contract TransientValidator {
    address public immutable authorizer;

    error NotAuthorizer();
    error CallerOrFromMustBeWhitelisted();

    constructor(address authorizer_) {
        authorizer = authorizer_;
    }

    function setTokenTypeOfCollection(address, uint16) external {}

    function beforeAuthorizedTransfer(address operator, address token, uint256 tokenId) external {
        if (msg.sender != authorizer) revert NotAuthorizer();
        bytes32 key = keccak256(abi.encode(token, tokenId));
        assembly {
            tstore(key, operator)
        }
    }

    function validateTransfer(address caller, address from, address, uint256 tokenId) external view {
        if (caller == from) return;
        bytes32 key = keccak256(abi.encode(msg.sender, tokenId));
        address operator;
        assembly {
            operator := tload(key)
        }
        if (caller != operator) revert CallerOrFromMustBeWhitelisted();
    }
}

/// @notice Offline, the marketplace path the fork test runs against the live validator: a zone-authorized sale goes
///         through only when the zone's authorization and the conduit's transfer leave from one frame, the shape of a
///         Seaport fulfilment. Foundry clears transient storage between two top-level calls from a test, so the test
///         drives both through the same Fulfilment helper the fork test uses, with relays etched at the zone's and the
///         conduit's addresses.
contract IMD6900FrensValidatorTest is Test, FrensRules {
    uint256 constant RELAYER_KEY = 0xA11CE;

    IMD6900Frens frens;
    TransientValidator validator;
    Fulfilment seaport;
    MockToken imd;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");
    address zone = makeAddr("zone");
    address conduit = makeAddr("conduit");

    function setUp() public {
        imd = new MockToken("IMD");
        frens = new IMD6900Frens(
            address(this),
            address(imd),
            address(new NoZeroToken()),
            address(new MockToken("IDMD")),
            address(new MockPermit2()),
            makeAddr("x402Proxy"),
            makeAddr("payTo"),
            address(this),
            vm.addr(RELAYER_KEY),
            _flatPrices()
        );
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setMintOpen(true);
        validator = new TransientValidator(zone);
        frens.setTransferValidator(address(validator));

        // alice mints two frens, revealed as common pepes 1 and 2
        imd.mint(alice, 10e18);
        vm.startPrank(alice);
        imd.approve(address(frens), type(uint256).max);
        uint256 id = frens.requestMint(2, type(uint256).max);
        vm.stopPrank();
        uint24[] memory combos = new uint24[](2);
        combos[0] = _combo(PEPE, 1, 0, 0, 2, 0, 7, 0);
        combos[1] = _combo(PEPE, 2, 0, 0, 2, 0, 7, 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s_) =
            vm.sign(RELAYER_KEY, frens.voucherDigest(id, combos, "job", bytes32(0), deadline));
        frens.reveal(id, combos, "job", bytes32(0), deadline, abi.encodePacked(r, s_, v), combos.length);
        assertEq(frens.ownerOf(1), alice);
        assertEq(frens.ownerOf(2), alice);

        // the marketplace: its zone and its conduit, as one fulfilment drives them
        vm.etch(zone, type(Relay).runtimeCode);
        vm.etch(conduit, type(Relay).runtimeCode);
        seaport = new Fulfilment();
        vm.prank(alice);
        frens.setApprovalForAll(conduit, true);
    }

    function _sell(address z, address c, address from, address to, uint256 id) internal returns (bool, bool) {
        vm.prank(buyer, buyer);
        return seaport.sell(address(validator), z, c, address(frens), from, to, id);
    }

    function test_HolderSendsItHerself() public {
        vm.prank(alice);
        frens.transferFrom(alice, bob, 1);
        assertEq(frens.ownerOf(1), bob);
    }

    function test_ConduitAloneIsBlocked() public {
        vm.prank(conduit, buyer);
        vm.expectRevert(TransientValidator.CallerOrFromMustBeWhitelisted.selector);
        frens.transferFrom(alice, buyer, 1);
        assertEq(frens.ownerOf(1), alice);
    }

    function test_ZoneAuthorizedSaleGoesThroughInOneFrame() public {
        (bool authorized, bool sale) = _sell(zone, conduit, alice, buyer, 1);
        assertTrue(authorized, "the zone is the authorizer");
        assertTrue(sale, "the conduit moves the fren it was authorized for");
        assertEq(frens.ownerOf(1), buyer);
        assertEq(frens.ownerOf(2), alice);
    }

    function test_AuthorizationFromTwoTopLevelCallsIsLost() public {
        // the shape the fork test had: Foundry clears transient storage between the two calls, so the sale is blocked;
        // not a defect of the frens, the reason the fulfilment must be one frame
        vm.prank(zone, buyer);
        IValidator(address(validator)).beforeAuthorizedTransfer(conduit, address(frens), 1);
        vm.prank(conduit, buyer);
        (bool sale,) = address(frens).call(abi.encodeCall(frens.transferFrom, (alice, buyer, 1)));
        emit log_named_string("sale authorized in a separate top-level call", sale ? "allowed" : "blocked");
        assertEq(frens.ownerOf(1), sale ? buyer : alice);
    }

    function test_OnlyTheAuthorizerAuthorizes() public {
        address rogueZone = makeAddr("rogue zone");
        vm.etch(rogueZone, type(Relay).runtimeCode);
        (bool authorized, bool sale) = _sell(rogueZone, conduit, alice, buyer, 1);
        assertFalse(authorized, "a contract off the authorizer list can't authorize");
        assertFalse(sale, "and the conduit stays a bare operator");
        assertEq(frens.ownerOf(1), alice);
    }

    function test_AuthorizationIsForThatOperatorOnly() public {
        address otherConduit = makeAddr("other conduit");
        vm.etch(otherConduit, type(Relay).runtimeCode);
        vm.prank(alice);
        frens.setApprovalForAll(otherConduit, true);
        // the zone authorizes `conduit`, but `otherConduit` makes the transfer
        vm.prank(buyer, buyer);
        bool authorized = Relay(zone)
            .relay(
                address(validator), abi.encodeCall(IValidator.beforeAuthorizedTransfer, (conduit, address(frens), 1))
            );
        assertTrue(authorized);
        Other other = new Other();
        vm.prank(buyer, buyer);
        bool sale = other.sell(address(validator), zone, conduit, otherConduit, address(frens), alice, buyer, 1);
        assertFalse(sale, "an operator the zone did not name can't move the fren");
        assertEq(frens.ownerOf(1), alice);
    }

    function test_AuthorizationIsForThatFrenOnly() public {
        Other other = new Other();
        vm.prank(buyer, buyer);
        // the zone authorizes fren 1; the conduit tries fren 2 in the same frame
        bool sale = other.sellAnother(address(validator), zone, conduit, address(frens), alice, buyer, 1, 2);
        assertFalse(sale, "the authorization names one fren");
        assertEq(frens.ownerOf(2), alice);
    }

    function test_AuthorizationDoesNotOutliveTheSale() public {
        (, bool sale) = _sell(zone, conduit, alice, buyer, 1);
        assertTrue(sale);
        vm.prank(buyer);
        frens.setApprovalForAll(conduit, true);
        vm.prank(conduit, buyer);
        vm.expectRevert(TransientValidator.CallerOrFromMustBeWhitelisted.selector);
        frens.transferFrom(buyer, bob, 1);
        assertEq(frens.ownerOf(1), buyer);
    }

    function test_FloorMovesSkipTheValidator() public {
        // a fren recycled into the treasury never asks the validator: the floor is no marketplace
        vm.prank(alice);
        frens.transferFrom(alice, address(frens), 1);
        assertEq(frens.ownerOf(1), address(frens));
    }
}

/// @dev Fulfilments that go wrong on purpose: another operator than the authorized one, or another fren
contract Other {
    function sell(
        address validator,
        address zone,
        address authorized,
        address mover,
        address token,
        address from,
        address to,
        uint256 id
    ) external returns (bool sale) {
        Relay(zone).relay(validator, abi.encodeCall(IValidator.beforeAuthorizedTransfer, (authorized, token, id)));
        sale = Relay(mover).relay(token, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id));
    }

    function sellAnother(
        address validator,
        address zone,
        address conduit,
        address token,
        address from,
        address to,
        uint256 authorizedId,
        uint256 movedId
    ) external returns (bool sale) {
        Relay(zone)
            .relay(validator, abi.encodeCall(IValidator.beforeAuthorizedTransfer, (conduit, token, authorizedId)));
        sale = Relay(conduit)
            .relay(token, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, movedId));
    }
}

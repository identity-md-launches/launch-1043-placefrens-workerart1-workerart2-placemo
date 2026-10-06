// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMD6900Frens} from "./IMD6900Frens.sol";

interface ILaunchModule {
    function frens() external view returns (address);
}

interface ILaunchMinter {
    function buyImd(uint256 imdOut) external payable returns (uint256 ethSpent);
}

interface ILaunchStrategy {
    function isDistributor(address) external view returns (bool);
}

interface ILaunchERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title FrensLaunch - the frens' governor from their deploy until the timelock takes over
/// @notice IMD's launch deploys the frens with no call afterwards, and never gives a role to whoever deploys them (the
///         swarm's factory). So the frens name this contract as their governor, and it does what a deploy script would:
///         - {setup}: wires the swapper and the workers' window, sets the keeper and relayer, writes and seals the
///           launch's trait rules;
///         - {first}: before the opening, mints the curve's first frens to the IMD6900 strategy, paid with the ETH sent;
///         - {open}: opens the mint (the workers' window first), once IMD6900 lets the frens pay out the floor;
///         - {handover}: the governor to the Ethereum timelock, for good.
///         Only the team wallet (the frens' owner) calls it; `govern` passes any other governor call on until the
///         handover. The team can't keep the role: after `handoverBy` anyone can hand it to the timelock.
contract FrensLaunch {
    /// @notice The team wallet: the frens' owner (the collection on marketplaces) and the only caller here
    address public immutable team;
    /// @notice The Ethereum timelock: the frens' governor after {handover}
    address public immutable timelock;
    /// @notice IMD6900, the strategy: holds the first frens, and must let the frens move IMD6900 before {open}
    address public immutable strategy;
    /// @notice $IMD
    address public immutable imd;
    /// @notice From then on anyone can call {handover}
    uint256 public immutable handoverBy;

    IMD6900Frens public frens;
    address public minter;
    bool public handedOver;

    error Unauthorized();
    error AlreadySetUp();
    error NotSetUp();
    error NotOurs();
    error Closed();
    error FloorNotLive();
    error UseHandover();
    error CallFailed(bytes reason);

    event SetUp(address frens, address swapper, address minter, address gate);
    event FirstFrens(uint256 count, uint256 imdPaid, uint256 totalMinted);
    event Opened();
    event HandedOver(address governor, address caller);

    modifier onlyTeam() {
        if (msg.sender != team) revert Unauthorized();
        _;
    }

    modifier live() {
        if (address(frens) == address(0)) revert NotSetUp();
        if (handedOver) revert Closed();
        _;
    }

    /// @param team_ the team wallet (IMD's `$owner`, the frens' owner too)
    /// @param timelock_ the Ethereum timelock
    /// @param strategy_ IMD6900
    /// @param imd_ $IMD
    /// @param handoverDelay seconds after this deploy when anyone may hand the governor to the timelock
    constructor(address team_, address timelock_, address strategy_, address imd_, uint256 handoverDelay) {
        if (team_ == address(0) || timelock_ == address(0) || strategy_ == address(0) || imd_ == address(0)) {
            revert Unauthorized();
        }
        team = team_;
        timelock = timelock_;
        strategy = strategy_;
        imd = imd_;
        handoverBy = block.timestamp + handoverDelay;
    }

    /// @notice Wires the frens to their modules and seals the launch's trait rules, once. Each module must be the one
    ///         deployed for these frens, and the frens must name this contract their governor and the team their owner.
    function setup(
        IMD6900Frens frens_,
        address swapper,
        address minter_,
        address gate,
        address keeper,
        address relayer,
        address imdPayTo
    ) external onlyTeam {
        if (address(frens) != address(0)) revert AlreadySetUp();
        if (frens_.governor() != address(this) || frens_.owner() != team || frens_.imd() != imd || frens_.imd6900() != strategy) {
            revert NotOurs();
        }
        if (
            ILaunchModule(swapper).frens() != address(frens_) || ILaunchModule(minter_).frens() != address(frens_)
                || ILaunchModule(gate).frens() != address(frens_)
        ) revert NotOurs();
        frens = frens_;
        minter = minter_;
        frens_.setModules(swapper, gate);
        frens_.setRoles(keeper, relayer, imdPayTo);
        _launchRules(frens_);
        frens_.sealTraits();
        emit SetUp(address(frens_), swapper, minter_, gate);
    }

    /// @notice Before the opening, mints the next `count` frens to IMD6900 (tier 3: it holds identity.md NFTs), 69 a
    ///         request, paid with the ETH sent: each request's exact quote in $IMD is bought on IMD's pool first. What
    ///         the ETH didn't need goes back to the team, with any $IMD left.
    function first(uint256 count) external payable onlyTeam live {
        IMD6900Frens f = frens;
        if (f.mintOpen()) revert Closed();
        uint256 paid;
        for (uint256 left = count; left != 0;) {
            uint8 n = uint8(left > 69 ? 69 : left);
            uint256 cost = f.quote(n); // the floor bought by the last request can lift this one a little
            ILaunchMinter(minter).buyImd{value: address(this).balance}(cost);
            SafeTransferLib.safeApprove(imd, address(f), cost);
            f.requestMintFor(strategy, n, cost);
            paid += cost;
            left -= n;
        }
        SafeTransferLib.safeApprove(imd, address(f), 0);
        uint256 imdLeft = ILaunchERC20(imd).balanceOf(address(this));
        if (imdLeft != 0) SafeTransferLib.safeTransfer(imd, team, imdLeft);
        if (address(this).balance != 0) SafeTransferLib.forceSafeTransferETH(team, address(this).balance);
        emit FirstFrens(count, paid, f.totalMinted());
    }

    /// @notice Opens the mint: the workers' window first. Only once IMD6900 lets the frens move IMD6900 (the Ethereum
    ///         timelock's batch), or selling a fren to the floor would fail.
    function open() external onlyTeam live {
        if (!ILaunchStrategy(strategy).isDistributor(address(frens))) revert FloorNotLive();
        frens.setMintOpen(true);
        emit Opened();
    }

    /// @notice Any other governor call on the frens (setParams, setRoles, setMaxMint…), the team's until the handover
    function govern(bytes calldata data) external onlyTeam live returns (bytes memory) {
        if (bytes4(data) == IMD6900Frens.setGovernor.selector) revert UseHandover();
        (bool ok, bytes memory ret) = address(frens).call(data);
        if (!ok) revert CallFailed(ret);
        return ret;
    }

    /// @notice The frens' governor to the Ethereum timelock, for good. The team's any time; anyone's after `handoverBy`.
    function handover() external live {
        if (msg.sender != team && block.timestamp < handoverBy) revert Unauthorized();
        handedOver = true;
        frens.setGovernor(timelock);
        emit HandedOver(timelock, msg.sender);
    }

    /// @dev FrenMinter.buyImd refunds the ETH it didn't spend
    receive() external payable {}

    /// @dev The launch rules (test/frens/FrensRules.sol and tools/fren-job.mjs mirror them):
    ///  - characters 1598 cyborg pepe / 312 mumu / 312 bobo, mumu and bobo from tier 2;
    ///  - laser eyes (56) tier 3; gold lens (222), gold coat (103) tier 1; hats (266 each) tier 1;
    ///  - items 140 each, six common ones open to all, the rest tier 1, the two lightsabers (56 each) tier 3;
    ///  - a gold-coat mumu or bobo tier 3.
    function _launchRules(IMD6900Frens f) internal {
        (uint16[] memory c, uint8[] memory t) = _fill(3, 0, 0);
        (c[0], c[1], c[2], t[1], t[2]) = (1598, 312, 312, 2, 2);
        f.setTraitRules(0, c, t);
        (c, t) = _fill(13, 2222, 0);
        (c[12], t[12]) = (56, 3);
        f.setTraitRules(1, c, t);
        (c, t) = _fill(4, 2222, 0);
        (c[3], t[3]) = (222, 1);
        f.setTraitRules(2, c, t);
        (c, t) = _fill(3, 2222, 0);
        (c[2], t[2]) = (103, 1);
        f.setTraitRules(3, c, t);
        (c, t) = _fill(6, 2222, 0);
        f.setTraitRules(4, c, t);
        (c, t) = _fill(3, 266, 1);
        (c[0], t[0]) = (2222, 0);
        f.setTraitRules(5, c, t);
        (c, t) = _fill(10, 2222, 0);
        f.setTraitRules(6, c, t);
        (c, t) = _fill(16, 140, 1);
        (c[0], t[0]) = (2222, 0);
        uint8[6] memory common = [1, 3, 4, 10, 11, 14];
        for (uint256 i; i < 6; ++i) t[common[i]] = 0;
        (c[12], t[12], c[13], t[13]) = (56, 3, 56, 3);
        f.setTraitRules(7, c, t);
        f.addPairRule(IMD6900Frens.PairRule(0, 1, 3, 2, 3));
        f.addPairRule(IMD6900Frens.PairRule(0, 2, 3, 2, 3));
    }

    function _fill(uint8 n, uint16 cap, uint8 tier) internal pure returns (uint16[] memory caps, uint8[] memory tiers) {
        caps = new uint16[](n);
        tiers = new uint8[](n);
        for (uint8 i; i < n; ++i) (caps[i], tiers[i]) = (cap, tier);
    }
}

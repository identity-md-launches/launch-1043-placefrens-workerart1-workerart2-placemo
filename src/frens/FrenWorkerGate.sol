// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IWorkerGate} from "./IMD6900Frens.sol";

interface IIdentityMin {
    function ownerOf(uint256 id) external view returns (address);
}

interface ISeatStrategyMin {
    function seatOperator() external view returns (address);
}

/// @title FrenWorkerGate - the workers' window: the first frens of the open mint go to identity.md holders and the WL
/// @notice IMD's workers are identity.md NFTs. Once the mint opens, its next WORKER_FRENS frens (the curve's cheapest
///         left) are theirs and the WL's alone: one fren per identity.md NFT, each NFT counted once, whoever holds it
///         later, and as many as the WL gives each listed wallet.
///          - claim(ids, to): the holder of each NFT turns it into one worker mint for `to` (themselves, or the
///            wallet they mint from). For NFTs the IMD6900 strategy holds as IMD seats, its seat operator claims.
///          - claimWl(amount, proof, to): a wallet on the owner's WL (a Merkle root of wallet and amount) turns its
///            amount into window mints for `to`, once; if the owner raises its amount, it claims the difference.
///          - The frens contract asks spend(minter, count) on every mint while the window is open: the minter needs a
///            credit per fren. Pay in $IMD or ETH (FrenMinter) alike: the credit is the minter's, not the payer's.
///          - The window closes for good once its frens are minted, or when the owner opens the public mint early
///            (openPublic: no timelock, it only ever widens who may mint). Then every mint is the public's.
/// @dev Holds nothing and moves nothing: it can only refuse a mint during the window, never take or price one.
contract FrenWorkerGate is IWorkerGate, Ownable {
    uint256 public constant WORKER_FRENS = 420;

    address public immutable frens;
    IIdentityMin public immutable identity;
    address public immutable strategy; // IMD6900: holds identity.md NFTs as IMD seats; its seat operator claims them

    bool public publicOpen;
    uint256 public workerMinted; // frens minted in the window so far
    mapping(uint256 => bool) public claimed; // identity.md NFTs that gave their worker mint
    mapping(address => uint256) public credits; // worker mints a wallet has left
    /// @notice The WL: a Merkle root over leaves keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))))
    ///         (OpenZeppelin's standard tree), set by the owner, replaceable at any time
    bytes32 public wlRoot;
    mapping(address => uint256) public wlClaimed; // how much of its WL amount a wallet has turned into credits

    event Claimed(address indexed by, address indexed to, uint256[] ids);
    event PublicOpened(uint256 workerMinted);
    event WlRootSet(bytes32 root);
    event WlClaimed(address indexed wallet, address indexed to, uint256 amount);

    error OnlyFrens();
    error NotYours(uint256 id);
    error AlreadyClaimed(uint256 id);
    error NoCredit(uint256 credits);
    error BadClaim();
    error NotOnWl();
    error WlClaimedAlready(uint256 claimed);

    constructor(address owner_, address frens_, address identity_, address strategy_) {
        _initializeOwner(owner_);
        frens = frens_;
        identity = IIdentityMin(identity_);
        strategy = strategy_;
    }

    /// @notice Whether a mint needs a worker credit now
    function workerWindow() public view returns (bool) {
        return !publicOpen && workerMinted < WORKER_FRENS;
    }

    /// @notice Turns identity.md NFTs into worker mints for `to`, one each: the caller holds every one of them (or is
    ///         the IMD6900 strategy's seat operator, for the NFTs the strategy holds)
    function claim(uint256[] calldata ids, address to) external {
        if (to == address(0) || ids.length == 0) revert BadClaim();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            address holder = identity.ownerOf(id);
            if (holder != msg.sender && (holder != strategy || msg.sender != ISeatStrategyMin(strategy).seatOperator())) {
                revert NotYours(id);
            }
            if (claimed[id]) revert AlreadyClaimed(id);
            claimed[id] = true;
        }
        credits[to] += ids.length;
        emit Claimed(msg.sender, to, ids);
    }

    /// @notice The caller's WL amount (proven against wlRoot) into window mints for `to`: all of it the first time,
    ///         the rest if the owner's list raised it since
    function claimWl(uint256 amount, bytes32[] calldata proof, address to) external {
        if (to == address(0)) revert BadClaim();
        if (!_verify(proof, wlRoot, keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount)))))) revert NotOnWl();
        uint256 had = wlClaimed[msg.sender];
        if (amount <= had) revert WlClaimedAlready(had);
        wlClaimed[msg.sender] = amount;
        credits[to] += amount - had;
        emit WlClaimed(msg.sender, to, amount - had);
    }

    /// @notice Sets (or replaces) the WL. What a wallet already claimed stays claimed.
    function setWlRoot(bytes32 root) external onlyOwner {
        wlRoot = root;
        emit WlRootSet(root);
    }

    /// @dev A Merkle proof with sorted pairs (OpenZeppelin's MerkleProof.verify)
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encode(h, p)) : keccak256(abi.encode(p, h));
        }
        return root != bytes32(0) && h == root;
    }

    /// @notice The frens contract, before each mint of the open mint: in the window it takes `count` of the minter's
    ///         credits, or refuses the mint
    function spend(address minter, uint256 count) external {
        if (msg.sender != frens) revert OnlyFrens();
        if (!workerWindow()) return;
        uint256 c = credits[minter];
        if (c < count) revert NoCredit(c);
        credits[minter] = c - count;
        workerMinted += count;
    }

    /// @notice Ends the window now: the public mints from here on
    function openPublic() external onlyOwner {
        publicOpen = true;
        emit PublicOpened(workerMinted);
    }
}

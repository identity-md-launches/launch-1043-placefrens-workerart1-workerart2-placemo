// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

interface ILaunchHook {
    function feeAddress() external view returns (address);
    function updateFeeAddress(address feeAddress) external;
}

interface IPairHook {
    function setFeeExempt(address caller, bool exempt) external;
    function feeExempt(address) external view returns (bool);
}

interface IStrategy {
    function setDistributor(address distributor, bool status) external;
    function isDistributor(address) external view returns (bool);
}

interface ITimelock {
    function hashOperationBatch(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32, bytes32)
        external
        pure
        returns (bytes32);
    function getMinDelay() external view returns (uint256);
}

/// @notice The Ethereum timelock batch for the IMD swarm's frens (src/FrensPlacement.sol: FrensPlan's addresses), once
///         its launch has landed:
///  1. the frens contract becomes an IMD6900 distributor: IMD6900 moves only through its pools or to and from
///     distributors, so without this the floor can't hold IMD6900 (it waits in $IMD, buys paused) and no one can sell a
///     fren to the floor for IMD6900;
///  2. the frens' swapper trades on the IMD6900/$IMD pool without its fee: the floor's own buys keep the 6.9%. Only the
///     frens contract can call the swapper, and only with the floor's own money, so nobody else's trade goes fee-free.
///  The launch hook's fee is 6.9% already (the first collection's batch). Its fee-address slice goes to the first
///  collection (0x69004fEd…) and stays there unless `moveHookFees` adds 3. updateFeeAddress(frens), which sends it to
///  this collection's floor instead. This only simulates the batch as the timelock on a fork and prints what to queue;
///  it sends nothing.
///
///   forge script script/frens/FrensTimelockBatch.s.sol --sig "run(address,address,bool)" <frens> <swapper> false --fork-url $MAINNET_RPC_URL
contract FrensTimelockBatch is Script {
    address public constant HOOK = 0xA16026A28aA581AA96713d20C608Da7F8db86444;
    address public constant TIMELOCK = 0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D;
    address public constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F; // the strategy: owner is TIMELOCK
    address public constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44; // owner is TIMELOCK
    bytes32 public constant SALT = keccak256("imd6900-frens-swarm-batch-1");

    function batch(address frens, address swapper, bool moveHookFees)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas)
    {
        uint256 n = moveHookFees ? 3 : 2;
        targets = new address[](n);
        values = new uint256[](n);
        datas = new bytes[](n);
        (targets[0], targets[1]) = (IMD6900, PAIR_HOOK);
        datas[0] = abi.encodeCall(IStrategy.setDistributor, (frens, true));
        datas[1] = abi.encodeCall(IPairHook.setFeeExempt, (swapper, true));
        if (moveHookFees) (targets[2], datas[2]) = (HOOK, abi.encodeCall(ILaunchHook.updateFeeAddress, (frens)));
    }

    function run(address frens, address swapper, bool moveHookFees) external {
        require(frens.code.length > 0 && swapper.code.length > 0, "frens / swapper not deployed here");
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) = batch(frens, swapper, moveHookFees);
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(TIMELOCK);
            (bool ok, bytes memory err) = targets[i].call{value: values[i]}(datas[i]);
            require(ok, string(err));
        }
        require(IStrategy(IMD6900).isDistributor(frens), "frens isn't a distributor");
        require(IPairHook(PAIR_HOOK).feeExempt(swapper), "the swapper isn't fee-exempt");
        if (moveHookFees) require(ILaunchHook(HOOK).feeAddress() == frens, "the fee address didn't move");
        uint256 delay = ITimelock(TIMELOCK).getMinDelay();
        console2.log("hook fee address after", ILaunchHook(HOOK).feeAddress());
        console2.log("operation id");
        console2.logBytes32(ITimelock(TIMELOCK).hashOperationBatch(targets, values, datas, bytes32(0), SALT));
        console2.log("queue from the proposer (the team wallet); executeBatch with the same arguments after the delay:");
        console2.log("cast send", TIMELOCK, "'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)'");
        for (uint256 i; i < targets.length; ++i) {
            console2.log("  target", targets[i]);
            console2.logBytes(datas[i]);
        }
        console2.log("  values all 0, predecessor 0x0, salt");
        console2.logBytes32(SALT);
        console2.log("  delay", delay);
    }
}

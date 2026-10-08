// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenSwapper} from "../../src/frens/FrenSwapper.sol";

/// @dev The swapper with its averaging open: no pool manager here, so nothing is seeded and the first buy sets it
contract SwapperProbe is FrenSwapper {
    constructor() FrenSwapper(address(0xdead), address(1), address(2), address(3), address(4), address(5)) {}

    function average(uint256 imdIn, uint256 out) external {
        _average(imdIn, out);
    }
}

/// @notice The slow average the frens value their floor by: a full buy (50 $IMD) moves it 1/64 of the way a block, a
///         smaller one proportionally less, so dust can't steer it; steering it means buying the floor a full buy a
///         block at the pushed price, every one of them into the reserve.
contract FrenSwapperAverageTest is Test {
    SwapperProbe s;
    uint256 constant RATE = 70_000e18; // IMD6900 per $IMD, as the pool pays today

    function setUp() public {
        s = new SwapperProbe();
        assertEq(s.averagedAt(), 0, "no pool manager: nothing seeded");
        s.average(1e18, 70_000e18); // the first buy sets it
        assertEq(s.rateAverage(), RATE);
    }

    function _buy(uint256 imdIn, uint256 rate) internal {
        vm.roll(vm.getBlockNumber() + 1);
        s.average(imdIn, imdIn * rate / 1e18);
    }

    function test_AFullBuyMovesItOneStep() public {
        _buy(s.FULL_BUY(), 2 * RATE);
        assertEq(s.rateAverage(), RATE + RATE / 64, "1/64 of the way to a rate twice as high");
        _buy(10 * s.FULL_BUY(), 2 * RATE);
        assertEq(s.rateAverage(), RATE + RATE / 64 + (RATE - RATE / 64) / 64, "a bigger buy is still one step");
    }

    function test_OnceABlock() public {
        _buy(s.FULL_BUY(), 2 * RATE);
        uint256 a = s.rateAverage();
        s.average(s.FULL_BUY(), 2 * RATE * s.FULL_BUY() / 1e18);
        assertEq(s.rateAverage(), a, "the same block: no second step");
    }

    function test_DustMovesItNextToNothing() public {
        // the pool pushed to 2.6x (IMD6900 cheaper) and held: 100 blocks of dust floor buys (1e9 wei of $IMD each)
        for (uint256 i; i < 100; ++i) {
            _buy(1e9, 26 * RATE / 10);
        }
        assertLt(s.rateAverage() - RATE, RATE / 1_000_000, "dust buys don't steer the average");
        // what it would have taken: a full buy a block, every one bought into the floor at the pushed price
        for (uint256 i; i < 100; ++i) {
            _buy(s.FULL_BUY(), 26 * RATE / 10);
        }
        assertGt(s.rateAverage(), 2 * RATE, "100 full buys move it most of the way");
    }

    function test_ASmallBuyMovesItInProportion() public {
        _buy(s.FULL_BUY() / 10, 2 * RATE);
        assertEq(s.rateAverage(), RATE + RATE / 640, "a tenth of a full buy: a tenth of the step");
    }

    function test_MovesDownToo() public {
        _buy(s.FULL_BUY(), RATE / 2);
        assertEq(s.rateAverage(), RATE - (RATE / 2) / 64);
    }

    function test_FloorRateIsTheLowerReading() public view {
        // no pool manager: spotRate can't be read here; the rule itself is floorRate = min(spot, average)
        assertEq(s.rateAverage(), RATE);
        assertEq(s.FULL_BUY(), 50e18, "the frens' default maxImdPerBuy");
    }
}

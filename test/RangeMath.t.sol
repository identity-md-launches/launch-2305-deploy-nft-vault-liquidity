// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";

/// Exposes the range arithmetic with a primed pool key; no pool is needed for it.
contract RangeHarness is InkLiquidity {
    constructor()
        InkLiquidity(IPoolManager(address(1)), IPositionManager(address(2)), address(3), address(4))
    {}

    function prime(address ink_, address other, int24 spacing, int24 floor, int24 premium_) external {
        (address c0, address c1) = ink_ < other ? (ink_, other) : (other, ink_);
        poolKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, spacing, IHooks(address(0)));
        ink = IERC20(ink_);
        floorTick = floor;
        premium = premium_;
    }

    function rangeFrom(int24 tick, int24 w) external view returns (int24 lower, int24 upper) {
        return _rangeFrom(tick, w);
    }
}

/// Review finding 96b69dd541d1: a width near type(int24).max overflowed `lower + w` before the clamp.
contract RangeMathTest is Test {
    RangeHarness h;
    address ink = address(0x1000);
    address imd = address(0x2000);
    int24 constant SPACING = 60;

    function setUp() public {
        h = new RangeHarness();
    }

    function test_maxWidthClampsWhenInkIsCurrency0() public {
        h.prime(ink, imd, SPACING, 0, 0);
        (int24 lower, int24 upper) = h.rangeFrom(100, type(int24).max);
        assertEq(lower, 120);
        assertEq(upper, TickMath.maxUsableTick(SPACING));
        (lower, upper) = h.rangeFrom(TickMath.maxUsableTick(SPACING) - SPACING, 20_000);
        assertEq(lower, TickMath.maxUsableTick(SPACING));
        assertEq(upper, TickMath.maxUsableTick(SPACING), "empty range at the end, as before");
    }

    function test_maxWidthClampsWhenInkIsCurrency1() public {
        h.prime(imd, ink, SPACING, 0, 0);
        (int24 lower, int24 upper) = h.rangeFrom(-100, type(int24).max);
        assertEq(upper, -120);
        assertEq(lower, TickMath.minUsableTick(SPACING));
    }

    function testFuzz_rangeNeverRevertsAndStaysUsable(int24 tick, int24 w, bool inkIs0) public {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        w = int24(bound(w, SPACING, type(int24).max));
        if (inkIs0) h.prime(ink, imd, SPACING, 0, 0);
        else h.prime(imd, ink, SPACING, 0, 0);
        (int24 lower, int24 upper) = h.rangeFrom(tick, w);
        assertGe(lower, TickMath.minUsableTick(SPACING));
        assertLe(upper, TickMath.maxUsableTick(SPACING));
        assertLe(lower, upper);
        assertEq(lower % SPACING, 0);
        assertEq(upper % SPACING, 0);
    }

    function test_ordinaryWidthUnchanged() public {
        h.prime(ink, imd, SPACING, -129_000, 16_000);
        (int24 lower, int24 upper) = h.rangeFrom(-100_000, 20_000);
        assertEq(lower, -99_960);
        assertEq(upper, -99_960 + 19_980);
    }
}

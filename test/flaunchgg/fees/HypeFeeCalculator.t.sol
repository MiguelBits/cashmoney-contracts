// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HypeFeeCalculator} from "@flaunch/fees/HypeFeeCalculator.sol";
import {FairLaunch} from "@flaunch/hooks/FairLaunch.sol";
import {FlaunchTest} from "../FlaunchTest.sol";

contract HypeFeeCalculatorTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    address internal constant POSITION_MANAGER = address(10);
    address internal constant NATIVE_TOKEN = address(1);
    address internal constant TOKEN = address(2);

    HypeFeeCalculator feeCalculator;
    FairLaunch mockFairLaunch;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        // Deploy mock FairLaunch contract
        vm.prank(POSITION_MANAGER);
        mockFairLaunch = new FairLaunch(IPoolManager(address(0)));

        // Deploy HypeFeeCalculator
        feeCalculator = new HypeFeeCalculator(mockFairLaunch, NATIVE_TOKEN);

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(NATIVE_TOKEN),
            currency1: Currency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(POSITION_MANAGER)
        });

        poolId = poolKey.toId();
    }

    // positionManager()
    function test_CanReferencePositionManager() public view {
        assertEq(feeCalculator.positionManager(), POSITION_MANAGER);
    }

    /// setTargetTokensPerSec()
    function test_CanSetTargetTokensPerSec(uint256 targetRate) public {
        vm.assume(targetRate > 0);

        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));

        (uint256 totalTokensSold, uint256 targetTokensPerSec) = feeCalculator
            .poolInfos(poolId);
        assertEq(targetTokensPerSec, targetRate);
        assertEq(totalTokensSold, 0);
    }

    function test_CannotSetTargetTokensPerSecFromUnknownCaller(
        address caller
    ) public {
        vm.assume(caller != POSITION_MANAGER);

        vm.prank(caller);
        vm.expectRevert(HypeFeeCalculator.CallerNotPositionManager.selector);
        feeCalculator.setFlaunchParams(poolId, abi.encode(1000));
    }

    function test_CannotSetZeroTargetRate() public {
        vm.prank(POSITION_MANAGER);
        vm.expectRevert(HypeFeeCalculator.ZeroTargetTokensPerSec.selector);
        feeCalculator.setFlaunchParams(poolId, abi.encode(0));
    }

    /// determineSwapFee()
    function test_ReturnsBaseFeeOutsideFairLaunch() public {
        uint24 baseFee = 100; // 1%

        // Mock fair launch not active
        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.inFairLaunchWindow, poolId),
            abi.encode(false)
        );

        assertEq(
            feeCalculator.determineSwapFee(
                poolKey,
                _getSwapParams(1e18),
                baseFee
            ),
            baseFee
        );
    }

    function test_CalculatesHypeFee() public {
        uint24 baseFee = 100; // 1%
        uint256 targetRate = 1000; // tokens per second
        uint256 fairLaunchStart = block.timestamp;
        uint256 fairLaunchEnd = fairLaunchStart + 30 minutes;

        // Setup fair launch window
        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.inFairLaunchWindow, poolId),
            abi.encode(true)
        );

        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.fairLaunchInfo, poolId),
            abi.encode(
                FairLaunch.FairLaunchInfo({
                    startsAt: fairLaunchStart,
                    endsAt: fairLaunchEnd,
                    initialTick: 0,
                    revenue: 0,
                    supply: 1e27,
                    closed: false
                })
            )
        );

        // Set target rate
        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));

        // First swap at target rate - should get minimum fee
        vm.warp(fairLaunchStart + 1);
        vm.prank(POSITION_MANAGER);
        _trackSwap(1000); // 1x target rate
        assertEq(
            feeCalculator.determineSwapFee(
                poolKey,
                _getSwapParams(1e18),
                baseFee
            ),
            feeCalculator.MINIMUM_FEE_SCALED() / 100
        );

        // Second swap slightly above target - should get increased fee
        vm.warp(fairLaunchStart + 2);
        vm.prank(POSITION_MANAGER);
        _trackSwap(1500);
        uint24 fee1 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee1, 13_25);

        // Third swap well above target - should get even higher fee
        vm.warp(fairLaunchStart + 3);
        vm.prank(POSITION_MANAGER);
        _trackSwap(3000);
        uint24 fee2 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee2, 41_81);

        // Allow some time to pass - rate should decrease and fee should lower
        vm.warp(fairLaunchStart + 10);
        uint24 fee3 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee3, 1_00);

        // Another large swap - fee should spike again
        vm.prank(POSITION_MANAGER);
        _trackSwap(5000);
        uint24 fee4 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee4, 3_45);

        // Skip to near end of fair launch - rate and fee should be much lower
        vm.warp(fairLaunchEnd - 1 minutes);
        uint24 fee5 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee5, 1_00);
    }

    function test_ReturnsMinimumFeeForLowRate() public {
        uint24 baseFee = 100; // 1%
        uint256 targetRate = 1000; // tokens per second
        uint256 fairLaunchStart = block.timestamp;
        uint256 fairLaunchEnd = fairLaunchStart + 30 minutes;

        // Setup fair launch window
        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.inFairLaunchWindow, poolId),
            abi.encode(true)
        );

        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.fairLaunchInfo, poolId),
            abi.encode(
                FairLaunch.FairLaunchInfo({
                    startsAt: fairLaunchStart,
                    endsAt: fairLaunchEnd,
                    initialTick: 0,
                    revenue: 0,
                    supply: 1e27,
                    closed: false
                })
            )
        );

        // Set target rate
        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));

        // Track small swap
        vm.warp(fairLaunchStart + 1);
        vm.prank(POSITION_MANAGER);
        _trackSwap(500); // 0.5x target rate

        // Fee should be minimum since rate is below target
        uint24 fee = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1e18),
            baseFee
        );
        assertEq(fee, feeCalculator.MINIMUM_FEE_SCALED() / 100);
    }

    function _trackSwap(int128 _amountSpecified) internal {
        feeCalculator.trackSwap(
            address(1),
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int(_amountSpecified),
                sqrtPriceLimitX96: uint160(
                    int160(TickMath.minUsableTick(poolKey.tickSpacing))
                )
            }),
            toBalanceDelta(-(_amountSpecified / 2), _amountSpecified),
            ""
        );
    }
}

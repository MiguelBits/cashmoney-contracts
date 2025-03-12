// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from 'forge-std/Test.sol';
import {println} from 'vulcan/test.sol';

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';


contract DynamicFeeV2ModellingInternal is Test {
    int internal constant VOLUME_DECAY_RATE = -277777777777777777; // -1/3600 scaled to 1e18
    int internal constant FEE_GROWTH_RATE = 277777777777777777; // 1/3600 scaled to 1e18
    uint internal constant MAXIMUM_FEE_SCALED = 50_00_00; // 50% in bps scaled by 1_00
    uint internal constant MINIMUM_FEE_SCALED = 1_00_00; // 1% in bps scaled by 1_00
    uint internal constant TOTAL_TOKEN_SUPPLY = 100e27;
    uint internal constant INCREASE_TOKEN_VOLUME_THRESHOLD = 5e24; // 0.5% of the total supply
    uint internal constant ROLLING_FEE_WINDOW_DURATION = 1 hours;

    uint internal constant ONE_PERCENT_SUPPLY = TOTAL_TOKEN_SUPPLY / 100;

    // function test_feeIncrease() external {
    //     _feeIncrease(INCREASE_TOKEN_VOLUME_THRESHOLD);

    //     _feeIncrease(TOTAL_TOKEN_SUPPLY);
    // }

    // function test_feeDecrease() external {
    //     _feeDecrease(0, MAXIMUM_FEE_SCALED);

    //     _feeDecrease(1, MAXIMUM_FEE_SCALED);
    // }

    function test_accumulatedVolume() external {
        _accumulatedVolume(INCREASE_TOKEN_VOLUME_THRESHOLD, 0);
        _accumulatedVolume(50 * ONE_PERCENT_SUPPLY, 0);
        _accumulatedVolume(100 * ONE_PERCENT_SUPPLY, 0);

        _accumulatedVolume(
            INCREASE_TOKEN_VOLUME_THRESHOLD,
            ROLLING_FEE_WINDOW_DURATION - 1
        );
        _accumulatedVolume(
            50 * ONE_PERCENT_SUPPLY,
            ROLLING_FEE_WINDOW_DURATION - 1
        );
        _accumulatedVolume(
            100 * ONE_PERCENT_SUPPLY,
            ROLLING_FEE_WINDOW_DURATION - 1
        );
    }

    // ExpOverflow()
    function _feeIncrease(uint volumeAboveThreshold) internal view {
        uint growthFactor = uint(
            FixedPointMathLib.expWad(
                int(volumeAboveThreshold) * FEE_GROWTH_RATE
            )
        );
        uint feeIncreasedScaled = FixedPointMathLib.mulDivUp(
            MAXIMUM_FEE_SCALED - MINIMUM_FEE_SCALED,
            growthFactor,
            1 ether
        );

        uint newFeeScaled = MINIMUM_FEE_SCALED + feeIncreasedScaled;

        println(
            'volumeAboveThreshold: {u:d18} newFeeScaled: {u:d4}',
            abi.encode(volumeAboveThreshold, newFeeScaled)
        );
    }

    // ExpOverflow()
    function _feeDecrease(
        uint timeRemaining,
        uint currentFeeScaled
    ) internal view {
        // as timeRemaining decreases, the decayFactor decreases
        uint growthFactor = uint(
            FixedPointMathLib.expWad(int(timeRemaining) * FEE_GROWTH_RATE)
        );
        uint feeDecreaseScaled = FixedPointMathLib.mulDivUp(
            currentFeeScaled - MINIMUM_FEE_SCALED,
            growthFactor,
            1 ether
        );

        uint swapFeeScaled = currentFeeScaled - feeDecreaseScaled;

        println(
            'timeRemaining: {u} swapFeeScaled: {u:d4}',
            abi.encode(timeRemaining, swapFeeScaled)
        );
    }

    function _accumulatedVolume(
        uint accumulatorWeightedVolume,
        uint timeElapsed
    ) internal view {
        uint decayFactor = uint(
            FixedPointMathLib.expWad(int(timeElapsed) * VOLUME_DECAY_RATE)
        );
        accumulatorWeightedVolume =
            (accumulatorWeightedVolume * decayFactor) /
            1 ether;

        println(
            'timeElapsed: {u} accumulatorWeightedVolume: {u:d18}',
            abi.encode(timeElapsed, accumulatorWeightedVolume)
        );
    }
}

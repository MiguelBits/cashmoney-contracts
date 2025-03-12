// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';


/**
 * Calculates hype fees during fair launch based on token sale rates.
 * The fee increases as the sale rate exceeds the target rate to discourage sniping.
 */
contract HypeFeeCalculator is IFeeCalculator {

    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint;

    error CallerNotPositionManager();
    error ZeroTargetTokensPerSec();

    /**
     * Holds information regarding each pool used in price calculations.
     *
     * @member totalTokensSold Total tokens sold during fair launch
     * @member targetTokensPerSec Target tokens per second
     */
    struct PoolInfo {
        uint totalTokensSold;
        uint targetTokensPerSec;
    }

    /// Our fair launch window duration
    uint internal constant FAIR_LAUNCH_WINDOW = 30 minutes;

    /// The scaling factor for the fee
    uint24 internal constant SCALING_FACTOR = 1e4;

    /// The fee charged for swaps has to be always greater than MINIMUM_FEE represented in bps
    uint24 public constant MINIMUM_FEE_SCALED = 1_0000; // 1% in bps scaled by 1_00

    /// The fee charged for swaps has to be always less than MAXIMUM_FEE represented in bps
    uint24 public constant MAXIMUM_FEE_SCALED = 50_0000; // 50% in bps scaled by 1_00

    /// The FairLaunch contract reference
    FairLaunch public immutable fairLaunch;

    /// The PositionManager contract reference
    address public immutable positionManager;

    /// Our native token
    address public immutable nativeToken;

    /// Maps pool IDs to their info
    mapping(PoolId => PoolInfo) public poolInfos;

    /**
     * Registers our FairLaunch contract and native token.
     *
     * @param _fairLaunch The address of our {FairLaunch} contract
     * @param _nativeToken The native token used for Flaunch
     */
    constructor (FairLaunch _fairLaunch, address _nativeToken) {
        fairLaunch = _fairLaunch;
        nativeToken = _nativeToken;

        // Find the {PositionManager} used by the {FairLaunch} contract
        positionManager = _fairLaunch.positionManager();
    }

    /**
     * Takes parameters during a Flaunch call to customise the PoolInfo.
     *
     * @param _poolId The PoolId of the pool that has been flaunched
     * @param _params Any additional parameter information
     */
    function setFlaunchParams(PoolId _poolId, bytes calldata _params) external override {
        // Decode the required parameters
        uint _targetTokensPerSec = abi.decode(_params, (uint));

        // Ensure that this call is coming from the {PositionManager} and validate the
        // value passed.
        if (msg.sender != positionManager) revert CallerNotPositionManager();
        if (_targetTokensPerSec == 0) revert ZeroTargetTokensPerSec();

        poolInfos[_poolId].targetTokensPerSec = _targetTokensPerSec;
    }

    /**
     * Calculates the current swap fee based on token sale rate.
     *
     * @param _poolKey The PoolKey to calculate the swap fee for
     * @param _baseFee The base fee of the pool
     *
     * @return swapFee_ The swap fee to be applied
     */
    function determineSwapFee(
        PoolKey memory _poolKey,
        IPoolManager.SwapParams memory,
        uint24 _baseFee
    ) external view override returns (uint24 swapFee_) {
        PoolId poolId = _poolKey.toId();

        // Return base fee if no swaps yet or fair launch ended
        if (!fairLaunch.inFairLaunchWindow(poolId)) {
            return _baseFee;
        }

        PoolInfo memory poolInfo = poolInfos[poolId];
        FairLaunch.FairLaunchInfo memory flInfo = fairLaunch.fairLaunchInfo(poolId);

        uint elapsedSeconds = block.timestamp - (flInfo.endsAt - FAIR_LAUNCH_WINDOW);

        // Prevent division by zero
        if (elapsedSeconds == 0) return _baseFee;

        // Calculate current sale rate
        uint currentSaleRatePerSec = poolInfo.totalTokensSold / elapsedSeconds;
        uint targetTokensPerSec = getTargetTokensPerSec(poolId);

        uint swapFeeScaled;

        // If sale rate <= target rate, return min fee
        if (currentSaleRatePerSec <= targetTokensPerSec) {
            swapFeeScaled = MINIMUM_FEE_SCALED;
        } else {
            // Calculate hype fee
            uint rateExcess = currentSaleRatePerSec - targetTokensPerSec;
            uint hypeFeeScaled = MINIMUM_FEE_SCALED +
                ((MAXIMUM_FEE_SCALED - MINIMUM_FEE_SCALED) * rateExcess) /
                targetTokensPerSec;

            // Cap at MAX_FEE
            swapFeeScaled = FixedPointMathLib.min(hypeFeeScaled, MAXIMUM_FEE_SCALED);
        }

        // Ensure that the swap fee is at least the base fee. scale down the result to bps
        swapFee_ = uint24(
            FixedPointMathLib.max(swapFeeScaled, _baseFee * 1_00) / 1_00
        );
    }

    /**
     * After a swap is made, we track the total tokens sold in fair launch window
     *
     * @param _key The key for the pool
     * @param _delta The amount owed to the caller (positive) or owed to the pool (negative)
     */
    function trackSwap(
        address /* _sender */,
        PoolKey calldata _key,
        IPoolManager.SwapParams calldata /* _params */,
        BalanceDelta _delta,
        bytes calldata /* _hookData */
    ) external override {
        // Ensure that this call is coming from the {PositionManager}
        if (msg.sender != positionManager) revert CallerNotPositionManager();

        // Load our PoolInfo, opened as storage to update values
        PoolId poolId = _key.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];

        // Skip if pool not initialized or fair launch ended
        if (!fairLaunch.inFairLaunchWindow(poolId)) {
            return;
        }

        // Absolute amount of non-native token swapped
        int tokenDelta = int(
            Currency.unwrap(_key.currency0) == nativeToken
                ? _delta.amount1()
                : _delta.amount0()
        );

        // Update the total tokens sold
        poolInfo.totalTokensSold += uint(tokenDelta < 0 ? -tokenDelta : tokenDelta);
    }

    /**
     * Gets the target tokens per second for the pool.
     *
     * If no target tokens per second is set, determine via the fair launch supply can happen
     * when the fee calculator is set after the fair launch has already started.
     *
     * @param _poolId The PoolId of the pool to query
     *
     * @return The target tokens per second
     */
    function getTargetTokensPerSec(PoolId _poolId) public view returns (uint) {
        uint storedTargetTokensPerSec = poolInfos[_poolId].targetTokensPerSec;

        //
        if (storedTargetTokensPerSec == 0) {
            return fairLaunch.fairLaunchInfo(_poolId).supply / FAIR_LAUNCH_WINDOW;
        }

        return storedTargetTokensPerSec;
    }
}

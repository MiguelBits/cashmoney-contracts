// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';


/**
 * As an alternative to Pausable logic in the {PositionManager}, this calculator will revert
 * transactions in the same way that {Pausable} would.
 *
 * @dev This must be set as both the Fair Launch calculator **and** the normal calculator.
 */
contract PauseCalculator is IFeeCalculator {

    /**
     * @dev The operation failed because the contract is paused.
     */
    error EnforcedPause();

    /**
     * Prevents a new token from being flaunched.
     *
     * @dev Called by the {PositionManager} `flaunch` function.
     */
    function setFlaunchParams(PoolId, bytes calldata) external pure override {
        revert EnforcedPause();
    }

    /**
     * Prevents swaps.
     *
     * @dev Called via the {FeeDistributor} via {PositionManager} `_captureAndDepositFees` in the
     * `beforeSwap` and `afterSwap` hooks.
     */
    function determineSwapFee(PoolKey memory, IPoolManager.SwapParams memory, uint24) external pure override returns (uint24) {
        revert EnforcedPause();
    }

    /**
     * Not required, as the swap will already have been reverted through calling `determineSwapFee`.
     */
    function trackSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external pure override {
        // ..
    }

}

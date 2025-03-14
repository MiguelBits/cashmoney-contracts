// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {PositionManager} from "../../src/PositionManager.sol";

contract MockReenterHook is BaseTestHooks {
    PositionManager posm;

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata functionSelector
    ) external override returns (bytes4) {
        if (functionSelector.length == 0) {
            return this.beforeAddLiquidity.selector;
        }
        (bytes4 selector, address owner, uint256 tokenId) = abi.decode(functionSelector, (bytes4, address, uint256));

        if (selector == posm.transferFrom.selector) {
            posm.transferFrom(owner, address(this), tokenId);
        } else if (selector == posm.subscribe.selector) {
            posm.subscribe(tokenId, address(this), "");
        } else if (selector == posm.unsubscribe.selector) {
            posm.unsubscribe(tokenId);
        }
        return this.beforeAddLiquidity.selector;
    }

    function setPosm(PositionManager _posm) external {
        posm = _posm;
    }
}

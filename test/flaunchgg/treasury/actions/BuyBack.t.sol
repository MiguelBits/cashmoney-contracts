// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {BuyBackAction, ITreasuryAction} from '@flaunch/treasury/actions/BuyBack.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from '../../FlaunchTest.sol';


contract BuyBackActionTest is FlaunchTest {

    PoolKey poolKey;
    BuyBackAction action;
    MemecoinTreasury memecoinTreasury;

    address memecoin;

    function setUp() public {
        _deployPlatform();

        // Flaunch a new token
        memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(10),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get our Treasury contract
        memecoinTreasury = MemecoinTreasury(IMemecoin(memecoin).treasury());

        poolKey = positionManager.poolKey(memecoin);

        // Deploy our action
        action = new BuyBackAction(positionManager.nativeToken(), address(poolSwap));

        // Approve our action in the ActionManager
        positionManager.actionManager().approveAction(address(action));
    }

    function test_CanGetConstructorVariables() public view {
        assertEq(Currency.unwrap(action.nativeToken()), positionManager.nativeToken());
        assertEq(address(action.poolSwap()), address(poolSwap));
    }

    function test_CanBuyBackWithZeroNativeTokens() public {
        // If the user has zero balance, then the event will return without reverting, but
        // it won't emit any events.
        memecoinTreasury.executeAction(address(action), abi.encode(TickMath.MIN_SQRT_PRICE));
    }

    function test_CanBuyBack() public {
        uint _amount = 1 ether;

        _bypassFairLaunch();

        // Add token liquidity
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Deal and approve
        deal(Currency.unwrap(poolKey.currency0), address(memecoinTreasury), _amount);

        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, -1000000000000000000, 1974064050842644603);

        memecoinTreasury.executeAction(address(action), abi.encode(TickMath.MIN_SQRT_PRICE + 1));
    }

}

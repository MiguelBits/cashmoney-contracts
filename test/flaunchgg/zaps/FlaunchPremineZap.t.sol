// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {FlaunchPremineZap} from '@flaunch/zaps/FlaunchPremineZap.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract FlaunchPremineZapTests is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    constructor() {
        _deployPlatform();
    }

    function test_CanPremineTokens(bool _flipped) external flipTokens(_flipped) {
        // Ensure we have a valid initial supply & premine amount
        uint _supply = 0.25e27;
        uint _premineAmount = supplyShare(5);

        // Set a market cap tick that is roughly equal to 2e18 : 1e27
        initialPrice.setSqrtPriceX96(InitialPrice.InitialSqrtPriceX96({
            unflipped: TickMath.getSqrtPriceAtTick(200703),
            flipped: TickMath.getSqrtPriceAtTick(-200704)
        }));

        // {PoolManager} must have some initial flETH balance to serve `take()` requests in our hook
        deal(address(flETH), address(poolManager), 1000e27 ether);

        // Store the ETH balance held before the flaunch
        uint ethBalBefore = address(this).balance;

        // Calculate the fee with 0% slippage
        uint ethRequired = premineZap.calculateFee(_premineAmount, 0, abi.encode(''));

        // Create our Memecoin, sending all ETH to account for residue as well
        (address memecoin, uint ethSpent) = premineZap.flaunch{value: ethRequired}(
            PositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', _supply, _premineAmount, address(this), 0, 0, abi.encode(''), abi.encode(1_000)
            )
        );

        // Confirm that we spent the expected amount
        assertApproxEqRel(ethRequired, ethSpent, 1e16, 'Invalid ETH spent');

        // Confirm that the caller is the confirmed creator of the token
        assertEq(IMemecoin(memecoin).creator(), address(this), 'Invalid Creator');

        // Ensure the actual ETH spent is less than or equal to our expected value
        assertLe(ethBalBefore - address(this).balance, ethRequired, 'Invalid ETH spent');

        // Confirm that the returned `ethSpent` variable is correct
        assertEq(ethBalBefore - address(this).balance, ethSpent, 'Invalid ethSpent returned');

        // Confirm that the user received their expected amount of tokens
        assertEq(IERC20(memecoin).balanceOf(address(this)), _premineAmount, 'Invalid token balance');
    }

    function test_CannotPremineTokensIfAmountExceedsSupply(
        uint _supply,
        uint _premineAmount,
        bool _flipped
    ) external flipTokens(_flipped) {
        // Ensure we have a valid initial supply & premine amount
        _supply = bound(_supply, supplyShare(10), flaunch.MAX_FAIR_LAUNCH_TOKENS());
        vm.assume(_premineAmount > _supply);

        vm.expectRevert(
            abi.encodeWithSelector(
                Flaunch.PremineExceedsInitialAmount.selector,
                _premineAmount,
                _supply
            )
        );

        premineZap.flaunch(
            PositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', _supply, _premineAmount, address(this), 0, 0, abi.encode(''), abi.encode(1_000)
            )
        );
    }

    function test_CanCalculateFees() public {
        // Set an fee to flaunch
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingFee.selector),
            abi.encode(0.001e18)
        );

        // Set an expected market cap here to in-line with Sepolia tests (2~ eth)
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingMarketCap.selector),
            abi.encode(2e18)
        );

        // premineCost : 0.1 ether
        // premineCost swap fee : 0.001 ether
        // fee : 0.001 ether

        uint ethRequired = premineZap.calculateFee(supplyShare(5_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.1 ether + 0.001 ether + 0.001 ether);

        // premineCost : 0.2 ether
        // premineCost swap fee : 0.002 ether
        // fee : 0.001 ether

        ethRequired = premineZap.calculateFee(supplyShare(10_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.2 ether + 0.002 ether + 0.001 ether);
    }

}

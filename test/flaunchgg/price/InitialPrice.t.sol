// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {InitialPrice} from '@flaunch/price/InitialPrice.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract InitialPriceTest is FlaunchTest {

    address owner = address(0x123);
    address nonOwner = address(0x456);

    function setUp() public {
        // Deploy contract and set `owner` as the protocol owner
        initialPrice = new InitialPrice(0, owner);
    }

    // Test that the owner is set correctly upon initialization
    function test_InitialOwner() public view {
        assertEq(initialPrice.owner(), owner, 'Owner should be set correctly');
    }

    function test_CanSetFlaunchingFee(uint _fee, address _sender) public {
        // Deploy a contract setting the fee
        initialPrice = new InitialPrice(_fee, owner);
        assertEq(initialPrice.getFlaunchingFee(_sender, abi.encode('')), _fee);
    }

    function test_CanGetMarketCap() public {
        // Deploy a contract setting the fee
        initialPrice = new InitialPrice(0.001 ether, owner);

        // Set a market cap tick that is roughly equal to 2e18 : 100e27
        vm.prank(owner);
        initialPrice.setSqrtPriceX96(InitialPrice.InitialSqrtPriceX96({
            unflipped: TickMath.getSqrtPriceAtTick(246765),
            flipped: TickMath.getSqrtPriceAtTick(-246766)
        }));

        // Try and get the market cap
        assertApproxEqRel(initialPrice.getMarketCap(abi.encode('')), 1.92 ether, 0.01 ether);
    }

    // Test that non-owner cannot set sqrtPriceX96
    function test_SetSqrtPriceX96FailsForNonOwner() public {
        // Expect revert when a non-owner tries to set price
        vm.prank(nonOwner);
        InitialPrice.InitialSqrtPriceX96 memory newPrice = InitialPrice.InitialSqrtPriceX96(100, 200);
        vm.expectRevert(UNAUTHORIZED);
        initialPrice.setSqrtPriceX96(newPrice);
    }

    // Test that the owner can set and retrieve the unflipped and flipped prices
    function test_SetAndGetSqrtPriceX96() public {
        InitialPrice.InitialSqrtPriceX96 memory newPrice = InitialPrice.InitialSqrtPriceX96(100, 200);

        // Set the price as the owner
        vm.prank(owner);
        initialPrice.setSqrtPriceX96(newPrice);

        // Test the unflipped price retrieval
        uint160 unflippedPrice = initialPrice.getSqrtPriceX96(address(this), false, abi.encode(''));
        assertEq(unflippedPrice, 100, 'Unflipped price should be correct');

        // Test the flipped price retrieval
        uint160 flippedPrice = initialPrice.getSqrtPriceX96(address(this), true, abi.encode(''));
        assertEq(flippedPrice, 200, 'Flipped price should be correct');
    }

    // Test the event emission when the owner sets the price
    function test_EventEmissionOnSetPrice() public {
        InitialPrice.InitialSqrtPriceX96 memory newPrice = InitialPrice.InitialSqrtPriceX96(100, 200);

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit InitialPrice.InitialSqrtPriceX96Updated(100, 200);

        // Set the price as the owner
        vm.prank(owner);
        initialPrice.setSqrtPriceX96(newPrice);
    }

    // Test that only owner can call setSqrtPriceX96
    function test_OnlyOwnerCanSetSqrtPriceX96() public {
        InitialPrice.InitialSqrtPriceX96 memory newPrice = InitialPrice.InitialSqrtPriceX96(300, 400);

        // Non-owner attempt to set the price should fail
        vm.prank(nonOwner);
        vm.expectRevert(UNAUTHORIZED);
        initialPrice.setSqrtPriceX96(newPrice);

        // Owner can set the price successfully
        vm.prank(owner);
        initialPrice.setSqrtPriceX96(newPrice);

        // Ensure the prices were set correctly
        assertEq(initialPrice.getSqrtPriceX96(address(this), false, abi.encode('')), 300, 'Unflipped price should be 300');
        assertEq(initialPrice.getSqrtPriceX96(address(this), true, abi.encode('')), 400, 'Flipped price should be 400');
    }

    // Test that setting the price works with edge values
    function test_SetSqrtPriceX96WithEdgeValues() public {
        InitialPrice.InitialSqrtPriceX96 memory edgePrice = InitialPrice.InitialSqrtPriceX96(
            type(uint160).max, // Maximum possible uint160 value
            0                  // Minimum possible value
        );

        // Set edge values as owner
        vm.prank(owner);
        initialPrice.setSqrtPriceX96(edgePrice);

        // Test retrieval of edge values
        assertEq(initialPrice.getSqrtPriceX96(address(this), false, abi.encode('')), type(uint160).max, 'Unflipped price should be max uint160');
        assertEq(initialPrice.getSqrtPriceX96(address(this), true, abi.encode('')), 0, 'Flipped price should be 0');
    }
}

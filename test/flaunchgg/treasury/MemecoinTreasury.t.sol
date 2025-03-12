// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {BlankAction} from '@flaunch/treasury/actions/Blank.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {TreasuryActionManager} from '@flaunch/treasury/ActionManager.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract MemecoinTreasuryTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    TreasuryActionManager internal actionManager;
    BlankAction internal blankAction;
    MemecoinTreasury internal memecoinTreasury;

    address internal token;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Register our {TreasuryActionManager}
        actionManager = positionManager.actionManager();

        // Register our blank action
        blankAction = new BlankAction();

        token = positionManager.flaunch(
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

        // Load our MemecoinTreasury
        memecoinTreasury = MemecoinTreasury(flaunch.memecoinTreasury(1));
    }

    function test_CanExecuteAction(bytes memory _data) public {
        // Approve the action
        actionManager.approveAction(address(blankAction));

        PoolKey memory poolKey = positionManager.poolKey(token);

        // Execute the action
        vm.expectEmit();
        emit MemecoinTreasury.ActionExecuted(address(blankAction), poolKey, _data);
        memecoinTreasury.executeAction(address(blankAction), _data);
    }

    function test_CannotExecuteUnapprovedAction(bytes memory _data) public {
        // Execute the action
        vm.expectRevert(MemecoinTreasury.ActionNotApproved.selector);
        memecoinTreasury.executeAction(address(blankAction), _data);
    }

    function test_CannotExecuteActionWithoutTokenHolding(address _caller, bytes memory _data) public {
        vm.assume(_caller != address(this));

        // Approve the action
        actionManager.approveAction(address(blankAction));

        vm.startPrank(_caller);

        // Execute the action
        vm.expectRevert(UNAUTHORIZED);
        memecoinTreasury.executeAction(address(blankAction), _data);

        vm.stopPrank();
    }

    function test_CanClaimFees_NoFlthAdded() public {
        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Call claimFees
        memecoinTreasury.claimFees();

        // Check that ETH balance has not changed
        assertEq(
            WETH.balanceOf(address(memecoinTreasury)),
            initialBalance,
            'ETH should not have been added'
        );
    }

    function test_CanClaimFees_FlethAdded(uint _flethAdded) public {
        // Set the {PositionManager} fees for {MemecoinTreasury} to a positive amount
        vm.assume(_flethAdded > 0);
        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),
            _recipient: payable(address(memecoinTreasury)),
            _amount: _flethAdded
        });

        // Provide sufficient native token to the {PositionManager}
        vm.startPrank(address(positionManager));
        deal(address(positionManager), _flethAdded);
        WETH.deposit{value: _flethAdded}();
        vm.stopPrank();

        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Call claimFees
        memecoinTreasury.claimFees();

        // Check that ETH balance increased by the expected amount
        assertEq(
            WETH.balanceOf(address(memecoinTreasury)),
            initialBalance + _flethAdded,
            'flETH should have been added'
        );
    }

    function test_CanClaimFeesDuringTransaction(uint _flethAdded) public {
        // Set the {PositionManager} fees for {MemecoinTreasury} to a positive amount
        vm.assume(_flethAdded > 0);
        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),
            _recipient: payable(address(memecoinTreasury)),
            _amount: _flethAdded
        });

        // Provide sufficient native token to the {PositionManager}
        vm.startPrank(address(positionManager));
        deal(address(positionManager), _flethAdded);
        WETH.deposit{value: _flethAdded}();
        vm.stopPrank();

        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Approve our blank action and execute it, which should claim the fees
        actionManager.approveAction(address(blankAction));
        memecoinTreasury.executeAction(address(blankAction), '');

        // Check that ETH balance increased by the expected amount
        assertEq(
            WETH.balanceOf(address(memecoinTreasury)),
            initialBalance + _flethAdded,
            'flETH should have been added'
        );
    }

}

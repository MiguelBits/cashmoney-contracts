// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {TreasuryActionManager} from '@flaunch/treasury/ActionManager.sol';
import {BlankAction} from '@flaunch/treasury/actions/Blank.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract TreasuryActionManagerTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    TreasuryActionManager internal actionManager;
    BlankAction internal blankAction;

    address internal token;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Register our {TreasuryActionManager}
        actionManager = positionManager.actionManager();

        // Register our blank action
        blankAction = new BlankAction();
    }

    function test_CanGetConstructorVariables() public view {
        assertEq(actionManager.owner(), address(this));
    }

    function test_CanApproveAction(address _action) public {
        // Approve the token
        vm.expectEmit();
        emit TreasuryActionManager.ActionApproved(_action);
        actionManager.approveAction(_action);

        // Approve it again
        vm.expectEmit();
        emit TreasuryActionManager.ActionApproved(_action);
        actionManager.approveAction(_action);
    }

    function test_CannotApproveActionWithoutPermissions(address _action) public {
        vm.startPrank(address(1));

        vm.expectRevert();
        actionManager.approveAction(_action);

        vm.stopPrank();
    }

    function test_CanUnapproveAction(address _action) public {
        // Unapprove the token when it is already approved
        vm.expectEmit();
        emit TreasuryActionManager.ActionUnapproved(_action);
        actionManager.unapproveAction(_action);

        // Approve the token
        actionManager.approveAction(_action);

        // Unapprove the token
        vm.expectEmit();
        emit TreasuryActionManager.ActionUnapproved(_action);
        actionManager.unapproveAction(_action);
    }

    function test_CannotUnapproveActionWithoutPermissions(address _action) public {
        actionManager.approveAction(_action);

        vm.startPrank(address(1));

        vm.expectRevert();
        actionManager.unapproveAction(_action);

        vm.stopPrank();
    }

    modifier flaunchToken {
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

        _;
    }

}

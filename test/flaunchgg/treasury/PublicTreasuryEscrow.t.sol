// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from '@solady/utils/Initializable.sol';

import {BlankAction} from '@flaunch/treasury/actions/Blank.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';
import {PublicTreasuryEscrow} from '@flaunch/treasury/PublicTreasuryEscrow.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract PublicTreasuryEscrowTest is FlaunchTest {

    PublicTreasuryEscrow escrow;

    address owner = address(0x123);
    address nonOwner = address(0x456);
    uint256 tokenId = 1;

    function setUp() public {
        _deployPlatform();

        // Deploy the escrow contract
        escrow = new PublicTreasuryEscrow(address(flaunch));

        // Flaunch a new coin and approve the escrow to use it. We know that this will be the
        // first token flaunched, so we can just use the tokenId '1'.
        vm.startPrank(owner);
        positionManager.flaunch(PositionManager.FlaunchParams('Test', 'TEST', '', supplyShare(50), 0, owner, 10_00, 0, abi.encode(''), abi.encode(1_000)));
        flaunch.approve(address(escrow), 1);
        vm.stopPrank();
    }

    function test_CanInitialize() public {
        vm.prank(owner);
        escrow.initialize(tokenId);

        assertEq(escrow.tokenId(), tokenId);
        assertEq(escrow.originalOwner(), owner);
        assertEq(flaunch.ownerOf(tokenId), address(escrow));
    }

    function test_CannotInitializeTwice() public {
        vm.startPrank(owner);
        escrow.initialize(tokenId);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(tokenId);
        vm.stopPrank();
    }

    function test_CanReclaimByOriginalOwner() public {
        vm.startPrank(owner);
        escrow.initialize(tokenId);
        escrow.reclaim();
        vm.stopPrank();

        assertEq(flaunch.ownerOf(tokenId), owner);
        assertEq(escrow.originalOwner(), address(0));
    }

    function test_CannotReclaimIfNotOwner() public {
        vm.prank(owner);
        escrow.initialize(tokenId);

        vm.prank(nonOwner);
        vm.expectRevert(PublicTreasuryEscrow.NotOriginalOwner.selector);
        escrow.reclaim();
    }

    function test_CannotReclaimIfOwnershipBurned() public {
        vm.startPrank(owner);
        escrow.initialize(tokenId);
        escrow.burnOwnership();

        vm.expectRevert(PublicTreasuryEscrow.OwnershipBurned.selector);
        escrow.reclaim();
        vm.stopPrank();
    }

    function testBurnOwnership() public {
        vm.prank(owner);
        escrow.initialize(tokenId);
        vm.prank(owner);
        escrow.burnOwnership();
        assertTrue(escrow.ownershipBurned());
    }

    function testCannotBurnOwnershipIfNotOwner() public {
        vm.prank(owner);
        escrow.initialize(tokenId);

        vm.prank(nonOwner);
        vm.expectRevert(PublicTreasuryEscrow.NotOriginalOwner.selector);
        escrow.burnOwnership();
    }

    function test_CannotBurnOwnershipIfAlreadyBurned() public {
        vm.startPrank(owner);
        escrow.initialize(tokenId);
        escrow.burnOwnership();

        vm.expectRevert(PublicTreasuryEscrow.OwnershipBurned.selector);
        escrow.burnOwnership();
        vm.stopPrank();
    }

    function test_CanClaim() public {
        vm.startPrank(owner);
        escrow.initialize(tokenId);
        escrow.claim();
        vm.stopPrank();
    }

    function test_CanExecuteAction() public {
        // Setup to allow testing executeAction functionality
        address action = address(new BlankAction());
        bytes memory data = '0x1234';
        positionManager.actionManager().approveAction(action);

        vm.prank(owner);
        escrow.initialize(tokenId);

        vm.prank(nonOwner);
        escrow.executeAction(action, data);
    }

}

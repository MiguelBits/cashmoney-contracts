// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IL2ToL2CrossDomainMessenger} from "@optimism/L2/interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Predeploys} from '@optimism/libraries/Predeploys.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from './FlaunchTest.sol';


contract FlaunchBridgeTest is FlaunchTest {

    /// This will be the token ID of the flaunched token
    uint TOKEN_ID = 1;

    /// Define an alternative chain
    uint ALTERNATIVE_CHAIN_ID = 420691337;

    /// The memecoin used for testing
    IMemecoin internal memecoin;

    function setUp() public {
        _deployPlatform();

        // Mock our messenger send to prevent errors
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.sendMessage.selector),
            abi.encode('')
        );

        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.crossDomainMessageSource.selector),
            abi.encode(uint(123))
        );

        // Deploy a memecoin through flaunching
        address memecoinAddress = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Cast our address to a memecoin we can reference in tests
        memecoin = IMemecoin(memecoinAddress);
    }

    function test_CanInitializeBridge_Success() public {
        // Confirm that the brdiging status is initially pending
        assertFalse(
            flaunch.bridgingStatus(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            "Bridging status should be false before initialization."
        );

        vm.expectEmit();
        emit Flaunch.TokenBridging(TOKEN_ID, ALTERNATIVE_CHAIN_ID, address(memecoin));

        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        // Confirm that the brdiging status has updated
        assertTrue(
            flaunch.bridgingStatus(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            "Bridging status should be true after initialization."
        );
    }

    function test_CannotInitializeBridge_AlreadyBridged() public {
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        vm.expectRevert(Flaunch.TokenAlreadyBridged.selector);
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);
    }

    function test_CannotInitializeBridge_DoesNotExist() public {
        vm.expectRevert(Flaunch.UnknownMemecoin.selector);
        flaunch.initializeBridge(TOKEN_ID + 1, ALTERNATIVE_CHAIN_ID);
    }

    function test_CanFinalizeBridge_Success() public isValidMessenger isValidSender {
        Flaunch.MemecoinMetadata memory memecoinMetadata = Flaunch.MemecoinMetadata({
            name: memecoin.name(),
            symbol: memecoin.symbol(),
            tokenUri: memecoin.tokenURI()
        });

        vm.chainId(ALTERNATIVE_CHAIN_ID);

        vm.expectEmit();
        emit Flaunch.TokenBridged(TOKEN_ID + 1, ALTERNATIVE_CHAIN_ID, 0x1A727A1caeE6449862aEF80DC3b47E1759ad3967, 123);

        flaunch.finalizeBridge(
            TOKEN_ID + 1,
            memecoinMetadata
        );

        // Additional assertions
        IMemecoin bridgedMemecoin = IMemecoin(0x1A727A1caeE6449862aEF80DC3b47E1759ad3967);
        assertEq(bridgedMemecoin.name(), memecoin.name());
        assertEq(bridgedMemecoin.symbol(), memecoin.symbol());
        assertEq(bridgedMemecoin.tokenURI(), memecoin.tokenURI());

    }

    modifier isValidMessenger {
        vm.startPrank(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        _;
    }

    modifier isValidSender {
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.crossDomainMessageSender.selector),
            abi.encode(address(flaunch))
        );

        _;
    }

}

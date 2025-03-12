// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/console.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {InternalSwapPool} from '@flaunch/hooks/InternalSwapPool.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {BidWallMock} from './mocks/BidWallMock.sol';
import {PositionManagerMock} from './mocks/PositionManagerMock.sol';
import {FlaunchTest} from './FlaunchTest.sol';


contract PoolSwapTests is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    function test_CanSell() internal forkBaseSepoliaBlock(17100844) {
        // ..
        address bidWall = 0x76eE99501407b80BC2fD8b0eC5AbC4812DB89F3e;

        // ..
        address to = 0x95273d871c8156636e114b63797d78D7E1720d81;
        address from = 0xb06a64615842CbA9b3Bdb7e6F726F3a5BD20daC2;
        bytes memory data = hex'24856bc30000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000020a100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000160000000000000000000000000fc23f4aab1c60b3f09d6765ecab603b1e141dd50000000000000000000000000ffffffffffffffffffffffffffffffffffffffff0000000000000000000000000000000000000000000000000000ffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000095273d871c8156636e114b63797d78d7e1720d81ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041e9b7586396964a139bc112bdac585b1508f5be999594b4072e0b81113c91c939276a31bd3b1fbb71750780001718c0f8e00c77210883fb513417bfad1c6ecab41c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000002051600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000fc23f4aab1c60b3f09d6765ecab603b1e141dd500000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000001295616e4f5c4fac78ec80d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000012000000000000000000000000079fc52701cd4be6f9ba9adc94c207de37e3314eb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000018a823027ab9d168b2fd235fbfd506916401bfdc00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000ed5feec571d132aea6d6a636c683b818b344288800000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000fc23f4aab1c60b3f09d6765ecab603b1e141dd500000000000000000000000000000000000000000000000000000000000000000';

        // ..
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb),
            currency1: Currency.wrap(0xFC23F4aab1c60b3F09d6765EcAb603B1E141dd50),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(0x18A823027ab9d168B2fD235fbfd506916401BFdC)
        });

        // Get the current pool info
        (
            bool disabled,
            bool initialized,
            int24 tickLower,
            int24 tickUpper,
            uint pendingETHFees,
            uint cumulativeSwapFees
        ) = BidWall(bidWall).poolInfo(poolKey.toId());

        console.log('~~~');
        console.log(disabled);
        console.log(initialized);
        console.log(tickLower);
        console.log(tickUpper);
        console.log(pendingETHFees);
        console.log(cumulativeSwapFees);

        console.log(address(BidWall(bidWall).poolManager()));
        console.log(address(BidWall(bidWall).positionManager()));
        console.log(BidWall(bidWall).nativeToken());

        vm.startPrank(from);
        (bool success,) = to.call(data);
        assertFalse(success, 'TX should not have passed');
        vm.stopPrank();

        // ..
        vm.startPrank(0x18A823027ab9d168B2fD235fbfd506916401BFdC);
        deployCodeTo('BidWallMock.sol', abi.encode(
            0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb, // flETH
            0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829  // PoolManager
        ), bidWall);
        vm.stopPrank();

        // ..
        BidWallMock(bidWall).setSwapFeeThresholdMock(0.001 ether);

        // ..
        BidWallMock(bidWall).setPoolInfo(poolKey.toId(), BidWall.PoolInfo({
            disabled: disabled,
            initialized: initialized,
            tickLower: tickLower,
            tickUpper: tickUpper,
            pendingETHFees: pendingETHFees,
            cumulativeSwapFees: cumulativeSwapFees
        }));

        vm.startPrank(from);
        (success,) = to.call(data);
        assertTrue(success, 'Failed tx');
        vm.stopPrank();
    }

    function test_CanBuy() internal forkBaseSepoliaBlock(18512471) {

        // $TIMMAY memecoin
        address timmay = 0xa0D0Ef63c8ff5A879118f3c5B856483370A956c6;
        address native = 0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb;

        // PositionManager
        PositionManager positionManager = PositionManager(payable(0x5f9466BC4b1eBbA82b308D4ed2b11025A9daFfDC));

        // Get our PoolKey
        PoolKey memory poolKey = positionManager.poolKey(timmay);

        // Get the ISP fees in the pool
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(poolKey);
        console.log(fees.amount0);
        console.log(fees.amount1);

        console.log(Currency.unwrap(poolKey.currency0));
        console.log(Currency.unwrap(poolKey.currency1));

        // Set up the new PositionManager
        FeeDistributor.FeeDistribution memory feeDistribution = FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: 5_00,
            protocol: 10_00,
            active: true
        });

        // Overwrite the PositionManager
        deployCodeTo('PositionManagerMock.sol', abi.encode(
            native, // nativeToken
            IPoolManager(0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829), // poolManager
            feeDistribution, // feeDistribution
            address(0), // initialPrice
            0x0f294726A2E3817529254F81e0C195b6cd0C834f, // protocolOwner
            0x0f294726A2E3817529254F81e0C195b6cd0C834f, // protocolFeeRecipient
            0x0000000000000000000000000000000000000000, // flayGovernance
            address(0) // feeExemptions
        ), 0x5f9466BC4b1eBbA82b308D4ed2b11025A9daFfDC);

        // Apply our fees via the Mock
        PositionManagerMock(payable(0x5f9466BC4b1eBbA82b308D4ed2b11025A9daFfDC)).setPoolFees(poolKey.toId(), fees.amount0, fees.amount1);

        vm.startPrank(0x498E93Bc04955fCBAC04BCF1a3BA792f01Dbaa96);
        (bool success, ) = 0x95273d871c8156636e114b63797d78D7E1720d81.call(
            hex'24856bc300000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000210040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000004600000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000002051600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000002386f26fc10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000010000000000000000000000000079fc52701cd4be6f9ba9adc94c207de37e3314eb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000ed5feec571d132aea6d6a636c683b818b344288800000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0d0ef63c8ff5a879118f3c5b856483370a956c60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000005f9466bc4b1ebba82b308d4ed2b11025a9daffdc00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0d0ef63c8ff5a879118f3c5b856483370a956c600000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000498e93bc04955fcbac04bcf1a3ba792f01dbaa960000000000000000000000000000000000000000000000000000000000000000'
        );

        assertTrue(success, 'Failed tx');
    }

    // the local contracts have been modified from the deployed version, so this test will fail. Making it internal
    function test_CanISP() internal forkBaseSepoliaBlock(16008642) {

        // $TIMMAY memecoin
        address timmay = 0xAb15bA8CDD0A00F47c80389ac38f6d00fb7B1bB0;
        address native = 0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb;

        // Give our test user some fleth as we cut out the pre-swap
        deal(native, 0xf8ea221b983aa314c86EFE15E00FA9e5D68bc89F, 1 ether);

        // PositionManager
        PositionManager positionManager = PositionManager(payable(0x046705475b26A3CFf04CE91F658B4Ae2F8eB3FDC));

        // Get our PoolKey
        PoolKey memory poolKey = positionManager.poolKey(timmay);

        // Connect as test address
        vm.startPrank(0xf8ea221b983aa314c86EFE15E00FA9e5D68bc89F);

        // Get the ISP fees in the pool
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(poolKey);
        console.log(fees.amount0);
        console.log(fees.amount1);

        console.log(Currency.unwrap(poolKey.currency0));
        console.log(Currency.unwrap(poolKey.currency1));

        // Set up the new PositionManager
        FeeDistributor.FeeDistribution memory feeDistribution = FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: 5_00,
            protocol: 30_00,
            active: true
        });

        // Overwrite the PositionManager
        deployCodeTo('PositionManagerMock.sol', abi.encode(
            0x81fD3646f5b422C92Ec39Cfb1359df40E78624Da,
            0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb,
            IPoolManager(0x39BF2eFF94201cfAA471932655404F63315147a4),
            feeDistribution,
            0x55D1B069e9a6B771a23474a5Dc2B4BCaFFb1BfD2,  // BidWall
            0x0f294726A2E3817529254F81e0C195b6cd0C834f,
            0x0f294726A2E3817529254F81e0C195b6cd0C834f,
            0x0000000000000000000000000000000000000000
        ), 0x046705475b26A3CFf04CE91F658B4Ae2F8eB3FDC);

        // Apply our fees via the Mock
        // pendingPoolFees.amount0 = 0
        // pendingPoolFees.amount1 = 5417215098518518596512876

        PositionManagerMock(payable(0x046705475b26A3CFf04CE91F658B4Ae2F8eB3FDC)).setPoolFees(poolKey.toId(), 0, 5417215098518518596512876);

        PoolSwap poolSwapNew = new PoolSwap(IPoolManager(0x39BF2eFF94201cfAA471932655404F63315147a4));

        IERC20(0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb).approve(address(poolSwapNew), type(uint).max);

        poolSwapNew.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.00001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        vm.stopPrank();
    }

    // the local contracts have been modified from the deployed version, so this test will fail. Making it internal
    function test_CanFlaunch() internal forkBaseSepoliaBlock(16044834) {
        PositionManager positionManager = PositionManager(payable(0x7B0920676b609BEB728960e4AD53f7CD7461bfdC));
        positionManager.flaunch(
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
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {PoolSwapTest} from '@uniswap/v4-core/src/test/PoolSwapTest.sol';
import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {FixedPoint96} from '@uniswap/v4-core/src/libraries/FixedPoint96.sol';

import {Quoter, IQuoter} from '@uniswap-periphery/lens/Quoter.sol';

import {DynamicFeeCalculatorV2} from '@flaunch/fees/DynamicFeeCalculatorV2.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';

import {Babylonian} from 'test/lib/Babylonian.sol';

import {println} from 'vulcan/test.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract DynamicFeeV2Modelling is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Strings for int256;
    using Strings for uint256;

    uint256 constant CURRENT_ETH_PRICE = 2500 ether;
    uint256 constant TOKEN_SUPPLY = 1e9 ether;
    uint24 constant BASE_FEE = 1_00;
    uint256 constant ONE_PERCENT_SUPPLY = TOKEN_SUPPLY / 100;
    uint256 constant POINT_ONE_PERCENT_SUPPLY = ONE_PERCENT_SUPPLY / 10;

    uint256 constant currentTimestamp = 1727961560;

    uint256[] internal mcapLevels = [
        5_000 ether,
        50_000 ether,
        1_000_000 ether,
        10_000_000 ether,
        100_000_000 ether,
        1_000_000_000 ether
    ];

    Quoter quoter;
    DynamicFeeCalculatorV2 feeCalculator;
    address memecoin;

    PoolKey internal POOL_KEY;
    PoolId internal immutable POOL_ID;
    bool internal immutable FLIPPED;

    // percentage to buy from the remaining balance of positionManager & poolManager
    uint256 BUY_PERCENTAGE = 10_00;
    uint256 constant MAX_BPS = 100_00;

    constructor() {
        vm.warp(currentTimestamp);

        // Deploy our platform
        _deployPlatform();
        quoter = new Quoter(poolManager);
        feeCalculator = new DynamicFeeCalculatorV2(address(positionManager));
        positionManager.setFeeCalculator(feeCalculator);

        // Deploy our InitialPrice contract
        initialPrice = new InitialPrice(0, address(this));

        // set initial price
        uint256 tokenPrice = _mcapToPrice(mcapLevels[0]);
        initialPrice.setSqrtPriceX96(_getInitialPriceX96(tokenPrice));
        positionManager.setInitialPrice(address(initialPrice));

        // flaunch with the updated price
        _flaunch();

        POOL_KEY = _normalizePoolKey(
            PoolKey({
                currency0: Currency.wrap(address(WETH)),
                currency1: Currency.wrap(memecoin),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(positionManager))
            })
        );
        POOL_ID = POOL_KEY.toId();
        FLIPPED = address(WETH) > memecoin;

        println('FLIPPED = {bool}', abi.encode(FLIPPED));

        deal(address(WETH), address(poolManager), 1000e27 ether);
        deal(address(WETH), address(positionManager), 1000e27 ether);
    }

    function test_dynamicFeeCalculatorV2() external {
        vm.startPrank(address(positionManager));

        for (uint i; i < mcapLevels.length; i++) {
            println('*****************************************************');
            _dynamicFeeCalculatorV2(mcapLevels[i]);
        }
    }

    function test_dynamicFeeModellingV2_buy() external {
        println(
            '========================================================================='
        );
        _getDynamicFeeForBuy(mcapLevels[0]);

        for (uint256 i = 1; i < mcapLevels.length; i++) {
            println(
                '========================================================================='
            );
            _buyToReachMCAP(mcapLevels[i]);
            _getDynamicFeeForBuy(mcapLevels[i]);
            // _scanLiquidityAcrossTicks(true, mcapLevels[i]);
            println(
                '========================================================================='
            );
        }
    }

    function _dynamicFeeCalculatorV2(uint256 currentMCAP) internal {
        // initialize vars
        vm.warp(block.timestamp + 1 days);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !FLIPPED,
            amountSpecified: 0,
            sqrtPriceLimitX96: !FLIPPED
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta delta;
        uint swapAmount;
        uint timeDelta;

        // Swap #1
        // 0.4% of the total supply
        timeDelta = 0;
        swapAmount = 4 * POINT_ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // Swap #2
        timeDelta = 40 minutes;
        // 0.4% of the total supply => Total volume in last 60 mins = (#1 + #2) = 0.8% [Note: this doesn't account for decay]
        swapAmount = 4 * POINT_ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // Swap #3
        timeDelta = 21 minutes; // 40 + 21 = 61 mins => Swap #1 out of 1 hr window
        // 1% of the total supply => Total volume in last 60 mins = (#2 + #3) = 1.4% [Note: this doesn't account for decay]
        swapAmount = ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // Swap #4
        timeDelta = 45 minutes; // 45 + 21 = 66 mins => Swap #2 out of 1 hr window
        // 5% of the total supply => Total volume in last 60 mins = (#3 + #4) = 6% [Note: this doesn't account for decay]
        swapAmount = 5 * ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // Swap #5
        timeDelta = 5 minutes;
        swapAmount = 50 * ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // Swap #6
        timeDelta = 5 minutes;
        swapAmount = 100 * ONE_PERCENT_SUPPLY;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // No swap #7
        timeDelta = 15 minutes; // 15 mins from last fee increase
        swapAmount = 0;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // No swap #8
        timeDelta = 15 minutes; // 30 mins from last fee increase
        swapAmount = 0;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // No swap #9
        timeDelta = 15 minutes; // 45 mins from last fee increase
        swapAmount = 0;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);

        // No swap #10
        timeDelta = 15 minutes; // 60 mins from last fee increase
        swapAmount = 0;
        _getDynamicFee(currentMCAP, delta, swapAmount, params, timeDelta);
    }

    function _getDynamicFee(
        uint256 currentMCAP,
        BalanceDelta delta,
        uint256 swapAmount,
        IPoolManager.SwapParams memory params,
        uint256 timeDelta
    ) internal {
        vm.warp(block.timestamp + timeDelta);

        if (swapAmount > 0) {
            delta = toBalanceDelta(
                !FLIPPED ? int128(0) : int128(uint128(swapAmount)),
                !FLIPPED ? int128(uint128(swapAmount)) : int128(0)
            );
            uint256 swapFee = feeCalculator.determineSwapFee(
                POOL_KEY,
                swapAmount,
                BASE_FEE
            );
            feeCalculator.trackSwap(address(this), POOL_KEY, params, delta, '');

            uint256 afterSwapFee = feeCalculator.determineSwapFee(
                POOL_KEY,
                swapAmount,
                BASE_FEE
            );
            println(
                'At MCAP of ${u:d18}: after time: {u} mins, swapAmount: ${u:d18} ({u:d16}%), swapFee: {u:d2}',
                abi.encode(
                    currentMCAP,
                    timeDelta / 60,
                    (swapAmount * currentMCAP) / TOKEN_SUPPLY,
                    (swapAmount * 1 ether) / TOKEN_SUPPLY,
                    swapFee
                )
            );
            println('After swap fee: {u:d2}', abi.encode(afterSwapFee));
        } else {
            uint256 currentSwapFee = feeCalculator.determineSwapFee(
                POOL_KEY,
                swapAmount,
                BASE_FEE
            );
            println(
                'No swap, At MCAP of ${u:d18}: after time: {u} mins, Current swap fee: {u:d2}',
                abi.encode(currentMCAP, timeDelta / 60, currentSwapFee)
            );
        }

        println(
            '========================================================================='
        );
    }

    function _getDynamicFeeForBuy(uint256 currentMCAP) internal {
        // bring the swap fee to minimum
        vm.warp(block.timestamp + 1 days);

        uint256 positionManagerTokenBalance = IERC20(memecoin).balanceOf(
            address(positionManager)
        );
        uint256 poolManagerTokenBalance = IERC20(memecoin).balanceOf(
            address(poolManager)
        );
        // FIXME: reverting due to insufficient positionManager token balance
        // uint128 tokensToBuy = SafeCast.toUint128(
        //     ((positionManagerTokenBalance + poolManagerTokenBalance) *
        //         BUY_PERCENTAGE) / MAX_BPS
        // );
        uint128 tokensToBuy = SafeCast.toUint128(
            ((positionManagerTokenBalance) * BUY_PERCENTAGE) / MAX_BPS
        );
        println(
            'At MCAP of ${u:d18}: tokenBalance of positionManager: {u:d18}, poolManager: {u:d18}, tokensToBuy: {u:d18}',
            abi.encode(
                currentMCAP,
                positionManagerTokenBalance,
                poolManagerTokenBalance,
                tokensToBuy
            )
        );

        // get weth amount to swap
        (uint wethAmount,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: POOL_KEY,
                // buy => WETH for memecoin => zeroForOne = true (false if flipped)
                zeroForOne: !FLIPPED,
                exactAmount: tokensToBuy,
                hookData: ''
            })
        );

        deal(address(WETH), address(this), wethAmount);
        WETH.approve(address(poolSwap), type(uint256).max);

        // split the swap to increase volume
        uint128 swapCount = 1;
        uint wethPerSwap = wethAmount / swapCount;

        for (uint256 i = 0; i < swapCount; i++) {
            BalanceDelta delta = poolSwap.swap(
                POOL_KEY,
                IPoolManager.SwapParams({
                    zeroForOne: !FLIPPED,
                    amountSpecified: -int(wethPerSwap),
                    sqrtPriceLimitX96: !FLIPPED
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                ''
            );
            uint128 wethSwapped = !FLIPPED
                ? uint128(-delta.amount0())
                : uint128(-delta.amount1());
            uint128 tokensReceived = !FLIPPED
                ? uint128(delta.amount1())
                : uint128(delta.amount0());

            println(
                'At MCAP: ${u:d18}: swapIndex: {u} wethSwapped: {u:d18}, tokensReceived: {u:d18}',
                abi.encode(currentMCAP, i, wethSwapped, tokensReceived)
            );
        }

        // check dynamic fee now
        uint24 baseSwapFee = FeeDistributor(payable(positionManager))
            .getPoolFeeDistribution(POOL_ID)
            .swapFee;
        uint24 dynamicSwapFees = feeCalculator.determineSwapFee(
            POOL_KEY,
            0,
            baseSwapFee
        );

        println(
            'At MCAP of ${u:d18}: for swapCount: {u}: dynamicSwapFees: {u}',
            abi.encode(currentMCAP, swapCount, dynamicSwapFees)
        );
    }

    function _buyToReachMCAP(uint256 targetMCAP) internal {
        uint256 targetPrice = _mcapToPrice(targetMCAP);

        // find weth amount to swap
        uint256 wethAmount = _findWETHAmountForTargetPrice({
            targetPrice: targetPrice,
            lowerBound: 0.0001 ether,
            upperBound: 100_000 ether,
            precision: 0.001 ether // few dollars ($ 2.5)
        });

        // get WETH to swap
        deal(address(WETH), address(this), wethAmount);
        WETH.approve(address(poolSwap), type(uint).max);

        // Action our swap
        BalanceDelta delta = poolSwap.swap(
            POOL_KEY,
            IPoolManager.SwapParams({
                zeroForOne: !FLIPPED,
                amountSpecified: -SafeCast.toInt128(wethAmount),
                sqrtPriceLimitX96: !FLIPPED
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint128 wethSwapped = !FLIPPED
            ? uint128(-delta.amount0())
            : uint128(-delta.amount1());
        uint128 tokensReceived = !FLIPPED
            ? uint128(delta.amount1())
            : uint128(delta.amount0());

        println(
            'To bring MCAP to ${u:d18}: wethSwapped: {u:d18}, tokensReceived: {u:d18}',
            abi.encode(targetMCAP, wethSwapped, tokensReceived)
        );
    }

    function _findWETHAmountForTargetPrice(
        uint256 targetPrice,
        uint128 lowerBound,
        uint128 upperBound,
        uint128 precision // to stop binary search
    ) internal returns (uint256 wethAmount) {
        InitialPrice.InitialSqrtPriceX96
            memory sqrtPriceX96 = _getInitialPriceX96(targetPrice);
        uint160 targetSqrtPriceX96 = FLIPPED
            ? sqrtPriceX96.flipped
            : sqrtPriceX96.unflipped;

        uint160 sqrtPriceX96After;
        (wethAmount, sqrtPriceX96After) = _findWETHAmountForTargetSqrtPriceX96(
            targetSqrtPriceX96,
            lowerBound,
            upperBound,
            precision
        );

        uint256 priceAfterInUSD = _memecoinSqrtPriceX96ToUSD(
            sqrtPriceX96After
        );
        println(
            'targetSqrtPriceX96: {u}, targetPrice: {u:d18}, priceAfter: {u:d18}',
            abi.encode(targetSqrtPriceX96, targetPrice, priceAfterInUSD)
        );
    }

    function _findWETHAmountForTargetSqrtPriceX96(
        uint160 targetSqrtPriceX96,
        uint128 lowerBound,
        uint128 upperBound,
        uint128 precision // to stop binary search
    ) internal returns (uint256 wethAmount, uint160 sqrtPriceX96After) {
        while (upperBound - lowerBound > precision) {
            uint128 mid = (lowerBound + upperBound) / 2;

            // try to get the amount of memecoin that can be bought for mid WETH
            try
                quoter.quoteExactInputSingle(
                    IQuoter.QuoteExactSingleParams({
                        poolKey: POOL_KEY,
                        // buy => WETH for memecoin => zeroForOne = true (false if flipped)
                        zeroForOne: !FLIPPED,
                        exactAmount: mid,
                        hookData: ''
                    })
                )

            returns (int128[] memory, uint160 _sqrtPriceX96After, uint32) {
                sqrtPriceX96After = _sqrtPriceX96After;

                if (!FLIPPED) {
                    // targetSqrtPrice is less than the current pool price
                    // we need to bring down the pool price to match our target
                    if (sqrtPriceX96After >= targetSqrtPriceX96) {
                        // current price is still higher
                        // need to increase swap amount
                        lowerBound = mid;
                    } else {
                        // current price is much lower
                        // need to decrease swap amount
                        upperBound = mid;
                    }
                } else {
                    if (sqrtPriceX96After <= targetSqrtPriceX96) {
                        upperBound = mid;
                    } else {
                        lowerBound = mid;
                    }
                }
            } catch {
                // if we get an error, we need to decrease the amount of WETH
                upperBound = mid;
            }
        }

        wethAmount = lowerBound;
    }

    function _memecoinSqrtPriceX96ToUSD(
        uint160 sqrtPriceX96
    ) internal view returns (uint256 priceInUSD) {
        uint256 priceInETH = _sqrtX96toPriceInETH(sqrtPriceX96);
        priceInUSD = (priceInETH * CURRENT_ETH_PRICE) / 1 ether;
    }

    function _sqrtX96toPriceInETH(
        uint160 sqrtPriceX96
    ) internal view returns (uint256 priceInETH) {
        uint256 priceX96 = FullMath.mulDiv(
            sqrtPriceX96,
            sqrtPriceX96,
            FixedPoint96.Q96
        );

        uint256 memecoinAmount = 1 ether;
        if (!FLIPPED) {
            priceInETH = FullMath.mulDiv(
                memecoinAmount,
                FixedPoint96.Q96,
                priceX96
            );
        } else {
            priceInETH = FullMath.mulDiv(
                memecoinAmount,
                priceX96,
                FixedPoint96.Q96
            );
        }
    }

    function _mcapToPrice(uint256 mcap) internal pure returns (uint256) {
        return (mcap * 1 ether) / TOKEN_SUPPLY;
    }

    function _getInitialPriceX96(
        uint256 tokenPrice
    )
        internal
        pure
        returns (InitialPrice.InitialSqrtPriceX96 memory initialSqrtPriceX96)
    {
        uint256 tokenPriceInETH = (tokenPrice * 1 ether) / CURRENT_ETH_PRICE;

        // note: flipped = nativeToken (1) > memecoin (0)
        initialSqrtPriceX96 = InitialPrice.InitialSqrtPriceX96({
            // for unflipped:
            // tokenPriceInETH = amount of ETH per 1 token
            //                 = a0 / a1, where a1 = 1 ether
            unflipped: _encodeSqrtRatioX96({
                amount0: tokenPriceInETH,
                amount1: 1 ether
            }),
            flipped: _encodeSqrtRatioX96({
                amount0: 1 ether,
                amount1: tokenPriceInETH
            })
        });
    }

    function _encodeSqrtRatioX96(
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint160 sqrtP) {
        // sqrtP = sqrt(price) * 2^96
        // = sqrt(amount1 / amount0) * 2^96
        // = sqrt(amount1 * 2^192 / amount0)
        // this restricts the max(amount1) to be (2^256 - 1)/(2^192) ~= 18.44e18
        // so rearranging the formula, keeping sufficient precision
        // = sqrt(amount1 * 2^142 / amount0) * 2^25

        sqrtP = SafeCast.toUint160(
            Babylonian.sqrt((amount1 * (2 ** 142)) / amount0) * (1 << 25)
        );
    }

    function _flaunch() internal {
        memecoin = positionManager.flaunch({
            _name: 'Token Name',
            _symbol: 'TOKEN',
            _tokenUri: 'https://flaunch.gg/',
            _initialTokenFairLaunch: supplyShare(50),
            _premineAmount: 0,
            _creatorFeeAllocation: 0,
            _vitaminAllocation: 0,
            _flaunchAt: 0
        });
        assertEq(
            IERC20(memecoin).balanceOf(address(positionManager)),
            MAX_FAIR_LAUNCH_TOKENS
        );
    }
}

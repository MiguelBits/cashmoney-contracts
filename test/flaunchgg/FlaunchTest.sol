// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {stdStorage, StdStorage} from 'forge-std/Test.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {Deployers} from '@uniswap/v4-core/test/utils/Deployers.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolModifyLiquidityTest} from '@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol';
import {IPoolManager, PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';
import {FlaunchPremineZap} from '@flaunch/zaps/FlaunchPremineZap.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {MemecoinMock} from 'test/mocks/MemecoinMock.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';
import {ReferralEscrow} from '@flaunch/referrals/ReferralEscrow.sol';
import {StaticFeeCalculator} from '@flaunch/fees/StaticFeeCalculator.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {PositionManagerMock} from './mocks/PositionManagerMock.sol';
import {WETH9} from './tokens/WETH9.sol';


contract FlaunchTest is Deployers {

    using stdStorage for StdStorage;

    bytes4 internal constant UNAUTHORIZED = 0x82b42900;
    int24 TICK_SPACING = 60;

    Flaunch internal flaunch;
    MemecoinMock internal memecoinImplementation;
    MemecoinTreasury internal memecoinTreasuryImplementation;

    /// In Uniswap's definition, FL_SQRT_PRICE_2_1 could be interpreted as meaning 'two token0
    /// for one token1,' but because this is the square root of the price ratio, the actual
    /// implication is that the price ratio is inverted compared to what we might expect
    /// intuitively. Therefore, a tick of `6931` confirms that 1 unit of token0 is worth 2
    /// units of token1, despite the name suggesting it might be the other way around.
    uint160 public constant FL_SQRT_PRICE_1_2 = 112045541949572279837463876454;
    uint160 public constant FL_SQRT_PRICE_2_1 = 56022770974786139918731938227;

    InitialPrice internal initialPrice;
    PoolManager internal poolManager;
    FairLaunch internal fairLaunch;
    PoolModifyLiquidityTest internal poolModifyPosition;
    PoolSwap internal poolSwap;
    PositionManagerMock internal positionManager;
    FeeExemptions internal feeExemptions;
    FlaunchPremineZap premineZap;
    ReferralEscrow referralEscrow;

    /// Store our deployer address
    address public constant DEPLOYER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    address payable internal constant VALID_POSITION_MANAGER_ADDRESS = payable(0x3Fdc8d547641A626eC40242196F69754b25D2fdC);

    WETH9 internal WETH;
    WETH9 internal flETH;
    address internal constant ETH = address(0);
    address public governance = address(0xCAFE);

    constructor() {
        // Deploy the Uniswap V4 {PoolManager}
        poolManager = new PoolManager(address(this));
        poolModifyPosition = new PoolModifyLiquidityTest(poolManager);

        // Deploy our swap zap
        poolSwap = new PoolSwap(poolManager);

        // Create a native token (use the modifier `flipTokens` to flip positions)
        deployCodeTo('WETH9.sol', abi.encode(), payable(address(123)));
        WETH = WETH9(payable(address(123)));
        flETH = WETH;
    }

    function _deployPlatform() internal {
        memecoinImplementation = new MemecoinMock();
        flaunch = new Flaunch(address(memecoinImplementation), 'https://api.flaunch.gg/token/');

        FeeDistributor.FeeDistribution memory feeDistribution = FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: 5_00,
            protocol: 10_00,
            active: true
        });

        // Define our initial token sqrtPriceX96
        InitialPrice.InitialSqrtPriceX96 memory initialSqrtPriceX96 = InitialPrice.InitialSqrtPriceX96({
            unflipped: FL_SQRT_PRICE_1_2,
            flipped: FL_SQRT_PRICE_2_1
        });

        // Deploy our InitialPrice contract
        initialPrice = new InitialPrice(0, address(this));
        initialPrice.setSqrtPriceX96(initialSqrtPriceX96);

        // Deploy our FeeExemptions contract
        feeExemptions = new FeeExemptions(address(this));

        // Deploy our Locker to a specific address that is valid for our hooks configuration
        deployCodeTo('PositionManagerMock.sol', abi.encode(
            address(WETH),
            address(poolManager),
            feeDistribution,
            address(initialPrice),
            address(this),
            address(this),
            governance,
            address(feeExemptions)
        ), VALID_POSITION_MANAGER_ADDRESS);

        positionManager = PositionManagerMock(VALID_POSITION_MANAGER_ADDRESS);

        memecoinTreasuryImplementation = new MemecoinTreasury();

        flaunch.initialize(positionManager, address(memecoinTreasuryImplementation));
        positionManager.setFlaunch(address(flaunch));

        // Deploy our StaticFeeCalculator
        StaticFeeCalculator feeCalculator = new StaticFeeCalculator();
        positionManager.setFeeCalculator(feeCalculator);

        premineZap = new FlaunchPremineZap(positionManager, address(flaunch), address(flETH), poolSwap);

        fairLaunch = positionManager.fairLaunch();

        referralEscrow = new ReferralEscrow(address(flETH), address(positionManager));
        referralEscrow.setPoolSwap(address(poolSwap));
        positionManager.setReferralEscrow(payable(address(referralEscrow)));
    }

    /**
     * Sets up the logic to fork from a mainnet block, based on just an integer passed.
     *
     * @dev This should be applied to a constructor.
     */
    modifier forkBlock(uint blockNumber) {
        // Generate a mainnet fork
        uint mainnetFork = vm.createFork(vm.rpcUrl('mainnet'));

        // Select our fork for the VM
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        // Set our block ID to a specific, test-suitable number
        vm.rollFork(blockNumber);

        // Confirm that our block number has set successfully
        require(block.number == blockNumber);
        _;
    }

    modifier forkBaseBlock(uint blockNumber) {
        // Generate a mainnet fork
        uint baseFork = vm.createFork(vm.rpcUrl('base'));

        // Select our fork for the VM
        vm.selectFork(baseFork);
        assertEq(vm.activeFork(), baseFork);

        // Set our block ID to a specific, test-suitable number
        vm.rollFork(blockNumber);

        // Confirm that our block number has set successfully
        require(block.number == blockNumber);
        _;
    }

    modifier forkBaseSepoliaBlock(uint blockNumber) {
        // Generate a mainnet fork
        uint baseSepoliaFork = vm.createFork(vm.rpcUrl('base_sepolia'));

        // Select our fork for the VM
        vm.selectFork(baseSepoliaFork);
        assertEq(vm.activeFork(), baseSepoliaFork);

        // Set our block ID to a specific, test-suitable number
        vm.rollFork(blockNumber);

        // Confirm that our block number has set successfully
        require(block.number == blockNumber);
        _;
    }

    function _assumeValidAddress(address _address) internal {
        // Ensure this is not a zero address
        vm.assume(_address != address(0));

        // Ensure that we don't match the test address
        vm.assume(_address != address(this));

        // Ensure that the address does not have known contract code attached
        vm.assume(_address != address(positionManager));
        vm.assume(_address != address(poolManager));
        vm.assume(_address != address(poolSwap));
        vm.assume(_address != address(feeExemptions));
        vm.assume(_address != address(initialPrice));
        vm.assume(_address != address(memecoinImplementation));
        vm.assume(_address != address(memecoinTreasuryImplementation));
        vm.assume(_address != address(flaunch));
        vm.assume(_address != address(premineZap));
        vm.assume(_address != address(referralEscrow));
        vm.assume(_address != DEPLOYER);

        // Prevent the VM address from being referenced
        vm.assume(_address != 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        // Finally, as a last resort, confirm that the target address is able
        // to receive ETH.
        vm.assume(payable(_address).send(0));
    }

    function _determineSqrtPrice(uint token0Amount, uint token1Amount) internal pure returns (uint160) {
        // Function to calculate sqrt price
        require(token0Amount > 0, 'Token0 amount should be greater than zero');
        return uint160((token1Amount * (2 ** 96)) / token0Amount);
    }

    /**
     * ..
     */
    function _addLiquidityToPool(address _memecoin, int _liquidityDelta, bool _skipWarp) internal {
        // Retrieve our pool key from the memecoin
        PoolKey memory poolKey = positionManager.poolKey(_memecoin);

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}
        deal(address(WETH), address(this), 10e27);
        WETH.approve(address(poolModifyPosition), type(uint).max);

        deal(_memecoin, address(this), 10e27);
        IERC20(_memecoin).approve(address(poolModifyPosition), type(uint).max);

        // Modify our position with additional ETH and tokens
        poolModifyPosition.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                // Set our tick boundaries
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: _liquidityDelta,
                salt: ''
            }),
            ''
        );

        // Skip forward in time, unless specified not to
        if (!_skipWarp) {
            vm.warp(block.timestamp + 3600);
        }
    }

    function _poolKeyZeroForOne(PoolKey memory poolKey) internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(WETH);
    }

    function _normalizePoolKey(PoolKey memory poolKey) internal pure returns (PoolKey memory) {
        if (poolKey.currency0 >= poolKey.currency1) {
            (poolKey.currency0, poolKey.currency1) = (poolKey.currency1, poolKey.currency0);
        }

        return poolKey;
    }

    function _bypassFairLaunch() internal {
        vm.warp(block.timestamp + 365 days);
    }

    function _getSwapParams(int _amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: _amount,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE
        });
    }

    /**
     * ..
     */
    function supplyShare(uint _percent) public pure returns (uint) {
        return TokenSupply.INITIAL_SUPPLY * _percent / 10000;
    }

    modifier flipTokens(bool _flipped) {
        if (_flipped) {
            deployCodeTo('WETH9.sol', abi.encode(), payable(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)));
            WETH = WETH9(payable(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF));
            flETH = WETH;

            _deployPlatform();
        }

        _;
    }

}

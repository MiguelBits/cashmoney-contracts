// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';


/**
 * This hook allows us to create a single sided liquidity position (Plunge Protection) that is
 * placed 1 tick below spot price, using the ETH fees accumulated.
 *
 * After each deposit into the BidWall the position is rebalanced to ensure it remains 1 tick
 * below spot. This spot will be determined by the tick value before the triggering swap.
 */
contract BidWall is Ownable {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickFinder for int24;
    using MemecoinFinder for PoolKey;

    error CallerIsNotCreator();
    error NotPositionManager();

    /// Emitted when the BidWall is first initialised with ETH
    event BidWallInitialized(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when a BidWall receives a deposit
    event BidWallDeposit(PoolId indexed _poolId, uint _added, uint _pending);

    /// Emitted when the BidWall is repositioned under an updated tick, or with additional ETH
    event BidWallRepositioned(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when non-ETH tokens received are transferrer to the memecoin treasury
    event BidWallRewardsTransferred(PoolId indexed _poolId, address _recipient, uint _tokens);

    /// Emitted when the BidWall is closed
    event BidWallClosed(PoolId indexed _poolId, address _recipient, uint _eth);

    /// Emitted when the BidWall is disabled or enabled
    event BidWallDisabledStateUpdated(PoolId indexed _poolId, bool _disabled);

    /// Emitted when the `_swapFeeThreshold` is updated
    event FixedSwapFeeThresholdUpdated(uint _newSwapFeeThreshold);

    /**
     * Stores the BidWall information for a specific pool.
     *
     * @member disabled If the BidWall is disabled for the pool
     * @member initialized If the BidWall has been initialized
     * @member tickLower The current lower tick of the BidWall
     * @member tickUpper The current upper tick of the BidWall
     * @member pendingETHFees The amount of ETH fees waiting to be put into the BidWall until threshold is crossed
     * @member cumulativeSwapFees The total amount of swap fees accumulated for the pool
     */
    struct PoolInfo {
        bool disabled;
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint pendingETHFees;
        uint cumulativeSwapFees;
    }

    /// Our Uniswap V4 {PoolManager} contract
    IPoolManager public immutable poolManager;

    /// Our {PositionManager} address
    PositionManager public immutable positionManager;

    /// The native token used in the Flaunch protocol
    address public immutable nativeToken;

    /// Our fixed swap fee threshold
    uint internal _swapFeeThreshold;

    /// Maps our poolId to the `PoolInfo` struct for bidWall data
    mapping (PoolId _poolId => PoolInfo _poolInfo) public poolInfo;

    /**
     * Set up our PoolManager and native ETH token.
     *
     * @param _nativeToken The ETH token being used in the {PositionManager}
     * @param _poolManager The Uniswap V4 {PoolManager}
     */
    constructor (address _nativeToken, address _poolManager, address _protocolOwner) {
        positionManager = PositionManager(payable(msg.sender));
        nativeToken = _nativeToken;
        poolManager = IPoolManager(_poolManager);

        // Set our initial swapFeeThreshold and emit an update for the amount
        _swapFeeThreshold = 0.1 ether;
        emit FixedSwapFeeThresholdUpdated(0.1 ether);

        _initializeOwner(_protocolOwner);
    }

    /**
     * Helper function that checks if a pool's BidWall is enabled or disabled.
     *
     * @param _poolId The pool ID to check
     *
     * @return bool Set to `true` if the hook is enabled, `false` if it is disabled
     */
    function isBidWallEnabled(PoolId _poolId) public view returns (bool) {
        return !poolInfo[_poolId].disabled;
    }

    /**
     * Attributes swap fees to the BidWall and calculates if it needs to rebalance
     * the current position.
     *
     * @dev The calling contract should have already checked if this hook is active
     * and ready to receive the swap fees.
     *
     * @param _poolKey The PoolKey to modify the BidWall of
     * @param _ethSwapAmount The amount of ETH swap fees added to BidWall
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is `currency0`
     */
    function deposit(
        PoolKey memory _poolKey,
        uint _ethSwapAmount,
        int24 _currentTick,
        bool _nativeIsZero
    ) public onlyPositionManager {
        // If we have no fees to swap, then exit early
        if (_ethSwapAmount == 0) return;

        // Increase our cumulative and pending fees
        PoolId poolId = _poolKey.toId();
        PoolInfo storage _poolInfo = poolInfo[poolId];
        _poolInfo.cumulativeSwapFees += _ethSwapAmount;
        _poolInfo.pendingETHFees += _ethSwapAmount;

        // Send an event to notify that BidWall has received funds
        emit BidWallDeposit(poolId, _ethSwapAmount, _poolInfo.pendingETHFees);

        // If we haven't yet crossed a threshold, then we just increase the amount of
        // pending fees to calculate against next time.
        if (_poolInfo.pendingETHFees < _getSwapFeeThreshold(_poolInfo.cumulativeSwapFees)) {
            return;
        }

        // Reset pending ETH token fees as we will be processing a bidwall initialization
        // or a rebalance.
        uint totalFees = _poolInfo.pendingETHFees;
        _poolInfo.pendingETHFees = 0;

        uint ethWithdrawn;
        uint memecoinWithdrawn;

        // Check if the BidWall has been initialized before, then we have a position
        if (_poolInfo.initialized) {
            // Remove tokens from our current position
            (ethWithdrawn, memecoinWithdrawn) = _removeLiquidity({
                _key: _poolKey,
                _nativeIsZero: _nativeIsZero,
                _tickLower: _poolInfo.tickLower,
                _tickUpper: _poolInfo.tickUpper
            });

            // Send the received ETH to the {PositionManager}, as that will be supplying the ETH
            // tokens to create the new position.
            if (ethWithdrawn != 0) {
                IERC20(nativeToken).transfer(address(positionManager), ethWithdrawn);
            }
        } else {
            // If this is the first time we are adding liquidity, then we can set our
            // pool initialized flag to true.
            _poolInfo.initialized = true;
        }

        /**
         * The `_currentTick` is calculated from the `_beforeSwapTick`, which means that it could be
         * that the actual swap has impacted the tick of the pool. This will affect our liquidity
         * modification in one of two ways:
         *
         *   1. The tick has moved FOR the native token, meaning that we will be creating our position to
         *      give a lower native token value. This is absolutely fine and is expected so as to not give
         *      an overly generous price when the BidWall is triggered.
         *   2. The tick has moved AGAINST the native token, meaning that we will be creating our position
         *      to give a higher native token value. This means that liquidity calculations called within
         *      the `_addETHLiquidity` will actually result in requiring both native _and_ memecoin tokens
         *      to be settled. If this is the case then we instead need to use the `slot0` tick rather than
         *      the beforeSwap tick value provided in `_currentTick`.
         *
         * This is the final, and only, place that `_currentTick` is referenced, so we can safely overwrite
         * the value if required.
         */

        (, int24 slot0Tick,,) = poolManager.getSlot0(poolId);
        if (_nativeIsZero == slot0Tick > _currentTick) {
            _currentTick = slot0Tick;
        }

        // Create our liquidity position; including any tokens withdrawn from our previous position if
        // set, as well as the additional swap fees.
        _addETHLiquidity({
            _key: _poolKey,
            _nativeIsZero: _nativeIsZero,
            _currentTick: _currentTick,
            _ethAmount: ethWithdrawn + totalFees
        });

        // If we have memecoins available, then we transfer those to the treasury
        if (memecoinWithdrawn != 0) {
            // Find our non-ETH token and the {TokenTreasury} attached to it
            IMemecoin memecoin = _poolKey.memecoin(nativeToken);
            address memecoinTreasury = memecoin.treasury();

            // Transfer the tokens to the memecoin treasury
            memecoin.transfer(memecoinTreasury, memecoinWithdrawn);
            emit BidWallRewardsTransferred(poolId, memecoinTreasury, memecoinWithdrawn);
        }

        emit BidWallRepositioned(poolId, ethWithdrawn + totalFees, _poolInfo.tickLower, _poolInfo.tickUpper);
    }

    /**
     * Allows the BidWall to be enabled or disabled for the {PoolKey}.
     *
     * If disabled, future swap fees will be transferred directly to the respective
     * {MemecoinTreasury} address instead of the BidWall.
     *
     * @dev This can only be called by the creator of the memecoin.
     *
     * @param _key The PoolKey that is being updated
     * @param _disable If the BidWall is being disabled (true) or enabled (false)
     */
    function setDisabledState(PoolKey memory _key, bool _disable) external {
        // Ensure that the caller is the pool creator
        if (msg.sender != _key.memecoin(nativeToken).creator()) revert CallerIsNotCreator();

        // We only need to process the following logic if anything is changing
        PoolInfo storage _poolInfo = poolInfo[_key.toId()];
        if (_disable == _poolInfo.disabled) return;

        // If we are disabling our BidWall, then we want to also remove the current liquidity. We
        // need to send this through the {PositionManager} so that it can open a {PoolManager} lock.
        if (_disable) {
            positionManager.closeBidWall(_key);
        }

        // Update our disabled flag
        _poolInfo.disabled = _disable;

        // Emit our event to flag the BidWall disabled state update
        emit BidWallDisabledStateUpdated(_key.toId(), _disable);
    }

    /**
     * Allows the memecoin creator to close the BidWall and distribute any fees held in the BidWall
     * to the treasury address.
     *
     * This call will have been routed in the following way:
     * ```
     * BidWall.disable -> PositionManager.closeBidWall -> PositionManager.unlockCallback -> BidWall.closeBidwall
     * ```
     *
     * @param _key The PoolKey that we are closing the BidWall of
     */
    function closeBidWall(PoolKey memory _key) external onlyPositionManager {
        // Unpack information required for our call
        bool nativeIsZero = nativeToken == Currency.unwrap(_key.currency0);

        PoolId poolId = _key.toId();
        PoolInfo storage _poolInfo = poolInfo[poolId];

        uint ethWithdrawn;
        uint memecoinWithdrawn;

        // If the pool has not yet been initialized, then there will be no liquidity to remove
        if (_poolInfo.initialized) {
            // Remove all liquidity from the BidWall
            (ethWithdrawn, memecoinWithdrawn) = _removeLiquidity({
                _key: _key,
                _nativeIsZero: nativeIsZero,
                _tickLower: _poolInfo.tickLower,
                _tickUpper: _poolInfo.tickUpper
            });

            // Set our pool back to being uninitialized
            _poolInfo.initialized = false;
        }

        // Reset pending ETH fees for the pool. We also reset our `cumulativeSwapFees` as this is
        // used to determine our threshold hits.
        uint pendingETHFees = _poolInfo.pendingETHFees;
        _poolInfo.pendingETHFees = 0;
        _poolInfo.cumulativeSwapFees = 0;

        // Unwrap the non-native token and find the treasury address
        IMemecoin memecoin = _key.memecoin(nativeToken);
        address memecoinTreasury = memecoin.treasury();

        // Pending ETH fees are stored in the {PositionManager}. So if we have a value there, then we
        // will need to transfer this from the {PositionManager}, rather than this contract.
        if (pendingETHFees != 0) {
            IERC20(nativeToken).transferFrom(address(positionManager), memecoinTreasury, pendingETHFees);
        }

        // Transfer ETH withdrawn from the legacy position to the governance contract. We Avoid using
        // safe transfer as this could brick calls if a malicious governance was set by the token.
        if (ethWithdrawn != 0) {
            IERC20(nativeToken).transfer(memecoinTreasury, ethWithdrawn);
        }

        // Transfer the flTokens withdrawn from the legacy position to the governance contract
        if (memecoinWithdrawn != 0) {
            memecoin.transfer(memecoinTreasury, memecoinWithdrawn);
            emit BidWallRewardsTransferred(poolId, memecoinTreasury, memecoinWithdrawn);
        }

        emit BidWallClosed(poolId, memecoinTreasury, ethWithdrawn + pendingETHFees);
    }

    /**
     * Retrieves the current position held by the BidWall.
     *
     * @param _poolId The `PoolId` to check the {BidWall} position of
     *
     * @return amount0_ The {BidWall} token0 position
     * @return amount1_ The {BidWall} token1 position
     * @return pendingEth_ The amount of ETH pending to be depositted into the {BidWall}
     */
    function position(PoolId _poolId) public view returns (uint amount0_, uint amount1_, uint pendingEth_) {
        // Get the BidWall tick range from our PoolInfo
        PoolInfo memory _poolInfo = poolInfo[_poolId];

        // If our pool is not initialized, then we don't have a position to query and we will
        // only have the pending fees to return
        if (!_poolInfo.initialized) {
            return (0, 0, _poolInfo.pendingETHFees);
        }

        // Retrieve the total liquidity of the pool
        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: _poolId,
            owner: address(this),
            tickLower: _poolInfo.tickLower,
            tickUpper: _poolInfo.tickUpper,
            salt: 'bidwall'
        });

        // Get the current slot of the pool and find the amounts against the liquidity
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        (amount0_, amount1_) = LiquidityAmounts.getAmountsForLiquidity({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_poolInfo.tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_poolInfo.tickUpper),
            liquidity: liquidity
        });

        // Map our pending fees to our response
        pendingEth_ = _poolInfo.pendingETHFees;
    }

    /**
     * Allows the threshold for the swap fee to be updated.
     *
     * @param swapFeeThreshold The new threshold to set
     */
    function setSwapFeeThreshold(uint swapFeeThreshold) external onlyOwner {
        _swapFeeThreshold = swapFeeThreshold;
        emit FixedSwapFeeThresholdUpdated(_swapFeeThreshold);
    }

    /**
     * Adds liquidity to our BidWall position. We calculate the tick to be adjacent to the current
     * tick of the pool into a single tick spaced range.
     *
     * @param _key The {PoolKey} that is being modified
     * @param _nativeIsZero If our native token is `currency0`
     * @param _currentTick The current tick for the pool
     * @param _ethAmount The amount of native token we are adding to the BidWall
     */
    function _addETHLiquidity(PoolKey memory _key, bool _nativeIsZero, int24 _currentTick, uint _ethAmount) internal {
        // Determine a base tick just outside of the current tick
        int24 baseTick = _nativeIsZero ? _currentTick + 1 : _currentTick - 1;

        /**
         * Calculate the tick range for the BidWall.
         *
         *                   tick ( lower | upper )
         * When the tick is  6931 (  6960 |  7020 )
         * When the tick is -6932 ( -7020 | -6960 )
         */

        int24 newTickLower;
        int24 newTickUpper;
        uint128 liquidityDelta;

        if (_nativeIsZero) {
            newTickLower = baseTick.validTick(false);
            newTickUpper = newTickLower + TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount0: _ethAmount
            });
        } else {
            newTickUpper = baseTick.validTick(true);
            newTickLower = newTickUpper - TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount1: _ethAmount
            });
        }

        // Modify the liquidity to add our position
        _modifyAndSettleLiquidity({
            _poolKey: _key,
            _tickLower: newTickLower,
            _tickUpper: newTickUpper,
            _liquidityDelta: int128(liquidityDelta),
            _sender: address(positionManager)
        });

        // Update the BidWall position tick range
        PoolInfo storage _poolInfo = poolInfo[_key.toId()];
        _poolInfo.tickLower = newTickLower;
        _poolInfo.tickUpper = newTickUpper;
    }

    /**
     * Removes liquidity from our BidWall position.
     *
     * @param _key The {PoolKey} that is being modified
     * @param _nativeIsZero If our native token is `currency0`
     * @param _tickLower The lower tick of our BidWall position
     * @param _tickUpper The upper tick of our BidWall position
     *
     * @return ethWithdrawn_ The amount of native token withdrawn
     * @return memecoinWithdrawn_ The amount of Memecoin withdrawn
     */
    function _removeLiquidity(
        PoolKey memory _key,
        bool _nativeIsZero,
        int24 _tickLower,
        int24 _tickUpper
    ) internal returns (
        uint ethWithdrawn_,
        uint memecoinWithdrawn_
    ) {
        // Get our existing liquidity for the position
        (uint128 liquidityBefore,,) = poolManager.getPositionInfo({
            poolId: _key.toId(),
            owner: address(this),
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            salt: 'bidwall'
        });

        BalanceDelta delta = _modifyAndSettleLiquidity({
            _poolKey: _key,
            _tickLower: _tickLower,
            _tickUpper: _tickUpper,
            _liquidityDelta: -int128(liquidityBefore),
            _sender: address(this)
        });

        // Set our ETH and Memecoin withdrawn amounts, depending on if the native token is currency0
        (ethWithdrawn_, memecoinWithdrawn_) = _nativeIsZero
            ? (uint128(delta.amount0()), uint128(delta.amount1()))
            : (uint128(delta.amount1()), uint128(delta.amount0()));
    }

    /**
     * This function will only be called by other functions via the PositionManager, which will already
     * hold the Uniswap V4 PoolManager key. It is for this reason we can interact openly with the
     * Uniswap V4 protocol without requiring a separate callback.
     *
     * @param _poolKey The {PoolKey} that is being modified
     * @param _tickLower The lower tick of our BidWall position
     * @param _tickUpper The upper tick of our BidWall position
     * @param _liquidityDelta The liquidity delta modifying the position
     * @param _sender The address that will be sending or receiving tokens
     */
    function _modifyAndSettleLiquidity(
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityDelta,
        address _sender
    ) internal returns (
        BalanceDelta delta_
    ) {
        (delta_, ) = poolManager.modifyLiquidity({
            key: _poolKey,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: _liquidityDelta,
                salt: 'bidwall'
            }),
            hookData: ''
        });

        if (delta_.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, _sender, uint128(-delta_.amount0()), false);
        } else if (delta_.amount0() > 0) {
            poolManager.take(_poolKey.currency0, _sender, uint128(delta_.amount0()));
        }

        if (delta_.amount1() < 0) {
            _poolKey.currency1.settle(poolManager, _sender, uint128(-delta_.amount1()), false);
        } else if (delta_.amount1() > 0) {
            poolManager.take(_poolKey.currency1, _sender, uint128(delta_.amount1()));
        }
    }

    /**
     * Defines our swap fee thresholds that must be crossed to provide fees. Each time
     * that we hit a set `cumulativeSwapFees` amount, we release a threshold of fees into
     * the bid wall.
     *
     * For this fixed threshold, this will just return the value set in `setSwapFeeThreshold`.
     *
     * @return uint The swap fee threshold
     */
    function _getSwapFeeThreshold(uint) internal virtual view returns (uint) {
        return _swapFeeThreshold;
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override virtual returns (bool) {
        return true;
    }

    /**
     * Ensures that only the immutable {PositionManager} can call the function.
     */
    modifier onlyPositionManager {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        _;
    }

}

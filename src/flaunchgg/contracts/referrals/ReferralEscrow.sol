// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';


/**
 * When a user referrers someone that then actions a swap, their address is passed in the `hookData`. This
 * user will then receive a referral fee of the unspecified token amount. This amount will be moved to this
 * escrow contract to be claimed at a later time.
 */
contract ReferralEscrow is Ownable {

    error MismatchedTokensAndLimits();

    /// Event emitted when tokens are assigned to a user
    event TokensAssigned(PoolId indexed _poolId, address indexed _user, address indexed _token, uint _amount);

    /// Event emitted when a user claims tokens for a specific token address
    event TokensClaimed(address indexed _user, address _recipient, address indexed _token, uint _amount);

    /// Event emitted when a user has swapped their claimed tokens to ETH
    event TokensSwapped(address indexed _user, address indexed _token, uint _tokenIn, uint _ethOut);

    /// PoolSwap contract for performing swaps
    PoolSwap public poolSwap;

    /// The native token used by the Flaunch protocol
    address public immutable nativeToken;

    /// The Flaunch {PositionManager} address
    address public immutable positionManager;

    /// Mapping to track token allocations by user and token
    mapping (address _user => mapping (address _token => uint _amount)) public allocations;

    /**
     * Constructor to initialize the PoolSwap contract address.
     *
     * @param _nativeToken The native token used by the Flaunch protocol
     * @param _positionManager The Flaunch {PositionManager} address
     */
    constructor (address _nativeToken, address _positionManager) {
        nativeToken = _nativeToken;
        positionManager = _positionManager;

        _initializeOwner(msg.sender);
    }

    /**
     * Function to update the PoolSwap contract address (only owner can call this).
     *
     * @param _poolSwap The new address that will handle pool swaps
     */
    function setPoolSwap(address _poolSwap) external onlyOwner {
        poolSwap = PoolSwap(_poolSwap);
    }

    /**
     * Function to assign tokens to a user with a PoolId included in the event.
     *
     * @dev Only the {PositionManager} contract can make this call.
     *
     * @param _poolId The PoolId that generated referral fees
     * @param _user The user that received the referral fees
     * @param _token The token that the fees are paid in
     * @param _amount The amount of fees granted to the user
     */
    function assignTokens(PoolId _poolId, address _user, address _token, uint _amount) external {
        // Ensure that the caller is the {PositionManager}
        if (msg.sender != positionManager) revert Unauthorized();

        // If no amount is passed, then we have nothing to process
        if (_amount == 0) return;

        allocations[_user][_token] += _amount;
        emit TokensAssigned(_poolId, _user, _token, _amount);
    }

    /**
     * Function for a user to claim tokens across multiple token addresses.
     *
     * @param _tokens The tokens to be claimed by the caller
     */
    function claimTokens(address[] calldata _tokens, address payable _recipient) external {
        address token;
        uint amount;
        for (uint i; i < _tokens.length; ++i) {
            token = _tokens[i];
            amount = allocations[msg.sender][token];

            // If there is nothing to claim, skip next steps
            if (amount == 0) continue;

            // Update allocation before transferring to prevent reentrancy attacks
            allocations[msg.sender][token] = 0;

            // If we are claiming the native token, then we can unwrap the flETH to ETH
            if (token == nativeToken) {
                // Withdraw the FLETH and transfer the ETH to the caller
                IFLETH(nativeToken).withdraw(amount);
                (bool _sent,) = _recipient.call{value: amount}('');
                require(_sent, 'ETH Transfer Failed');
            }
            // Otherwise, just transfer the token directly to the user
            else {
                IERC20(token).transfer(_recipient, amount);
            }

            emit TokensClaimed(msg.sender, _recipient, token, amount);
        }
    }

    /**
     * Function for a user to claim and swap tokens across multiple token addresses.
     *
     * @param _tokens The tokens that are being claimed and swapped
     * @param _sqrtPriceX96Limits The respective token's sqrtPriceX96 limit
     */
    function claimAndSwap(address[] calldata _tokens, uint160[] calldata _sqrtPriceX96Limits, address payable _recipient) external {
        // Ensure that we have a limit for each token
        uint tokensLength = _tokens.length;
        if (tokensLength > _sqrtPriceX96Limits.length) revert MismatchedTokensAndLimits();

        address token;
        uint amount;
        uint amountOut;
        uint totalAmountOut;
        for (uint i; i < tokensLength; ++i) {
            token = _tokens[i];
            amount = allocations[msg.sender][token];

            // If no tokens are available, skip the claim
            if (amount == 0) continue;

            // Update allocation before transferring to prevent reentrancy attacks
            allocations[msg.sender][token] = 0;

            // If we are including the native token, then we can just bypass the swap as we will
            // just unwrap it later
            if (token == nativeToken) {
                amountOut = amount;
            } else {
                // Provide the swap contract with sufficient allocation for the swap
                IERC20(token).approve(address(poolSwap), amount);

                // Perform the swap using PoolSwap contract with corresponding sqrtPriceX96Limit
                bool flipped = token < nativeToken;
                BalanceDelta delta = poolSwap.swap({
                    _key: PoolKey({
                        currency0: Currency.wrap(flipped ? token : nativeToken),
                        currency1: Currency.wrap(flipped ? nativeToken : token),
                        fee: 0,
                        hooks: IHooks(positionManager),
                        tickSpacing: 60
                    }),
                    _params: IPoolManager.SwapParams({
                        zeroForOne: flipped,
                        amountSpecified: -int(amount),
                        sqrtPriceLimitX96: _sqrtPriceX96Limits[i]
                    })
                });

                // Get the amount of tokens received from the swap
                amountOut = uint128(flipped ? delta.amount1() : delta.amount0());
            }

            totalAmountOut += amountOut;

            emit TokensClaimed(msg.sender, _recipient, token, amount);
            emit TokensSwapped(msg.sender, token, amount, amountOut);
        }

        // Withdraw the FLETH and transfer the ETH to the caller
        IFLETH(nativeToken).withdraw(totalAmountOut);
        (bool _sent,) = _recipient.call{value: totalAmountOut}('');
        require(_sent, 'ETH Transfer Failed');
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /**
     * Allows the contract to receive ETH from the flETH withdrawal.
     */
    receive() external payable {}

}

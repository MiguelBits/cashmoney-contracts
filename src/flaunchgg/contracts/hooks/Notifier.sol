// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {ISubscriber} from '@flaunch-interfaces/ISubscriber.sol';


/**
 * Notifier is used to opt in to sending updates to external contracts about position modifications
 * against a managed pool.
 */
contract Notifier is Ownable {

    using EnumerableSet for EnumerableSet.AddressSet;

    error SubscriptionReverted();

    event Subscription(address _subscriber);
    event Unsubscription(address _subscriber);

    /// Store a list of subscribed contracts
    EnumerableSet.AddressSet internal subscribers;

    /// Store the {PositionManager} that created this contract
    address internal _positionManager;

    /**
     * Registers the caller as the contract owner.
     *
     * @param _protocolOwner The initial EOA owner of the contract
     */
    constructor (address _protocolOwner) {
        _positionManager = msg.sender;

        // Grant ownership permissions to the caller
        _initializeOwner(_protocolOwner);
    }

    /**
     * Subscribes a contract to receive updates regarding pool modifications.
     *
     * @param _subscriber The address of the contract being subscribed
     * @param _data Any data passed to subscription call
     */
    function subscribe(address _subscriber, bytes calldata _data) public onlyOwner {
        // Add the subscriber to our array, which returns true if address is not already
        // present in our EnumerableSet.
        if (subscribers.add(_subscriber)) {
            // Check if we receive a success response. If not, we cannot subscribe the address
            if (!ISubscriber(_subscriber).subscribe(_data)) {
                revert SubscriptionReverted();
            }

            emit Subscription(_subscriber);
        }
    }

    /**
     * Removes a subscriber based on the index they were stored at.
     *
     * @param _subscriber The address of the subscriber to unsubscribe
     */
    function unsubscribe(address _subscriber) public onlyOwner {
        // If we have referenced an empty index, prevent futher processing
        if (!subscribers.contains(_subscriber)) {
            return;
        }

        // Delete our subscriber by the index
        subscribers.remove(_subscriber);

        // Unsubscribe our subscriber, catching the revert in case the contract has become corrupted
        try ISubscriber(_subscriber).unsubscribe() {} catch {}
        emit Unsubscription(_subscriber);
    }

    /**
     * Send our pool modification notification to all subscribers.
     *
     * @param _poolId The PoolId that was modified
     */
    function notifySubscribers(PoolId _poolId, bytes4 _key, bytes calldata _data) public {
        // Ensure that the {PositionManager} sent this notification
        require(msg.sender == _positionManager);

        // Iterate over all subscribers to pass on data
        uint subscribersLength = subscribers.length();
        for (uint i; i < subscribersLength; ++i) {
            ISubscriber(subscribers.at(i)).notify(_poolId, _key, _data);
        }
    }

}

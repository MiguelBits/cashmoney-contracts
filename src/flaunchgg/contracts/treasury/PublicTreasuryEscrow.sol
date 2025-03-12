// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from '@solady/utils/Initializable.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';


/**
 * Allows a {Flaunch} ERC721 token holder to deposit their ERC721 into this escrow contract to
 * allow anyone to execute approve treasury actions.
 */
contract PublicTreasuryEscrow is Initializable {

    error NotOriginalOwner();
    error OwnershipBurned();

    event TreasuryOwnershipBurned(uint indexed _tokenId);
    event TreasuryEscrowed(uint indexed _tokenId, address _sender);
    event TreasuryReclaimed(uint indexed _tokenId, address _sender);

    /// ERC721 Flaunch contract address
    Flaunch public immutable flaunch;

    /// The {Flaunch} token ID stored in the contract
    uint public tokenId;

    /// The original owner of the Flaunch ERC721
    address public originalOwner;

    /// If ownership has been burned for the Flaunch ERC721
    bool public ownershipBurned;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _flaunch The {Flaunch} ERC721 contract address
     */
    constructor (address _flaunch) {
        flaunch = Flaunch(_flaunch);
    }

    /**
     * Escrow an ERC721 token by transferring it to this contract and recording the original
     * owner.
     *
     * @param _tokenId The ID of the token to escrow
     */
    function initialize(uint _tokenId) public initializer {
        // Register the immutable tokenId
        tokenId = _tokenId;

        // Set the original owner
        originalOwner = msg.sender;

        // Transfer the token from the msg.sender to the contract
        flaunch.transferFrom(msg.sender, address(this), _tokenId);
        emit TreasuryEscrowed(_tokenId, msg.sender);
    }

    /**
     * Reclaims the escrowed token by the original owner. Calls the `claim` function before
     * transferring the token back.
     */
    function reclaim() public ownerAndUnburned {
        // Call claim before transferring back
        claim();

        // Clear the original owner record after reclaiming
        delete originalOwner;

        // Transfer the token back to the original owner
        flaunch.transferFrom(address(this), msg.sender, tokenId);
        emit TreasuryReclaimed(tokenId, msg.sender);
    }

    /**
     * Burn the ownership record for a tokenId. Only the original owner can call this function.
     */
    function burnOwnership() public ownerAndUnburned {
        // Make our final claim before burning ownership
        claim();

        // Delete the mapping reference
        ownershipBurned = true;

        emit TreasuryOwnershipBurned(tokenId);
    }

    /**
     * Calls `withdrawFees` against the {PositionManager} to claim any fees allocated to this
     * escrow contract. If ownership has been burned, sends fees to the {TokenTreasury} address.
     */
    function claim() public {
        flaunch.positionManager().withdrawFees(
            ownershipBurned ? flaunch.memecoinTreasury(tokenId) : originalOwner,
            true
        );
    }

    /**
     * Allows any approved action to be called by anyone.
     *
     * @param _action The {ITreasuryAction} address to execute
     * @param _data Additional data that the {ITreasuryAction} may require
     */
    function executeAction(address _action, bytes memory _data) public {
        MemecoinTreasury(flaunch.memecoinTreasury(tokenId)).executeAction(_action, _data);
    }

    /**
     * Checks that the token ownership has not been burned and that the original owner of
     * the token is the function caller.
     */
    modifier ownerAndUnburned {
        if (ownershipBurned) revert OwnershipBurned();
        if (originalOwner != msg.sender) revert NotOriginalOwner();
        _;
    }

}

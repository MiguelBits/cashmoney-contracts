// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, expect, ctx} from "vulcan/test.sol";

/// @title Modify chain parameters
/// @dev Use the context module to modify chain parameters
contract ContextExample is Test {
    function test() external {
        ctx.setBlockTimestamp(1);
        expect(block.timestamp).toEqual(1);

        ctx.setBlockNumber(123);
        expect(block.number).toEqual(123);

        ctx.setBlockBaseFee(99999);
        expect(block.basefee).toEqual(99999);

        ctx.setBlockPrevrandao(bytes32(uint256(123)));
        expect(block.prevrandao).toEqual(uint256(bytes32(uint256(123))));

        ctx.setChainId(666);
        expect(block.chainid).toEqual(666);

        ctx.setBlockCoinbase(address(1));
        expect(block.coinbase).toEqual(address(1));

        ctx.setGasPrice(1e18);
        expect(tx.gasprice).toEqual(1e18);
    }
}

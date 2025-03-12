// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


interface IInitialPrice {

    function getFlaunchingFee(address _sender, bytes calldata _initialPriceParams) external view returns (uint);

    function getMarketCap(bytes calldata _initialPriceParams) external view returns (uint);

    function getSqrtPriceX96(address _sender, bool _flipped, bytes calldata _initialPriceParams) external view returns (uint160);

}

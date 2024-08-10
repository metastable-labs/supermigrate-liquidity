// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        pool = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB, fee)))));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}

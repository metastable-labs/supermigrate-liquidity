// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockUniswapV2Router02 {
    uint256 public amountAOut;
    uint256 public amountBOut;

    function setRemoveLiquidityReturn(uint256 _amountA, uint256 _amountB) external {
        amountAOut = _amountA;
        amountBOut = _amountB;
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(amountAOut >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        require(amountBOut >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
        return (amountAOut, amountBOut);
    }
}

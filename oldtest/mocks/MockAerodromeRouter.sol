// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./MockWETH.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAerodromeRouter {
    IWETH public immutable wethToken;
    mapping(address => mapping(address => address)) public pools;

    constructor(address _weth) {
        wethToken = IWETH(_weth);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        //return (amountADesired, amountBDesired, 100);
        // Transfer tokens from the caller to this contract
        IERC20(tokenA).transferFrom(tx.origin, to, amountADesired);
        IERC20(tokenB).transferFrom(tx.origin, to, amountBDesired);

        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = amountA + amountB;
        return (amountA, amountB, liquidity);
    }

    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // Mock implementation
        wethToken.deposit{value: msg.value}();
        IERC20(token).transferFrom(tx.origin, to, amountTokenDesired);

        // Transfer WETH to the caller (which would be the L2LiquidityManager contract)
        wethToken.transfer(msg.sender, msg.value);
        //return (amountTokenDesired, msg.value, 100);

        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = amountToken + amountETH;
        return (amountToken, amountETH, liquidity);
    }

    function weth() external view returns (IWETH) {
        return wethToken;
    }
}

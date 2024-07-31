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
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity) {
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
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity)
    {
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
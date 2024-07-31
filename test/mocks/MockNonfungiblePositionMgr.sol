// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";
import "forge-std/console.sol";

interface INonfungiblePositionManager {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
}

contract MockNonfungiblePositionManager {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 => Position) public positions_track;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    uint256 public decreaseLiquidityAmount0;
    uint256 public decreaseLiquidityAmount1;

    function setDecreaseLiquidityReturn(uint256 _amount0, uint256 _amount1) external {
        decreaseLiquidityAmount0 = _amount0;
        decreaseLiquidityAmount1 = _amount1;
    }

    function approve(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "Not the owner");
        getApproved[tokenId] = to;
    }

    function mint(address recipient, uint256 tokenId) external {
        ownerOf[tokenId] = recipient;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory pos = positions_track[tokenId];
        return (0, address(0), pos.token0, pos.token1, pos.fee, pos.tickLower, pos.tickUpper, pos.liquidity, 0, 0, 0, 0);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = positions_track[params.tokenId];
        require(pos.liquidity >= params.liquidity, "Not enough liquidity");

        amount0 = decreaseLiquidityAmount0;
        amount1 = decreaseLiquidityAmount1;

        pos.liquidity -= params.liquidity;
        return (amount0, amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = positions_track[params.tokenId];

        require(pos.liquidity > 0, "No liquidity to collect");

        uint256 tokensOwed = pos.liquidity;
        console.log("Liquidity available:  ", tokensOwed);

        amount0 = params.amount0Max > tokensOwed / 2 ? tokensOwed / 2 : params.amount0Max;
        amount1 = params.amount1Max > tokensOwed / 2 ? tokensOwed / 2 : params.amount1Max;

        console.log("Collecting amount0: ", amount0);
        console.log("Collecting amount1: ", amount1);

        pos.liquidity -= uint128(amount0 + amount1);
    }

    function setPosition(
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        positions_track[tokenId] = Position(token0, token1, fee, tickLower, tickUpper, liquidity);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not the owner");
        ownerOf[tokenId] = to;
    }
}

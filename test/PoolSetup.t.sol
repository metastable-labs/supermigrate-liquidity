// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}
contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    address public owner;
    address public mockRouter;
    address public mockFeeReceiver;
    MockEndpoint public endpoint;

    function setUp() public {
        owner = address(this);
        mockRouter = address(0x1);
        mockFeeReceiver = address(0x2);
        endpoint = new MockEndpoint();

        liquidityManager = new L2LiquidityManager(address(mockRouter), address(mockFeeReceiver), 100, address(endpoint), owner);
    }

function testSetPoolSuccess() public {
    address tokenA = address(0x3);
    address tokenB = address(0x4);
    address pool = address(0x5);
    address gauge = address(0x6);

    vm.expectEmit(true, true, true, true);
    emit L2LiquidityManager.PoolSet(tokenA, tokenB, pool, gauge);

    liquidityManager.setPool(tokenA, tokenB, pool, gauge);

    // Verify the pool was set correctly
    (address returnedPool, address returnedGauge) = liquidityManager.getPool(tokenA, tokenB);
    assertEq(returnedPool, pool, "Pool address mismatch");
    assertEq(returnedGauge, gauge, "Gauge address mismatch");
}

    function testSetPoolReverseOrder() public {
        address tokenA = address(0x3);
        address tokenB = address(0x4);
        address pool = address(0x5);
        address gauge = address(0x6);

        liquidityManager.setPool(tokenA, tokenB, pool, gauge);

        (address returnedPool, address returnedGauge) = liquidityManager.getPool(tokenB, tokenA);
        assertEq(returnedPool, pool, "Pool address mismatch for reverse order");
        assertEq(returnedGauge, gauge, "Gauge address mismatch for reverse order");
    }

    function testSetPoolOnlyOwner() public {
        address tokenA = address(0x3);
        address tokenB = address(0x4);
        address pool = address(0x5);
        address gauge = address(0x6);

        address nonOwner = address(0x7);
        vm.prank(nonOwner);
        //vm.expectRevert("Ownable: caller is not the owner");
        vm.expectRevert();
        liquidityManager.setPool(tokenA, tokenB, pool, gauge);
    }

    function testSetPoolInvalidAddresses() public {
        address tokenA = address(0);
        address tokenB = address(0x4);
        address pool = address(0x5);
        address gauge = address(0x6);

        vm.expectRevert("Invalid addresses");
        liquidityManager.setPool(tokenA, tokenB, pool, gauge);

        tokenA = address(0x3);
        tokenB = address(0);
        vm.expectRevert("Invalid addresses");
        liquidityManager.setPool(tokenA, tokenB, pool, gauge);

        tokenB = address(0x4);
        pool = address(0);
        vm.expectRevert("Invalid addresses");
        liquidityManager.setPool(tokenA, tokenB, pool, gauge);
    }

    function testSetPoolDuplicateTokens() public {
        address tokenA = address(0x3);
        address pool = address(0x5);
        address gauge = address(0x6);

        vm.expectRevert("Invalid addresses");
        liquidityManager.setPool(tokenA, tokenA, pool, gauge);
    }

    function testSetPoolMultiplePools() public {
        address tokenA = address(0x3);
        address tokenB = address(0x4);
        address tokenC = address(0x7);
        address pool1 = address(0x5);
        address gauge1 = address(0x6);
        address pool2 = address(0x8);
        address gauge2 = address(0x9);

        liquidityManager.setPool(tokenA, tokenB, pool1, gauge1);
        liquidityManager.setPool(tokenB, tokenC, pool2, gauge2);

        assertEq(liquidityManager.getPoolsCount(), 2, "Incorrect number of pools");

        (address[] memory pools, address[] memory gauges) = liquidityManager.getPools(0, 2);
        assertEq(pools[0], pool1, "First pool address mismatch");
        assertEq(gauges[0], gauge1, "First gauge address mismatch");
        assertEq(pools[1], pool2, "Second pool address mismatch");
        assertEq(gauges[1], gauge2, "Second gauge address mismatch");
    }

    function testSetPoolUpdateExisting() public {
        address tokenA = address(0x3);
        address tokenB = address(0x4);
        address pool1 = address(0x5);
        address gauge1 = address(0x6);
        address pool2 = address(0x7);
        address gauge2 = address(0x8);

        liquidityManager.setPool(tokenA, tokenB, pool1, gauge1);
        liquidityManager.setPool(tokenA, tokenB, pool2, gauge2);

        (address returnedPool, address returnedGauge) = liquidityManager.getPool(tokenA, tokenB);
        assertEq(returnedPool, pool2, "Updated pool address mismatch");
        assertEq(returnedGauge, gauge2, "Updated gauge address mismatch");
        assertEq(liquidityManager.getPoolsCount(), 2, "Incorrect number of pools after update");
    }
}
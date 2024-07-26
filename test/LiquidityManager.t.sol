// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";
import "./mocks/MockAerodromeRouter.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    MockAerodromeRouter public router;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        
        weth = new MockWETH();
        router = new MockAerodromeRouter(address(weth));
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        L2LiquidityManager impl = new L2LiquidityManager();
        bytes memory data = abi.encodeWithSelector(
            L2LiquidityManager.initialize.selector,
            address(router),
            address(0x2), // fee receiver
            100 // 1% migration fee
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        liquidityManager = L2LiquidityManager(payable(address(proxy)));

        address mockPool = address(0x3);
        address mockGauge = address(0x4);
        liquidityManager.setPool(address(tokenA), address(tokenB), mockPool, mockGauge);
        liquidityManager.setPool(address(weth), address(tokenA), mockPool, mockGauge);
    }

    function testDepositLiquidityERC20() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user, user);
        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);
        tokenA.approve(address(router), amountA);
        tokenB.approve(address(router), amountB);


        liquidityManager.depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountA,
            amountB,
            false
        );
        vm.stopPrank();

        // Check user liquidity (after 1% fee deduction)
        assertEq(liquidityManager.getUserLiquidity(user, address(tokenA)), 99 ether, "Incorrect tokenA liquidity");
        assertEq(liquidityManager.getUserLiquidity(user, address(tokenB)), 198 ether, "Incorrect tokenB liquidity");
    }

    function testDepositLiquidityETH() public {
        uint256 amountETH = 1 ether;
        uint256 amountToken = 100 ether;
        tokenA.mint(user, amountToken);
        vm.deal(user, amountETH);

        vm.startPrank(user, user);
        tokenA.approve(address(liquidityManager), amountToken);
        tokenA.approve(address(router), amountToken);

        liquidityManager.depositLiquidity{value: amountETH}(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETH,
            amountToken,
            false
        );
        vm.stopPrank();

        // Check user liquidity (after 1% fee deduction)
        assertEq(liquidityManager.getUserLiquidity(user, address(weth)), 0.99 ether, "Incorrect ETH liquidity");
        assertEq(liquidityManager.getUserLiquidity(user, address(tokenA)), 99 ether, "Incorrect tokenA liquidity");
    }

    function testDepositLiquidityInsufficientBalance() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        tokenA.mint(user, amountA - 1 ether);
        tokenB.mint(user, amountB);

        vm.startPrank(user);
        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        //vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.expectRevert();
        liquidityManager.depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountA,
            amountB,
            false
        );
        vm.stopPrank();
    }

    function testDepositLiquidityETHInsufficientAmount() public {
        uint256 amountETH = 1 ether;
        uint256 amountToken = 100 ether;
        tokenA.mint(user, amountToken);

        vm.startPrank(user, user);
        tokenA.approve(address(liquidityManager), amountToken);

        vm.expectRevert("Must send ETH");
        liquidityManager.depositLiquidity(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETH,
            amountToken,
            false
        );
        vm.stopPrank();
    }

    function testDepositLiquidityNonExistentPool() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user);
        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        vm.expectRevert("Pool does not exist");
        liquidityManager.depositLiquidity(
            address(tokenA),
            address(0x5), // non-existent token
            amountA,
            amountB,
            amountA,
            amountB,
            false
        );
        vm.stopPrank();
    }
}
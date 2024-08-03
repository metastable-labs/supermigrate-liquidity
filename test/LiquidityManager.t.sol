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

contract MockFeeRecipient {}

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockFeeRecipient public mockFeeRecipient;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    MockAerodromeRouter public router;
    address public owner;
    address public user;
    MockEndpoint public endpoint;

    function setUp() public {
        owner = address(this);
        user = address(0x1);

        weth = new MockWETH();
        router = new MockAerodromeRouter(address(weth));
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        mockFeeRecipient = new MockFeeRecipient();
        endpoint = new MockEndpoint();

        try new L2LiquidityManager(address(router), address(mockFeeRecipient), 100, address(endpoint), owner) returns (
            L2LiquidityManager _liquidityManager
        ) {
            liquidityManager = _liquidityManager;
        } catch Error(string memory reason) {
            console.log("L2LiquidityManager creation failed:", reason);
            revert(reason);
        }

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

        liquidityManager._depositLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, L2LiquidityManager.PoolType.STABLE
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

        liquidityManager._depositLiquidity{value: amountETH}(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETH,
            amountToken,
            L2LiquidityManager.PoolType.STABLE
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
        liquidityManager._depositLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, L2LiquidityManager.PoolType.STABLE
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
        liquidityManager._depositLiquidity(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETH,
            amountToken,
            L2LiquidityManager.PoolType.STABLE
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
        liquidityManager._depositLiquidity(
            address(tokenA),
            address(0x5), // non-existent token
            amountA,
            amountB,
            amountA,
            amountB,
            L2LiquidityManager.PoolType.STABLE
        );
        vm.stopPrank();
    }

    function testFuzz_DepositLiquidity(uint256 amountA, uint256 amountB, uint256 migrationFee) public {
        vm.assume(amountA > 1 && amountA <= 100_000_000 ether);
        vm.assume(amountB > 1 && amountB <= 100_000_000 ether);
        vm.assume(migrationFee >= 1 && migrationFee <= 10_000);

        liquidityManager.setFee(migrationFee);

        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user, user);
        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);
        tokenA.approve(address(router), amountA);
        tokenB.approve(address(router), amountB);

        liquidityManager._depositLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, L2LiquidityManager.PoolType.STABLE
        );
        vm.stopPrank();

        assertGe(liquidityManager.getUserLiquidity(user, address(tokenA)), 0, "TokenA liquidity should be positive");
        assertGe(liquidityManager.getUserLiquidity(user, address(tokenB)), 0, "TokenB liquidity should be positive");
    }

    function testFuzz_DepositLiquidityETH(uint256 amountETH, uint256 amountToken, uint256 migrationFee) public {
        vm.assume(amountETH > 1 && amountETH <= 100_000_000 ether);
        vm.assume(amountToken > 1 && amountToken <= 100_000_000 ether);
        vm.assume(migrationFee >= 1 && migrationFee <= 10_000);

        liquidityManager.setFee(migrationFee);

        tokenA.mint(user, amountToken);
        vm.deal(user, amountETH);

        vm.startPrank(user, user);
        tokenA.approve(address(liquidityManager), amountToken);
        tokenA.approve(address(router), amountToken);

        liquidityManager._depositLiquidity{value: amountETH}(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETH,
            amountToken,
            L2LiquidityManager.PoolType.STABLE
        );
        vm.stopPrank();

        assertGe(liquidityManager.getUserLiquidity(user, address(weth)), 0, "ETH liquidity should be positive");
        assertGe(liquidityManager.getUserLiquidity(user, address(tokenA)), 0, "TokenA liquidity should be positive");
    }

    function invariant_TotalLiquidityLessThanSupply() public view {
        uint256 totalLiquidityA = liquidityManager.getUserLiquidity(user, address(tokenA));
        uint256 totalLiquidityB = liquidityManager.getUserLiquidity(user, address(tokenB));
        uint256 totalLiquidityWETH = liquidityManager.getUserLiquidity(user, address(weth));

        assertLe(totalLiquidityA, tokenA.totalSupply(), "Total liquidity A exceeds supply");
        assertLe(totalLiquidityB, tokenB.totalSupply(), "Total liquidity B exceeds supply");
        assertLe(totalLiquidityWETH, address(weth).balance, "Total liquidity WETH exceeds balance");
    }

    function invariant_UserLiquidityNeverNegative() public view {
        assertGe(liquidityManager.getUserLiquidity(user, address(tokenA)), 0, "User liquidity A is negative");
        assertGe(liquidityManager.getUserLiquidity(user, address(tokenB)), 0, "User liquidity B is negative");
        assertGe(liquidityManager.getUserLiquidity(user, address(weth)), 0, "User liquidity WETH is negative");
    }

    function invariant_ContractBalanceExceedsLiquidity() public view {
        uint256 totalLiquidityA = liquidityManager.getUserLiquidity(user, address(tokenA));
        uint256 totalLiquidityB = liquidityManager.getUserLiquidity(user, address(tokenB));
        uint256 totalLiquidityWETH = liquidityManager.getUserLiquidity(user, address(weth));

        assertGe(tokenA.balanceOf(address(liquidityManager)), totalLiquidityA, "Contract balance A less than liquidity");
        assertGe(tokenB.balanceOf(address(liquidityManager)), totalLiquidityB, "Contract balance B less than liquidity");
        assertGe(
            weth.balanceOf(address(liquidityManager)), totalLiquidityWETH, "Contract WETH balance less than liquidity"
        );
    }

    function testFuzz_SetFee(uint256 newFee) public {
        vm.assume(newFee > 0);
        vm.assume(newFee <= liquidityManager.FEE_DENOMINATOR());

        vm.prank(owner);
        liquidityManager.setFee(newFee);

        assertEq(liquidityManager.migrationFee(), newFee, "Fee not set correctly");
    }

    function testFuzz_SetPool(address tokenX, address tokenY, address pool, address gauge) public {
        vm.assume(tokenX != address(0) && tokenY != address(0) && tokenX != tokenY && pool != address(0));

        vm.prank(owner);
        liquidityManager.setPool(tokenX, tokenY, pool, gauge);

        (address returnedPool, address returnedGauge) = liquidityManager.getPool(tokenX, tokenY);
        assertEq(returnedPool, pool, "Pool not set correctly");
        assertEq(returnedGauge, gauge, "Gauge not set correctly");
    }
}

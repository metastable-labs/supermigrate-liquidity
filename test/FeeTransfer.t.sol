// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";
import "./mocks/MockAerodromeRouter.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockFeeRecipient {}

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    MockAerodromeRouter public mockRouter;
    MockFeeRecipient public mockFeeRecipient;
    MockEndpoint public endpoint;
    address public user;
    address public owner;

    function setUp() public {
        owner = address(this);
        weth = new MockWETH();
        endpoint = new MockEndpoint();
        mockRouter = new MockAerodromeRouter(address(weth));
        owner = address(this);
        mockFeeRecipient = new MockFeeRecipient();
        liquidityManager =
            new L2LiquidityManager(address(mockRouter), address(mockFeeRecipient), 100, address(endpoint), owner);
        user = address(0x1);

        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        endpoint = new MockEndpoint();

        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);

        // Set up a pool for tokenA and tokenB
        liquidityManager.setPool(address(tokenA), address(tokenB), address(0x123), address(0x456));
        // Set up a pool for tokenA and WETH
        liquidityManager.setPool(address(tokenA), address(weth), address(0x789), address(0xabc));
    }

    function testDepositLiquidityERC20() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 amountAMin = 99 ether;
        uint256 amountBMin = 198 ether;

        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user, user);

        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);
        tokenA.approve(address(mockRouter), amountA);
        tokenB.approve(address(mockRouter), amountB);

        liquidityManager._depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountAMin,
            amountBMin,
            L2LiquidityManager.PoolType.STABLE
        );

        vm.stopPrank();

        // Check if fees were deducted correctly (1% fee)
        uint256 expectedAmountAfterFeeA = 99 ether;
        uint256 expectedAmountAfterFeeB = 198 ether;

        assertEq(
            liquidityManager.getUserLiquidity(address(user), address(tokenA)),
            expectedAmountAfterFeeA,
            "Incorrect tokenA liquidity"
        );
        assertEq(
            liquidityManager.getUserLiquidity(address(user), address(tokenB)),
            expectedAmountAfterFeeB,
            "Incorrect tokenB liquidity"
        );

        // Check if fees were transferred to the fee receiver
        assertEq(tokenA.balanceOf(liquidityManager.feeReceiver()), 1 ether, "Incorrect tokenA fee");
        assertEq(tokenB.balanceOf(liquidityManager.feeReceiver()), 2 ether, "Incorrect tokenB fee");
    }

    function testDepositLiquidityETH() public {
        uint256 amountETH = 1 ether;
        uint256 amountToken = 100 ether;
        uint256 amountETHMin = 0.99 ether;
        uint256 amountTokenMin = 99 ether;

        tokenA.mint(user, amountToken);
        vm.deal(user, amountETH);
        vm.startPrank(user, user);

        tokenA.approve(address(liquidityManager), amountToken);
        tokenA.approve(address(mockRouter), amountToken);

        liquidityManager._depositLiquidity{value: amountETH}(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETHMin,
            amountTokenMin,
            L2LiquidityManager.PoolType.STABLE
        );

        vm.stopPrank();

        // Check if fees were deducted correctly (1% fee)
        uint256 expectedAmountAfterFeeETH = 0.99 ether;
        uint256 expectedAmountAfterFeeToken = 99 ether;

        assertEq(
            liquidityManager.getUserLiquidity(user, address(weth)), expectedAmountAfterFeeETH, "Incorrect ETH liquidity"
        );
        assertEq(
            liquidityManager.getUserLiquidity(user, address(tokenA)),
            expectedAmountAfterFeeToken,
            "Incorrect tokenA liquidity"
        );

        assertEq(weth.balanceOf(address(liquidityManager.feeReceiver())), 0.01 ether, "Incorrect ETH fee");
        assertEq(tokenA.balanceOf(liquidityManager.feeReceiver()), 1 ether, "Incorrect tokenA fee");

        assertEq(weth.balanceOf(address(liquidityManager)), 0.99 ether, "WETH balance of L2LiquidityManager");
    }

    function testDepositLiquidityFeeCalculation() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 expectedFeeA = (amountA * liquidityManager.migrationFee()) / liquidityManager.FEE_DENOMINATOR();
        uint256 expectedFeeB = (amountB * liquidityManager.migrationFee()) / liquidityManager.FEE_DENOMINATOR();

        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user, user);

        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        tokenA.approve(address(mockRouter), amountA);
        tokenB.approve(address(mockRouter), amountB);

        liquidityManager._depositLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, L2LiquidityManager.PoolType.STABLE
        );

        vm.stopPrank();

        assertEq(tokenA.balanceOf(liquidityManager.feeReceiver()), expectedFeeA, "Incorrect tokenA fee");
        assertEq(tokenB.balanceOf(liquidityManager.feeReceiver()), expectedFeeB, "Incorrect tokenB fee");
    }

    function testChangeFeesAndVerify() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 incorrectFee = 2000; // 20% fee, overriding original 1%

        vm.prank(address(this));

        liquidityManager.setFee(incorrectFee);

        tokenA.mint(user, amountA);
        tokenB.mint(user, amountB);

        vm.startPrank(user, user);

        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);
        tokenA.approve(address(mockRouter), amountA);
        tokenB.approve(address(mockRouter), amountB);

        liquidityManager._depositLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, L2LiquidityManager.PoolType.STABLE
        );

        vm.stopPrank();

        uint256 expectedAmountAfterFeeA = 80 ether; // 100 - 20% fee
        uint256 expectedAmountAfterFeeB = 160 ether; // 200 - 20% fee

        assertEq(
            liquidityManager.getUserLiquidity(address(user), address(tokenA)),
            expectedAmountAfterFeeA,
            "Incorrect tokenA liquidity after wrong fee"
        );
        assertEq(
            liquidityManager.getUserLiquidity(address(user), address(tokenB)),
            expectedAmountAfterFeeB,
            "Incorrect tokenB liquidity after wrong fee"
        );

        assertEq(tokenA.balanceOf(liquidityManager.feeReceiver()), 20 ether, "Incorrect tokenA fee transfer");
        assertEq(tokenB.balanceOf(liquidityManager.feeReceiver()), 40 ether, "Incorrect tokenB fee transfer");
    }
}

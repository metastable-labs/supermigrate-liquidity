// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./MockERC20.sol";
import "./MockWETH.sol";
import "./MockAerodromeRouter.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract MockFeeRecipient {}

contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockWETH public weth;
    MockAerodromeRouter public mockRouter;
    MockFeeRecipient public mockFeeRecipient;

    function setUp() public {
        weth = new MockWETH();
        mockRouter = new MockAerodromeRouter(address(weth));
        mockFeeRecipient = new MockFeeRecipient();
        L2LiquidityManager impl = new L2LiquidityManager();

        bytes memory data = abi.encodeWithSelector(
            L2LiquidityManager.initialize.selector,
            address(mockRouter),
            address(mockFeeRecipient),
            100 //1% fee
        );

        // Deploy the proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);

        // Cast the proxy to L2LiquidityManager
        liquidityManager = L2LiquidityManager(payable(address(proxy)));

        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);

        // Set up a pool for tokenA and tokenB
        liquidityManager.setPool(
            address(tokenA),
            address(tokenB),
            address(0x123),
            address(0x456)
        );
        // Set up a pool for tokenA and WETH
        liquidityManager.setPool(
            address(tokenA),
            address(weth),
            address(0x789),
            address(0xabc)
        );
    }

    function testDepositLiquidityERC20() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 amountAMin = 99 ether;
        uint256 amountBMin = 198 ether;

        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        liquidityManager.depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountAMin,
            amountBMin,
            false
        );

        // Check if fees were deducted correctly (1% fee)
        uint256 expectedAmountAfterFeeA = 99 ether;
        uint256 expectedAmountAfterFeeB = 198 ether;

        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(tokenA)),
            expectedAmountAfterFeeA,
            "Incorrect tokenA liquidity"
        );
        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(tokenB)),
            expectedAmountAfterFeeB,
            "Incorrect tokenB liquidity"
        );

        // Check if fees were transferred to the fee receiver
        assertEq(
            tokenA.balanceOf(liquidityManager.feeReceiver()),
            1 ether,
            "Incorrect tokenA fee"
        );
        assertEq(
            tokenB.balanceOf(liquidityManager.feeReceiver()),
            2 ether,
            "Incorrect tokenB fee"
        );
    }

    function testDepositLiquidityETH() public {
        uint256 amountETH = 1 ether;
        uint256 amountToken = 100 ether;
        uint256 amountETHMin = 0.99 ether;
        uint256 amountTokenMin = 99 ether;

        tokenA.mint(address(this), amountToken);
        tokenA.approve(address(liquidityManager), amountToken);

        liquidityManager.depositLiquidity{value: amountETH}(
            address(weth),
            address(tokenA),
            amountETH,
            amountToken,
            amountETHMin,
            amountTokenMin,
            false
        );

        // Check if fees were deducted correctly (1% fee)
        uint256 expectedAmountAfterFeeETH = 0.99 ether;
        uint256 expectedAmountAfterFeeToken = 99 ether;

        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(weth)),
            expectedAmountAfterFeeETH,
            "Incorrect ETH liquidity"
        );
        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(tokenA)),
            expectedAmountAfterFeeToken,
            "Incorrect tokenA liquidity"
        );

        assertEq(
            weth.balanceOf(address(liquidityManager.feeReceiver())),
            0.01 ether,
            "Incorrect ETH fee"
        );
        assertEq(
            tokenA.balanceOf(liquidityManager.feeReceiver()),
            1 ether,
            "Incorrect tokenA fee"
        );

        assertEq(
            weth.balanceOf(address(liquidityManager)),
            0.99 ether,
            "WETH balance of L2LiquidityManager"
        );
    }

    function testDepositLiquidityFeeCalculation() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 expectedFeeA = (amountA * liquidityManager.migrationFee()) /
            liquidityManager.FEE_DENOMINATOR();
        uint256 expectedFeeB = (amountB * liquidityManager.migrationFee()) /
            liquidityManager.FEE_DENOMINATOR();

        tokenA.mint(address(this), amountA);
        tokenB.mint(address(this), amountB);
        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        liquidityManager.depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountA,
            amountB,
            false
        );

        assertEq(
            tokenA.balanceOf(liquidityManager.feeReceiver()),
            expectedFeeA,
            "Incorrect tokenA fee"
        );
        assertEq(
            tokenB.balanceOf(liquidityManager.feeReceiver()),
            expectedFeeB,
            "Incorrect tokenB fee"
        );
    }

    function testChangeFeesAndVerify() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 incorrectFee = 2000; // 20% fee, overriding original 1%

        tokenA.mint(address(this), amountA);
        tokenB.mint(address(this), amountB);

        tokenA.approve(address(liquidityManager), amountA);
        tokenB.approve(address(liquidityManager), amountB);

        liquidityManager.setFee(incorrectFee);

        liquidityManager.depositLiquidity(
            address(tokenA),
            address(tokenB),
            amountA,
            amountB,
            amountA,
            amountB,
            false
        );

        uint256 expectedAmountAfterFeeA = 80 ether; // 100 - 20% fee
        uint256 expectedAmountAfterFeeB = 160 ether; // 200 - 20% fee

        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(tokenA)),
            expectedAmountAfterFeeA,
            "Incorrect tokenA liquidity after wrong fee"
        );
        assertEq(
            liquidityManager.getUserLiquidity(address(this), address(tokenB)),
            expectedAmountAfterFeeB,
            "Incorrect tokenB liquidity after wrong fee"
        );

        assertEq(
            tokenA.balanceOf(liquidityManager.feeReceiver()),
            20 ether,
            "Incorrect tokenA fee transfer"
        );
        assertEq(
            tokenB.balanceOf(liquidityManager.feeReceiver()),
            40 ether,
            "Incorrect tokenB fee transfer"
        );
    }
}

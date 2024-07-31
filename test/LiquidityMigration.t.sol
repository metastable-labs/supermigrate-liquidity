// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LiquidityMigration.sol";
import "./mocks/MockUniswapV2Factory.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockUniswapV3Factory.sol";
import "./mocks/MockStandardBridge.sol";
import "./mocks/MockNonfungiblePositionMgr.sol";
import "./mocks/MockERC20.sol";

contract LiquidityMigrationTest is Test {
    LiquidityMigration public liquidityMigration;
    MockUniswapV2Factory public mockV2Factory;
    MockUniswapV2Router02 public mockV2Router;
    MockUniswapV3Factory public mockV3Factory;
    MockNonfungiblePositionManager public mockNFTManager;
    MockStandardBridge public mockBridge;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public constant LAYER_ZERO_ENDPOINT = address(0x123);
    address public constant DELEGATE = address(0x456);
    address public constant L2_LIQUIDITY_MANAGER = address(0x789);

    function setUp() public {
        console.log("Starting setUp");

        console.log("Deploying MockUniswapV2Factory");
        mockV2Factory = new MockUniswapV2Factory();
        console.log("MockUniswapV2Factory deployed at", address(mockV2Factory));

        console.log("Deploying MockUniswapV2Router02");
        mockV2Router = new MockUniswapV2Router02();
        console.log("MockUniswapV2Router02 deployed at", address(mockV2Router));

        console.log("Deploying MockUniswapV3Factory");
        mockV3Factory = new MockUniswapV3Factory();
        console.log("MockUniswapV3Factory deployed at", address(mockV3Factory));

        console.log("Deploying MockNonfungiblePositionMgr");
        mockNFTManager = new MockNonfungiblePositionManager();
        console.log("MockNonfungiblePositionMgr deployed at", address(mockNFTManager));

        console.log("Deploying MockStandardBridge");
        mockBridge = new MockStandardBridge();
        console.log("MockStandardBridge deployed at", address(mockBridge));

        console.log("Deploying TokenA");
        tokenA = new MockERC20("Token A", "TKA");
        console.log("TokenA deployed at", address(tokenA));

        console.log("Deploying TokenB");
        tokenB = new MockERC20("Token B", "TKB");
        console.log("TokenB deployed at", address(tokenB));

        console.log("Deploying LiquidityMigration");
        liquidityMigration = new LiquidityMigration(
            LAYER_ZERO_ENDPOINT,
            DELEGATE,
            address(mockV2Factory),
            address(mockV2Router),
            address(mockV3Factory),
            address(mockNFTManager),
            address(mockBridge),
            L2_LIQUIDITY_MANAGER
        );
        console.log("LiquidityMigration deployed at", address(liquidityMigration));

        console.log("setUp completed successfully");
    }

    function testSetup() public {
        console.log("Running testSetup");
        assertTrue(address(liquidityMigration) != address(0), "LiquidityMigration not deployed");
        assertEq(address(liquidityMigration.uniswapV2Factory()), address(mockV2Factory), "Incorrect V2 Factory");
        assertEq(address(liquidityMigration.uniswapV2Router()), address(mockV2Router), "Incorrect V2 Router");
        assertEq(address(liquidityMigration.uniswapV3Factory()), address(mockV3Factory), "Incorrect V3 Factory");
        assertEq(
            address(liquidityMigration.nonfungiblePositionManager()), address(mockNFTManager), "Incorrect NFT Manager"
        );
        assertEq(address(liquidityMigration.l1StandardBridge()), address(mockBridge), "Incorrect Standard Bridge");
        console.log("testSetup completed successfully");
    }

    // Unit Tests

    function testConstructor() public {
        assertEq(address(liquidityMigration.uniswapV2Factory()), address(mockV2Factory));
        assertEq(address(liquidityMigration.uniswapV2Router()), address(mockV2Router));
        assertEq(address(liquidityMigration.uniswapV3Factory()), address(mockV3Factory));
        assertEq(address(liquidityMigration.nonfungiblePositionManager()), address(mockNFTManager));
        assertEq(address(liquidityMigration.l1StandardBridge()), address(mockBridge));
    }

    function testIsV3Pool() public {
        assertTrue(liquidityMigration.isV3Pool(address(tokenA), address(tokenB)));
        assertFalse(liquidityMigration.isV3Pool(address(tokenA), address(0x2)));
    }

    // Fuzz Tests

    function testFuzz_MigrateERC20Liquidity(
        uint32 dstEid,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        uint32 minGasLimit,
        bool isV3,
        bool stakeLPtokens
    ) public {
        vm.assume(liquidity > 0 && liquidity < type(uint128).max);
        vm.assume(amountAMin < liquidity && amountBMin < liquidity);
        vm.assume(deadline > block.timestamp);

        if (!isV3) {
            mockV2Factory.setPair(address(tokenA), address(tokenB), address(0x1));
        }

        mockV2Router.setRemoveLiquidityReturn(liquidity / 2, liquidity / 2);
        mockNFTManager.setDecreaseLiquidityReturn(liquidity / 2, liquidity / 2);

        vm.prank(DELEGATE);
        liquidityMigration.migrateERC20Liquidity(
            dstEid,
            address(tokenA),
            address(tokenB),
            address(tokenA),
            address(tokenB),
            liquidity,
            amountAMin,
            amountBMin,
            deadline,
            minGasLimit,
            "",
            isV3 ? LiquidityMigration.PoolType.CONCENTRATED : LiquidityMigration.PoolType.VOLATILE,
            stakeLPtokens
        );

        // Add assertions here based on expected behavior
    }

    // Invariant Tests

    function invariant_TokenBalancesNeverNegative() public {
        assertGe(tokenA.balanceOf(address(liquidityMigration)), 0);
        assertGe(tokenB.balanceOf(address(liquidityMigration)), 0);
    }

    function invariant_OnlyOwnerCanSetConfig() public {
        vm.prank(address(0xdead));
        vm.expectRevert("Ownable: caller is not the owner");
        liquidityMigration._setConfig(1, 1, 1, 1);
    }
}

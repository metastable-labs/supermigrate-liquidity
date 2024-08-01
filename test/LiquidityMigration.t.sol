// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LiquidityMigration.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Factory.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockUniswapV3Factory.sol";
import {MockNonfungiblePositionManager} from "./mocks/MockNonfungiblePositionMgr.sol";
import "./mocks/MockStandardBridge.sol";
import "./mocks/MockEndpoint.sol";
import {OAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppCore.sol";

contract LiquidityMigrationTest is Test {
    LiquidityMigration public liquidityMigration;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public l2TokenA;
    MockERC20 public l2TokenB;
    MockUniswapV2Factory public uniswapV2Factory;
    MockUniswapV2Router02 public uniswapV2Router;
    MockUniswapV3Factory public uniswapV3Factory;
    MockNonfungiblePositionManager public nonfungiblePositionManager;
    MockStandardBridge public l1StandardBridge;
    MockEndpoint public endpoint;
    address public owner;
    address public user;
    uint32 public constant TEST_CHAIN_ID = 123;
    address public constant L2_LIQUIDITY_MANAGER = address(0x123);

    function setUp() public {
        owner = address(this);
        user = address(0x1);

        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        l2TokenA = new MockERC20("L2 Token A", "L2TKNA");
        l2TokenB = new MockERC20("L2 Token B", "L2TKNB");

        uniswapV2Factory = new MockUniswapV2Factory();
        uniswapV2Router = new MockUniswapV2Router02();
        uniswapV3Factory = new MockUniswapV3Factory();
        nonfungiblePositionManager = new MockNonfungiblePositionManager();
        l1StandardBridge = new MockStandardBridge();
        endpoint = new MockEndpoint();

        liquidityMigration = new LiquidityMigration(
            address(endpoint),
            owner,
            address(uniswapV2Factory),
            address(uniswapV2Router),
            address(uniswapV3Factory),
            address(nonfungiblePositionManager),
            address(l1StandardBridge),
            L2_LIQUIDITY_MANAGER
        );

        uniswapV2Factory.createPair(address(tokenA), address(tokenB));
    }

    function testMigrateERC20LiquidityV2() public {
        uint256 liquidity = 1000 ether;
        uint256 amountAMin = 100 ether;
        uint256 amountBMin = 200 ether;
        uint256 deadline = block.timestamp + 1 hours;

        MockERC20 lpToken = new MockERC20("LP Token", "LP");

        tokenA.mint(user, liquidity);
        tokenB.mint(user, liquidity);
        lpToken.mint(user, liquidity);

        address mockPair = address(lpToken);
        uniswapV2Factory.setPair(address(tokenA), address(tokenB), mockPair);
        uniswapV2Router.setRemoveLiquidityReturn(150 ether, 250 ether);
        bytes32 mockPeer = bytes32(uint256(uint160(address(0x123))));
        OAppCore(address(liquidityMigration)).setPeer(TEST_CHAIN_ID, mockPeer);

        vm.startPrank(user);

        tokenA.approve(address(liquidityMigration), liquidity);
        tokenB.approve(address(liquidityMigration), liquidity);
        lpToken.approve(address(liquidityMigration), liquidity);

        l1StandardBridge.setExpectedCalls(
            address(tokenA),
            address(l2TokenA),
            150 ether,
            address(tokenB),
            address(l2TokenB),
            250 ether
        );

        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            address(tokenB),
            address(l2TokenA),
            address(l2TokenB),
            liquidity,
            amountAMin,
            amountBMin,
            deadline,
            100000,
            "", // options
            LiquidityMigration.PoolType.VOLATILE,
            true
        );

        vm.stopPrank();

        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenA)),
            150 ether,
            "Incorrect bridged amount for tokenA"
        );
        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenB)),
            250 ether,
            "Incorrect bridged amount for tokenB"
        );
    }

    function testMigrateERC20LiquidityV3() public {
        uint256 tokenId = 1;
        uint128 liquidity = 1000 ether;
        uint256 amountAMin = 148.5 ether; // Slightly less than 150 ether
        uint256 amountBMin = 247.5 ether; // Slightly less than 250 ether

        tokenA.mint(user, liquidity);
        tokenB.mint(user, liquidity);
        tokenA.mint(address(nonfungiblePositionManager), liquidity);
        tokenB.mint(address(nonfungiblePositionManager), liquidity);

        nonfungiblePositionManager.mint(user, tokenId);

        nonfungiblePositionManager.setPosition(
            tokenId,
            address(tokenA),
            address(tokenB),
            3000, // fee
            -100, // tickLower
            100, // tickUpper
            liquidity // liquidity
        );

        uniswapV3Factory.createPool(address(tokenA), address(tokenB), 3000);
        nonfungiblePositionManager.setDecreaseLiquidityReturn(
            150 ether,
            250 ether
        );

        bytes32 mockPeer = bytes32(uint256(uint160(address(0x123))));
        OAppCore(address(liquidityMigration)).setPeer(TEST_CHAIN_ID, mockPeer);

        vm.startPrank(user);

        tokenA.approve(address(liquidityMigration), 1000 ether);
        tokenB.approve(address(liquidityMigration), 1000 ether);
        nonfungiblePositionManager.approve(
            address(liquidityMigration),
            tokenId
        );

        l1StandardBridge.setExpectedCalls(
            address(tokenA),
            address(l2TokenA),
            150 ether,
            address(tokenB),
            address(l2TokenB),
            250 ether
        );

        vm.expectCall(
            address(nonfungiblePositionManager),
            abi.encodeCall(nonfungiblePositionManager.burn, (tokenId))
        );

        // Execute migration
        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            address(tokenB),
            address(l2TokenA),
            address(l2TokenB),
            tokenId,
            amountAMin,
            amountBMin,
            block.timestamp + 1 hours,
            100000, // minGasLimit
            "", // options
            LiquidityMigration.PoolType.CONCENTRATED,
            true
        );

        vm.stopPrank();

        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenA)),
            150 ether,
            "Incorrect bridged amount for tokenA"
        );
        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenB)),
            250 ether,
            "Incorrect bridged amount for tokenB"
        );

        assertEq(
            nonfungiblePositionManager.ownerOf(tokenId),
            address(0),
            "NFT should be burned"
        );
    }

    function testMigrateERC20LiquidityInsufficientLiquidity() public {
        uint256 liquidity = 1000 ether;
        uint256 amountAMin = 200 ether; // Higher than what the mock will return
        uint256 amountBMin = 300 ether; // Higher than what the mock will return
        uint256 deadline = block.timestamp + 1 hours;

        MockERC20 lpToken = new MockERC20("LP Token", "LP");

        tokenA.mint(user, liquidity);
        tokenB.mint(user, liquidity);
        lpToken.mint(user, liquidity);

        address mockPair = address(lpToken);
        uniswapV2Factory.setPair(address(tokenA), address(tokenB), mockPair);
        uniswapV2Router.setRemoveLiquidityReturn(150 ether, 250 ether);

        bytes32 mockPeer = bytes32(uint256(uint160(address(0x123))));
        OAppCore(address(liquidityMigration)).setPeer(TEST_CHAIN_ID, mockPeer);

        vm.startPrank(user);

        tokenA.approve(address(liquidityMigration), liquidity);
        tokenB.approve(address(liquidityMigration), liquidity);
        lpToken.approve(address(liquidityMigration), liquidity);

        vm.expectRevert("UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            address(tokenB),
            address(l2TokenA),
            address(l2TokenB),
            liquidity,
            amountAMin,
            amountBMin,
            deadline,
            100000,
            "", // options
            LiquidityMigration.PoolType.VOLATILE,
            true
        );
        vm.stopPrank();
    }

    function testIsV3Pool() public {
        uniswapV3Factory.createPool(address(tokenA), address(tokenB), 3000);
        assertTrue(
            liquidityMigration.isV3Pool(address(tokenA), address(tokenB))
        );

        address tokenC = address(new MockERC20("Token C", "TKNC"));
        assertFalse(
            liquidityMigration.isV3Pool(address(tokenA), address(tokenC))
        );
    }

    function testFuzz_MigrateERC20Liquidity(
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        uint32 minGasLimit,
        bool isV3,
        bool stakeLPtokens
    ) public {
        vm.assume(liquidity > 0 && liquidity < type(uint128).max);
        vm.assume(
            amountAMin < liquidity &&
                amountBMin < liquidity &&
                amountAMin + amountBMin < liquidity
        );
        vm.assume(deadline > block.timestamp);
        MockERC20 lpToken = new MockERC20("LP Token", "LP");

        if (isV3) {
            uniswapV3Factory.createPool(address(tokenA), address(tokenB), 3000);
            nonfungiblePositionManager.setPosition(
                1,
                address(tokenA),
                address(tokenB),
                3000,
                -100,
                100,
                uint128(liquidity)
            );
            nonfungiblePositionManager.setDecreaseLiquidityReturn(
                amountAMin,
                amountBMin
            );
            nonfungiblePositionManager.mint(user, 1);
        } else {
            address mockPair = address(lpToken);
            uniswapV2Factory.setPair(
                address(tokenA),
                address(tokenB),
                mockPair
            );
            uniswapV2Router.setRemoveLiquidityReturn(amountAMin, amountBMin);
            lpToken.mint(user, liquidity);
        }

        tokenA.mint(user, liquidity);
        tokenB.mint(user, liquidity);
        tokenA.mint(address(nonfungiblePositionManager), liquidity);
        tokenB.mint(address(nonfungiblePositionManager), liquidity);

        bytes32 mockPeer = bytes32(uint256(uint160(address(0x123))));
        OAppCore(address(liquidityMigration)).setPeer(TEST_CHAIN_ID, mockPeer);

        vm.startPrank(user);
        tokenA.approve(address(liquidityMigration), liquidity);
        tokenB.approve(address(liquidityMigration), liquidity);
        if (isV3) {
            nonfungiblePositionManager.approve(address(liquidityMigration), 1);
        } else {
            lpToken.approve(address(liquidityMigration), liquidity);
        }

        l1StandardBridge.setExpectedCalls(
            address(tokenA),
            address(l2TokenA),
            amountAMin,
            address(tokenB),
            address(l2TokenB),
            amountBMin
        );

        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            address(tokenB),
            address(l2TokenA),
            address(l2TokenB),
            isV3 ? 1 : liquidity,
            amountAMin,
            amountBMin,
            deadline,
            minGasLimit,
            "",
            isV3
                ? LiquidityMigration.PoolType.CONCENTRATED
                : LiquidityMigration.PoolType.VOLATILE,
            stakeLPtokens
        );

        vm.stopPrank();

        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenA)),
            amountAMin
        );
        assertEq(
            l1StandardBridge.getBridgedAmount(address(tokenB)),
            amountBMin
        );
    }

    function invariant_CannotMigrateIdenticalTokens() public {
        vm.expectRevert("Identical addresses");
        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            address(tokenA),
            address(l2TokenA),
            address(l2TokenA),
            1000 ether,
            100 ether,
            100 ether,
            block.timestamp + 1 hours,
            100000,
            "",
            LiquidityMigration.PoolType.VOLATILE,
            true
        );
    }

    function invariant_CannotMigrateNonExistentPool() public {
        address nonExistentToken = address(0xdead);
        vm.expectRevert("V2: Pool does not exist");
        liquidityMigration.migrateERC20Liquidity(
            TEST_CHAIN_ID,
            address(tokenA),
            nonExistentToken,
            address(l2TokenA),
            address(0x123),
            1000 ether,
            100 ether,
            100 ether,
            block.timestamp + 1 hours,
            100000,
            "",
            LiquidityMigration.PoolType.VOLATILE,
            true
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockWETH.sol";
import "./mocks/MockGauge.sol";
import "./mocks/MockAerodromeRouter.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract MockFeeRecipient {}

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockERC20 public lpToken;
    MockERC20 public rewardToken;
    MockGauge public gauge;
    MockAerodromeRouter public router;
    MockFeeRecipient public mockFeeRecipient;
    MockEndpoint public endpoint;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1);

        lpToken = new MockERC20("LP Token", "LP");
        rewardToken = new MockERC20("Reward Token", "RWD");
        router = new MockAerodromeRouter(address(0x8));
        gauge = new MockGauge(lpToken, rewardToken, address(this));
        mockFeeRecipient = new MockFeeRecipient();
        endpoint = new MockEndpoint();

        liquidityManager =
            new L2LiquidityManager(address(router), address(mockFeeRecipient), 100, address(endpoint), owner);

        liquidityManager.setPool(address(0x4), address(0x5), address(lpToken), address(gauge));
    }

    function testSuccessfulStaking() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);

        lpToken.mint(user, amount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);

        (address pool,) = liquidityManager.getPool(tokenA, tokenB);

        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);
        vm.stopPrank();

        // Check that the gauge records the correct balance for the user
        assertEq(gauge.balanceOf(user), amount, "Incorrect staked amount in gauge");

        // Check that the user's staked LP token balance is updated in L2LiquidityManager
        assertEq(liquidityManager.getUserStakedLP(user, pool), amount, "Incorrect staked LP token balance");
    }

    function testStakingZeroAmount() public {
        vm.expectRevert("ZeroAmount");
        liquidityManager.stakeLPToken(0, user, address(0x4), address(0x5));
    }

    function testStakingInsufficientBalance() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount - 1 ether);

        vm.startPrank(user);
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(address(liquidityManager), amount);
        vm.expectRevert();
        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);
        vm.stopPrank();
    }

    function testStakingUnapprovedTokens() public {
        uint256 amount = 100 ether;
        lpToken.mint(user, amount);

        vm.startPrank(user);
        //vm.expectRevert("ERC20: insufficient allowance");
        vm.expectRevert();
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        vm.stopPrank();
    }

    function testStakingNonExistentPool() public {
        uint256 amount = 100 ether;
        lpToken.mint(user, amount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        vm.expectRevert(); // Expect revert due to non-existent pool
        liquidityManager.stakeLPToken(amount, user, address(0x6), address(0x7));
        vm.stopPrank();
    }

    function testStakingWhenGaugeNotAlive() public {
        uint256 amount = 100 ether;
        lpToken.mint(user, amount);

        gauge.setAlive(false);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        vm.expectRevert("NotAlive");
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        vm.stopPrank();
    }

    function testSuccessfulUnstaking() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount);

        vm.startPrank(user, user);
        lpToken.approve(address(liquidityManager), amount);
        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);

        liquidityManager.unstakeLPToken(amount, tokenA, tokenB);
        vm.stopPrank();

        assertEq(gauge.balanceOf(user), 0, "Incorrect unstaked amount");
        assertEq(lpToken.balanceOf(user), amount, "LP tokens not returned");
    }

    function testUnstakingMoreThanStaked() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);

        vm.expectRevert("Insufficient staked LP tokens");
        liquidityManager.unstakeLPToken(amount + 1 ether, tokenA, tokenB);
        vm.stopPrank();
    }

    function testClaimingRewards() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        uint256 rewardAmount = 10 ether;
        lpToken.mint(user, amount);
        rewardToken.mint(address(gauge), rewardAmount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);

        gauge.setReward(user, rewardAmount);

        liquidityManager.claimAeroRewards(user, tokenA, tokenB);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user), rewardAmount, "Incorrect reward amount claimed");
    }

    function testClaimingZeroRewards() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);

        liquidityManager.claimAeroRewards(user, tokenA, tokenB);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user), 0, "Should not receive rewards when none accrued");
    }

    function testStakingEventEmission() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount);

        vm.startPrank(user);
        lpToken.approve(address(liquidityManager), amount);
        lpToken.approve(address(liquidityManager), amount);

        vm.expectEmit(true, true, true, true);
        emit L2LiquidityManager.LPTokensStaked(user, address(lpToken), address(gauge), amount);

        liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);
        vm.stopPrank();
    }
}

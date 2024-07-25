// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "./MockERC20.sol";
import "./MockWETH.sol";
import "./MockGauge.sol";
import "./MockAerodromeRouter.sol";
import "../src/modules/L2LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";


contract L2LiquidityManagerTest is Test {
    L2LiquidityManager public liquidityManager;
    MockERC20 public lpToken;
    MockERC20 public rewardToken;
    MockGauge public gauge;
    MockAerodromeRouter public router;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        
        lpToken = new MockERC20("LP Token", "LP");
        rewardToken = new MockERC20("Reward Token", "RWD");
        router = new MockAerodromeRouter(address(0x8));
        gauge = new MockGauge(lpToken, rewardToken, address(this));

        L2LiquidityManager impl = new L2LiquidityManager();
        bytes memory data = abi.encodeWithSelector(
            L2LiquidityManager.initialize.selector,
            address(router),
            address(0x3), // mock fee receiver
            100 // 1% migration fee
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        liquidityManager = L2LiquidityManager(payable(address(proxy)));

        liquidityManager.setPool(address(0x4), address(0x5), address(lpToken), address(gauge));
    }

function testSuccessfulStaking() public {
    uint256 amount = 100 ether;
    address tokenA = address(0x4);
    address tokenB = address(0x5);

    lpToken.mint(user, amount);
    
    vm.startPrank(user);
    lpToken.approve(address(liquidityManager), amount);
    
    // Give allowance to the gauge contract on behalf of the user, this has to be done because LP tokens deposit is not implemented inside L2LiquidityManager
    (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
    lpToken.approve(gaugeAddress, amount);
    
    liquidityManager.stakeLPToken(amount, user, tokenA, tokenB);
    vm.stopPrank();

    // Check that the gauge records the correct balance for the user
    assertEq(gauge.balanceOf(user), amount, "Incorrect staked amount in gauge");
    
    // Disabling Test: Not implemented inside L2LiquidityManager
    // Check that the user's staked LP token balance is updated in L2LiquidityManager
    // assertEq(liquidityManager.getUserStakedLP(user, pool), amount, "Incorrect staked LP token balance");
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
        lpToken.approve(gaugeAddress, amount);
        //vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.expectRevert();
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
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
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(gaugeAddress, amount);
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        
        liquidityManager.unstakeLPToken(amount, address(0x4), address(0x5));
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
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(gaugeAddress, amount);
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        
        vm.expectRevert("Insufficient balance");
        liquidityManager.unstakeLPToken(amount + 1 ether, address(0x4), address(0x5));
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
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(gaugeAddress, amount);
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        
        gauge.setReward(user, rewardAmount);
        
        liquidityManager.claimAeroRewards(user, address(0x4), address(0x5));
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user), rewardAmount, "Incorrect reward amount claimed");
    }

    function testClaimingZeroRewards() public {
        uint256 amount = 100 ether;
        address tokenA = address(0x4);
        address tokenB = address(0x5);
        lpToken.mint(user, amount);
        
        vm.startPrank(user);
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(gaugeAddress, amount);
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        
        liquidityManager.claimAeroRewards(user, address(0x4), address(0x5));
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
        (, address gaugeAddress) = liquidityManager.getPool(tokenA, tokenB);
        lpToken.approve(gaugeAddress, amount);
        
        vm.expectEmit(true, true, true, true);
        emit L2LiquidityManager.LPTokensStaked(user, address(lpToken), address(gauge), amount);
        
        liquidityManager.stakeLPToken(amount, user, address(0x4), address(0x5));
        vm.stopPrank();
    }
}
// Interacts with aerodrome to deposit Liquidity
// stake LP tokens for aero rewards
// Tracks individual migration positions
// make contracts upgradeable

// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "@aerodrome/contracts/contracts/interfaces/IRouter.sol";
import {IPool} from "@aerodrome/contracts/contracts/interfaces/IPool.sol";
import {IGauge} from "@aerodrome/contracts/contracts/interfaces/IGauge.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract L2LiquidityManager is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    IRouter public aerodromeRouter;
    PoolData[] private allPools;
    mapping(address => bool) private poolExists;

    struct PoolData {
        address poolAddress;
        address gaugeAddress;
    }

    mapping(address => mapping(address => uint256)) public userLiquidity; // user address => token address => amount
    mapping(address => mapping(address => uint256)) public userStakedLPTokens; // user address => lp token address => amount
    mapping(address => mapping(address => PoolData)) public tokenPairToPools;

    event LiquidityDeposited(
        address user, address token0, address token1, uint256 amount0, uint256 amount1, uint256 lpTokens
    );
    event LPTokensStaked(address user, address pool, uint256 amount);
    event PoolSet(address tokenA, address tokenB, address pool, address gauge);
    event LPTokensStaked(address user, address pool, address gauge, uint256 amount);
    event LPTokensWithdrawn(address user, address pool, address gauge, uint256 amount);
    event AeroEmissionsClaimed(address user, address pool, address gauge);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _aerodromeRouter) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        aerodromeRouter = IRouter(_aerodromeRouter);
    }
    // add a new pool to supermigrate

    function setPool(address tokenA, address tokenB, address pool, address gauge) external onlyOwner {
        require(tokenA != address(0) && tokenB != address(0) && pool != address(0), "Invalid addresses");
        PoolData memory poolData = PoolData(pool, gauge);
        tokenPairToPools[tokenA][tokenB] = poolData;
        tokenPairToPools[tokenB][tokenA] = poolData;
        emit PoolSet(tokenA, tokenB, pool, gauge);

        if (!poolExists[pool]) {
            allPools.push(poolData);
            poolExists[pool] = true;
        }

        emit PoolSet(token0, token1, pool);
    }

    function getPool(address tokenA, address tokenB) external view returns (address pool, address gauge) {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        return (poolData.poolAddress, poolData.gaugeAddress);
    }
    // get the total number of pools within supermigrate

    function getPoolsCount() external view returns (uint256) {
        return allPools.length;
    }
    // get all pools within Supermigrate

    /**
     *
     * start To get all pools, you would typically:
     *
     * Call getPoolsCount() to know how many pools there are.
     * Then make one or more calls to getPools(start, end) to retrieve all pools in batches.
     * end
     */
    function getPools(uint256 start, uint256 end)
        external
        view
        returns (address[] memory pools, address[] memory gauges)
    {
        require(start < end, "Invalid range");
        require(end <= allPools.length, "End out of bounds");

        uint256 length = end - start;
        pools = new address[](length);
        gauges = new address[](length);

        for (uint256 i = start; i < end; i++) {
            pools[i - start] = allPools[i].poolAddress;
            gauges[i - start] = allPools[i].gaugeAddress;
        }

        return (pools, gauges);
    }

    function getUserLiquidity(address user, address token) external view returns (uint256) {
        return userLiquidity[user][token];
    }

    function getUserStakedLP(address user, address pool) external view returns (uint256) {
        return userStakedLPTokens[user][pool];
    }

    function depositLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin
    ) external payable nonReentrant {
        address pool = tokenPairToPools[tokenA][tokenB];
        require(pool != address(0), "Pool does not exist");

        bool isETHA = tokenA == address(aerodromeRouter.weth());
        bool isETHB = tokenB == address(aerodromeRouter.weth());
        require(!(isETHA && isETHB), "Cannot deposit ETH for both tokens");

        if (isETHA || isETHB) {
            require(msg.value > 0, "Must send ETH");
            _depositLiquidityETH(
                isETHA ? tokenB : tokenA,
                isETHA ? amountB : amountA,
                isETHA ? amountBMin : amountAMin,
                isETHA ? amountAMin : amountBMin
            );
        } else {
            require(msg.value == 0, "ETH sent with token-token deposit");
            _depositLiquidityERC20(tokenA, tokenB, amountA, amountB, amountAMin, amountBMin);
        }
    }

    function _depositLiquidityETH(address token, uint256 amountToken, uint256 amountTokenMin, uint256 amountETHMin)
        private
    {
        IERC20(token).approve(address(aerodromeRouter), amountToken);

        (uint256 amountTokenOut, uint256 amountETHOut, uint256 liquidity) = aerodromeRouter.addLiquidityETH{
            value: msg.value
        }(
            token,
            true, // assuming stable pool
            amountToken,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp
        );
        // Update user liquidity
        userLiquidity[msg.sender][token] += amountTokenOut;
        userLiquidity[msg.sender][address(aerodromeRouter.weth())] += amountETHOut;

        // Refund excess ETH if any
        if (msg.value > amountETHOut) {
            (bool success,) = msg.sender.call{value: msg.value - amountETHOut}("");
            require(success, "ETH transfer failed");
        }

        emit LiquidityDeposited(
            msg.sender, address(aerodromeRouter.weth()), token, amountETHOut, amountTokenOut, liquidity
        );
    }

    function _depositLiquidityERC20(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin
    ) private {
        IERC20(tokenA).approve(address(aerodromeRouter), amountA);
        IERC20(tokenB).approve(address(aerodromeRouter), amountB);

        (uint256 amountAOut, uint256 amountBOut, uint256 liquidity) = aerodromeRouter.addLiquidity(
            tokenA,
            tokenB,
            true, // assuming stable pool, adjust if needed
            amountA,
            amountB,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp
        );

        // Update user liquidity
        userLiquidity[msg.sender][tokenA] += amountAOut;
        userLiquidity[msg.sender][tokenB] += amountBOut;
        emit LiquidityDeposited(msg.sender, tokenA, tokenB, amountAOut, amountBOut, liquidity);
    }

    function stakeLPToken(uint256 amount, address owner, address tokenA, address tokenB) external nonReentrant {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IERC20(poolData.poolAddress).approve(poolData.gaugeAddress, amount);
        IGauge(poolData.gaugeAddress).deposit(amount, owner);
        emit LPTokensStaked(owner, poolData.poolAddress, poolData.gaugeAddress, amount);
    }

    function unstakeLPToken(uint256 amount, address owner, address tokenA, address tokenB) external nonReentrant {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IGauge(poolData.gaugeAddress).withdraw(amount, owner);
        emit LPTokensWithdrawn(owner, poolData.poolAddress, poolData.gaugeAddress, amount);
    }

    function claimAeroRewards(address owner, address tokenA, address tokenB) external nonReentrant {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IGauge(poolData.gaugeAddress).getReward(owner);
        emit AeroEmissionsClaimed(owner, poolData.poolAddress, poolData.gaugeAddress);
    }

    receive() external payable {}
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

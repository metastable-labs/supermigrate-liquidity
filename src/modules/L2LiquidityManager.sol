// Interacts with aerodrome to deposit Liquidity
// check if pool exist on aerodrome, deposit, else create
// stake LP tokens for aero rewards
// Tracks individual migration positions
// make contracts upgradeable

// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "@aerodrome/contracts/contracts/interfaces/IRouter.sol";
import {IPool} from "@aerodrome/contracts/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract L2LiquidityManager is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IRouter public aerodromeRouter;
    address[] private allPools;
    mapping(address => bool) private poolExists;

    mapping(address => mapping(address => uint256)) public userLiquidity; // user address => token address => amount
    mapping(address => mapping(address => uint256)) public userStakedLPTokens; // user address => lp token address => amount
    mapping(address => mapping(address => address)) public tokenPairToPools; // pool address => first token => second token

    event LiquidityDeployed(
        address user, address token0, address token1, uint256 amount0, uint256 amount1, uint256 lpTokens
    );
    event LPTokensStaked(address user, address pool, uint256 amount);
    event PoolSet(address token0, address token1, address pool);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _aerodromeRouter) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        aerodromeRouter = IRouter(_aerodromeRouter);
    }
    // add a new pool to supermigrate

    function setPool(address token0, address token1, address pool) external onlyOwner {
        require(token0 != address(0) && token1 != address(0) && pool != address(0), "Invalid addresses");
        tokenPairToPools[token0][token1] = pool;
        tokenPairToPools[token1][token0] = pool;

        if (!poolExists[pool]) {
            allPools.push(pool);
            poolExists[pool] = true;
        }

        emit PoolSet(token0, token1, pool);
    }

    function getPool(address token0, address token1) external view returns (address) {
        return tokenPairToPools[token0][token1];
    }
    // get the total number of pools within supermigrate

    function getPoolsCount() external view returns (uint256) {
        return allPools.length;
    }
    // get all pools within Supermigrate

    /**
     *
     * @param start To get all pools, you would typically:
     *
     * Call getPoolsCount() to know how many pools there are.
     * Then make one or more calls to getPools(start, end) to retrieve all pools in batches.
     * @param end
     */
    function getPools(uint256 start, uint256 end) external view returns (address[] memory) {
        require(start < end, "Invalid range");
        require(end <= allPools.length, "End out of bounds");

        address[] memory result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = allPools[i];
        }
        return result;
    }

    function getUserLiquidity(address user, address token) external view returns (uint256) {
        return userLiquidity[user][token];
    }

    function getUserStakedLP(address user, address pool) external view returns (uint256) {
        return userStakedLPTokens[user][pool];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

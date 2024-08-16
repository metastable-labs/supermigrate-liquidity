// Interacts with aerodrome to deposit Liquidity
// stake LP tokens for aero rewards
// Tracks individual migration positions
// make contracts upgradeable

// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRouter} from "@aerodrome/contracts/contracts/interfaces/IRouter.sol";
import {IPool} from "@aerodrome/contracts/contracts/interfaces/IPool.sol";
import {IGauge} from "@aerodrome/contracts/contracts/interfaces/IGauge.sol";
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Babylonian} from "../lib/Babylonian.sol";

/**
 * @title L2LiquidityManager
 * @dev Manages liquidity on L2, interacting with Aerodrome to deposit liquidity,
 * stake LP tokens, and handle cross-chain liquidity migrations.
 */
contract L2LiquidityManager is OApp {
    IRouter public aerodromeRouter;
    PoolData[] private allPools;
    mapping(address => bool) private poolExists;

    /// @dev 10000 = 100%, 5000 = 50%, 100 = 1%, 1 = 0.01%
    uint256 public constant FEE_DENOMINATOR = 10_000;
    /// @dev Liquidity slippage tolerance: 0.3%
    uint256 public constant LIQ_SLIPPAGE = 30;
    /// @dev 10 ** 18
    uint256 public constant WAD = 1e18;
    /// @dev 10 ** 27
    uint256 public constant RAY = 1e27;

    address public BASE_USDC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address public NORMAL_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;
    uint256 public migrationFee;
    address public feeReceiver;

    /// @dev Struct to store pool and gauge addresses
    struct PoolData {
        address poolAddress;
        address gaugeAddress;
    }

    /// @dev Mapping of user address to token address to liquidity amount
    mapping(address => mapping(address => uint256)) public userLiquidity;
    /// @dev Mapping of user address to LP token address to staked amount
    mapping(address => mapping(address => uint256)) public userStakedLPTokens;
    /// @dev Mapping of token pair to pool data
    mapping(address => mapping(address => PoolData)) public tokenPairToPools;

    event LiquidityDeposited(
        address user, address token0, address token1, uint256 amount0, uint256 amount1, uint256 lpTokens
    );
    event PoolSet(address tokenA, address tokenB, address pool, address gauge);
    event LPTokensStaked(address user, address pool, address gauge, uint256 amount);
    event LPTokensWithdrawn(address user, address pool, uint256 amount);
    event AeroEmissionsClaimed(address user, address pool, address gauge);
    event CrossChainLiquidityReceived(address user, address tokenA, address tokenB, uint256 amountA, uint256 amountB);
    event TrustedRemoteSet(uint32 indexed srcEid, bytes srcAddress);

    enum PoolType {
        NONE,
        STABLE,
        VOLATILE,
        CONCENTRATED
    }

    /**
     * @dev Constructor to initialize the L2LiquidityManager contract
     * @param _aerodromeRouter Address of the Aerodrome router
     * @param _feeReceiver Address to receive migration fees
     * @param _migrationFee Migration fee percentage
     * @param _endpoint LayerZero endpoint address
     * @param _delegate Address of the contract owner/delegate
     */
    constructor(
        address _aerodromeRouter,
        address _feeReceiver,
        uint256 _migrationFee,
        address _endpoint,
        address _delegate
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {
        migrationFee = _migrationFee;
        feeReceiver = _feeReceiver;
        aerodromeRouter = IRouter(_aerodromeRouter);
    }

    /**
     * @notice Adds a new pool to Supermigrate
     * @dev Only callable by the contract owner
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     * @param pool Address of the pool
     * @param gauge Address of the gauge for the pool
     */
    function setPool(address tokenA, address tokenB, address pool, address gauge) external onlyOwner {
        require(
            tokenA != address(0) && tokenB != address(0) && tokenA != tokenB && pool != address(0), "Invalid addresses"
        );
        PoolData memory poolData = PoolData(pool, gauge);
        tokenPairToPools[tokenA][tokenB] = poolData;
        tokenPairToPools[tokenB][tokenA] = poolData;
        emit PoolSet(tokenA, tokenB, pool, gauge);

        if (!poolExists[pool]) {
            allPools.push(poolData);
            poolExists[pool] = true;
        }

        emit PoolSet(tokenA, tokenB, pool, gauge);
    }

    /**
     * @notice Sets the migration fee
     * @dev Only callable by the contract owner
     * @param _newFee New fee percentage (based on FEE_DENOMINATOR)
     */
    function setFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= FEE_DENOMINATOR, "Fee too high");
        migrationFee = _newFee;
    }

    /**
     * @notice Retrieves pool and gauge addresses for a token pair
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @return pool Address of the pool
     * @return gauge Address of the gauge
     */
    function getPool(address tokenA, address tokenB) external view returns (address pool, address gauge) {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        return (poolData.poolAddress, poolData.gaugeAddress);
    }

    /**
     * @notice Gets the total number of pools within Supermigrate
     * @return uint256 Number of pools
     */
    function getPoolsCount() external view returns (uint256) {
        return allPools.length;
    }

    /**
     * @notice Retrieves a range of pools within Supermigrate
     * @dev Used to fetch pools in batches
     * @param start Start index of the range
     * @param end End index of the range (exclusive)
     * @return pools Array of pool addresses
     * @return gauges Array of corresponding gauge addresses
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

    /**
     * @notice Gets the liquidity amount for a user and token
     * @param user Address of the user
     * @param token Address of the token
     * @return uint256 Liquidity amount
     */
    function getUserLiquidity(address user, address token) external view returns (uint256) {
        return userLiquidity[user][token];
    }

    /**
     * @notice Gets the staked LP token amount for a user and pool
     * @param user Address of the user
     * @param pool Address of the pool
     * @return uint256 Staked LP token amount
     */
    function getUserStakedLP(address user, address pool) external view returns (uint256) {
        return userStakedLPTokens[user][pool];
    }

    /**
     * @dev Deducts the migration fee from the given amount
     * @param token Address of the token
     * @param amount Amount to deduct fee from
     * @return uint256 Amount after fee deduction
     */
    function deductFee(address token, uint256 amount) private returns (uint256) {
        uint256 precisionFactor = WAD;
        uint256 feeAmount = (amount * migrationFee * precisionFactor) / FEE_DENOMINATOR;
        feeAmount = (feeAmount + precisionFactor - 1) / precisionFactor;
        if (feeAmount > 0) {
            IERC20(token).transfer(feeReceiver, feeAmount);
        }
        return amount - feeAmount;
    }

    /**
     * @notice Deposits liquidity into Aerodrome
     * @dev Handles ERC20 token deposits
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param amountA Amount of tokenA to deposit
     * @param amountB Amount of tokenB to deposit
     * @param poolType Type of the pool (stable, volatile, or concentrated)
     * @param user User to receive LP tokens
     * @return uint256 Amount of LP tokens received
     */
    function _depositLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        PoolType poolType,
        address user
    ) internal returns (uint256) {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        // Wrap ETH to WETH if necessary
        if (tokenA == address(0)) {
            IWETH(WETH).deposit{value: amountA}();
            tokenA = WETH;
        }
        if (tokenB == address(0)) {
            IWETH(WETH).deposit{value: amountB}();
            tokenB = WETH;
        }

        uint256 liquidity = _depositLiquidityERC20(tokenA, tokenB, amountA, amountB, poolType, user);
        return liquidity;
    }

    /**
     * @notice Deposits ERC20 liquidity into Aerodrome
     * @dev Assumes that amountAMin and amountBMin are calculated after deducting the migration fees in the front end
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param amountA Amount of tokenA to deposit
     * @param amountB Amount of tokenB to deposit
     * @param poolType Type of the pool (stable, volatile, or concentrated)
     * @param user User address to receive LP tokens
     * @return uint256 Amount of LP tokens received
     */
    function _depositLiquidityERC20(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        PoolType poolType,
        address user
    ) private returns (uint256) {
        bool stable = (poolType == PoolType.STABLE);

        // Check and swap Base USDC if necessary
        if (tokenA == BASE_USDC) {
            amountA = _swapBaseUSDCToNormalUSDC(amountA);
            tokenA = NORMAL_USDC;
        }
        if (tokenB == BASE_USDC) {
            amountB = _swapBaseUSDCToNormalUSDC(amountB);
            tokenB = NORMAL_USDC;
        }

        amountA = deductFee(tokenA, amountA);
        amountB = deductFee(tokenB, amountB);

        // Only balance token ratio for non-stable pairs
        if (!stable) {
            (uint256[] memory amounts, bool sellTokenA) = _balanceTokenRatio(tokenA, tokenB, amountA, amountB);

            // Update token amounts after swaps
            if (sellTokenA) {
                amountA -= amounts[0];
                amountB += amounts[1];
            } else {
                amountB -= amounts[0];
                amountA += amounts[1];
            }
        }

        IERC20(tokenA).approve(address(aerodromeRouter), amountA);
        IERC20(tokenB).approve(address(aerodromeRouter), amountB);

        // calculate minimum amount with 0.1% slippage
        uint256 amountAMin = mulDiv(amountA, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);
        uint256 amountBMin = mulDiv(amountB, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);

        (uint256 amountAOut, uint256 amountBOut, uint256 liquidity) = aerodromeRouter.addLiquidity(
            tokenA, tokenB, stable, amountA, amountB, amountAMin, amountBMin, address(this), block.timestamp
        );

        uint256 leftoverA = amountA - amountAOut;
        uint256 leftoverB = amountB - amountBOut;

        if (leftoverA > 0) {
            if (tokenA == WETH) {
                IWETH(WETH).withdraw(leftoverA);
                (bool success,) = user.call{value: leftoverA}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(tokenA).transfer(user, leftoverA);
            }
        }
        if (leftoverB > 0) {
            if (tokenB == WETH) {
                IWETH(WETH).withdraw(leftoverB);
                (bool success,) = user.call{value: leftoverB}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(tokenB).transfer(user, leftoverB);
            }
        }

        // Update user liquidity
        userLiquidity[user][tokenA] += amountAOut;
        userLiquidity[user][tokenB] += amountBOut;

        emit LiquidityDeposited(user, tokenA, tokenB, amountAOut, amountBOut, liquidity);

        return liquidity;
    }

    function _balanceTokenRatio(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        internal
        returns (uint256[] memory, bool)
    {
        bool stable = false;

        uint256 aDecMultiplier = 10 ** (18 - IERC20Metadata(tokenA).decimals());
        uint256 bDecMultiplier = 10 ** (18 - IERC20Metadata(tokenB).decimals());

        uint256 tokensToSell;
        uint256 amountOutMin;

        (uint256 reserveA, uint256 reserveB) =
            aerodromeRouter.getReserves(tokenA, tokenB, stable, aerodromeRouter.defaultFactory());

        uint256 x = (reserveA);
        uint256 y = (reserveB);
        uint256 a = (amountA);
        uint256 b = (amountB);

        bool sellTokenA;

        if (amountA == 0) {
            sellTokenA = false;
        } else if (amountB == 0) {
            sellTokenA = true;
        } else {
            sellTokenA = mulDiv(a, RAY, b) > mulDiv(x, RAY, y); // our ratio of A:B is greater than the pool ratio
        }

        if (!sellTokenA) {
            // Sell token B
            tokensToSell = _calculateAmountIn(y, x, b, a, bDecMultiplier, aDecMultiplier) / bDecMultiplier;

            uint256 amtToReceive = _calculateAmountOut(tokensToSell, y, x);

            amountOutMin = (amtToReceive * 9999) / 10_000; // allow for 1bip of error
        } else {
            // Sell token A
            tokensToSell = _calculateAmountIn(x, y, a, b, aDecMultiplier, bDecMultiplier);
            sellTokenA = true;

            uint256 amtToReceive = _calculateAmountOut(tokensToSell, x, y);

            amountOutMin = (amtToReceive * 9999) / 10_000; // allow for 1bip of error
        }

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(
            sellTokenA ? tokenA : tokenB, sellTokenA ? tokenB : tokenA, stable, aerodromeRouter.defaultFactory()
        );

        IERC20(sellTokenA ? tokenA : tokenB).approve(address(aerodromeRouter), tokensToSell);

        uint256[] memory amounts =
            aerodromeRouter.swapExactTokensForTokens(tokensToSell, amountOutMin, routes, address(this), block.timestamp);
        return (amounts, sellTokenA);
    }

    /**
     * @notice Calculates the exact amount of tokens to swap to achieve the pool ratio
     * @param x Pool reserves of the token to sell
     * @param y Pool reserves of the token to buy
     * @param a User's amount of the token to sell (currently in excess)
     * @param b User's amount of the token to buy
     * @param aDec 10 ** (18 - tokenA.decimals())
     * @param bDec 10 ** (18 - tokenB.decimals())
     */
    function _calculateAmountIn(uint256 x, uint256 y, uint256 a, uint256 b, uint256 aDec, uint256 bDec)
        internal
        pure
        returns (uint256)
    {
        // Normalize to 18 decimals
        x = x * aDec;
        a = a * aDec;

        y = y * bDec;
        b = b * bDec;

        // Perform calculations
        uint256 xy = (y * x) / WAD;
        uint256 bx = (b * x) / WAD;
        uint256 ay = (y * a) / WAD;

        // Compute the square root term
        uint256 innerTerm = (xy + bx) * (3_988_009 * xy + 9 * bx + 3_988_000 * ay);
        uint256 sqrtTerm = Babylonian.sqrt(innerTerm);

        // Compute the numerator
        uint256 numerator = sqrtTerm - 1997 * (xy + bx);

        // Compute the denominator
        uint256 denominator = 1994 * (y + b);

        // Calculate the final value of amountIn
        uint256 amountIn = (numerator * WAD) / denominator;

        return amountIn;
    }

    function _calculateAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        return (reserveOut * 997 * amountIn) / (1000 * reserveIn + 997 * amountIn);
    }

    /**
     * @dev Swaps Base USDC to normal USDC
     * @param amount Amount of Base USDC to swap
     * @return uint256 Amount of normal USDC received
     */
    function _swapBaseUSDCToNormalUSDC(uint256 amount) internal returns (uint256) {
        IERC20(BASE_USDC).approve(address(aerodromeRouter), amount);

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(BASE_USDC, NORMAL_USDC, true, aerodromeRouter.defaultFactory());

        uint256 amountMin = mulDiv(amount, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);

        uint256[] memory amounts =
            aerodromeRouter.swapExactTokensForTokens(amount, amountMin, routes, address(this), block.timestamp);

        return amounts[amounts.length - 1];
    }

    /**
     * @notice Receives and processes cross-chain messages
     * @dev This function is called by the LayerZero endpoint when a message is received
     * @param _origin Information about the source of the message
     * @param _guid Unique identifier for the message
     * @param _message The payload of the message
     * @param _executor Address of the executor (unused in this implementation)
     * @param _extraData Any extra data attached to the message (unused in this implementation)
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        (address tokenA, address tokenB, uint256 amountA, uint256 amountB, address user, PoolType poolType) =
            abi.decode(_message, (address, address, uint256, uint256, address, PoolType, bool));

        emit CrossChainLiquidityReceived(user, tokenA, tokenB, amountA, amountB);

        uint256 liquidity = _depositLiquidity(tokenA, tokenB, amountA, amountB, poolType, user);
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IERC20(poolData.poolAddress).transfer(user, liquidity);
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev This function is called when ETH is sent to the contract address
     */
    receive() external payable {}

    /**
     * @notice Performs a multiplication followed by a division
     * @dev This function uses assembly for gas optimization and to prevent overflow
     * @param x First multiplicand
     * @param y Second multiplicand
     * @param denominator The divisor
     * @return result The result of (x * y) / denominator
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        require(denominator > prod1);

        uint256 remainder;
        assembly {
            remainder := mulmod(x, y, denominator)
        }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
        }

        assembly {
            prod0 := div(prod0, twos)
        }
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;

        result = prod0 * inv;
        return result;
    }
}

interface IWETH {
    function deposit() external;
    function withdraw(uint256 amount) external;
}

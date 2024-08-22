// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRouter} from "@aerodrome/contracts/contracts/interfaces/IRouter.sol";
import {IPool} from "@aerodrome/contracts/contracts/interfaces/IPool.sol";
import {IGauge} from "@aerodrome/contracts/contracts/interfaces/IGauge.sol";
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Babylonian} from "../lib/Babylonian.sol";

import {INonfungiblePositionManager} from "../interfaces/slipstream/INonfungiblePositionManager.sol";
import {ICLPool} from "../interfaces/slipstream/ICLPool.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

import {console} from "forge-std/console.sol";
/**
 * @title L2LiquidityManager
 * @dev Manages liquidity on L2, interacting with Aerodrome to deposit liquidity,
 * stake LP tokens, and handle cross-chain liquidity migrations.
 */
contract L2LiquidityManager is OApp {
    IRouter public aerodromeRouter;
    ISwapRouterV3 public swapRouterV3;

    PoolData[] private allPools;
    mapping(address => bool) private poolExists;

    /// @dev 10000 = 100%, 5000 = 50%, 100 = 1%, 1 = 0.01%
    uint256 public constant FEE_DENOMINATOR = 10_000;
    /// @dev Liquidity slippage tolerance: 0.5%
    uint256 public constant LIQ_SLIPPAGE = 50;
    /// @dev 10 ** 18
    uint256 public constant WAD = 1e18;
    /// @dev 10 ** 27
    uint256 public constant RAY = 1e27;

    address public constant BASE_USDC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address public constant NORMAL_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    INonfungiblePositionManager public constant nftPositionManager 
        = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    uint256 public migrationFee;
    address public feeReceiver;

    /// @dev Struct to store pool data
    struct PoolData {
        address poolAddress;
        address gaugeAddress;
        PoolType poolType;
    }

    struct PriceFeedData {
        AggregatorV3Interface feed;
        uint256 heartbeat;
    }

    /// @dev Mapping of user address to token address to liquidity amount
    mapping(address => mapping(address => uint256)) public userLiquidity;
    /// @dev Mapping of user address to LP token address to staked amount
    mapping(address => mapping(address => uint256)) public userStakedLPTokens;
    /// @dev Mapping of token pair to pool data
    mapping(address => mapping(address => PoolData)) public tokenPairToPools;
    /// @dev Mapping of pool key to pool data
    mapping(bytes32 => PoolData) public poolKeyToPoolData;
    /// @dev Mapping of user address to their NFT positions
    mapping(address => uint256[]) public userNFTPositions;
    /// @dev Mapping of token address to it's chainlink price feed data
    mapping(address => PriceFeedData) public tokenToPriceFeedData;

    event LiquidityDeposited(
        address user, address token0, address token1, uint256 amount0, uint256 amount1, uint256 lpTokens
    );
    event PoolSet(address tokenA, address tokenB, address pool, address gauge);
    event LPTokensStaked(address user, address pool, address gauge, uint256 amount);
    event LPTokensWithdrawn(address user, address pool, uint256 amount);
    event AeroEmissionsClaimed(address user, address pool, address gauge);
    event CrossChainLiquidityReceived(address user, address tokenA, address tokenB, uint256 amountA, uint256 amountB);
    event TrustedRemoteSet(uint32 indexed srcEid, bytes srcAddress);
    event NFTPositionMinted(address indexed user, uint256 tokenId);

    enum PoolType {
        NONE,
        BASIC_STABLE,
        BASIC_VOLATILE,
        CONCENTRATED_STABLE,
        CONCENTRATED_VOLATILE
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
        address _swapRouterV3,
        address _feeReceiver,
        uint256 _migrationFee,
        address _endpoint,
        address _delegate
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {
        migrationFee = _migrationFee;
        feeReceiver = _feeReceiver;
        aerodromeRouter = IRouter(_aerodromeRouter);
        swapRouterV3 = ISwapRouterV3(_swapRouterV3);
    }

    /**
     * @notice Adds a new pool to Supermigrate
     * @dev Only callable by the contract owner
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     * @param pool Address of the pool
     * @param gauge Address of the gauge for the pool
     */
    function setPool
    (address tokenA, address tokenB, PoolType poolType,
    address pool, address gauge, 
    PriceFeedData memory feedA, PriceFeedData memory feedB) 
    external onlyOwner {
        require(
            tokenA != address(0) && tokenB != address(0) && tokenA != tokenB && pool != address(0), "Invalid addresses"
        );

        PoolData memory poolData = PoolData(pool, gauge, poolType);
        tokenPairToPools[tokenA][tokenB] = poolData;
        tokenPairToPools[tokenB][tokenA] = poolData;
        emit PoolSet(tokenA, tokenB, pool, gauge);

        // NEW, able to store multiple different pool types for same token pair
        bytes32 poolKey = getPoolKey(tokenA, tokenB, poolData.poolType);
        poolKeyToPoolData[poolKey] = poolData;

        if (!poolExists[pool]) {
            allPools.push(poolData);
            poolExists[pool] = true;
        }

        tokenToPriceFeedData[tokenA] = feedA;
        tokenToPriceFeedData[tokenB] = feedB;

        emit PoolSet(tokenA, tokenB, pool, gauge);
    }

    function getPoolKey(address tokenA, address tokenB, PoolType poolType) public view returns(bytes32) {
        
        require(tokenA != tokenB);

        if (uint160(tokenA) < uint160(tokenB)) {
            return keccak256(abi.encodePacked(tokenA, tokenB, poolType));
        }
        else {
             return keccak256(abi.encodePacked(tokenB, tokenA, poolType));
        }
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

    /// @notice Retrieves the NFT positions of a user
    /// @param user The address of the user
    /// @return An array of token IDs representing the user's NFT positions
    function getUserNFTPositions(address user) external view returns (uint256[] memory) {
        return userNFTPositions[user];
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
        PoolData memory poolData = poolKeyToPoolData[getPoolKey(tokenA, tokenB, poolType)];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        // Wrap ETH to WETH if necessary
        if (tokenA == WETH) {
            IWETH(WETH).deposit{value: amountA}();
        }
        if (tokenB == WETH) {
            IWETH(WETH).deposit{value: amountB}();
        }

        if (poolType == PoolType.CONCENTRATED_STABLE || poolType == PoolType.CONCENTRATED_VOLATILE) {
            return _depositConcentratedLiquidity(tokenA, tokenB, amountA, amountB, poolData, user);
        } else {
            return _depositBasicLiquidity(tokenA, tokenB, amountA, amountB, poolType, user);
        }
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
    function _depositBasicLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        PoolType poolType,
        address user
    ) private returns (uint256) {
        bool stable = (poolType == PoolType.BASIC_STABLE);

        // Check and swap USDbC to USDC if necessary
        if (tokenA == NORMAL_USDC) {
            amountA = _swapBaseUSDCToNormalUSDC(amountA);
        }
        if (tokenB == NORMAL_USDC) {
            amountB = _swapBaseUSDCToNormalUSDC(amountB);
        }

        amountA = deductFee(tokenA, amountA);
        amountB = deductFee(tokenB, amountB);

        //Compare spot price to chainlink price, to prevent price manipulation attacks
        _checkPriceRatio(tokenA, tokenB, amountA, amountB, poolType);

        // Balance token ratio before depositing
        (uint256[] memory amounts, bool sellTokenA) = _balanceTokenRatio(tokenA, tokenB, amountA, amountB, stable);

        // Update token amounts after swaps
        if (sellTokenA) {
            amountA -= amounts[0];
            amountB += amounts[1];
        } else {
            amountB -= amounts[0];
            amountA += amounts[1];
        }
        
        IERC20(tokenA).approve(address(aerodromeRouter), amountA);
        IERC20(tokenB).approve(address(aerodromeRouter), amountB);

        // For volatile pairs: calculate minimum amount out with 0.5% slippage
        uint256 amountAMin;
        uint256 amountBMin;
        if (!stable) {
            amountAMin = mulDiv(amountA, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);
            amountBMin = mulDiv(amountB, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);
        }
        
        // Add liquidity to the basic pool
        (uint256 amountAOut, uint256 amountBOut, uint256 liquidity) = aerodromeRouter.addLiquidity(
            tokenA, tokenB, stable, amountA, amountB, amountAMin, amountBMin, address(this), block.timestamp
        );

        uint256 leftoverA = amountA - amountAOut;
        uint256 leftoverB = amountB - amountBOut;

        _returnLeftovers(tokenA, tokenB, leftoverA, leftoverB, user);

        // Update user liquidity
        userLiquidity[user][tokenA] += amountAOut;
        userLiquidity[user][tokenB] += amountBOut;

        emit LiquidityDeposited(user, tokenA, tokenB, amountAOut, amountBOut, liquidity);

        return liquidity;
    }

    function _returnLeftovers(address tokenA, address tokenB, uint256 leftoverA, uint256 leftoverB, address user) internal {
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
    }

    /// @notice Deposits liquidity into a concentrated liquidity pool
    /// @dev Calculates optimal tick range and mints an NFT position
    /// @param tokenA The address of the first token
    /// @param tokenB The address of the second token
    /// @param amountA The amount of tokenA to deposit
    /// @param amountB The amount of tokenB to deposit
    /// @param poolData The pool data struct containing pool information
    /// @param user The address of the user depositing liquidity
    /// @return The amount of liquidity tokens received
    function _depositConcentratedLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        PoolData memory poolData,
        address user
    ) internal returns (uint256) {
        ICLPool pool = ICLPool(poolData.poolAddress);

        // Approve tokens
        IERC20(tokenA).approve(poolData.poolAddress, amountA);
        IERC20(tokenB).approve(poolData.poolAddress, amountB);

        // Calculate optimal tick range
        (int24 lowerTick, int24 upperTick) = _calculateOptimalTickRange(pool);

        // Calculate the liquidity amount
        uint128 liquidityAmount = _calculateLiquidityAmount(tokenA, tokenB, amountA, amountB, lowerTick, upperTick);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: tokenA,
                token1: tokenB,
                tickSpacing: 2,
                tickLower: 5,
                tickUpper:  10,
                amount0Desired: amountA,
                amount1Desired: amountB,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                sqrtPriceX96: 5
            });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            nftPositionManager.mint(params);

        // Transfer the NFT to the user
        _transferNFTToUser(tokenId, user);

        // Update user liquidity
        userLiquidity[user][tokenA] += amount0;
        userLiquidity[user][tokenB] += amount1;

        emit LiquidityDeposited(user, tokenA, tokenB, amount0, amount1, liquidity);
        emit NFTPositionMinted(user, tokenId);

        return liquidity;
    }

   

    function _balanceTokenRatio(address tokenA, address tokenB, uint256 amountA, uint256 amountB, bool stable)
        internal
        returns (uint256[] memory, bool)
    {
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

        // Calculating tokensToSell for volatile pairs
        if (!stable) {
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
        }
        // Approximating tokensToSell for stable pairs
        else {
            if (!sellTokenA) {
                // Sell token B
                // value of tokenA denominated in B

                uint256 valueA = amountA * y / x;
                uint256 valueDifference = amountB - valueA;
                tokensToSell = valueDifference / 2;
            }
            else {
                // Sell token A
                // value of tokenB denominated in A
                
                uint256 valueB = amountB * x / y;
                uint256 valueDifference = amountA - valueB;
                tokensToSell = valueDifference / 2;
            }
        }

        // Return early if no need to swap
        if (tokensToSell == 0) {
            return (new uint256[](2), sellTokenA);
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

        return amountIn / aDec;
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
        IERC20(BASE_USDC).approve(address(swapRouterV3), amount);

        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3.ExactInputSingleParams({
            tokenIn: BASE_USDC,
            tokenOut: NORMAL_USDC,
            tickSpacing: 1,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: mulDiv(amount, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR),
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouterV3.exactInputSingle(params);
        return amountOut;
    }

     /// @notice Calculates the optimal tick range for a concentrated liquidity position
    /// @dev Calculates a range of approximately ±10% around the current price
    /// @param pool The concentrated liquidity pool interface
    /// @return lowerTick The calculated lower tick
    /// @return upperTick The calculated upper tick
    function _calculateOptimalTickRange(ICLPool pool)
        internal
        view
        returns (int24 lowerTick, int24 upperTick)
    {
        (,int24 currentTick,,,,) = pool.slot0();

        // Define a price range of ±10% around the current price
        int24 tickSpacing = pool.tickSpacing(); // Assuming a tick spacing of 60
        int24 tickRange = 2000; // Approximately 10% price range

        lowerTick = ((currentTick - tickRange) / tickSpacing) * tickSpacing;
        upperTick = ((currentTick + tickRange) / tickSpacing) * tickSpacing;

        // Ensure the calculated ticks are within the allowed range
        int24 MIN_TICK = -887_272;
        int24 MAX_TICK = 887_272;
        lowerTick = lowerTick < MIN_TICK ? MIN_TICK : lowerTick;
        upperTick = upperTick > MAX_TICK ? MAX_TICK : upperTick;

        return (lowerTick, upperTick);
    }

    /// @notice Calculates the liquidity amount for a concentrated liquidity position
    /// @param tokenA The address of the first token
    /// @param tokenB The address of the second token
    /// @param amountA The amount of tokenA
    /// @param amountB The amount of tokenB
    /// @param lowerTick The lower tick of the position
    /// @param upperTick The upper tick of the position
    /// @return The calculated liquidity amount
    function _calculateLiquidityAmount(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (uint128) {
    }

    /// @notice Transfers an NFT position to the user
    /// @dev Transfers the NFT and updates the user's NFT positions
    /// @param tokenId The ID of the NFT to transfer
    /// @param user The address of the user to receive the NFT
    function _transferNFTToUser(uint256 tokenId, address user) internal {
        nftPositionManager.transferFrom(address(this), user, tokenId);
        userNFTPositions[user].push(tokenId);
    }
    
    /// @notice Gets price by combining two price feeds
    /// @dev Both feeds must have price denominated in USD
    /// @dev Returns the price of A denominated in B, after adjusting both to 18 decimals
    function _combinePriceFeeds(address tokenA, address tokenB) public view returns(uint256) {

        PriceFeedData memory priceFeedA = tokenToPriceFeedData[tokenA];
        PriceFeedData memory priceFeedB = tokenToPriceFeedData[tokenB]; 

        (, int256 priceA_int,, uint256 updatedAtA, ) = priceFeedA.feed.latestRoundData(); 
        (, int256 priceB_int,, uint256 updatedAtB, ) = priceFeedB.feed.latestRoundData();

        require(priceA_int > 0 && priceB_int > 0, "Invalid price");
        require(updatedAtA >= block.timestamp - priceFeedA.heartbeat * 2, "Stale price");
        require(updatedAtB >= block.timestamp - priceFeedB.heartbeat * 2, "Stale price");

        uint256 priceA = uint256(priceA_int) * 10 ** (18 - priceFeedA.feed.decimals());
        uint256 priceB = uint256(priceB_int) * 10 ** (18 - priceFeedB.feed.decimals());
        
        uint256 aDecMultiplier = (10 ** (18 - IERC20Metadata(tokenA).decimals())); 
        uint256 bDecMultiplier = (10 ** (18 - IERC20Metadata(tokenB).decimals()));

        return mulDiv(priceA * aDecMultiplier, RAY, priceB * bDecMultiplier);
    }

    function _checkPriceRatio(address tokenA, address tokenB, uint256 amountA, uint256 amountB, PoolType poolType) public view {
        
        PoolData memory poolData = poolKeyToPoolData[getPoolKey(tokenA, tokenB, poolType)];
        uint256 aDecMultiplier = (10 ** (18 - IERC20Metadata(tokenA).decimals())); 
        uint256 bDecMultiplier = (10 ** (18 - IERC20Metadata(tokenB).decimals()));

        // Check using reserve ratio if basic volatile pool
        if (poolType == PoolType.BASIC_VOLATILE) {
            (uint256 reserveA, uint256 reserveB) =
            aerodromeRouter.getReserves(tokenA, tokenB, false, aerodromeRouter.defaultFactory());

            uint256 reserveRatio = mulDiv(reserveB, RAY, reserveA);
            uint256 priceFeedRatio = _combinePriceFeeds(tokenA, tokenB);

            // 0.5% allowed deviation from chainlink data
            uint256 allowedDeviation = mulDiv(priceFeedRatio, LIQ_SLIPPAGE, FEE_DENOMINATOR);

            require(_diff(reserveRatio, priceFeedRatio) <= allowedDeviation, "Price has deviated too much");
        }
        else if (poolType == PoolType.BASIC_STABLE) { // If stable pool, check using amountOut when swapping
            IPool pool = IPool(poolData.poolAddress);
            require(amountA > 0 || amountB > 0);
            uint256 amountOut;
            if (amountA > 0) {
                amountOut = pool.getAmountOut(amountA, tokenA);
                require(amountOut*bDecMultiplier >= mulDiv(amountA * aDecMultiplier, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR));
            }
            else {
                amountOut = pool.getAmountOut(amountB, tokenB);
                require(amountOut*aDecMultiplier >= mulDiv(amountB * bDecMultiplier, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR));
            }
        }
        else { // concentrated pool, check slot0
            ICLPool pool = ICLPool(poolData.poolAddress);
            (uint160 sqrtPriceX96,,,,,) = pool.slot0(); // price of token0, denominated in token1

            address poolToken0 = pool.token0();
            
            // Ensure that tokenA is the sams as poolToken0
            if (poolToken0 != tokenA) {
                address temp = tokenA;
                tokenA = tokenB;
                tokenB = temp;
            }

            uint256 priceFeedRatio = _combinePriceFeeds(tokenA, tokenB); // tokenA in tokenB
            uint256 spotPrice = _getPriceRatio(sqrtPriceX96);

            //0.5% allowed deviation from chainlink data
            uint256 allowedDeviation = mulDiv(priceFeedRatio, LIQ_SLIPPAGE, FEE_DENOMINATOR);

            require(_diff(spotPrice, priceFeedRatio) <= allowedDeviation, "Price has deviated too much");
        }
    }

    function _getPriceRatio(uint160 sqrtPriceX96) internal pure returns(uint256) {
        return mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 192);
    }
    function _diff(uint256 a, uint256 b) internal pure returns(uint256) {
        return a > b ? a - b : b - a;
    }

    /**
     * Staking methods
     */
    /// @notice Stakes LP tokens in the corresponding gauge
    /// @dev User must approve the gauge to spend their LP tokens before calling this function
    /// @param amount The amount of LP tokens to stake
    /// @param tokenA The address of the first token in the pair
    /// @param tokenB The address of the second token in the pair
    function stakeLPToken(uint256 amount, address tokenA, address tokenB) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        IGauge(poolData.gaugeAddress).deposit(amount, msg.sender);
        userStakedLPTokens[msg.sender][poolData.poolAddress] += amount;
        emit LPTokensStaked(msg.sender, poolData.poolAddress, poolData.gaugeAddress, amount);
    }

    /// @notice Unstakes LP tokens from the corresponding gauge
    /// @dev This function will fail if the user tries to unstake more than they have staked
    /// @param amount The amount of LP tokens to unstake
    /// @param tokenA The address of the first token in the pair
    /// @param tokenB The address of the second token in the pair
    function unstakeLPToken(uint256 amount, address tokenA, address tokenB) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        require(userStakedLPTokens[msg.sender][poolData.poolAddress] >= amount, "Insufficient staked LP tokens");

        IGauge(poolData.gaugeAddress).withdraw(amount);
        userStakedLPTokens[msg.sender][poolData.poolAddress] -= amount;

        emit LPTokensWithdrawn(msg.sender, poolData.poolAddress, amount);
    }

    /// @notice Claims Aero rewards for the caller from the specified pool's gauge
    /// @dev This function interacts with the Aerodrome gauge to claim rewards
    /// @param tokenA The address of the first token in the pair
    /// @param tokenB The address of the second token in the pair
    function claimAeroRewards(address tokenA, address tokenB) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        IGauge(poolData.gaugeAddress).getReward(msg.sender);
        emit AeroEmissionsClaimed(msg.sender, poolData.poolAddress, poolData.gaugeAddress);
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
        (address tokenA, address tokenB, uint256 amountA, uint256 amountB, address user, PoolType poolType, ) =
            abi.decode(_message, (address, address, uint256, uint256, address, PoolType, bool));

        emit CrossChainLiquidityReceived(user, tokenA, tokenB, amountA, amountB);

        uint256 liquidity = _depositLiquidity(tokenA, tokenB, amountA, amountB, poolType, user);

        PoolData memory poolData = poolKeyToPoolData[getPoolKey(tokenA, tokenB, poolType)];
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
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via CL
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
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
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
    /// @dev Liquidity slippage tolerance: 0.1%
    uint256 public constant LIQ_SLIPPAGE = 10;
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
    /// @dev Mapping of source chain ID to trusted remote address
    mapping(uint32 => bytes32) public trustedRemoteLookup;

    event LiquidityDeposited(
        address user, address token0, address token1, uint256 amount0, uint256 amount1, uint256 lpTokens
    );
    event LPTokensStaked(address user, address pool, uint256 amount);
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
    uint256 precisionFactor = 1e18;
    uint256 feeAmount = (amount * migrationFee * precisionFactor) / FEE_DENOMINATOR;
    feeAmount = (feeAmount + precisionFactor - 1) / precisionFactor;
    if (feeAmount > 0) {
        if (token == address(aerodromeRouter.weth())) {
            aerodromeRouter.weth().deposit{value: feeAmount}();
            IERC20(aerodromeRouter.weth()).transfer(feeReceiver, feeAmount);
        } else {
            IERC20(token).transferFrom(_msgSender(), feeReceiver, feeAmount);
        }
    }
    return amount - feeAmount;
}

    /**
     * @notice Deposits liquidity into Aerodrome
     * @dev Handles both ETH and ERC20 token deposits
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param amountA Amount of tokenA to deposit
     * @param amountB Amount of tokenB to deposit
     * @param amountAMin Minimum amount of tokenA to accept
     * @param amountBMin Minimum amount of tokenB to accept
     * @param poolType Type of the pool (stable, volatile, or concentrated)
     * @return uint256 Amount of LP tokens received
     */
    function _depositLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin,
        PoolType poolType
    ) public payable returns (uint256) {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        bool isETHA = tokenA == address(aerodromeRouter.weth());
        bool isETHB = tokenB == address(aerodromeRouter.weth());
        require(!(isETHA && isETHB), "Cannot deposit ETH for both tokens");

        if (isETHA || isETHB) {
            require(msg.value > 0, "Must send ETH");
            uint256 liquidity = _depositLiquidityETH(
                isETHA ? tokenB : tokenA,
                isETHA ? amountB : amountA,
                isETHA ? amountBMin : amountAMin,
                isETHA ? amountAMin : amountBMin,
                poolType
            );
            return liquidity;
        } else {
            require(msg.value == 0, "ETH sent with token-token deposit");
            uint256 liquidity =
                _depositLiquidityERC20(tokenA, tokenB, amountA, amountB, amountAMin, amountBMin, poolType);
            return liquidity;
        }
    }

    /**
     * @dev Deposits liquidity for ETH and an ERC20 token
     * @param token Address of the ERC20 token
     * @param amountToken Amount of ERC20 token to deposit
     * @param amountTokenMin Minimum amount of ERC20 token to accept
     * @param amountETHMin Minimum amount of ETH to accept
     * @param poolType Type of the pool
     * @return uint256 Amount of LP tokens received
     */
    function _depositLiquidityETH(
        address token,
        uint256 amountToken,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        PoolType poolType
    ) private returns (uint256) {
        IERC20(token).approve(address(aerodromeRouter), amountToken);
        bool stable = (poolType == PoolType.STABLE);

        amountToken = deductFee(token, amountToken);
        uint256 ethAmount = deductFee(address(aerodromeRouter.weth()), msg.value);

        // calculate minimum amount with 0.1% slippage
        uint256 updatedAmountTokenMin = mulDiv(amountTokenMin, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);
        uint256 updatedAmountEthMin = mulDiv(amountETHMin, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);

        (uint256 amountTokenOut, uint256 amountETHOut, uint256 liquidity) = aerodromeRouter.addLiquidityETH{
            value: ethAmount
        }(token, stable, amountToken, updatedAmountTokenMin, updatedAmountEthMin, address(this), block.timestamp);
        // Update user liquidity
        userLiquidity[msg.sender][token] += amountTokenOut;
        userLiquidity[msg.sender][address(aerodromeRouter.weth())] += amountETHOut;

        // Refund excess ETH if any
        if (ethAmount > amountETHOut) {
            (bool success,) = msg.sender.call{value: ethAmount - amountETHOut}("");
            require(success, "ETH transfer failed");
        }

        emit LiquidityDeposited(
            msg.sender, address(aerodromeRouter.weth()), token, amountETHOut, amountTokenOut, liquidity
        );
        return liquidity;
    }

    /**
     * @notice Deposits ERC20 liquidity into Aerodrome
     * @dev Assumes that amountAMin and amountBMin are calculated after deducting the migration fees in the front end
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param amountA Amount of tokenA to deposit
     * @param amountB Amount of tokenB to deposit
     * @param amountAMin Minimum amount of tokenA to accept (after fee deduction)
     * @param amountBMin Minimum amount of tokenB to accept (after fee deduction)
     * @param poolType Type of the pool (stable, volatile, or concentrated)
     * @return uint256 Amount of LP tokens received
     */
    function _depositLiquidityERC20(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin,
        PoolType poolType
    ) private returns (uint256) {
        IERC20(tokenA).approve(address(aerodromeRouter), amountA);
        IERC20(tokenB).approve(address(aerodromeRouter), amountB);
        bool stable = (poolType == PoolType.STABLE);

        amountA = deductFee(tokenA, amountA);
        amountB = deductFee(tokenB, amountB);

        // calculate minimum amount with 0.1% slippage
        uint256 updatedAmountAMin = mulDiv(amountAMin, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);
        uint256 updatedAmountBMin = mulDiv(amountBMin, FEE_DENOMINATOR - LIQ_SLIPPAGE, FEE_DENOMINATOR);

        (uint256 amountAOut, uint256 amountBOut, uint256 liquidity) = aerodromeRouter.addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountA,
            amountB,
            updatedAmountAMin,
            updatedAmountBMin,
            address(this),
            block.timestamp
        );

        // Update user liquidity
        userLiquidity[msg.sender][tokenA] += amountAOut;
        userLiquidity[msg.sender][tokenB] += amountBOut;
        emit LiquidityDeposited(msg.sender, tokenA, tokenB, amountAOut, amountBOut, liquidity);

        return liquidity;
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
        // Ensure the message is from the trusted remote on the source chain
        require(_checkTrustedRemote(_origin), "L2LiquidityManager: Invalid remote sender");
        (
            address tokenA,
            address tokenB,
            uint256 amountA,
            uint256 amountB,
            address user,
            PoolType poolType,
            bool stakeLptoken
        ) = abi.decode(_message, (address, address, uint256, uint256, address, PoolType, bool));

        emit CrossChainLiquidityReceived(user, tokenA, tokenB, amountA, amountB);

        uint256 liquidity = _depositLiquidity(tokenA, tokenB, amountA, amountB, amountA, amountB, poolType);
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        // if user wants to automatically stake lp, stake lp tokens on their behalf, else transfer lp tokens to user
        if (stakeLptoken) {
            IERC20(poolData.poolAddress).approve(poolData.gaugeAddress, liquidity);
            _stakeLPToken(liquidity, user, tokenA, tokenB);
        } else {
            IERC20(poolData.poolAddress).transfer(user, liquidity);
        }
    }

    /**
     * @notice Stakes LP tokens for a user
     * @dev This function is called externally to stake LP tokens
     * @param amount Amount of LP tokens to stake
     * @param owner Address of the LP token owner
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     */
    function stakeLPToken(uint256 amount, address owner, address tokenA, address tokenB) external {
        _stakeLPToken(amount, owner, tokenA, tokenB);
    }

    /**
     * @notice Internal function to stake LP tokens
     * @dev This function handles the actual staking process
     * @param amount Amount of LP tokens to stake
     * @param owner Address of the LP token owner
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     */
    function _stakeLPToken(uint256 amount, address owner, address tokenA, address tokenB) internal {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        IGauge(poolData.gaugeAddress).deposit(amount, owner);
        userStakedLPTokens[msg.sender][poolData.poolAddress] += amount;
        emit LPTokensStaked(owner, poolData.poolAddress, poolData.gaugeAddress, amount);
    }

    /**
     * @notice Unstakes LP tokens for a user
     * @dev This function allows users to withdraw their staked LP tokens
     * @param amount Amount of LP tokens to unstake
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     */
    function unstakeLPToken(uint256 amount, address tokenA, address tokenB) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        require(userStakedLPTokens[msg.sender][poolData.poolAddress] >= amount, "Insufficient staked LP tokens");

        IGauge(poolData.gaugeAddress).withdraw(amount);
        userStakedLPTokens[msg.sender][poolData.poolAddress] -= amount;

        emit LPTokensWithdrawn(msg.sender, poolData.poolAddress, amount);
    }

    /**
     * @notice Claims Aero rewards for a user
     * @dev This function allows users to claim their accumulated Aero rewards
     * @param owner Address of the user claiming rewards
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     */
    function claimAeroRewards(address owner, address tokenA, address tokenB) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IGauge(poolData.gaugeAddress).getReward(owner);
        emit AeroEmissionsClaimed(owner, poolData.poolAddress, poolData.gaugeAddress);
    }

    /**
     * @notice Checks if a remote sender is trusted
     * @dev Internal function to validate the source of cross-chain messages
     * @param _origin Information about the source of the message
     * @return bool True if the remote sender is trusted, false otherwise
     */
    function _checkTrustedRemote(Origin calldata _origin) internal view returns (bool) {
        return trustedRemoteLookup[_origin.srcEid] == _origin.sender;
    }

    /**
     * @notice Sets a trusted remote for cross-chain communication
     * @dev Only callable by the contract owner
     * @param _srcEid The source chain ID
     * @param _srcAddress The address on the source chain to trust
     */
    function setTrustedRemote(uint32 _srcEid, bytes calldata _srcAddress) external onlyOwner {
        trustedRemoteLookup[_srcEid] = bytes32(bytes20(_srcAddress));
        emit TrustedRemoteSet(_srcEid, _srcAddress);
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

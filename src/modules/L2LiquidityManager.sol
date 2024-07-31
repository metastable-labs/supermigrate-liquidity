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

contract L2LiquidityManager is OApp {
    IRouter public aerodromeRouter;
    PoolData[] private allPools;
    mapping(address => bool) private poolExists;

    // 10000 = 100%, 5000 = 50%, 100 = 1%, 1 = 0.01%
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant LIQ_SLIPPAGE = 10; // 0.1%
    uint256 public migrationFee;
    address public feeReceiver;

    struct PoolData {
        address poolAddress;
        address gaugeAddress;
    }

    mapping(address => mapping(address => uint256)) public userLiquidity; // user address => token address => amount
    mapping(address => mapping(address => uint256)) public userStakedLPTokens; // user address => lp token address => amount
    mapping(address => mapping(address => PoolData)) public tokenPairToPools;
    mapping(uint32 => bytes32) public trustedRemoteLookup;

    event LiquidityDeposited(
        address user,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 lpTokens
    );
    event LPTokensStaked(address user, address pool, uint256 amount);
    event PoolSet(address tokenA, address tokenB, address pool, address gauge);
    event LPTokensStaked(
        address user,
        address pool,
        address gauge,
        uint256 amount
    );
    event LPTokensWithdrawn(address user, address pool, uint256 amount);
    event AeroEmissionsClaimed(address user, address pool, address gauge);
    event CrossChainLiquidityReceived(
        address user,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    );
    event TrustedRemoteSet(uint32 indexed srcEid, bytes srcAddress);

    enum PoolType {
        NONE,
        STABLE,
        VOLATILE,
        CONCENTRATED
    }

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
    // add a new pool to supermigrate

    function setPool(
        address tokenA,
        address tokenB,
        address pool,
        address gauge
    ) external onlyOwner {
        require(
            tokenA != address(0) &&
                tokenB != address(0) &&
                tokenA != tokenB &&
                pool != address(0),
            "Invalid addresses"
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

    function setFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= FEE_DENOMINATOR, "Fee too high");
        migrationFee = _newFee;
    }

    function getPool(
        address tokenA,
        address tokenB
    ) external view returns (address pool, address gauge) {
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
    function getPools(
        uint256 start,
        uint256 end
    ) external view returns (address[] memory pools, address[] memory gauges) {
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

    function getUserLiquidity(
        address user,
        address token
    ) external view returns (uint256) {
        return userLiquidity[user][token];
    }

    function getUserStakedLP(
        address user,
        address pool
    ) external view returns (uint256) {
        return userStakedLPTokens[user][pool];
    }

    function deductFee(
        address token,
        uint256 amount
    ) private returns (uint256) {
        uint256 feeAmount = (amount * migrationFee) / FEE_DENOMINATOR;
        if (token == address(aerodromeRouter.weth())) {
            aerodromeRouter.weth().deposit{value: feeAmount}();
            IERC20(aerodromeRouter.weth()).transfer(feeReceiver, feeAmount);
        } else {
            IERC20(token).transferFrom(_msgSender(), feeReceiver, feeAmount);
        }
        return amount - feeAmount;
    }

    function _depositLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin,
        PoolType poolType
    ) public payable {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        bool isETHA = tokenA == address(aerodromeRouter.weth());
        bool isETHB = tokenB == address(aerodromeRouter.weth());
        require(!(isETHA && isETHB), "Cannot deposit ETH for both tokens");

        if (isETHA || isETHB) {
            require(msg.value > 0, "Must send ETH");
            _depositLiquidityETH(
                isETHA ? tokenB : tokenA,
                isETHA ? amountB : amountA,
                isETHA ? amountBMin : amountAMin,
                isETHA ? amountAMin : amountBMin,
                poolType
            );
        } else {
            require(msg.value == 0, "ETH sent with token-token deposit");
            _depositLiquidityERC20(
                tokenA,
                tokenB,
                amountA,
                amountB,
                amountAMin,
                amountBMin,
                poolType
            );
        }
    }

    /**
     * Assuming that amountTokenMin is calculated after deducting migration fees in the front end.
     */
    function _depositLiquidityETH(
        address token,
        uint256 amountToken,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        PoolType poolType
    ) private {
        IERC20(token).approve(address(aerodromeRouter), amountToken);
        bool stable = (poolType == PoolType.STABLE);

        amountToken = deductFee(token, amountToken);
        uint256 ethAmount = deductFee(
            address(aerodromeRouter.weth()),
            msg.value
        );

        // calculate minimum amount with 0.1% slippage
        uint256 updatedAmountTokenMin = mulDiv(
            amountTokenMin,
            FEE_DENOMINATOR - LIQ_SLIPPAGE,
            FEE_DENOMINATOR
        );
        uint256 updatedAmountEthMin = mulDiv(
            amountETHMin,
            FEE_DENOMINATOR - LIQ_SLIPPAGE,
            FEE_DENOMINATOR
        );

        (
            uint256 amountTokenOut,
            uint256 amountETHOut,
            uint256 liquidity
        ) = aerodromeRouter.addLiquidityETH{value: ethAmount}(
                token,
                stable,
                amountToken,
                updatedAmountTokenMin,
                updatedAmountEthMin,
                address(this),
                block.timestamp
            );
        // Update user liquidity
        userLiquidity[msg.sender][token] += amountTokenOut;
        userLiquidity[msg.sender][
            address(aerodromeRouter.weth())
        ] += amountETHOut;

        // Refund excess ETH if any
        if (ethAmount > amountETHOut) {
            (bool success, ) = msg.sender.call{value: ethAmount - amountETHOut}(
                ""
            );
            require(success, "ETH transfer failed");
        }

        emit LiquidityDeposited(
            msg.sender,
            address(aerodromeRouter.weth()),
            token,
            amountETHOut,
            amountTokenOut,
            liquidity
        );
    }

    /**
     * Assuming that amountAMin and amountBMin are calculated after deducting the migration fees in the front end.
     */
    function _depositLiquidityERC20(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 amountAMin,
        uint256 amountBMin,
        PoolType poolType
    ) private {
        IERC20(tokenA).approve(address(aerodromeRouter), amountA);
        IERC20(tokenB).approve(address(aerodromeRouter), amountB);
        bool stable = (poolType == PoolType.STABLE);

        amountA = deductFee(tokenA, amountA);
        amountB = deductFee(tokenB, amountB);

        // calculate minimum amount with 0.1% slippage
        uint256 updatedAmountAMin = mulDiv(
            amountAMin,
            FEE_DENOMINATOR - LIQ_SLIPPAGE,
            FEE_DENOMINATOR
        );
        uint256 updatedAmountBMin = mulDiv(
            amountBMin,
            FEE_DENOMINATOR - LIQ_SLIPPAGE,
            FEE_DENOMINATOR
        );

        (
            uint256 amountAOut,
            uint256 amountBOut,
            uint256 liquidity
        ) = aerodromeRouter.addLiquidity(
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
        emit LiquidityDeposited(
            msg.sender,
            tokenA,
            tokenB,
            amountAOut,
            amountBOut,
            liquidity
        );
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        // Ensure the message is from the trusted remote on the source chain
        require(
            _checkTrustedRemote(_origin),
            "L2LiquidityManager: Invalid remote sender"
        );
        (
            address tokenA,
            address tokenB,
            uint256 amountA,
            uint256 amountB,
            address user,
            PoolType poolType
        ) = abi.decode(
                _message,
                (address, address, uint256, uint256, address, PoolType)
            );

        emit CrossChainLiquidityReceived(
            user,
            tokenA,
            tokenB,
            amountA,
            amountB
        );

        _depositLiquidity(
            tokenA,
            tokenB,
            amountA,
            amountB,
            amountA,
            amountB,
            poolType
        );
    }

    function stakeLPToken(
        uint256 amount,
        address owner,
        address tokenA,
        address tokenB
    ) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        IERC20(poolData.poolAddress).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        IERC20(poolData.poolAddress).approve(poolData.gaugeAddress, amount);
        IGauge(poolData.gaugeAddress).deposit(amount, owner);
        userStakedLPTokens[msg.sender][poolData.poolAddress] += amount;
        emit LPTokensStaked(
            owner,
            poolData.poolAddress,
            poolData.gaugeAddress,
            amount
        );
    }

    function unstakeLPToken(
        uint256 amount,
        address tokenA,
        address tokenB
    ) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];
        require(poolData.poolAddress != address(0), "Pool does not exist");

        require(
            userStakedLPTokens[msg.sender][poolData.poolAddress] >= amount,
            "Insufficient staked LP tokens"
        );

        IGauge(poolData.gaugeAddress).withdraw(amount);
        userStakedLPTokens[msg.sender][poolData.poolAddress] -= amount;

        emit LPTokensWithdrawn(msg.sender, poolData.poolAddress, amount);
    }

    function claimAeroRewards(
        address owner,
        address tokenA,
        address tokenB
    ) external {
        PoolData memory poolData = tokenPairToPools[tokenA][tokenB];

        IGauge(poolData.gaugeAddress).getReward(owner);
        emit AeroEmissionsClaimed(
            owner,
            poolData.poolAddress,
            poolData.gaugeAddress
        );
    }

    function _checkTrustedRemote(
        Origin calldata _origin
    ) internal view returns (bool) {
        return trustedRemoteLookup[_origin.srcEid] == _origin.sender;
    }

    function setTrustedRemote(
        uint32 _srcEid,
        bytes calldata _srcAddress
    ) external onlyOwner {
        trustedRemoteLookup[_srcEid] = bytes32(bytes20(_srcAddress));
        emit TrustedRemoteSet(_srcEid, _srcAddress);
    }

    receive() external payable {}

    // Helper function for safe multiplication and division
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
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

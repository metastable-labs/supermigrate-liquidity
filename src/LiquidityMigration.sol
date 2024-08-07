// SPDX-License-Identifier: GNU
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface StandardBridge {
    event ERC20BridgeFinalized(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event ETHBridgeFinalized(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);

    function bridgeERC20(
        address _localToken,
        address _remoteToken,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    ) external;
    function bridgeERC20To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    ) external;
    function bridgeETH(uint32 _minGasLimit, bytes memory _extraData) external payable;
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes memory _extraData) external payable;
    function deposits(address, address) external view returns (uint256);
    function finalizeBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    ) external;
    function finalizeBridgeETH(address _from, address _to, uint256 _amount, bytes memory _extraData) external payable;
    function messenger() external view returns (address);
    function OTHER_BRIDGE() external view returns (address);
}

/**
 * @title LiquidityMigration
 * @dev Facilitates the migration of liquidity from Uniswap V2 and V3 pools on Ethereum to Layer 2 solutions.
 * This contract handles the removal of liquidity, bridging of assets, and cross-chain messaging.
 */
contract LiquidityMigration is OApp {
    /// @notice Uniswap V2 Factory contract
    IUniswapV2Factory public immutable uniswapV2Factory;
    /// @notice Uniswap V2 Router contract
    IUniswapV2Router02 public immutable uniswapV2Router;
    /// @notice Uniswap V3 Factory contract
    IUniswapV3Factory public immutable uniswapV3Factory;
    /// @notice Uniswap V3 NonFungiblePositionManager contract
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    /// @notice L1 Standard Bridge contract for asset bridging
    StandardBridge public immutable l1StandardBridge;

    /// @notice Address of the L2 Liquidity Manager contract
    address l2LiquidityManager;

    /// @notice Emitted when liquidity is removed from a pool
    event LiquidityRemoved(address tokenA, address tokenB, uint256 amountA, uint256 amountB);
    /// @notice Emitted when tokens are bridged to L2
    event TokensBridged(address token, uint256 amount);

    /// @notice Enum representing different types of liquidity pools
    enum PoolType {
        NONE,
        STABLE,
        VOLATILE,
        CONCENTRATED
    }

    // New struct to hold migration parameters
    struct MigrationParams {
        uint32 dstEid;
        address tokenA;
        address tokenB;
        address l2TokenA;
        address l2TokenB;
        uint256 liquidity;
        uint256 tokenId;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 deadline;
        uint32 minGasLimit;
        PoolType poolType;
        bool stakeLPtokens;
    }

    /**
     * @dev Constructor to initialize the LiquidityMigration contract
     * @param _endpoint LayerZero endpoint address
     * @param _delegate Address of the contract owner/delegate
     * @param _uniswapV2Factory Address of Uniswap V2 Factory
     * @param _uniswapV2Router Address of Uniswap V2 Router
     * @param _uniswapV3Factory Address of Uniswap V3 Factory
     * @param _nonfungiblePositionManager Address of Uniswap V3 NonFungiblePositionManager
     * @param _l1StandardBridge Address of L1 Standard Bridge
     * @param _l2LiquidityManager Address of L2 Liquidity Manager
     */
    constructor(
        address _endpoint,
        address _delegate,
        address _uniswapV2Factory,
        address _uniswapV2Router,
        address _uniswapV3Factory,
        address _nonfungiblePositionManager,
        address _l1StandardBridge,
        address _l2LiquidityManager
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {
        uniswapV2Factory = IUniswapV2Factory(_uniswapV2Factory);
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        l1StandardBridge = StandardBridge(_l1StandardBridge);
        l2LiquidityManager = _l2LiquidityManager;
    }

    /**
     * @notice Migrates ERC20 liquidity from Uniswap V2 or V3 to L2
     * @dev Removes liquidity, bridges tokens, and sends a cross-chain message
     * @param params MigrationParams struct containing all necessary parameters
     * @param _options LayerZero options
     * @return receipt MessagingReceipt for the cross-chain message
     */
    function migrateERC20Liquidity(MigrationParams calldata params, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        require(params.tokenA != params.tokenB, "Identical addresses");

        (uint256 amountA, uint256 amountB) = _removeLiquidity(params);

        emit LiquidityRemoved(params.tokenA, params.tokenB, amountA, amountB);

        _bridgeTokens(params, amountA, amountB);

        bytes memory payload = abi.encode(
            params.tokenA, params.tokenB, amountA, amountB, msg.sender, params.poolType, params.stakeLPtokens
        );

        receipt = _lzSend(params.dstEid, payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));

        return receipt;
    }

    /**
     * @dev Internal function to remove liquidity from either V2 or V3 pool
     * @param params MigrationParams struct containing necessary parameters
     * @return amountA Amount of token A received
     * @return amountB Amount of token B received
     */
    function _removeLiquidity(MigrationParams memory params) internal returns (uint256 amountA, uint256 amountB) {
        if (isV3Pool(params.tokenA, params.tokenB) && params.tokenId != 0) {
            return _removeV3Liquidity(
                params.tokenA, params.tokenB, params.tokenId, params.amountAMin, params.amountBMin, params.deadline
            );
        } else {
            return _removeV2Liquidity(
                params.tokenA, params.tokenB, params.liquidity, params.amountAMin, params.amountBMin, params.deadline
            );
        }
    }

    /**
     * @dev Internal function to bridge tokens to L2
     * @param params MigrationParams struct containing necessary parameters
     * @param amountA Amount of token A to bridge
     * @param amountB Amount of token B to bridge
     */
    function _bridgeTokens(MigrationParams memory params, uint256 amountA, uint256 amountB) internal {
        _bridgeToken(params.tokenA, params.l2TokenA, amountA, params.minGasLimit, "Supermigrate Liquidity");
        _bridgeToken(params.tokenB, params.l2TokenB, amountB, params.minGasLimit, "Supermigrate Liquidity");
    }
    /**
     * @notice Quotes the fee for cross-chain messaging
     * @param _dstEid Destination chain ID
     * @param tokenA Address of token A
     * @param tokenB Address of token B
     * @param liquidity Amount of liquidity
     * @param _options LayerZero options
     * @param _payInLzToken Whether to pay in LZ token
     * @return fee MessagingFee struct containing the fee details
     */

    function quote(
        uint32 _dstEid,
        address tokenA,
        address tokenB,
        uint256 liquidity,
        bytes memory _options,
        bool _payInLzToken
    ) public view returns (MessagingFee memory fee) {
        bytes memory payload = abi.encode(tokenA, tokenB, liquidity, msg.sender);
        fee = _quote(_dstEid, payload, _options, _payInLzToken);
    }

    /**
     * @notice Handles the receipt of ERC721 tokens
     * @dev Required for ERC721 safeTransferFrom
     * @return bytes4 Function selector
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /**
     * @notice Checks if a pool is a V3 pool
     * @param tokenA Address of token A
     * @param tokenB Address of token B
     * @return bool True if it's a V3 pool, false otherwise
     */
    function isV3Pool(address tokenA, address tokenB) public view returns (bool) {
        uint16[3] memory fees = [500, 3000, 10_000];
        for (uint256 i = 0; i < fees.length; i++) {
            if (uniswapV3Factory.getPool(tokenA, tokenB, fees[i]) != address(0)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Removes liquidity from a Uniswap V2 pool
     * @param tokenA Address of token A in the pair
     * @param tokenB Address of token B in the pair
     * @param liquidity Amount of liquidity to remove
     * @param amountAMin Minimum amount of token A to receive
     * @param amountBMin Minimum amount of token B to receive
     * @param deadline Deadline for the transaction
     * @return amountA Amount of token A received
     * @return amountB Amount of token B received
     */
    function _removeV2Liquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = IUniswapV2Factory(uniswapV2Factory).getPair(tokenA, tokenB);
        require(pair != address(0), "V2: Pool does not exist");

        // Transfer LP tokens from user to this contract
        IERC20(pair).transferFrom(msg.sender, address(this), liquidity);

        // Approve the router to spend the LP tokens
        IERC20(pair).approve(address(uniswapV2Router), liquidity);

        // Remove liquidity
        (amountA, amountB) = IUniswapV2Router02(uniswapV2Router).removeLiquidity(
            tokenA, tokenB, liquidity, amountAMin, amountBMin, address(this), deadline
        );

        return (amountA, amountB);
    }

    /**
     * @dev Removes liquidity from a Uniswap V3 pool
     * @param tokenA Address of token A in the pair
     * @param tokenB Address of token B in the pair
     * @param tokenId ID of the NFT representing the liquidity position
     * @param amountAMin Minimum amount of token A to receive
     * @param amountBMin Minimum amount of token B to receive
     * @param deadline Deadline for the transaction
     * @return amountA Amount of token A received
     * @return amountB Amount of token B received
     */
    function _removeV3Liquidity(
        address tokenA,
        address tokenB,
        uint256 tokenId,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) internal returns (uint256 amountA, uint256 amountB) {
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);
        require(
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA),
            "Invalid token pair for position"
        );

        // Transfer the NFT to this contract
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId);

        // Decrease liquidity
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: deadline
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.decreaseLiquidity(params);
        // Collect the tokens
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);

        // Check minimum amounts
        require(amount0 >= amountAMin && amount1 >= amountBMin, "Slippage check failed");

        nonfungiblePositionManager.burn(tokenId);

        return token0 == tokenA ? (amount0, amount1) : (amount1, amount0);
    }

    /**
     * @dev Bridges tokens from L1 to L2
     * @param localToken Address of the token on L1
     * @param l2Token Address of the corresponding token on L2
     * @param amount Amount of tokens to bridge
     * @param minGasLimit Minimum gas limit for the bridging transaction
     * @param extraData Additional data for the bridging process
     */
    function _bridgeToken(
        address localToken,
        address l2Token,
        uint256 amount,
        uint32 minGasLimit,
        bytes memory extraData
    ) internal {
        if (localToken == address(0)) {
            l1StandardBridge.bridgeETHTo{value: amount}(l2LiquidityManager, minGasLimit, extraData);
        } else {
            IERC20(localToken).approve(address(l1StandardBridge), amount);
            l1StandardBridge.bridgeERC20To(localToken, l2Token, l2LiquidityManager, amount, minGasLimit, extraData);
        }
        emit TokensBridged(l2Token, amount);
    }

    /**
     * @dev Internal function to handle incoming LayerZero messages
     * @notice This contract doesn't receive messages, so this function always reverts
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        revert("CrossChainLiquidityMigration does not receive messages");
    }

    /**
     * @dev Internal function to check if the caller is authorized
     * @return bool True if the caller is the owner, false otherwise
     */
    function _authorized() internal view returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Sets the configuration for LayerZero messaging
     * @dev Can only be called by the owner
     * @param _version Version of the configuration
     * @param _dstEid Destination chain ID
     * @param _outboundConfirmations Number of confirmations required for outbound messages
     * @param _inboundConfirmations Number of confirmations required for inbound messages
     */
    function _setConfig(uint32 _version, uint32 _dstEid, uint256 _outboundConfirmations, uint256 _inboundConfirmations)
        external
        onlyOwner
    {
        // Implementation needed
    }
}

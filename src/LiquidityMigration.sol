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

contract LiquidityMigration is OApp {
    IUniswapV2Factory public immutable uniswapV2Factory;
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV3Factory public immutable uniswapV3Factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    StandardBridge public immutable l1StandardBridge;

    address l2LiquidityManager;

    event LiquidityRemoved(address tokenA, address tokenB, uint256 amountA, uint256 amountB);
    event TokensBridged(address token, uint256 amount);

    enum PoolType {
        NONE,
        STABLE,
        VOLATILE,
        CONCENTRATED
    }

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

    function migrateERC20Liquidity(
        uint32 _dstEid,
        address tokenA,
        address tokenB,
        address l2TokenA,
        address l2TokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        uint32 minGasLimit,
        bytes calldata _options,
        PoolType poolType
    ) external payable returns (MessagingReceipt memory receipt) {
        require(tokenA != tokenB, "Identical addresses");

        (uint256 amountA, uint256 amountB) = isV3Pool(tokenA, tokenB)
            ? _removeV3Liquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, deadline)
            : _removeV2Liquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, deadline);

        emit LiquidityRemoved(tokenA, tokenB, amountA, amountB);

        _bridgeToken(tokenA, l2TokenA, amountA, minGasLimit, "Supermigrate Liquidity");
        _bridgeToken(tokenB, l2TokenB, amountB, minGasLimit, "Supermigrate Liquidity");

        bytes memory payload = abi.encode(tokenA, tokenB, amountA, amountB, msg.sender, poolType);
        receipt = _lzSend(_dstEid, payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));

        return receipt;
    }

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

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function isV3Pool(address tokenA, address tokenB) public view returns (bool) {
        uint16[3] memory fees = [500, 3000, 10_000];
        for (uint256 i = 0; i < fees.length; i++) {
            if (uniswapV3Factory.getPool(tokenA, tokenB, fees[i]) != address(0)) {
                return true;
            }
        }
        return false;
    }

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

        return token0 == tokenA ? (amount0, amount1) : (amount1, amount0);
    }

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
            IERC20(l2Token).approve(address(l1StandardBridge), amount);
            l1StandardBridge.bridgeERC20To(localToken, l2Token, l2LiquidityManager, amount, minGasLimit, extraData);
        }
        emit TokensBridged(l2Token, amount);
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        // This contract doesn't receive messages, so we can leave this empty or revert
        revert("CrossChainLiquidityMigration does not receive messages");
    }

    function _authorized() internal view returns (bool) {
        return msg.sender == owner();
    }

    function _setConfig(uint32 _version, uint32 _dstEid, uint256 _outboundConfirmations, uint256 _inboundConfirmations)
        external
        onlyOwner
    {
        // _setConfig(_version, _dstEid, _outboundConfirmations, _inboundConfirmations);
    }
}

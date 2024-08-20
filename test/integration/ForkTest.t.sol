pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {L2LiquidityManager} from "../../src/modules/L2LiquidityManager.sol";
import {LiquidityMigration} from "../../src/LiquidityMigration.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {IRouter} from "@aerodrome/contracts/contracts/interfaces/IRouter.sol";

contract ForkTest is Test {
    using OptionsBuilder for bytes;

    // ETH CONTRACTS
    IUniswapV2Factory public constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapRouter public constant uniswapV2Router = IUniswapRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV3Factory public constant uniswapV3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    StandardBridge public constant l1StandardBridge = StandardBridge(0x3154Cf16ccdb4C6d922629664174b904d80F2C35); // base l1 standard bridge
    address public constant swapRouterV3 = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    // ETH TOKENS
    ERC20 WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 pool = ERC20(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);

    // BASE CONTRACTS
    address public constant base_gauge = 0x519BBD1Dd8C6A94C46080E24f316c14Ee758C025;
    address public constant aerodromeRouter = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // BASE TOKENS
    ERC20 base_WETH = ERC20(0x4200000000000000000000000000000000000006);
    ERC20 base_bridgedUSDC = ERC20(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);
    ERC20 base_USDC = ERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ERC20 base_pool = ERC20(0xcDAC0d6c6C59727a65F871236188350531885C43);

    address public constant endpointMainnet = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant endpointBase = 0x1a44076050125825900e736c501f859c50fE728c;

    address public delegate;

    L2LiquidityManager l2LiquidityManager;
    LiquidityMigration liquidityMigration;

    address user;
    address feeReceiver;

    uint32 public constant ETH_EID = 30_101;
    uint32 public constant BASE_EID = 30_184;

    uint256 ethFork;
    uint256 baseFork;

    uint256 public constant MIGRATION_FEE = 10; // 0.1%

    uint256 ethPrice;

    function setUp() public {
        ///////////////
        // L2 SETUP////
        ///////////////
        baseFork = vm.createSelectFork(vm.envString("BASE_RPC"));

        delegate = makeAddr("delegate");
        feeReceiver = makeAddr("feeReceiver");

        l2LiquidityManager = new L2LiquidityManager(aerodromeRouter, swapRouterV3, feeReceiver, MIGRATION_FEE, endpointBase, delegate);

        ///////////////
        // L1 SETUP////
        ///////////////
        ethFork = vm.createSelectFork(vm.envString("ETH_RPC"));
        (uint112 r1, uint112 r2,) = IUniswapV2Pair(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc).getReserves();
        uint256 a = uint256(r1);
        uint256 b = uint256(r2);
        ethPrice = (a * 1e12 * 1e18) / b;

        user = makeAddr("user");

        liquidityMigration = new LiquidityMigration(
            endpointMainnet,
            delegate,
            address(uniswapV2Factory),
            address(uniswapV2Router),
            address(uniswapV3Factory),
            address(nonfungiblePositionManager),
            address(l1StandardBridge),
            address(l2LiquidityManager)
        );

        vm.prank(delegate);
        liquidityMigration.setPeer(BASE_EID, bytes32(uint256(uint160(address(l2LiquidityManager)))));

        ////////////////
        // L2 CONFIG////
        ////////////////
        vm.selectFork(baseFork);
        vm.startPrank(delegate);
        l2LiquidityManager.setPeer(ETH_EID, bytes32(uint256(uint160(address(liquidityMigration)))));
        l2LiquidityManager.setPool(address(base_USDC), address(base_WETH), address(base_pool), base_gauge);
        vm.stopPrank();

        vm.label(address(l2LiquidityManager), "l2LiquidityManager");
        vm.label(user, "user");
    }

    function test_old_migrateV2Liquidity() public {
        vm.selectFork(ethFork);
        deal(address(WETH), user, 10e18);
        deal(address(USDC), user, 25_000e6);
        deal(user, 20 ether);

        uint256 lpTokens = _addV2Liquidity(user);

        pool.approve(address(liquidityMigration), pool.balanceOf(user));

        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: BASE_EID,
            tokenA: address(WETH),
            tokenB: address(USDC),
            l2TokenA: address(base_WETH),
            l2TokenB: address(base_USDC),
            liquidity: lpTokens,
            tokenId: 0,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp,
            minGasLimit: 50_000,
            poolType: LiquidityMigration.PoolType(0),
            stakeLPtokens: false
        });

        // Example options
        bytes memory options =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0).addExecutorLzComposeOption(0, 500_000, 0);

        //(uint256 tokenFee, ) = liquidityMigration.quote(BASE_EID);
        vm.recordLogs();
        MessagingReceipt memory receipt = liquidityMigration.migrateERC20Liquidity{value: 0.1 ether}(params, options);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // can make this more robust if needed
        (,, uint256 amountA, uint256 amountB) =
            abi.decode(_getMigrationEventData(entries), (address, address, uint256, uint256));

        bytes memory messageSent =
            abi.encode(params.l2TokenA, params.l2TokenB, amountA, amountB, user, params.poolType, params.stakeLPtokens);

        // Now switch to Base
        vm.selectFork(baseFork);

        // Simulate bridged tokens
        deal(params.l2TokenA, address(l2LiquidityManager), amountA);
        deal(params.l2TokenB, address(l2LiquidityManager), amountB);

        address executor = makeAddr("executor");

        Origin memory origin = Origin(ETH_EID, bytes32(uint256(uint160(address(liquidityMigration)))), receipt.nonce);

        uint256 wethBefore = base_WETH.balanceOf(user);
        uint256 usdcBefore = base_USDC.balanceOf(user);
        uint256 liqBefore = base_pool.balanceOf(user);

        vm.prank(endpointBase);
        l2LiquidityManager.lzReceive(origin, receipt.guid, messageSent, executor, "");

        (uint256 valueIn, uint256 valueOut) = print_results(amountA, amountB, wethBefore, usdcBefore, liqBefore, params);

        assertGt(valueOut, (valueIn * (10_000 - 50)) / 10_000); // allowing 0.5%
    }

    function test_old_migrateV3Liquidity() public {
        uint256[] memory tokenIds = new uint256[](5);

        tokenIds[0] = 777_460;
        tokenIds[1] = 777_461;
        tokenIds[2] = 777_805; // sell tokenB
        tokenIds[3] = 781_034; // sell tokenA
        tokenIds[4] = 781_470; // Single side

        for (uint256 i = 0; i < 5; i++) {
            _migrateV3Liquidity(tokenIds[i]);
        }
    }

    function _migrateV3Liquidity(uint256 tokenId) internal {
        vm.selectFork(ethFork);
        deal(address(WETH), user, 10e18);
        deal(address(USDC), user, 25_000e6);
        deal(user, 20 ether);

        // Transfer position from `owner` to `user`
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        vm.startPrank(owner);
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: owner,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        // Collect fees so out-of-range positions become single sided
        nonfungiblePositionManager.collect(collectParams);
        nonfungiblePositionManager.safeTransferFrom(owner, user, tokenId);
        vm.stopPrank();

        vm.startPrank(user);
        nonfungiblePositionManager.approve(address(liquidityMigration), tokenId);

        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: BASE_EID,
            tokenA: address(WETH),
            tokenB: address(USDC),
            l2TokenA: address(base_WETH),
            l2TokenB: address(base_USDC),
            liquidity: 0,
            tokenId: tokenId,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp,
            minGasLimit: 50_000,
            poolType: LiquidityMigration.PoolType(0),
            stakeLPtokens: false
        });

        // Example options
        bytes memory options =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0).addExecutorLzComposeOption(0, 500_000, 0);

        //(uint256 tokenFee, ) = liquidityMigration.quote(BASE_EID);
        vm.recordLogs();
        MessagingReceipt memory receipt = liquidityMigration.migrateERC20Liquidity{value: 0.1 ether}(params, options);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 amountA, uint256 amountB) =
            abi.decode(_getMigrationEventData(entries), (address, address, uint256, uint256));

        bytes memory messageSent =
            abi.encode(params.l2TokenA, params.l2TokenB, amountA, amountB, user, params.poolType, params.stakeLPtokens);

        // Now switch to Base
        vm.selectFork(baseFork);

        // Simulate bridged tokens
        deal(params.l2TokenA, address(l2LiquidityManager), amountA);
        deal(params.l2TokenB, address(l2LiquidityManager), amountB);

        address executor = makeAddr("executor");

        Origin memory origin = Origin(ETH_EID, bytes32(uint256(uint160(address(liquidityMigration)))), receipt.nonce);

        uint256 liqBefore = base_pool.balanceOf(user);
        uint256 wethBefore = base_WETH.balanceOf(user);
        uint256 usdcBefore = base_USDC.balanceOf(user);

        vm.prank(endpointBase);
        l2LiquidityManager.lzReceive(origin, receipt.guid, messageSent, executor, "");

        (uint256 valueIn, uint256 valueOut) = print_results(amountA, amountB, wethBefore, usdcBefore, liqBefore, params);

        assertGt(valueOut, (valueIn * (10_000 - 50)) / 10_000); // allowing 0.5%
            // FEES:
            // Migration fee (0.1%), Swap fee (0.3% of at most half of funds)
            // Worst case fees paid (If single sided, and swapping half of the liquidity) = 0.1% + 0.15% = 0.25%
    }

    function _addV2Liquidity(address _user) internal returns (uint256 lpTokens) {
        vm.startPrank(_user);
        WETH.approve(address(uniswapV2Router), type(uint256).max);
        USDC.approve(address(uniswapV2Router), type(uint256).max);

        uniswapV2Router.addLiquidity(address(WETH), address(USDC), 1e18, 2500e6, 0, 0, _user, block.timestamp);

        lpTokens = pool.balanceOf(_user);
    }

    function print_results(
        uint256 amountA,
        uint256 amountB,
        uint256 wethBefore,
        uint256 usdcBefore,
        uint256 liqBefore,
        LiquidityMigration.MigrationParams memory params
    ) internal view returns (uint256, uint256) {
        bool AisWeth = params.l2TokenA == address(base_WETH);

        uint256 liquidityProvided = base_pool.balanceOf(user) - liqBefore;

        uint256 usdcGain = base_USDC.balanceOf(user) - usdcBefore;
        uint256 wethGain = base_WETH.balanceOf(user) - wethBefore;

        (uint256 amountAOut, uint256 amountBOut) = IRouter(aerodromeRouter).quoteRemoveLiquidity(
            params.l2TokenA, params.l2TokenB, false, IRouter(aerodromeRouter).defaultFactory(), liquidityProvided
        );

        if (AisWeth) {
            amountAOut += wethGain;
            amountBOut += usdcGain;
        } else {
            amountAOut += usdcGain;
            amountBOut += wethGain;
        }

        console.log("amountAOut: %e", amountAOut);
        console.log("amountBOut: %e", amountBOut);

        console.log("amountAIn: %e", amountA);
        console.log("amountBIn: %e", amountB);

        uint256 valueIn;
        uint256 valueOut;

        uint256 amountA_converted = IPool(address(base_pool)).getAmountOut(amountA, params.l2TokenA);
        uint256 amountAOut_converted = IPool(address(base_pool)).getAmountOut(amountAOut, params.l2TokenA);

        valueIn = amountA_converted + amountB;
        valueOut = amountAOut_converted + amountBOut;

        console.log("valueIn: %e", valueIn);
        console.log("valueOut: %e", valueOut);

        return (valueIn, valueOut);
    }

    function _getMigrationEventData(Vm.Log[] memory entries) internal pure returns (bytes memory) {
        uint256 length = entries.length;
        for (uint256 i = 0; i < length; i++) {
            if (entries[i].topics[0] == LiquidityMigration.LiquidityRemoved.selector) {
                return entries[i].data;
            }
        }
    }
}

//////////////
//INTERFACES//
//////////////
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
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

    function approve(address to, uint256 tokenId) external;

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

    function ownerOf(uint256 tokenId) external returns (address);
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

interface IUniswapRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

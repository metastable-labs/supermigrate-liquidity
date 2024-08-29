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

import {IVoter} from "./test_interfaces/IVoter.sol";
import {StandardBridge} from "./test_interfaces/IStandardBridge.sol";
import {IUniswapRouter} from "./test_interfaces/IUniswapRouter.sol";

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Packet} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract BaseFork is Test {
    using OptionsBuilder for bytes;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant base_WETH = 0x4200000000000000000000000000000000000006;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant base_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant base_USDbC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;

    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant base_DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;

    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant base_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    ///Migrated tokens
    ERC20 public constant tokenP = ERC20(DAI);
    ERC20 public constant tokenQ = ERC20(USDC);

    // Set this appropriately based on the pair
    LiquidityMigration.PoolType public constant poolType = LiquidityMigration.PoolType.BASIC_STABLE;

    ERC20 public constant base_tokenP = ERC20(base_DAI);
    ERC20 public constant base_tokenQ = ERC20(base_USDC);

    // ETH CONTRACTS
    IUniswapV2Factory public constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapRouter public constant uniswapV2Router = IUniswapRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV3Factory public constant uniswapV3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    StandardBridge public constant l1StandardBridge = StandardBridge(0x3154Cf16ccdb4C6d922629664174b904d80F2C35); // base l1 standard bridge

    address pool;

    // BASE CONTRACTS
    address public base_gauge;
    IRouter public constant aerodromeRouter = IRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    address public constant swapRouterV3 = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    IVoter public constant voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    StandardBridge public constant l2StandardBridge = StandardBridge(0x4200000000000000000000000000000000000010);
    address public constant l2messenger = 0x4200000000000000000000000000000000000007;

    ERC20 base_pool;

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

    // Token decimals (10 ** decimals)
    uint256 pDec;
    uint256 qDec;

    mapping(address => L2LiquidityManager.PriceFeedData) public tokenToPriceFeedData;

    function setUp() public {
        ///////////////
        // L2 SETUP////
        ///////////////

        baseFork = vm.createSelectFork(vm.envString("BASE_RPC"));
        tokenToPriceFeedData[base_USDC] =
            L2LiquidityManager.PriceFeedData(AggregatorV3Interface(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B), 86_400); // usdc

        tokenToPriceFeedData[base_WETH] =
            L2LiquidityManager.PriceFeedData(AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), 1200); // weth

        tokenToPriceFeedData[base_DAI] =
            L2LiquidityManager.PriceFeedData(AggregatorV3Interface(0x591e79239a7d679378eC8c847e5038150364C78F), 86_400); // dai

        address defaultFactory = aerodromeRouter.defaultFactory();

        base_pool = ERC20(
            aerodromeRouter.poolFor(
                address(base_tokenP),
                address(base_tokenQ),
                poolType == LiquidityMigration.PoolType.BASIC_STABLE,
                defaultFactory
            )
        );

        vm.makePersistent(address(base_pool));

        if (address(base_pool) == address(0)) {
            revert("The aero pool does not exist");
        }

        pDec = 10 ** base_tokenP.decimals();
        qDec = 10 ** base_tokenQ.decimals();

        base_gauge = voter.gauges(address(base_pool));

        delegate = makeAddr("delegate");
        feeReceiver = makeAddr("feeReceiver");

        l2LiquidityManager = new L2LiquidityManager(
            address(aerodromeRouter), swapRouterV3, feeReceiver, MIGRATION_FEE, endpointBase, delegate
        );

        ///////////////
        // L1 SETUP////
        ///////////////
        ethFork = vm.createSelectFork(vm.envString("ETH_RPC"));

        pool = uniswapV2Factory.getPair(address(tokenP), address(tokenQ));
        if (pool == address(0)) {
            console.log("The univ2 pool does not exist");

            //////////////////////
            uint16[3] memory fees = [500, 3000, 10_000];
            for (uint256 i = 0; i < fees.length; i++) {
                address tempPool = uniswapV3Factory.getPool(address(tokenP), address(tokenQ), fees[i]);
                if (tempPool != address(0)) {
                    pool = tempPool;
                }
            }
            /////////////////////////////
        }
        if (pool == address(0)) revert("NO UNIV2 or UNIV3 POOL");
        vm.makePersistent(pool);
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

        L2LiquidityManager.PriceFeedData memory a = tokenToPriceFeedData[address(base_tokenP)];
        L2LiquidityManager.PriceFeedData memory b = tokenToPriceFeedData[address(base_tokenQ)];

        L2LiquidityManager.PoolType pType = L2LiquidityManager.PoolType(uint256(poolType));

        l2LiquidityManager.setPool(
            address(base_tokenP), address(base_tokenQ), pType, address(base_pool), base_gauge, a, b
        );

        vm.stopPrank();

        vm.label(address(l2LiquidityManager), "l2LiquidityManager");
        vm.label(user, "user");
    }

    function print_results(
        uint256 amountA,
        uint256 amountB,
        uint256 tokenPBefore,
        uint256 tokenQBefore,
        uint256 liqBefore,
        LiquidityMigration.MigrationParams memory params
    ) internal view returns (uint256, uint256) {
        bool AisTokenP = params.l2TokenA == address(base_tokenP);

        uint256 liquidityProvided = base_pool.balanceOf(user) - liqBefore;

        uint256 tokenQGain = base_tokenQ.balanceOf(user) - tokenQBefore;
        uint256 tokenPGain = base_tokenP.balanceOf(user) - tokenPBefore;

        (uint256 amountAOut, uint256 amountBOut) = aerodromeRouter.quoteRemoveLiquidity(
            params.l2TokenA,
            params.l2TokenB,
            poolType == LiquidityMigration.PoolType.BASIC_STABLE,
            aerodromeRouter.defaultFactory(),
            liquidityProvided
        );

        if (AisTokenP) {
            amountAOut += tokenPGain;
            amountBOut += tokenQGain;
        } else {
            amountAOut += tokenQGain;
            amountBOut += tokenPGain;
        }
        console.log("amountAIn: %e", amountA);
        console.log("amountBIn: %e", amountB);

        console.log("amountAOut: %e", amountAOut);
        console.log("amountBOut: %e", amountBOut);

        uint256 valueIn;
        uint256 valueOut;

        uint256 amountA_converted = IPool(address(base_pool)).getAmountOut(amountA, params.l2TokenA);
        uint256 amountAOut_converted = IPool(address(base_pool)).getAmountOut(amountAOut, params.l2TokenA);

        valueIn = amountA_converted + amountB;
        valueOut = amountAOut_converted + amountBOut;

        console.log("valueIn: %e (%s)", valueIn, IERC20Metadata(params.l2TokenB).symbol());
        console.log("valueOut: %e (%s)", valueOut, IERC20Metadata(params.l2TokenB).symbol());

        return (valueIn, valueOut);
    }

    function _getWithdrawLiquidityData(Vm.Log[] memory entries) internal pure returns (bytes memory) {
        uint256 length = entries.length;
        for (uint256 i = 0; i < length; i++) {
            if (entries[i].topics[0] == LiquidityMigration.LiquidityRemoved.selector) {
                return entries[i].data;
            }
        }
    }

    function _getBridgeEventData(Vm.Log[] memory entries) internal pure returns (bytes memory) {
        uint256 length = entries.length;
        for (uint256 i = 0; i < length; i++) {
            if (entries[i].topics[0] == StandardBridge.ERC20BridgeInitiated.selector) {
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

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    function ownerOf(uint256 tokenId) external returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

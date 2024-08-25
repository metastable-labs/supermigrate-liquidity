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
import {ICLFactory} from "./test_interfaces/ICLFactory.sol";

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Packet} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {INonfungiblePositionManager} from "src/interfaces/slipstream/INonfungiblePositionManager.sol";
import {ICLPool} from "src/interfaces/slipstream/ICLPool.sol";

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
    ERC20 public tokenP = ERC20(WETH);
    ERC20 public tokenQ = ERC20(USDC);

    // Set this appropriately based on the pair
    LiquidityMigration.PoolType public poolType = LiquidityMigration.PoolType.CONCENTRATED_VOLATILE;

    ERC20 public base_tokenP = ERC20(base_WETH);
    ERC20 public base_tokenQ = ERC20(base_USDC);

    StandardBridge public constant l1StandardBridge = StandardBridge(0x3154Cf16ccdb4C6d922629664174b904d80F2C35); // base l1 standard bridge

    address pool;

    // BASE CONTRACTS
    address public base_gauge;
    IRouter public constant aerodromeRouter = IRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    address public constant swapRouterV3 = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    IVoter public constant voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    StandardBridge public constant l2StandardBridge = StandardBridge(0x4200000000000000000000000000000000000010);
    address public constant l2messenger = 0x4200000000000000000000000000000000000007;
    ICLFactory clFactory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    INonfungiblePositionManager public constant nftPositionManager =
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

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

        int24 tickSpacing = (poolType == LiquidityMigration.PoolType.CONCENTRATED_STABLE) ? int24(1) : int24(100);
        if (
            poolType == LiquidityMigration.PoolType.BASIC_STABLE
                || poolType == LiquidityMigration.PoolType.BASIC_VOLATILE
        ) {
            base_pool = ERC20(
                aerodromeRouter.poolFor(
                    address(base_tokenP),
                    address(base_tokenQ),
                    poolType == LiquidityMigration.PoolType.BASIC_STABLE,
                    defaultFactory
                )
            );
        } else {
            base_pool = ERC20(clFactory.getPool(address(base_tokenP), address(base_tokenQ), tickSpacing));
        }

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

        ////////////////
        // L2 CONFIG////
        ////////////////
        liquidityMigration = LiquidityMigration(payable(address(1)));
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

    function test_depositConcentratedLiquidity() public {
        uint256 amountP;
        uint256 amountQ;

        if (address(tokenP) == WETH) {
            // P is WETH, Q is stable
            amountP = 10 * pDec;
            amountQ = 30_000 * qDec;
        } else if (address(tokenQ) == WETH) {
            // Q is WETH, P is stable
            // P is stable
            amountP = 25_000 * pDec;

            // Q is WETH
            amountQ = 10 * qDec;
        } else {
            // both are stable
            amountP = 25_000 * pDec;
            amountQ = 25_000 * qDec;
        }

        // migration params
        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: BASE_EID,
            tokenA: address(tokenP),
            tokenB: address(tokenQ),
            l2TokenA: address(base_tokenP),
            l2TokenB: address(base_tokenQ),
            liquidity: 0, // not needed for this test
            tokenId: 0, // not needed for this test
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp,
            minGasLimit: 50_000,
            poolType: poolType
        });

        vm.store(l2messenger, bytes32(uint256(204)), bytes32(uint256(uint160(address(l1StandardBridge)))));
        bytes memory messageSent = abi.encode(params.l2TokenA, params.l2TokenB, amountP, amountQ, user, params.poolType);

        address l2TokenA = params.l2TokenA;
        address l2TokenB = params.l2TokenB;
        // Set L2 tokens for bridging
        if (params.l2TokenA == base_WETH) {
            l2TokenA = address(0);
        } else if (params.l2TokenB == base_WETH) {
            l2TokenB = address(0);
        }
        // Sanity check for USDC
        if (params.tokenA == USDC) {
            l2TokenA = base_USDbC;
        } else if (params.tokenB == USDC) {
            l2TokenB = base_USDbC;
        }

        vm.startPrank(l2messenger);
        if (address(base_tokenP) == base_WETH) {
            deal(l2messenger, amountP);

            l2StandardBridge.finalizeBridgeETH{value: amountP}(
                address(liquidityMigration), address(l2LiquidityManager), amountP, ""
            );
        } else {
            l2StandardBridge.finalizeBridgeERC20(
                address(l2TokenA),
                address(tokenP),
                address(liquidityMigration),
                address(l2LiquidityManager),
                amountP,
                ""
            );
        }

        if (address(base_tokenQ) == base_WETH) {
            deal(l2messenger, amountQ);

            l2StandardBridge.finalizeBridgeETH{value: amountQ}(
                address(liquidityMigration), address(l2LiquidityManager), amountQ, ""
            );
        } else {
            l2StandardBridge.finalizeBridgeERC20(
                address(l2TokenB),
                address(tokenQ),
                address(liquidityMigration),
                address(l2LiquidityManager),
                amountQ,
                ""
            );
        }
        vm.stopPrank();

        address executor = makeAddr("executor");

        Origin memory origin = Origin(ETH_EID, bytes32(uint256(uint160(address(liquidityMigration)))), 312);

        uint256 tokenPBefore = base_tokenP.balanceOf(user);
        uint256 tokenQBefore = base_tokenQ.balanceOf(user);

        vm.recordLogs();

        vm.prank(endpointBase);
        l2LiquidityManager.lzReceive(origin, 0, messageSent, executor, "");

        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenId) = abi.decode(_getTokenIdMinted(entries), (address, uint256));

        (uint256 valueIn, uint256 valueOut) =
            print_results_slipstream(amountP, amountQ, tokenPBefore, tokenQBefore, 0, tokenId, params);

        assertGt(valueOut, valueIn * (10_000 - 50) / 10_000); // allowing 0.5%
    }

    function print_results_slipstream(
        uint256 amountA,
        uint256 amountB,
        uint256 tokenPBefore,
        uint256 tokenQBefore,
        uint256 liqBefore,
        uint256 tokenId,
        LiquidityMigration.MigrationParams memory params
    ) internal returns (uint256, uint256) {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidityProvided,,,,) = nftPositionManager.positions(tokenId);

        ICLPool basePool = ICLPool(address(base_pool));
        (uint256 amountAOut, uint256 amountBOut) = basePool.burn(tickLower, tickUpper, liquidityProvided);

        console.log("amountAOut: %e", amountAOut);
        console.log("amountBOut: %e", amountBOut);
        return (amountAOut, amountBOut);
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

    function _getTokenIdMinted(Vm.Log[] memory entries) internal pure returns (bytes memory) {
        uint256 length = entries.length;
        for (uint256 i = 0; i < length; i++) {
            if (entries[i].topics[0] == L2LiquidityManager.NFTPositionMinted.selector) {
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

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

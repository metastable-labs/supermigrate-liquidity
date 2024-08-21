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
import {BaseFork} from "./BaseFork.t.sol";

contract V2Test is BaseFork {
    using OptionsBuilder for bytes;

    function test_migrateV2Liquidity() public {
        vm.selectFork(ethFork);
        deal(address(tokenP), user, 100 * pDec);
        deal(address(tokenQ), user, 250 * qDec);
        deal(user, 20 ether);

        uint256 lpTokens = _addV2Liquidity(user);

        ERC20(pool).approve(address(liquidityMigration), ERC20(pool).balanceOf(user));

        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: BASE_EID,
            tokenA: address(tokenP),
            tokenB: address(tokenQ),
            l2TokenA: address(base_tokenP),
            l2TokenB: address(base_tokenQ),
            liquidity: lpTokens / 5,
            tokenId: 0,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp,
            minGasLimit: 50_000,
            poolType: LiquidityMigration.PoolType(stable ? 1 : 0),
            stakeLPtokens: false
        });

        // Example options
        bytes memory options =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0).addExecutorLzComposeOption(0, 500_000, 0);

        vm.recordLogs();
        MessagingReceipt memory receipt = liquidityMigration.migrateERC20Liquidity{value: 0.1 ether}(params, options);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 amountA, uint256 amountB) =
            abi.decode(_getWithdrawLiquidityData(entries), (address, address, uint256, uint256));

       

        bytes memory messageSent =
            abi.encode(params.l2TokenA, params.l2TokenB, amountA, amountB, user, params.poolType, params.stakeLPtokens);

        // Now switch to Base
        vm.selectFork(baseFork);

        // Simulate bridged tokens
        vm.store(l2messenger, bytes32(uint256(204)), bytes32(uint256(uint160(address(l1StandardBridge)))));

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
            deal(l2messenger, amountA);

            l2StandardBridge.finalizeBridgeETH{value: amountA}(
                address(liquidityMigration), address(l2LiquidityManager), amountA, ""
            );
        } else {
            l2StandardBridge.finalizeBridgeERC20(
                address(l2TokenA),
                address(tokenP),
                address(liquidityMigration),
                address(l2LiquidityManager),
                amountA,
                ""
            );
        }

        if (address(base_tokenQ) == base_WETH) {
            deal(l2messenger, amountB);

            l2StandardBridge.finalizeBridgeETH{value: amountB}(
                address(liquidityMigration), address(l2LiquidityManager), amountB, ""
            );
        } else {
            l2StandardBridge.finalizeBridgeERC20(
                address(l2TokenB),
                address(tokenQ),
                address(liquidityMigration),
                address(l2LiquidityManager),
                amountB,
                ""
            );
        }
        vm.stopPrank();

        address executor = makeAddr("executor");

        Origin memory origin = Origin(ETH_EID, bytes32(uint256(uint160(address(liquidityMigration)))), receipt.nonce);

        uint256 tokenPBefore = base_tokenP.balanceOf(user);
        uint256 tokenQBefore = base_tokenQ.balanceOf(user);
        console.log("chain id is: ", block.chainid);
        uint256 liqBefore = base_pool.balanceOf(user);

        vm.prank(endpointBase);
        l2LiquidityManager.lzReceive(origin, receipt.guid, messageSent, executor, "");

        (uint256 valueIn, uint256 valueOut) =
            print_results(amountA, amountB, tokenPBefore, tokenQBefore, liqBefore, params);

        assertGt(valueOut, valueIn * (10_000 - 50) / 10_000); // allowing 0.5%
    }

    function test_getPrice() public {
        console.log("price is %e", l2LiquidityManager._combinePriceFeeds(address(base_tokenP), address(base_tokenQ)));
        l2LiquidityManager._checkPriceRatio(address(base_tokenP), address(base_tokenQ), stable);
    }


    function _addV2Liquidity(address _user) internal returns (uint256 lpTokens) {
        vm.startPrank(_user);
        tokenP.approve(address(uniswapV2Router), type(uint256).max);
        tokenQ.approve(address(uniswapV2Router), type(uint256).max);

        uniswapV2Router.addLiquidity(
            address(tokenP), address(tokenQ), 100 * pDec, 100 * qDec, 0, 0, _user, block.timestamp
        );

        lpTokens = ERC20(pool).balanceOf(_user);
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

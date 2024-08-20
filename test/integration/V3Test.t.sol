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
import { Packet } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";

import {BaseFork, INonfungiblePositionManager} from "./BaseFork.t.sol";
contract V3Test is BaseFork {
    using OptionsBuilder for bytes;

    function test_migrateV3Liquidity() public {
        uint256[] memory tokenIds = new uint256[](5);

        tokenIds[0] = 777_460;
        tokenIds[1] = 777_461; // USDC/WETH
        tokenIds[2] = 777_805; // sell tokenB
        tokenIds[3] = 781_034; // sell tokenA
        tokenIds[4] = 781_470; // Single side

        // DAI/USDC
        tokenIds[0] = 387_362;

        for (uint256 i = 1; i < 2; i++) {
            _migrateV3Liquidity(tokenIds[i]);
        }
    }

    function _migrateV3Liquidity(uint256 tokenId) internal {
        vm.selectFork(ethFork);
        deal(address(tokenP), user, 10e18);
        deal(address(tokenQ), user, 25_000e6);
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

        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);

        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: BASE_EID,
            tokenA: address(tokenP),
            tokenB: address(tokenQ),
            l2TokenA: address(base_tokenP),
            l2TokenB: address(base_tokenQ),
            liquidity: liquidity, // entire liquidity
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

        vm.recordLogs();
        MessagingReceipt memory receipt = liquidityMigration.migrateERC20Liquidity{value: 0.1 ether}(params, options);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();

        (,, uint256 amountA, uint256 amountB) =
            abi.decode(_getWithdrawLiquidityData(entries), (address, address, uint256, uint256));

        bytes memory messageSent = abi.encode(params.l2TokenA, params.l2TokenB, amountA, amountB, user, params.poolType, params.stakeLPtokens);

        // Now switch to Base
        vm.selectFork(baseFork);

        vm.store(l2messenger, bytes32(uint256(204)), bytes32(uint256(uint160(address(l1StandardBridge)))));

        address l2TokenA;
        address l2TokenB;
        // Set L2 tokens for bridging
        if (params.l2TokenA == base_WETH) {
            l2TokenA = address(0);
        } else if (params.l2TokenB == base_WETH) {
            l2TokenB = address(0);
        }
        // Sanity check for USDC
        if (params.tokenA == USDC) {
            l2TokenA = base_USDbC;
        }
        else if (params.tokenB == USDC) {
            l2TokenB = base_USDbC;
        }

        vm.startPrank(l2messenger);
        if (address(base_tokenP) == base_WETH) {
            deal(l2messenger, amountA);

            l2StandardBridge.finalizeBridgeETH{value: amountA}(
                address(liquidityMigration), address(l2LiquidityManager), amountA, ""
            );
        } 
        else {
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
        } 
        else {
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

        uint256 liqBefore = base_pool.balanceOf(user);
        uint256 tokenPBefore = base_tokenP.balanceOf(user);
        uint256 tokenQBefore = base_tokenQ.balanceOf(user);

        vm.prank(endpointBase);
        l2LiquidityManager.lzReceive(origin, receipt.guid, messageSent, executor, "");

        (uint256 valueIn, uint256 valueOut) =
            print_results(amountA, amountB, tokenPBefore, tokenQBefore, liqBefore, params);

        assertGt(valueOut, valueIn * (10_000 - 50) / 10_000); // allowing 0.5%
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

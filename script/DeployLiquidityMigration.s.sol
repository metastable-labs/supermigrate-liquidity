// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "../src/LiquidityMigration.sol";

contract DeployLiquidityMigration is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address lzEndpointL1 = 0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675; // LayerZero Ethereum Mainnet Endpoint
        address delegate = vm.addr(deployerPrivateKey);
        address uniswapV2Factory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
        address uniswapV2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        address uniswapV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
        address nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        address l1StandardBridge = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1; // Optimism's L1 Standard Bridge

        // Read existing deployment info
        string memory existingInfo = vm.readFile("./deployment-addresses.json");
        address liquidityManagerAddress = existingInfo.readAddress(".L2LiquidityManager");

        LiquidityMigration liquidityMigration = new LiquidityMigration(
            lzEndpointL1,
            delegate,
            uniswapV2Factory,
            uniswapV2Router,
            uniswapV3Factory,
            nonfungiblePositionManager,
            l1StandardBridge,
            liquidityManagerAddress
        );

        vm.stopBroadcast();

        console.log("LiquidityMigration deployed to:", address(liquidityMigration));

        // Write deployment info to JSON file
        string memory deploymentInfo =
            vm.serializeAddress("deployment", "LiquidityMigration", address(liquidityMigration));
        vm.writeJson(deploymentInfo, "./deployment-addresses.json");
    }
}

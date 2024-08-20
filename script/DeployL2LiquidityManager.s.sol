// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/modules/L2LiquidityManager.sol";

contract DeployL2LiquidityManager is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address lzEndpointL2 = 0x3c2269811836af69497E5F486A85D7316753cf62; // LayerZero Base Mainnet Endpoint
        address aerodromeRouter = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43; // Aerodrome Router on Base
        address swapRouterV3 = 0x2626664c2603336E57B271c5C0b26F421741e481; // Aerodrome V3 Router on Base
        address feeReceiver = vm.addr(deployerPrivateKey); // Set fee receiver to the deployer, will be changed later
        uint256 migrationFee = 50; // 0.5% fee (50 / 10000)

        L2LiquidityManager l2LiquidityManager = new L2LiquidityManager(
            aerodromeRouter, swapRouterV3, feeReceiver, migrationFee, lzEndpointL2, vm.addr(deployerPrivateKey)
        );

        vm.stopBroadcast();

        console.log("L2LiquidityManager deployed to:", address(l2LiquidityManager));
        // Read existing deployment info
        string memory existingInfo = vm.readFile("./deployment-addresses.json");

        // Update with new deployment info
        string memory updatedInfo = vm.serializeAddress("deployment", "L2LiquidityManager", address(l2LiquidityManager));
        vm.writeJson(updatedInfo, "./deployment-addresses.json");
    }
}

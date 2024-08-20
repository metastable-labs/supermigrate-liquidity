// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/modules/L2LiquidityManager.sol";

contract SetupTrustedRemoteBase is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Read deployment addresses from JSON file
        string memory json = vm.readFile("./deployment-addresses.json");
        address liquidityMigrationAddress = abi.decode(vm.parseJson(json, ".LiquidityMigration"), (address));
        address l2LiquidityManagerAddress = abi.decode(vm.parseJson(json, ".L2LiquidityManager"), (address));

        uint16 ETHEREUM_EID = 30_101;

        vm.startBroadcast(deployerPrivateKey);

        L2LiquidityManager l2LiquidityManager = L2LiquidityManager(l2LiquidityManagerAddress);

        bytes memory remoteAndLocalAddresses = abi.encodePacked(liquidityMigrationAddress, l2LiquidityManagerAddress);
        l2LiquidityManager.setTrustedRemote(ETHEREUM_EID, remoteAndLocalAddresses);

        vm.stopBroadcast();

        console.log("Trusted remote setup completed on Base");
        console.log("L2LiquidityManager address:", l2LiquidityManagerAddress);
        console.log("LiquidityMigration address set:", liquidityMigrationAddress);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LiquidityMigration.sol";

contract SetupETH is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Read deployment addresses from JSON file
        string memory json = vm.readFile("./deployment-addresses.json");
        address liquidityMigrationAddress = abi.decode(vm.parseJson(json, ".LiquidityMigration"), (address));
        address l2LiquidityManagerAddress = abi.decode(vm.parseJson(json, ".L2LiquidityManager"), (address));

        uint16 BASE_EID = 30_184;

        vm.startBroadcast(deployerPrivateKey);

        LiquidityMigration liquidityMigration = LiquidityMigration(liquidityMigrationAddress);

        bytes memory remoteAndLocalAddresses = abi.encodePacked(l2LiquidityManagerAddress, liquidityMigrationAddress);
        liquidityMigration.setTrustedRemote(BASE_EID, remoteAndLocalAddresses);

        liquidityMigration.setL2LiquidityManager(l2LiquidityManagerAddress);

        vm.stopBroadcast();

        console.log("Trusted remote setup completed on Ethereum");
        console.log("LiquidityMigration address:", liquidityMigrationAddress);
        console.log("L2LiquidityManager address set:", l2LiquidityManagerAddress);
    }
}

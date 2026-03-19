// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LeanSwapRouter} from "../src/TestSwapRouter.sol";

contract DeployTestnet is Script {
    IPoolManager manager;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);

        manager = IPoolManager(poolManager);

        vm.startBroadcast(deployerPrivateKey);

        LeanSwapRouter router = new LeanSwapRouter(manager);
        console.log("Router deployed at:", address(router));

        vm.stopBroadcast();
    }
}

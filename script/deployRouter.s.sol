// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LeanSwapRouter} from "../src/LeanSwapRouter.sol";
import {IPermit2} from "v4-hooks-public/lib/briefcase/src/protocols/permit2/interfaces/IPermit2.sol";

contract DeployTestnet is Script {
    IPoolManager manager;
    IPermit2 permit2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        address permit2Address = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        manager = IPoolManager(poolManager);
        permit2 = IPermit2(permit2Address);

        vm.startBroadcast(deployerPrivateKey);

        LeanSwapRouter router = new LeanSwapRouter(manager, permit2);
        console.log("Router deployed at:", address(router));

        vm.stopBroadcast();
    }
}

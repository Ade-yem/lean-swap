// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {LeanSwapReactive} from "../src/LeanSwapReactive.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployReactiveSmartContract is Script {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address reactiveSystemContract = address(0x0000000000000000000000000000000000fffFfF);
    uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(block.chainid));
    uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(block.chainid));
    address hookAddress = vm.envAddress("HOOK_ADDRESS");
    uint256 orderCreatedTopic0 =
        uint256(keccak256("SwapOrderCreated((address,address,uint24,int24,address),bool,uint256,uint256,uint256)"));
    uint256 orderSettledTopic0 =
        uint256(keccak256("SwapOrderSettled((address,address,uint24,int24,address),bool,uint256,uint256)"));
    uint256 orderDeadlineTopic0 = uint256(
        keccak256("SwapOrderDeadlineExceededSettled(address,(address,address,uint24,int24,address),uint256,uint256)")
    );

    function run() external {
        vm.startBroadcast(deployerPrivateKey);
        LeanSwapReactive leanSwapReactive = new LeanSwapReactive{value: msg.sender.balance > 0.1 ether ? 0.1 ether : 0}(
            reactiveSystemContract,
            originChainId,
            destChainId,
            hookAddress,
            orderCreatedTopic0,
            orderSettledTopic0,
            orderDeadlineTopic0,
            hookAddress, // callback is the hook itself
            10 // minOrderAmount
        );
        console.log("LeanSwapReactive deployed at:", address(leanSwapReactive));

        // 6. Set RSC address in Hook
        // leanSwap.setRscAddress(address(leanSwapReactive));
        // console.log("LeanSwap hook RSC address updated.");
        vm.stopBroadcast();
    }
}

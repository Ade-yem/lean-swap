// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {LeanSwapReactive} from "../src/LeanSwapReactive.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-hooks-public/src/utils/HookMiner.sol";

contract DeployHook is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        address create2Deployer = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        address reactiveService = address(0x0000000000000000000000000000000000fffFfF);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, reactiveService);
        (address hookAddress, bytes32 salt) = HookMiner.find(create2Deployer, flags, type(LeanSwap).creationCode, constructorArgs);

        vm.startBroadcast(deployerPrivateKey);

        LeanSwap leanSwap = new LeanSwap{salt: salt}(IPoolManager(poolManager), reactiveService);

        console.log("Calculated LeanSwap Hook address:", hookAddress);
        console.log("LeanSwap Hook deployed at:", address(leanSwap));
        require(address(leanSwap) == hookAddress, "Hook address mismatch");
        vm.stopBroadcast();
    }
}

contract DeployReactive is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Configuration
        address reactiveSystemContract = vm.envAddress("REACTIVE_SYSTEM_CONTRACT");
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        address leanSwapAddress = vm.envAddress("LEAN_SWAP_ADDRESS");

        // Event signatures
        // SwapOrderCreated(PoolKey poolKey, bool zeroForOne, uint256 deadline, uint256 orderId, uint256 amountIn)
        uint256 orderCreatedTopic0 =
            uint256(keccak256("SwapOrderCreated((address,address,uint24,int24,address),bool,uint256,uint256,uint256)"));

        // SwapOrderSettled(PoolKey poolKey, bool zeroForOne, uint256 amountOut, uint256 orderId)
        uint256 orderSettledTopic0 =
            uint256(keccak256("SwapOrderSettled((address,address,uint24,int24,address),bool,uint256,uint256)"));

        // SwapOrderDeadlineExceededSettled(address owner, PoolKey poolKey, uint256 amount, uint256 orderId)
        uint256 orderDeadlineTopic0 = uint256(
            keccak256(
                "SwapOrderDeadlineExceededSettled(address,(address,address,uint24,int24,address),uint256,uint256)"
            )
        );

        vm.startBroadcast(deployerPrivateKey);

        LeanSwapReactive leanSwapReactive = new LeanSwapReactive{value: 0.1 ether}(
            reactiveSystemContract,
            originChainId,
            destChainId,
            leanSwapAddress,
            orderCreatedTopic0,
            orderSettledTopic0,
            orderDeadlineTopic0,
            leanSwapAddress // callback is the hook itself
        );

        console.log("LeanSwapReactive deployed at:", address(leanSwapReactive));

        vm.stopBroadcast();
    }
}

contract SetupHook is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address leanSwapAddress = vm.envAddress("LEAN_SWAP_ADDRESS");
        address reactiveContractAddress = vm.envAddress("REACTIVE_CONTRACT_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        LeanSwap(payable(leanSwapAddress)).setRscAddress(reactiveContractAddress);

        console.log("LeanSwap hook updated with RSC address:", reactiveContractAddress);

        vm.stopBroadcast();
    }
}

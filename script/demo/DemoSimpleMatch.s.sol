// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwapLibrary} from "../../src/Library.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouter {
    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, uint256 amountIn) external payable returns (int256 delta0, int256 delta1);
}

contract DemoSimpleMatch is Script {
    // Addresses from deployment logs
    address constant HOOK_ADDRESS = 0x605167C336F499D47031001Db4c8AC4299140088;
    address constant ROUTER_ADDRESS = 0x47e943dA37E94CAC11DD504534A585d30555E941;
    address constant tETH = 0x568933d38886b2aA8A2165dAfDcE7D017388637C;
    address constant tUSDC = 0x69421BB202C3514384DCb5053DCDc3FD591e4507;
    
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function run() external {
        uint256 pkA = vm.envUint("USER_A_PK");
        uint256 pkB = vm.envUint("USER_B_PK");
        address userA = vm.addr(pkA);
        address userB = vm.addr(pkB);

        // tETH < tUSDC (by address sorting)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tETH),
            currency1: Currency.wrap(tUSDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // 100 units (Using small amount to accommodate potential decimals mismatch)
        uint256 amountIn = 100 * 10**6; 
        uint256 deadline = block.timestamp + 1 hours;

        // --- USER A: Sell tETH for tUSDC ---
        vm.startBroadcast(pkA);
        IERC20(tETH).approve(ROUTER_ADDRESS, type(uint256).max);
        IERC20(tETH).approve(HOOK_ADDRESS, type(uint256).max);
        bytes memory hookDataA = LeanSwapLibrary.encodeHookData(deadline, true, userA); // useCoW = true
        IRouter(ROUTER_ADDRESS).swap(
            key,
            SwapParams({
                zeroForOne: true, // tETH is currency0
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookDataA,
            amountIn
        );
        vm.stopBroadcast();

        // --- USER B: Sell tUSDC for tETH ---
        vm.startBroadcast(pkB);
        IERC20(tUSDC).approve(ROUTER_ADDRESS, type(uint256).max);
        IERC20(tUSDC).approve(HOOK_ADDRESS, type(uint256).max);
        bytes memory hookDataB = LeanSwapLibrary.encodeHookData(deadline, true, userB);
        IRouter(ROUTER_ADDRESS).swap(
            key,
            SwapParams({
                zeroForOne: false, // tUSDC is currency1
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            hookDataB,
            amountIn
        );
        vm.stopBroadcast();
    }
}
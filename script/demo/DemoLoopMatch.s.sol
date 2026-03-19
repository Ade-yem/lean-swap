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

contract DemoLoopMatch is Script {
    address constant HOOK_ADDRESS = 0x605167C336F499D47031001Db4c8AC4299140088;
    address constant ROUTER_ADDRESS = 0x47e943dA37E94CAC11DD504534A585d30555E941;
    
    // Tokens
    address constant tETH = 0x568933d38886b2aA8A2165dAfDcE7D017388637C;
    address constant tUSDC = 0x69421BB202C3514384DCb5053DCDc3FD591e4507;
    address constant tDAI = 0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function run() external {
        uint256 pkA = vm.envUint("USER_A_PK");
        uint256 pkB = vm.envUint("USER_B_PK");
        uint256 pkC = vm.envUint("USER_C_PK");

        address userA = vm.addr(pkA);
        address userB = vm.addr(pkB);
        address userC = vm.addr(pkC);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 amountIn = 100 * 10**6; 

        // Pool 1: tETH/tUSDC (User A sells tETH for tUSDC)
        PoolKey memory keyEthUsdc = PoolKey(Currency.wrap(tETH), Currency.wrap(tUSDC), FEE, TICK_SPACING, IHooks(HOOK_ADDRESS));
        
        // Pool 2: tUSDC/tDAI (User B sells tUSDC for tDAI) -> tUSDC < tDAI
        PoolKey memory keyUsdcDai = PoolKey(Currency.wrap(tUSDC), Currency.wrap(tDAI), FEE, TICK_SPACING, IHooks(HOOK_ADDRESS));
        
        // Pool 3: tETH/tDAI (User C sells tDAI for tETH) -> tETH < tDAI
        PoolKey memory keyEthDai = PoolKey(Currency.wrap(tETH), Currency.wrap(tDAI), FEE, TICK_SPACING, IHooks(HOOK_ADDRESS));

        // --- USER A: Sell tETH for tUSDC ---
        vm.startBroadcast(pkA);
        IERC20(tETH).approve(ROUTER_ADDRESS, type(uint256).max);
        IERC20(tETH).approve(HOOK_ADDRESS, type(uint256).max);
        IRouter(ROUTER_ADDRESS).swap(
            keyEthUsdc,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            LeanSwapLibrary.encodeHookData(deadline, true, userA),
            amountIn
        );
        vm.stopBroadcast();

        // --- USER B: Sell tUSDC for tDAI ---
        vm.startBroadcast(pkB);
        IERC20(tUSDC).approve(ROUTER_ADDRESS, type(uint256).max);
        IERC20(tUSDC).approve(HOOK_ADDRESS, type(uint256).max);
        IRouter(ROUTER_ADDRESS).swap(
            keyUsdcDai,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            LeanSwapLibrary.encodeHookData(deadline, true, userB),
            amountIn
        );
        vm.stopBroadcast();

        // --- USER C: Sell tDAI for tETH ---
        vm.startBroadcast(pkC);
        IERC20(tDAI).approve(ROUTER_ADDRESS, type(uint256).max);
        IERC20(tDAI).approve(HOOK_ADDRESS, type(uint256).max);
        IRouter(ROUTER_ADDRESS).swap(
            keyEthDai,
            SwapParams({ zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }),
            LeanSwapLibrary.encodeHookData(deadline, true, userC),
            amountIn
        );
        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LeanSwapRouter} from "../src/TestSwapRouter.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LeanSwapLibrary} from "../src/Library.sol";
import {TestnetToken} from "../src/TestnetToken.sol";
contract TestPool is Script {
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    
    // Token Addresses
    address constant tUSDC = 0x69421BB202C3514384DCb5053DCDc3FD591e4507;
    address constant tDAI  = 0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec;
    address constant tLEAN = 0x18754e7c697A6DB8afC0BF963692f53c2719453f;
    address constant tETH  = 0x568933d38886b2aA8A2165dAfDcE7D017388637C;
    address constant tCOW  = 0xFF02F80E373317b778a1335808ddEFD1FC448227;
    address constant router = 0x2E297061451a5B83748Cdf14025dcf86553b9f38;
    address constant poolManagerAddr = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address hookAddress = 0x605167C336F499D47031001Db4c8AC4299140088;
    LeanSwapRouter immutable leanSwapRouter = LeanSwapRouter(router);
    LeanSwap immutable leanSwap = LeanSwap(payable(hookAddress));
    // LeanSwapRouter immutable leanSwap = LeanSwapRouter(payable(0x605167C336F499D47031001Db4c8AC4299140088));

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        manager = IPoolManager(poolManagerAddr);

        console.log("--- STARTING MULTI-POOL QUOTES ---");

        // 1. ETH / USDC (18 vs 6 decimals)
        runSwap("ETH/USDC", tETH, tUSDC, 1 ether, deployer);

        // 2. ETH / DAI (18 vs 18 decimals)
        runSwap("ETH/DAI", tETH, tDAI, 1 ether, deployer);

        // 3. USDC / DAI (6 vs 18 decimals)
        runSwap("USDC/DAI", tUSDC, tDAI, 10 * 1e6, deployer);

        // 4. COW / LEAN (18 vs 18 decimals)
        runSwap("COW/LEAN", tCOW, tLEAN, 1 ether, deployer);

        // 5. USDC / COW (6 vs 18 decimals)
        runSwap("USDC/COW", tUSDC, tCOW, 10 * 1e6, deployer);
    }

    /**
     * @dev Internal helper to fetch pool state and perform a quote.
     * Automatically handles token sorting.
     */
    function runSwap(
        string memory label,
        address tokenA,
        address tokenB,
        uint256 amountIn,
        address owner
    ) internal {
        // Sort tokens for correct PoolKey identification
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bool zeroForOne = (tokenA == t0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(leanSwap))
        });

        // Get current pool state
        (uint160 sqrtPriceX96, int24 tick, , ) = manager.getSlot0(key.toId());
        
        console.log("-----------------------------------------");
        console.log("Pool:", label);
        
        if (sqrtPriceX96 == 0) {
            console.log("  Status: POOL NOT INITIALIZED");
            return;
        }

        console.log("  Current Tick:", tick);
        console.log("  Current SqrtPriceX96:", uint256(sqrtPriceX96));
        TestnetToken tokenIn = TestnetToken(tokenA);
        TestnetToken tokenOut = TestnetToken(tokenB);

        tokenIn.approve(address(leanSwapRouter), amountIn);
        
        uint256 initTABal = tokenIn.balanceOf(owner);
        console.log("Balance of", tokenIn.symbol(), "is", initTABal);
        uint256 initTBBal = tokenOut.balanceOf(owner);
        console.log("Balance of", tokenOut.symbol(), "is", initTBBal);
        // Prepare swap params
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        leanSwapRouter.swap(key, params, LeanSwapLibrary.encodeHookData(block.timestamp + 1000, true, owner), amountIn);

        uint256 finTABal = tokenIn.balanceOf(owner);
        uint256 finTBBal = tokenOut.balanceOf(owner);
        console.log("Balance after swap of", tokenIn.symbol(), "is", finTABal);
        console.log("Difference is", (initTABal - finTABal));
        console.log("Balance after swap of", tokenOut.symbol(), "is", finTBBal);
        console.log("Difference is", (finTBBal - initTBBal));
    }
}
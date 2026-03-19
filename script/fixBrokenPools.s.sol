// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TestnetToken} from "../src/TestnetToken.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LeanSwapLibrary} from "../src/Library.sol";
import {LeanSwapRouter} from "../src/TestSwapRouter.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta);
}

contract FixBrokenPools is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── Infrastructure ────────────────────────────────────────────────────────
    IPoolManager constant manager =
        IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    IPoolModifyLiquidityTest constant modifyLiquidityRouter =
        IPoolModifyLiquidityTest(0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB);
    LeanSwapRouter constant swapRouter =
        LeanSwapRouter(0x0022317ce7F4e37FEB7a2E6BbeBD946Aeedc158C);

    // ── Tokens ────────────────────────────────────────────────────────────────
    TestnetToken constant tUSDC =
        TestnetToken(0x69421BB202C3514384DCb5053DCDc3FD591e4507);
    TestnetToken constant tDAI =
        TestnetToken(0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec);
    TestnetToken constant tETH =
        TestnetToken(0x568933d38886b2aA8A2165dAfDcE7D017388637C);

    address constant hookAddr   = 0x605167C336F499D47031001Db4c8AC4299140088;
    int24   constant TICK_LOWER = -60000;
    int24   constant TICK_UPPER =  60000;

    // ─────────────────────────────────────────────────────────────────────────
    // Correct price encoding using full 256-bit precision.
    //
    // The OLD approach:
    //   ratioX96 = (amount1 << 96) / amount0   ← loses precision when ratio < 1
    //   sqrtPrice = sqrt(ratioX96) << 48        ← compounds the error
    //
    // The CORRECT approach:
    //   sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0)
    //   i.e. fold the full 2^96 scale factor inside the sqrt so integer
    //   arithmetic keeps all significant digits.
    // ─────────────────────────────────────────────────────────────────────────
    function encodePriceSqrtCorrect(uint256 amount1, uint256 amount0)
        internal pure returns (uint160 sqrtPriceX96)
    {
        require(amount0 > 0 && amount1 > 0, "amounts must be > 0");
        // (amount1 << 192) keeps precision; safe as long as amount1 < 2^64
        uint256 ratio = (amount1 << 192) / amount0;
        sqrtPriceX96  = uint160(sqrt256(ratio));

        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE)
            sqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE)
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
    }

    function sqrt256(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) {
            z = 1;
        }
    }

    function buildKey(address tA, address tB)
        internal pure returns (PoolKey memory key)
    {
        (address t0, address t1) = tA < tB ? (tA, tB) : (tB, tA);
        key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1: Remove all liquidity from the broken pool.
    // ─────────────────────────────────────────────────────────────────────────
    function drainLiquidity(
        address tA,
        address tB,
        int256  liq,
        string memory label
    ) internal {
        PoolKey memory key = buildKey(tA, tB);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        require(price != 0, "Pool not initialized");

        console.log("--- Draining:", label, "---");
        TestnetToken(tA).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestnetToken(tB).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: -liq,   // negative = remove
                salt:           bytes32(0)
            }),
            new bytes(0)
        );
        console.log("  Liquidity removed.");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2: Swap to push the pool price to targetPrice, then re-add liquidity.
    //
    // We cannot re-initialize an existing pool, so we use a swap to correct
    // the price. The swap budget should be large enough to move the price
    // fully to the target — it does not need to be exact since sqrtPriceLimitX96
    // will stop the swap exactly at targetPrice.
    // ─────────────────────────────────────────────────────────────────────────
    function alignAndRefill(
        address tA,
        address tB,
        uint256 swapBudget,     // generous budget; actual spend = what's needed
        uint160 targetPrice,
        int256  liq,
        string memory label
    ) internal {
        (address t0, address t1) = tA < tB ? (tA, tB) : (tB, tA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        (uint160 currentPrice,,,) = manager.getSlot0(key.toId());
        console.log("--- Aligning:", label, "---");
        console.log("  Current price :", uint256(currentPrice));
        console.log("  Target  price :", uint256(targetPrice));

        if (currentPrice != targetPrice) {
            bool zeroForOne = currentPrice > targetPrice;

            TestnetToken(t0).approve(address(swapRouter), type(uint256).max);
            TestnetToken(t1).approve(address(swapRouter), type(uint256).max);

            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne:        zeroForOne,
                    amountSpecified:   -int256(swapBudget),
                    sqrtPriceLimitX96: targetPrice
                }),
                LeanSwapLibrary.encodeHookData(0, false, msg.sender),
                swapBudget
            );

            (uint160 newPrice,,,) = manager.getSlot0(key.toId());
            console.log("  Price after swap:", uint256(newPrice));
        } else {
            console.log("  Price already correct, skipping swap.");
        }

        // Re-add liquidity at the corrected price
        TestnetToken(t0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestnetToken(t1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: liq,    // positive = add
                salt:           bytes32(0)
            }),
            new bytes(0)
        );
        console.log("  Liquidity re-added.");
    }

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // Mint plenty so we have enough for swaps + re-adding liquidity
        tETH.mint(deployer,  10_000 * 1e18);
        tUSDC.mint(deployer, 50_000_000 * 1e6);
        tDAI.mint(deployer,  50_000_000 * 1e18);

        // ─────────────────────────────────────────────────────────────────────
        // Pool 1: ETH / USDC  — 1 ETH = 2000 USDC
        //   t0 = tETH  (lower address, 18 decimals)
        //   t1 = tUSDC (higher address, 6 decimals)
        //   → price = t1/t0 = 2000e6 / 1e18
        //   → encodePriceSqrtCorrect(amount1=2000e6, amount0=1e18)
        // ─────────────────────────────────────────────────────────────────────
        uint160 targetETHUSDC = encodePriceSqrtCorrect(2000e6, 1e18);
        console.log("ETH/USDC target sqrtPriceX96 :", uint256(targetETHUSDC));

        // drainLiquidity(address(tETH), address(tUSDC), 10 ether, "ETH/USDC");
        alignAndRefill(
            address(tETH), address(tUSDC),
            10_000e6,        // 10,000 USDC budget — more than enough to move price
            targetETHUSDC,
            10 ether,
            "ETH/USDC"
        );

        // ─────────────────────────────────────────────────────────────────────
        // Pool 2: USDC / DAI  — 1 USDC = 1 DAI
        //   Determine token order at compile time from known addresses:
        //   tUSDC = 0x6942...  tDAI = 0x98ED...
        //   0x6942 < 0x98ED  →  t0 = tUSDC (6 dec), t1 = tDAI (18 dec)
        //   → price = t1/t0 = 1e18 / 1e6
        //   → encodePriceSqrtCorrect(amount1=1e18, amount0=1e6)
        //
        //   If you ever redeploy tokens and the order flips, swap the args.
        // ─────────────────────────────────────────────────────────────────────
        uint160 targetUSDCDAI = encodePriceSqrtCorrect(1e18, 1e6);
        console.log("USDC/DAI target sqrtPriceX96 :", uint256(targetUSDCDAI));

        // drainLiquidity(address(tUSDC), address(tDAI), 10 ether, "USDC/DAI");
        alignAndRefill(
            address(tUSDC), address(tDAI),
            100_000e6,       // 100,000 USDC budget
            targetUSDCDAI,
            10 ether,
            "USDC/DAI"
        );

        vm.stopBroadcast();
    }
}

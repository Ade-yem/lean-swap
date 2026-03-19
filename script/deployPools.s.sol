// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {LeanSwapRouter} from "../src/TestSwapRouter.sol";
import {TestnetToken} from "../src/TestnetToken.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwapLibrary} from "../src/Library.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta);
}

contract DeployAndFixTestnet is Script {
    using StateLibrary for IPoolManager;

    IPoolManager manager = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    IPoolModifyLiquidityTest modifyLiquidityRouter =
        IPoolModifyLiquidityTest(0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB);

    TestnetToken immutable tUSDC = TestnetToken(0x69421BB202C3514384DCb5053DCDc3FD591e4507);
    TestnetToken immutable tDAI = TestnetToken(0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec);
    TestnetToken immutable tLEAN = TestnetToken(0x18754e7c697A6DB8afC0BF963692f53c2719453f);
    TestnetToken immutable tETH = TestnetToken(0x568933d38886b2aA8A2165dAfDcE7D017388637C);
    TestnetToken immutable tCOW = TestnetToken(0xFF02F80E373317b778a1335808ddEFD1FC448227);
    address immutable hookAddr = 0x605167C336F499D47031001Db4c8AC4299140088;
    LeanSwapRouter immutable swapRouter = LeanSwapRouter(0x0022317ce7F4e37FEB7a2E6BbeBD946Aeedc158C);

    function encodePriceSqrt(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        require(amount0 > 0 && amount1 > 0, "amounts must be > 0");

        // Compute ratio in Q96 fixed point: (amount1 << 96) / amount0
        uint256 ratioX96 = (amount1 << 96) / amount0;

        // Integer square root of ratioX96, then shift left 48 to reach Q96
        sqrtPriceX96 = uint160(sqrt(ratioX96) << 48);

        // Clamp to Uniswap V4 valid range
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        }
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        }
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function setupOrModifyPool(address tA, uint256 rA, address tB, uint256 rB, int256 liq)
        internal
        returns (PoolKey memory key)
    {
        (address t0, address t1, uint256 res0, uint256 res1) = tA < tB ? (tA, tB, rA, rB) : (tB, tA, rB, rA);
        key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // FETCH STATE: Check if initialized to avoid simulation revert
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) {
            uint160 startingPrice = encodePriceSqrt(res1, res0);
            manager.initialize(key, startingPrice);
            console.log("Initialized Pool:", TestnetToken(t0).symbol(), "/", TestnetToken(t1).symbol());
        } else {
            console.log("Pool already exists:", TestnetToken(t0).symbol(), "/", TestnetToken(t1).symbol());
        }

        TestnetToken(t0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestnetToken(t1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: liq, salt: bytes32(0)}),
            new bytes(0)
        );
    }

    function alignPrice(address tA, address tB, uint256 budget, uint160 targetPrice) internal {
        (address t0, address t1) = tA < tB ? (tA, tB) : (tB, tA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        (uint160 currentPrice,,,) = manager.getSlot0(key.toId());
        if (currentPrice == targetPrice) {
            console.log("Current proce is equal to target price");
            return;
        }

        bool zeroForOne = currentPrice > targetPrice;
        console.log("Aligning Price for", TestnetToken(t0).symbol(), "/", TestnetToken(t1).symbol());

        TestnetToken(t0).approve(address(swapRouter), type(uint256).max);
        TestnetToken(t1).approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: targetPrice}),
            LeanSwapLibrary.encodeHookData(0, false, msg.sender),
            budget
        );
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1. MINT BALANCES (Ensure deployer has enough for liquidity/alignment)
        tUSDC.mint(deployer, 50_000_000 * 1e6);
        tDAI.mint(deployer, 50_000_000 * 1e18);
        tETH.mint(deployer, 10_000 * 1e18);
        tLEAN.mint(deployer, 50_000_000 * 1e18);
        tCOW.mint(deployer, 50_000_000 * 1e18);

        // 2. ETH / USDC (1 ETH = 2000 USDC)
        setupOrModifyPool(address(tETH), 1e18, address(tUSDC), 2000e6, 10 ether);
        alignPrice(address(tETH), address(tUSDC), 1000e6, encodePriceSqrt(2000e6, 1e18));

        // 3. ETH / DAI (1 ETH = 2000 DAI)
        setupOrModifyPool(address(tETH), 1e18, address(tDAI), 2000e18, 100 ether);
        alignPrice(address(tETH), address(tDAI), 10 ether, encodePriceSqrt(2000e18, 1e18));

        // 4. USDC / DAI (1 USDC = 1 DAI)
        setupOrModifyPool(address(tUSDC), 1e6, address(tDAI), 1e18, 10 ether);
        alignPrice(address(tUSDC), address(tDAI), 1000e6, encodePriceSqrt(1e18, 1e6));

        // 5. COW / LEAN (1 COW = 100 LEAN)
        // tLEAN < tCOW. Price (t1/t0) = 1/100
        setupOrModifyPool(address(tCOW), 1e18, address(tLEAN), 100e18, 50 ether);
        alignPrice(address(tCOW), address(tLEAN), 10 ether, encodePriceSqrt(1e18, 100e18));

        // 6. USDC / COW (1 USDC = 20 COW)
        // tUSDC < tCOW. Price (t1/t0) = 20/1
        setupOrModifyPool(address(tUSDC), 1e6, address(tCOW), 20e18, 10 ether);
        uint160 targetPrice = encodePriceSqrt(20e18, 1e6);
        console.log("Target price", targetPrice);
        alignPrice(address(tUSDC), address(tCOW), 1000e6, targetPrice);

        vm.stopBroadcast();
    }
}

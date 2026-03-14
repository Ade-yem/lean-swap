// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title LeanSwapLoopOrders Tests
 * @notice Tests for closed-cycle (loop) CoW order matching across multiple pools and tokens.
 *
 * Real Life Scenario:
 * ─────────────────────────────────────────────────────────────────────────────
 *   Eli   → wants to sell ETH  for DAI   (~2000 DAI per ETH)
 *   Edith → wants to sell USDC for ETH   (~2000 USDC per ETH)
 *   Lily  → wants to sell COW  for USDC  (~0.5 USDC per COW)
 *   Chow  → wants to sell DAI  for COW   (~2 COW per DAI)
 *
 * Asset flow in the cycle:
 *   Eli   gives 1 ETH      → gets ~2000 DAI
 *   Chow  gives ~1990 DAI  → gets ~3980 COW
 *   Lily  gives ~3960 COW  → gets ~1980 USDC
 *   Edith gives ~1970 USDC → gets ~0.985 ETH
 */

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {LeanSwapReactive} from "../src/LeanSwapReactive.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {LeanSwapLibrary, ReactiveLibrary} from "../src/Library.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract LeanSwapLoopOrdersRealLifeScenarioWithDifferentPricePointsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Constants ─────────────────────────────────────────────────────────────
    address constant RSC_ADDR = address(0x0000000000000000000000000000000000fffFfF);
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ── Contracts ─────────────────────────────────────────────────────────────
    LeanSwap hook;
    LeanSwapReactive reactive;

    // ── Tokens (sorted by address after deployment) ───────────────────────────
    MockERC20 tokenEth;
    MockERC20 tokenDai;
    MockERC20 tokenUsdc;
    MockERC20 tokenCow;

    Currency cETH;
    Currency cDAI;
    Currency cUSDC;
    Currency cCOW;

    PoolKey keyEthDai;
    PoolKey keyDaiCow;
    PoolKey keyCowUsdc;
    PoolKey keyUsdcEth;

    PoolId pidEthDai;
    PoolId pidDaiCow;
    PoolId pidCowUsdc;
    PoolId pidUsdcEth;

    // ── Users ─────────────────────────────────────────────────────────────────
    address eli = makeAddr("eli"); // sells ETH  for DAI
    address edith = makeAddr("edith"); // sells USDC for ETH
    address lily = makeAddr("lily"); // sells COW  for USDC
    address chow = makeAddr("chow"); // sells DAI  for COW

    // ── Event topics ──────────────────────────────────────────────────────────
    uint256 constant ORDER_CREATED_TOPIC = uint256(
        keccak256("SwapOrderCreated(((address,address,uint24,int24,address),bytes32),bool,uint256,uint256,uint256)")
    );
    uint256 constant ORDER_SETTLED_TOPIC =
        uint256(keccak256("SwapOrderSettled(((address,address,uint24,int24,address),bytes32),bool,uint256,uint256)"));
    uint256 constant ORDER_DEADLINE_TOPIC = uint256(
        keccak256(
            "SwapOrderDeadlineExceededSettled(address,((address,address,uint24,int24,address),bytes32),uint256,uint256)"
        )
    );

    function setUp() public {
        deployFreshManagerAndRouters();

        tokenEth = new MockERC20("Wrapped Ether", "WETH", 18);
        tokenDai = new MockERC20("Dai Stablecoin", "DAI", 18);
        tokenUsdc = new MockERC20("USD Coin", "USDC", 6);
        tokenCow = new MockERC20("CoW Protocol", "COW", 18);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LeanSwap.sol", abi.encode(manager, RSC_ADDR), hookAddress);
        hook = LeanSwap(payable(hookAddress));

        cETH = Currency.wrap(address(tokenEth));
        cDAI = Currency.wrap(address(tokenDai));
        cUSDC = Currency.wrap(address(tokenUsdc));
        cCOW = Currency.wrap(address(tokenCow));

        // ETH/DAI ~ 2000: tick = 76020
        (keyEthDai, pidEthDai) = _initPool(cETH, cDAI, hook, 76020, -76020);
        // DAI/COW ~ 2: tick = 6900
        (keyDaiCow, pidDaiCow) = _initPool(cDAI, cCOW, hook, 6930, -6930);
        // COW/USDC ~ 0.5 * 10^6 / 10^18 = 0.5e-12 => tick = -283260
        // cUSDC is likely C0, so tick should be ~283260
        (keyCowUsdc, pidCowUsdc) = _initPool(cCOW, cUSDC, hook, -283260, 283260);
        // USDC/ETH ~ 1 * 10^18 / (2000 * 10^6) = 5e8 => tick = 200340
        // cETH is likely C0, so tick should be ~-200340
        (keyUsdcEth, pidUsdcEth) = _initPool(cUSDC, cETH, hook, 200340, -200340);

        reactive = new LeanSwapReactive(
            RSC_ADDR,
            block.chainid,
            block.chainid,
            address(hook),
            ORDER_CREATED_TOPIC,
            ORDER_SETTLED_TOPIC,
            ORDER_DEADLINE_TOPIC,
            address(hook),
            1000
        );

        uint256 MINT = 1000_000 ether;
        _setupUser(eli, MINT, MINT);
        _setupUser(edith, MINT, MINT);
        _setupUser(lily, MINT, MINT);
        _setupUser(chow, MINT, MINT);
    }

    function _initPool(Currency a, Currency b, LeanSwap _hook, int24 tickIfAIsC0, int24 tickIfAIsC1)
        internal
        returns (PoolKey memory poolKey_, PoolId poolId_)
    {
        bool isA_C0 = Currency.unwrap(a) < Currency.unwrap(b);
        (Currency c0, Currency c1) = isA_C0 ? (a, b) : (b, a);
        int24 tick = isA_C0 ? tickIfAIsC0 : tickIfAIsC1;

        poolKey_ = PoolKey({
            currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(_hook))
        });
        poolId_ = poolKey_.toId();

        MockERC20(Currency.unwrap(c0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Adjust liquidity delta to prevent exhaustion on different decimals
        // 50_000 * 10**18 or 10**6 for USDC
        // uint256 amount0 = MockERC20(Currency.unwrap(c0)).decimals() == 6 ? 5_000_000 * 10 ** 6 : 5_000_000 ether;
        // uint256 amount1 = MockERC20(Currency.unwrap(c1)).decimals() == 6 ? 5_000_000 * 10 ** 6 : 5_000_000 ether;

        MockERC20(Currency.unwrap(c0)).mint(address(this), 10 ** 30);
        MockERC20(Currency.unwrap(c1)).mint(address(this), 10 ** 30);

        manager.initialize(poolKey_, TickMath.getSqrtPriceAtTick(tick));

        // Provide liquidity centered around our tick
        int24 tickLower = (tick / TICK_SPACING) * TICK_SPACING - TICK_SPACING * 100;
        int24 tickUpper = (tick / TICK_SPACING) * TICK_SPACING + TICK_SPACING * 100;

        uint256 decimals0 = MockERC20(Currency.unwrap(c0)).decimals();
        uint256 decimals1 = MockERC20(Currency.unwrap(c1)).decimals();
        uint128 liq = (decimals0 == 6 || decimals1 == 6) ? 1e14 : 100_000 ether;

        modifyLiquidityRouter.modifyLiquidity(
            poolKey_,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)
            }),
            new bytes(0)
        );
    }

    function _setupUser(address user, uint256 amount18, uint256 amount6) internal {
        tokenEth.mint(user, amount18);
        tokenDai.mint(user, amount18);
        tokenUsdc.mint(user, amount6);
        tokenCow.mint(user, amount18);

        vm.startPrank(user);
        tokenEth.approve(address(swapRouter), type(uint256).max);
        tokenDai.approve(address(swapRouter), type(uint256).max);
        tokenUsdc.approve(address(swapRouter), type(uint256).max);
        tokenCow.approve(address(swapRouter), type(uint256).max);
        tokenEth.approve(address(hook), type(uint256).max);
        tokenDai.approve(address(hook), type(uint256).max);
        tokenUsdc.approve(address(hook), type(uint256).max);
        tokenCow.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _zeroForOne(PoolKey memory poolKey_, address tokenSell) internal pure returns (bool) {
        return Currency.unwrap(poolKey_.currency0) == tokenSell;
    }

    function _placeOrder(address user, PoolKey memory poolKey_, bool isZeroForOne, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 orderId)
    {
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, user);
        vm.prank(user);
        swapRouter.swap(
            poolKey_,
            SwapParams({
                zeroForOne: isZeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: isZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        PoolId pid = poolKey_.toId();
        uint256 idx = _pendingCount(pid, isZeroForOne) - 1;
        orderId = _getOrderId(pid, isZeroForOne, idx, user);
    }

    function _pendingCount(PoolId pid, bool zeroForOne) internal view returns (uint256) {
        uint256 i;
        while (true) {
            try hook.pendingOrders(pid, zeroForOne, i) returns (
                address, bool, bool, bool, uint64, PoolId, uint256, uint256, uint256, uint256
            ) {
                i++;
            } catch {
                break;
            }
        }
        return i;
    }

    function _getOrderId(
        PoolId pid,
        bool zeroForOne,
        uint256 index,
        address /*owner*/
    )
        internal
        view
        returns (uint256)
    {
        (address owner_,,,, uint64 dl,, uint256 amtIn, uint256 amtOut, uint256 nonce_,) =
            hook.pendingOrders(pid, zeroForOne, index);
        return uint256(keccak256(abi.encode(pid, zeroForOne, dl, amtIn, amtOut, owner_, nonce_)));
    }

    function _buildOrderCreatedLog(
        PoolKey memory poolKey_,
        bool zeroForOne,
        uint256 deadline,
        uint256 orderId,
        uint256 amountIn
    ) internal view returns (IReactive.LogRecord memory) {
        ReactiveLibrary.OrderMetadata memory meta = ReactiveLibrary.OrderMetadata({
            poolKey: poolKey_, zeroForOne: zeroForOne, deadline: deadline, orderId: orderId, amountIn: amountIn
        });
        return IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: ORDER_CREATED_TOPIC,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(meta),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "payload too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            result[i - 4] = data[i];
        }
        return result;
    }

    // =========================================================================
    // LOOP ORDER TESTS
    // =========================================================================

    function test_fourParty_cycleSettle_manual_callback() public {
        uint256 amountEli = 1 ether; // 1 ETH  (~2000 DAI)
        uint256 amountChow = 10 ether; // 1990 DAI
        uint256 amountLily = 390 ether; // 3960 COW
        uint256 amountEdith = 190 * 10 ** 6; // 1970 USDC

        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountEdith, deadline);

        uint256[] memory orderIds = new uint256[](4);
        orderIds[0] = eliOrderId;
        orderIds[1] = chowOrderId;
        orderIds[2] = lilyOrderId;
        orderIds[3] = edithOrderId;

        PoolKey[] memory keys = new PoolKey[](4);
        keys[0] = keyEthDai;
        keys[1] = keyDaiCow;
        keys[2] = keyCowUsdc;
        keys[3] = keyUsdcEth;

        uint256 eliDaiBefore = tokenDai.balanceOf(eli);
        uint256 chowCowBefore = tokenCow.balanceOf(chow);
        uint256 lilyUsdcBefore = tokenUsdc.balanceOf(lily);
        uint256 edithEthBefore = tokenEth.balanceOf(edith);

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli should receive DAI");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow should receive COW");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily should receive USDC");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith should receive ETH");
    }

    function test_reactive_detects_fourParty_cycle_and_emits_callback() public {
        uint256 amountEli = 1.0 ether;
        uint256 amountChow = 190 ether;
        uint256 amountLily = 396 ether;
        uint256 amountEdith = 170 * 10 ** 6;

        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountEdith, deadline);

        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountEli));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountChow));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountLily));
        vm.stopPrank();

        assertTrue(reactive.isActiveOrder(eliOrderId), "Eli order active");
        assertTrue(reactive.isActiveOrder(chowOrderId), "Chow order active");
        assertTrue(reactive.isActiveOrder(lilyOrderId), "Lily order active");

        vm.recordLogs();
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyUsdcEth, edithZfo, deadline, edithOrderId, amountEdith));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory callbackPayload;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackPayload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }

        assertTrue(callbackPayload.length > 0, "Reactive contract should have emitted a Callback for the cycle");

        bytes memory innerCalldata = _stripSelector(callbackPayload);
        bytes memory innerData = abi.decode(innerCalldata, (bytes));

        (ReactiveLibrary.CallbackType cType,,) =
            abi.decode(innerData, (ReactiveLibrary.CallbackType, uint256[], PoolKey[]));
        assertEq(
            uint256(cType),
            uint256(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER),
            "Callback type should be SETTLE_COMPLEX_ORDER"
        );
    }

    function test_reactive_fourParty_cycle_endToEnd() public {
        uint256 amountEli = 1 ether;
        uint256 amountChow = 990 ether;
        uint256 amountLily = 60 ether;
        uint256 amountEdith = 70 * 10 ** 6;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountEdith, deadline);

        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountEli));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountChow));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountLily));
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyUsdcEth, edithZfo, deadline, edithOrderId, amountEdith));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory callbackPayload;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackPayload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        assertTrue(callbackPayload.length > 0, "Must have captured a Callback payload");

        bytes memory innerCalldata = _stripSelector(callbackPayload);
        bytes memory innerData = abi.decode(innerCalldata, (bytes));

        uint256 eliDaiBefore = tokenDai.balanceOf(eli);
        uint256 chowCowBefore = tokenCow.balanceOf(chow);
        uint256 lilyUsdcBefore = tokenUsdc.balanceOf(lily);
        uint256 edithEthBefore = tokenEth.balanceOf(edith);

        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli received DAI");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow received COW");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily received USDC");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith received ETH");
    }

    function test_partialCycle_noSettlement() public {
        uint256 amountEli = 1 ether;
        uint256 amountChow = 190 ether;
        uint256 amountLily = 360 ether;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);

        vm.recordLogs();
        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountEli));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountChow));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountLily));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool foundComplexCallback = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes memory inner = abi.decode(_stripSelector(payload), (bytes));
                (ReactiveLibrary.CallbackType cType,,) =
                    abi.decode(inner, (ReactiveLibrary.CallbackType, uint256[], PoolKey[]));
                if (cType == ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER) {
                    foundComplexCallback = true;
                }
            }
        }
        assertFalse(foundComplexCallback, "No complex settle should be triggered with only 3 legs");

        assertGt(hook.batchPendingOrdersIn(pidEthDai, eliZfO), 0, "ETH/DAI batch not empty");
        assertGt(hook.batchPendingOrdersIn(pidDaiCow, chowZfo), 0, "DAI/COW batch not empty");
        assertGt(hook.batchPendingOrdersIn(pidCowUsdc, lilyZfo), 0, "COW/USDC batch not empty");
    }

    function test_fourParty_cycle_imbalanced_amounts() public {
        // Here we can tweak the real life numbers just slightly so they don't perfectly line up without hitting AMM somewhat.
        uint256 amountEli = 1 ether; // 1 ETH  -> gets ~2000 DAI
        uint256 amountChow = 19 ether; // 1995 DAI -> gets ~3990 COW
        uint256 amountLily = 38 ether; // 3980 COW -> gets ~1990 USDC
        uint256 amountEdith = 18 * 10 ** 6; // 1980 USDC -> gets ~0.99 ETH
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountEdith, deadline);

        uint256[] memory orderIds = new uint256[](4);
        orderIds[0] = eliOrderId;
        orderIds[1] = chowOrderId;
        orderIds[2] = lilyOrderId;
        orderIds[3] = edithOrderId;

        PoolKey[] memory keys = new PoolKey[](4);
        keys[0] = keyEthDai;
        keys[1] = keyDaiCow;
        keys[2] = keyCowUsdc;
        keys[3] = keyUsdcEth;

        uint256 eliDaiBefore = tokenDai.balanceOf(eli);
        uint256 chowCowBefore = tokenCow.balanceOf(chow);
        uint256 lilyUsdcBefore = tokenUsdc.balanceOf(lily);
        uint256 edithEthBefore = tokenEth.balanceOf(edith);

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli received DAI (imbalanced)");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow received COW (imbalanced)");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily received USDC (imbalanced)");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith received ETH (imbalanced)");
    }

    function test_settleComplex_mismatchedArrays_reverts() public {
        uint256[] memory orderIds = new uint256[](2);
        PoolKey[] memory keys = new PoolKey[](3);

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        vm.expectRevert(LeanSwap.ArrayLengthMismatch.selector);
        hook.callback(innerData);
    }

    function test_settleComplex_alreadyFulfilled_reverts() public {
        uint256 amountEli = 1 ether;
        uint256 amountChow = 190 ether;
        uint256 amountLily = 390 ether;
        uint256 amountEdith = 10 * 10 ** 6;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountEli, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountChow, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountLily, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountEdith, deadline);

        uint256[] memory orderIds = new uint256[](4);
        orderIds[0] = eliOrderId;
        orderIds[1] = chowOrderId;
        orderIds[2] = lilyOrderId;
        orderIds[3] = edithOrderId;

        PoolKey[] memory keys = new PoolKey[](4);
        keys[0] = keyEthDai;
        keys[1] = keyDaiCow;
        keys[2] = keyCowUsdc;
        keys[3] = keyUsdcEth;

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        vm.prank(RSC_ADDR);
        vm.expectRevert(LeanSwap.SwapOrderNotFound.selector);
        hook.callback(innerData);
    }

    function test_settleComplex_exceedMaxDepth_reverts() public {
        uint256 n = 11;
        uint256[] memory orderIds = new uint256[](n);
        PoolKey[] memory keys = new PoolKey[](n);
        for (uint256 i = 0; i < n; i++) {
            orderIds[i] = i + 1;
            keys[i] = keyEthDai;
        }

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        vm.expectRevert(LeanSwap.MaxCycleDepthExceeded.selector);
        hook.callback(innerData);
    }
}

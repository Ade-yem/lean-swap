// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title LeanSwapLoopOrders Tests
 * @notice Tests for closed-cycle (loop) CoW order matching across multiple pools and tokens.
 *
 * The 4-party cycle under test:
 * ─────────────────────────────────────────────────────────────────────────────
 *   Eli   → wants to sell ETH  for DAI  (ETH/DAI pool,   zeroForOne = true  if ETH < DAI by address)
 *   Edith → wants to sell USDC for ETH  (ETH/USDC pool,  zeroForOne = ?)
 *   Lily  → wants to sell COW  for USDC (USDC/COW pool,  zeroForOne = ?)
 *   Chow  → wants to sell DAI  for COW  (DAI/COW pool,   zeroForOne = ?)
 *
 * Asset flow in the cycle:
 *   Eli   gives ETH  → gets DAI
 *   Chow  gives DAI  → gets COW
 *   Lily  gives COW  → gets USDC
 *   Edith gives USDC → gets ETH
 *
 * The closed cycle is:  ETH → DAI → COW → USDC → ETH
 *
 * Pool setup (currency ordering is by address, lower address = currency0):
 *   We deploy 4 MockERC20 tokens and sort them so Uniswap v4 PoolKey requirements
 *   (currency0 < currency1 by address) are satisfied.
 *   Then we identify the correct zeroForOne direction per user.
 *
 * Settlement:
 *   The complex order settlement (_settleComplexOrder) is invoked via hook.callback()
 *   with a SETTLE_COMPLEX_ORDER payload.  The payload carries:
 *     • orderIds[i]  — the orderId for each leg of the cycle
 *     • keys[i]      — the PoolKey for each leg
 *   The cycle is interpreted as: order[i] is fulfilled by order[(i+1) % N].amountIn.
 *
 * Reactive integration:
 *   We also exercise the reactive contract's DFS cycle detection by feeding the four
 *   SwapOrderCreated log records one by one and asserting that the 4th injection produces
 *   a Callback event with a SETTLE_COMPLEX_ORDER payload.
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

contract LeanSwapLoopOrdersTest is Test, Deployers {
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

    // ── Currencies (wrapped tokens) ───────────────────────────────────────────
    Currency cETH;
    Currency cDAI;
    Currency cUSDC;
    Currency cCOW;

    // ── Pool keys ─────────────────────────────────────────────────────────────
    // Uniswap v4 requires currency0 < currency1 (by address).
    // We will sort each pair after deployment.
    PoolKey keyEthDai; // pool for ETH ↔ DAI
    PoolKey keyDaiCow; // pool for DAI ↔ COW
    PoolKey keyCowUsdc; // pool for COW ↔ USDC
    PoolKey keyUsdcEth; // pool for USDC ↔ ETH

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

    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        // 1. Deploy pool infrastructure
        deployFreshManagerAndRouters();

        // 2. Deploy and label 4 tokens
        tokenEth = new MockERC20("Wrapped Ether", "WETH", 18);
        tokenDai = new MockERC20("Dai Stablecoin", "DAI", 18);
        tokenUsdc = new MockERC20("USD Coin", "USDC", 6);
        tokenCow = new MockERC20("CoW Protocol", "COW", 18);

        // 3. Deploy hook at the encoded permission address
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LeanSwap.sol", abi.encode(manager, RSC_ADDR), hookAddress);
        hook = LeanSwap(payable(hookAddress));

        // 4. Wrap as Currency
        cETH = Currency.wrap(address(tokenEth));
        cDAI = Currency.wrap(address(tokenDai));
        cUSDC = Currency.wrap(address(tokenUsdc));
        cCOW = Currency.wrap(address(tokenCow));

        // 5. Create sorted pool keys (currency0 must be the lower address)
        //    and init each pool + add liquidity
        (keyEthDai, pidEthDai) = _initPool(cETH, cDAI, hook, 0);
        (keyDaiCow, pidDaiCow) = _initPool(cDAI, cCOW, hook, 0);
        (keyCowUsdc, pidCowUsdc) = _initPool(cCOW, cUSDC, hook, 0);
        (keyUsdcEth, pidUsdcEth) = _initPool(cUSDC, cETH, hook, 0);

        // 6. Deploy reactive contract (in VM mode — no real subscriptions)
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

        // 7. Mint tokens and approve for each user
        uint256 MINT = 100_000 ether;
        _setupUser(eli, MINT);
        _setupUser(edith, MINT);
        _setupUser(lily, MINT);
        _setupUser(chow, MINT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Sort two currencies so currency0 < currency1 (Uniswap v4 requirement),
    ///      then initialize the pool and add symmetric deep liquidity.
    function _initPool(Currency a, Currency b, LeanSwap _hook, int24 tick)
        internal
        returns (PoolKey memory poolKey_, PoolId poolId_)
    {
        // Sort by address
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        poolKey_ = PoolKey({
            currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(_hook))
        });
        poolId_ = poolKey_.toId();

        // Approve router to spend hook tokens (needed for liquidity)
        MockERC20(Currency.unwrap(c0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Mint liquidity tokens to this test contract
        MockERC20(Currency.unwrap(c0)).mint(address(this), 200_000 ether);
        MockERC20(Currency.unwrap(c1)).mint(address(this), 200_000 ether);

        manager.initialize(poolKey_, TickMath.getSqrtPriceAtTick(tick));

        modifyLiquidityRouter.modifyLiquidity(
            poolKey_,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 50_000 ether, salt: bytes32(0)}),
            new bytes(0)
        );
    }

    /// @dev Mint all 4 tokens to a user and approve the swap router + hook.
    function _setupUser(address user, uint256 amount) internal {
        tokenEth.mint(user, amount);
        tokenDai.mint(user, amount);
        tokenUsdc.mint(user, amount);
        tokenCow.mint(user, amount);

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

    /// @dev Determine the zeroForOne direction for a user who wants to sell `tokenSell`
    ///      in a pool whose sorted key is `poolKey_`.
    function _zeroForOne(PoolKey memory poolKey_, address tokenSell) internal pure returns (bool) {
        return Currency.unwrap(poolKey_.currency0) == tokenSell;
    }

    /// @dev Place a CoW order and return the derived orderId.
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

        // Derive orderId from the last order placed on this side of the pool
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

    /// @dev Build a LogRecord for the reactive contract.
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

    /// @dev Strip 4-byte selector from encoded calldata payload.
    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "payload too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            result[i - 4] = data[i];
        }
        return result;
    }

    // =========================================================================
    // ─────────────────────────  LOOP ORDER TESTS  ────────────────────────────
    // =========================================================================

    // =========================================================================
    // Test 1 — Manual 4-party cycle via SETTLE_COMPLEX_ORDER callback
    //
    // Cycle:
    //   Eli   sells ETH  → gets DAI  (ETH/DAI pool)
    //   Chow  sells DAI  → gets COW  (DAI/COW pool)
    //   Lily  sells COW  → gets USDC (COW/USDC pool)
    //   Edith sells USDC → gets ETH  (USDC/ETH pool)
    //
    // The complex order is settled as a 4-node ring where order[i] is satisfied
    // by the tokenIn provided by order[(i+1) % 4].
    // =========================================================================
    function test_fourParty_cycleSettle_manual_callback() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 2 hours;

        // ── Determine correct zeroForOne for each user ────────────────────────
        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth)); // Eli sells ETH
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai)); // Chow sells DAI
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow)); // Lily sells COW
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc)); // Edith sells USDC

        // ── Place orders ───────────────────────────────────────────────────────
        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountIn, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountIn, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountIn, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountIn, deadline);

        // ── Snapshot balances before settlement ───────────────────────────────
        uint256 eliDaiBefore = tokenDai.balanceOf(eli);
        uint256 chowCowBefore = tokenCow.balanceOf(chow);
        uint256 lilyUsdcBefore = tokenUsdc.balanceOf(lily);
        uint256 edithEthBefore = tokenEth.balanceOf(edith);

        // ── Build SETTLE_COMPLEX_ORDER payload ────────────────────────────────
        // The cycle follows: Eli → Chow → Lily → Edith (→ Eli)
        // cycleOrders[i] is fulfilled by cycleOrders[(i+1) % N].amountIn
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

        // ── Trigger settlement ─────────────────────────────────────────────────
        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        // ── Verify each user received the correct token ────────────────────────
        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli should receive DAI");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow should receive COW");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily should receive USDC");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith should receive ETH");

        // ── Orders should be cleared from all batch aggregators ────────────────
        assertEq(hook.batchPendingOrdersIn(pidEthDai, eliZfO), 0, "ETH/DAI batch cleared");
        assertEq(hook.batchPendingOrdersIn(pidDaiCow, chowZfo), 0, "DAI/COW batch cleared");
        assertEq(hook.batchPendingOrdersIn(pidCowUsdc, lilyZfo), 0, "COW/USDC batch cleared");
        assertEq(hook.batchPendingOrdersIn(pidUsdcEth, edithZfo), 0, "USDC/ETH batch cleared");

        // ── Orders should be marked as fulfilled in storage ────────────────────
        (,, bool eliFulfilled,,,,,,,) = hook.orders(eliOrderId);
        (,, bool chowFulfilled,,,,,,,) = hook.orders(chowOrderId);
        (,, bool lilyFulfilled,,,,,,,) = hook.orders(lilyOrderId);
        (,, bool edithFulfilled,,,,,,,) = hook.orders(edithOrderId);

        assertTrue(eliFulfilled, "Eli order fulfilled");
        assertTrue(chowFulfilled, "Chow order fulfilled");
        assertTrue(lilyFulfilled, "Lily order fulfilled");
        assertTrue(edithFulfilled, "Edith order fulfilled");
    }

    // =========================================================================
    // Test 2 — Reactive contract detects the 4-party cycle via DFS and emits
    //           the SETTLE_COMPLEX_ORDER Callback event.
    //           We feed the 4 SwapOrderCreated logs one by one and confirm that
    //           the 4th injection triggers a Callback event carrying a
    //           SETTLE_COMPLEX_ORDER payload.
    // =========================================================================
    function test_reactive_detects_fourParty_cycle_and_emits_callback() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountIn, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountIn, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountIn, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountIn, deadline);

        // Feed first 3 orders — no cycle yet
        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountIn));
        vm.stopPrank();

        // All 3 ingested OK, none triggered a cycle callback yet
        assertTrue(reactive.isActiveOrder(eliOrderId), "Eli order active");
        assertTrue(reactive.isActiveOrder(chowOrderId), "Chow order active");
        assertTrue(reactive.isActiveOrder(lilyOrderId), "Lily order active");

        // Record logs for the 4th injection — this should close the cycle
        vm.recordLogs();
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyUsdcEth, edithZfo, deadline, edithOrderId, amountIn));

        // Find the Callback event (SETTLE_COMPLEX_ORDER)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory callbackPayload;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                // chain_id, _contract, gas_limit are indexed → in topics.
                // logs[i].data only contains the non-indexed `bytes payload`.
                callbackPayload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }

        assertTrue(callbackPayload.length > 0, "Reactive contract should have emitted a Callback for the cycle");

        // Decode and verify the payload is a SETTLE_COMPLEX_ORDER
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

    // =========================================================================
    // Test 3 — Full end-to-end reactive cycle: place orders → reactive detects
    //           cycle → capture payload from Callback event → replay to
    //           hook.callback() → verify users received correct tokens.
    // =========================================================================
    function test_reactive_fourParty_cycle_endToEnd() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountIn, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountIn, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountIn, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountIn, deadline);

        // Feed orders 1-3 to reactive
        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountIn));
        vm.stopPrank();

        // Capture Callback event from 4th order injection
        vm.recordLogs();
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyUsdcEth, edithZfo, deadline, edithOrderId, amountIn));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory callbackPayload;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                // chain_id, _contract, gas_limit are indexed → in topics.
                // logs[i].data only contains the non-indexed `bytes payload`.
                callbackPayload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        assertTrue(callbackPayload.length > 0, "Must have captured a Callback payload");

        // Decode inner data
        bytes memory innerCalldata = _stripSelector(callbackPayload);
        bytes memory innerData = abi.decode(innerCalldata, (bytes));

        // Snapshot balances
        uint256 eliDaiBefore = tokenDai.balanceOf(eli);
        uint256 chowCowBefore = tokenCow.balanceOf(chow);
        uint256 lilyUsdcBefore = tokenUsdc.balanceOf(lily);
        uint256 edithEthBefore = tokenEth.balanceOf(edith);

        // Replay to hook as if the Reactive Network delivered it
        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        // Verify settlements
        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli received DAI");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow received COW");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily received USDC");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith received ETH");
    }

    // =========================================================================
    // Test 4 — Partial cycle (only 3 of 4 users place orders).
    //           No cycle should be detected; orders stay pending.
    // =========================================================================
    function test_partialCycle_noSettlement() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountIn, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountIn, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountIn, deadline);

        // No Callback event should be emitted — only 3 legs of the 4-leg cycle
        vm.recordLogs();
        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(keyEthDai, eliZfO, deadline, eliOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyDaiCow, chowZfo, deadline, chowOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(keyCowUsdc, lilyZfo, deadline, lilyOrderId, amountIn));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool foundComplexCallback = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                // chain_id, _contract, gas_limit are indexed → in topics.
                // logs[i].data only contains the non-indexed `bytes payload`.
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

        // Orders remain pending
        assertGt(hook.batchPendingOrdersIn(pidEthDai, eliZfO), 0, "ETH/DAI batch not empty");
        assertGt(hook.batchPendingOrdersIn(pidDaiCow, chowZfo), 0, "DAI/COW batch not empty");
        assertGt(hook.batchPendingOrdersIn(pidCowUsdc, lilyZfo), 0, "COW/USDC batch not empty");
    }

    // =========================================================================
    // Test 5 — Imbalanced cycle: users provide different amounts.
    //           Settlement should still succeed; the deficit is routed via AMM.
    // =========================================================================
    function test_fourParty_cycle_imbalanced_amounts() public {
        // To ensure every leg is a FULL internal match (nextOrder.amountIn > currentOrder.amountOut)
        // without invoking the AMM, the amounts must strictly adhere to the AMM's fee decay (~0.3%).
        // We use a decreasing sequence so that each order provides slightly more than the previous
        // order's simulated `amountOut`, preventing any AMM swaps.
        uint256 amountEli = 1 ether;
        uint256 amountChow = 0.998 ether;
        uint256 amountLily = 0.996 ether;
        uint256 amountEdith = 0.994 ether;
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

        // All users should receive their output token (possibly via AMM for the deficit)
        assertGt(tokenDai.balanceOf(eli), eliDaiBefore, "Eli received DAI (imbalanced)");
        assertGt(tokenCow.balanceOf(chow), chowCowBefore, "Chow received COW (imbalanced)");
        assertGt(tokenUsdc.balanceOf(lily), lilyUsdcBefore, "Lily received USDC (imbalanced)");
        assertGt(tokenEth.balanceOf(edith), edithEthBefore, "Edith received ETH (imbalanced)");
    }

    // =========================================================================
    // Test 6 — Invalid payload: SETTLE_COMPLEX_ORDER with mismatched array
    //           lengths reverts with ArrayLengthMismatch.
    // =========================================================================
    function test_settleComplex_mismatchedArrays_reverts() public {
        uint256[] memory orderIds = new uint256[](2);
        PoolKey[] memory keys = new PoolKey[](3); // mismatch!

        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        vm.expectRevert(LeanSwap.ArrayLengthMismatch.selector);
        hook.callback(innerData);
    }

    // =========================================================================
    // Test 7 — Cycle with a settled order in the path causes revert.
    //           After one settlement, trying to re-settle the same orderIds must
    //           revert with SwapOrderNotFound.
    // =========================================================================
    function test_settleComplex_alreadyFulfilled_reverts() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 2 hours;

        bool eliZfO = _zeroForOne(keyEthDai, address(tokenEth));
        bool chowZfo = _zeroForOne(keyDaiCow, address(tokenDai));
        bool lilyZfo = _zeroForOne(keyCowUsdc, address(tokenCow));
        bool edithZfo = _zeroForOne(keyUsdcEth, address(tokenUsdc));

        uint256 eliOrderId = _placeOrder(eli, keyEthDai, eliZfO, amountIn, deadline);
        uint256 chowOrderId = _placeOrder(chow, keyDaiCow, chowZfo, amountIn, deadline);
        uint256 lilyOrderId = _placeOrder(lily, keyCowUsdc, lilyZfo, amountIn, deadline);
        uint256 edithOrderId = _placeOrder(edith, keyUsdcEth, edithZfo, amountIn, deadline);

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

        // First settlement — succeeds
        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        // Second settlement — should revert because orders are already fulfilled
        vm.prank(RSC_ADDR);
        vm.expectRevert(LeanSwap.SwapOrderNotFound.selector);
        hook.callback(innerData);
    }

    // =========================================================================
    // Test 8 — Cycle depth exceeding MAX_CYCLE_DEPTH reverts.
    // =========================================================================
    function test_settleComplex_exceedMaxDepth_reverts() public {
        // Create 11 dummy orderIds (> MAX_CYCLE_DEPTH = 10)
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

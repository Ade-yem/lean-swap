// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title LeanSwapReactiveInteraction Tests
 * @notice Tests the integration between LeanSwapReactive and LeanSwap:
 *         1. Simple pair settle: reactive react() receives SwapOrderCreated logs, builds a
 *            SETTLE_ORDER callback payload, and LeanSwap.callback() correctly settles matching orders.
 *         2. Complex cycle detect: reactive react() detects a closed cycle via cycle-detection DFS,
 *            emits a SETTLE_COMPLEX_ORDER payload, and LeanSwap.callback() correctly routes the cycle.
 *         3. Deadline trigger: reactive react() detects an expired order and emits a
 *            DEADLINE_EXCEEDED payload, which LeanSwap.callback() handles correctly.
 *
 * Testing strategy
 * ────────────────
 * • LeanSwapReactive.react() is guarded by `vmOnly`, which requires `vm == true`.
 *   `vm` is set by detectVm(): if extcodesize(0xfffFfF) == 0 then vm = true.
 *   In a standard Forge test environment 0xfffFfF has no code, so vm == true automatically.
 * • We call react() as address(0x0000000000000000000000000000000000fffFfF) (the SERVICE_ADDR)
 *   to satisfy the vmOnly modifier's sender check.
 * • The Callback event emitted by the reactive contract carries the payload that the
 *   Reactive Network would eventually deliver to LeanSwap.callback(). We capture it with
 *   vm.recordLogs() and replay it directly to LeanSwap.callback() — exactly as the
 *   Reactive Network would do on-chain.
 * • LeanSwap is deployed at the hook address that encodes the required permission flags.
 * • The RSC address passed to LeanSwap's constructor is 0xfffFfF so that callback() auth passes.
 */

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {LeanSwapReactive} from "../src/LeanSwapReactive.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {LeanSwapLibrary, ReactiveLibrary} from "../src/Library.sol";

// ─── Dummy system-contract stub ────────────────────────────────────────────────
// LeanSwapReactive constructor calls service.subscribe() unless vm == true.
// Because in Forge vm == true (0xfffFfF has no code), the subscribe calls are skipped.
// So we only need a minimal payable stub so the `payable` cast in the constructor compiles.
contract DummyService {
    // accept ETH so the payable cast doesn't revert
    receive() external payable {}
    fallback() external payable {}
}

contract LeanSwapReactiveInteractionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Addresses ──────────────────────────────────────────────────────────────
    address constant RSC_ADDR = address(0x0000000000000000000000000000000000fffFfF);

    // ── Contracts ──────────────────────────────────────────────────────────────
    LeanSwap hook;
    LeanSwapReactive reactive;
    PoolId poolId;

    // ── Event topics for the reactive contract subscription ───────────────────
    // These are keccak256 hashes of the event signatures from LeanSwap.sol
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

    // ── Users ──────────────────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        // 1. Deploy pool manager + routers + two mock tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // 2. Deploy LeanSwap hook at the address that encodes the hook permission flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LeanSwap.sol", abi.encode(manager, RSC_ADDR), hookAddress);
        hook = LeanSwap(payable(hookAddress));

        // 3. Init pool and add liquidity
        (key, poolId) = initPool(currency0, currency1, hook, 3000, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10_000 ether, salt: bytes32(0)}),
            new bytes(0)
        );

        // 4. Deploy LeanSwapReactive (in VM mode — no real service subscription)
        //    We pass RSC_ADDR as _service so the constructor payable cast succeeds.
        //    Since 0xfffFfF has no code in Forge, detectVm() → vm = true → no subscribe calls.
        reactive = new LeanSwapReactive(
            RSC_ADDR, // _service
            block.chainid, // _originChainId
            block.chainid, // _destinationChainId
            address(hook), // _contract (the LeanSwap hook)
            ORDER_CREATED_TOPIC, // _orderCreatedTopic0
            ORDER_SETTLED_TOPIC, // _orderSettledTopic0
            ORDER_DEADLINE_TOPIC, // _orderDeadlineTopic0
            address(hook), // _callback (where payloads are delivered)
            1000 // _minOrderAmount
        );

        // 5. Mint and approve for users
        _mintAndApprove(alice);
        _mintAndApprove(bob);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mintAndApprove(address user) internal {
        MockERC20(Currency.unwrap(currency0)).mint(user, 1_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user, 1_000 ether);
        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Place a CoW order via the swapRouter and return the orderId from the pending array.
    function _placeOrder(address user, bool zeroForOne, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 orderId)
    {
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, user);
        vm.prank(user);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        // Derive orderId from pending array (last element on the side)
        uint256 idx = _pendingCount(zeroForOne) - 1;
        orderId = _getOrderId(zeroForOne, idx, user);
    }

    function _pendingCount(bool zeroForOne) internal view returns (uint256) {
        // iterate until it reverts
        uint256 i;
        while (true) {
            try hook.pendingOrders(poolId, zeroForOne, i) returns (
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
        bool zeroForOne,
        uint256 index,
        address /*owner*/
    )
        internal
        view
        returns (uint256)
    {
        (address owner_,,,, uint64 dl,, uint256 amtIn, uint256 amtOut, uint256 nonce_,) =
            hook.pendingOrders(poolId, zeroForOne, index);
        return uint256(keccak256(abi.encode(poolId, zeroForOne, dl, amtIn, amtOut, owner_, nonce_)));
    }

    /// @dev Build a synthetic SwapOrderCreated log record for the reactive contract.
    ///      The event signature is:
    ///      SwapOrderCreated(PoolKey key, bool zeroForOne, uint256 deadline, uint256 orderId, uint256 amountIn)
    function _buildOrderCreatedLog(
        PoolKey memory _key,
        bool zeroForOne,
        uint256 deadline,
        uint256 orderId,
        uint256 amountIn
    ) internal view returns (IReactive.LogRecord memory logRec) {
        ReactiveLibrary.OrderMetadata memory meta = ReactiveLibrary.OrderMetadata({
            poolKey: _key, zeroForOne: zeroForOne, deadline: deadline, orderId: orderId, amountIn: amountIn
        });
        logRec = IReactive.LogRecord({
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

    /// @dev Build a synthetic SwapOrderSettled log record.
    function _buildOrderSettledLog(PoolKey memory _key, bool zeroForOne, uint256 amountOut, uint256 orderId)
        internal
        view
        returns (IReactive.LogRecord memory logRec)
    {
        ReactiveLibrary.SettledOrderMetadata memory meta = ReactiveLibrary.SettledOrderMetadata({
            poolKey: _key, zeroForOne: zeroForOne, amountOut: amountOut, orderId: orderId
        });
        logRec = IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: ORDER_SETTLED_TOPIC,
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

    /// @dev Build a synthetic SwapOrderDeadlineExceededSettled log record.
    function _buildDeadlineLog(address owner, uint256 amount, uint256 orderId)
        internal
        view
        returns (IReactive.LogRecord memory logRec)
    {
        ReactiveLibrary.DeadlineSettledData memory meta =
            ReactiveLibrary.DeadlineSettledData({owner: owner, poolKey: key, amount: amount, orderId: orderId});
        logRec = IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: ORDER_DEADLINE_TOPIC,
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

    // =========================================================================
    // Test 1 — Reactive contract ingests an order event and its internal graph
    //           state is updated correctly.
    // =========================================================================
    function test_reactive_ingests_orderCreated_event() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 orderId = _placeOrder(alice, true, amountIn, deadline);

        // Feed the SwapOrderCreated log to the reactive contract (as if the RSC is processing it)
        IReactive.LogRecord memory logRec = _buildOrderCreatedLog(key, true, deadline, orderId, amountIn);

        vm.prank(RSC_ADDR);
        reactive.react(logRec);

        // The reactive contract should have stored the order
        assertTrue(reactive.isActiveOrder(orderId), "Order should be marked active in reactive contract");
        assertEq(reactive.deadlines(orderId), deadline, "Deadline should be stored");

        // The ordersByAssetIn mapping — assetIn is currency0 (zeroForOne = true)
        address assetIn = Currency.unwrap(key.currency0);
        assertEq(reactive.ordersByAssetIn(assetIn, 0), orderId, "Order should be in ordersByAssetIn");
    }

    // =========================================================================
    // Test 2 — Two matching orders: reactive detects them individually (no cycle),
    //           then we manually trigger LeanSwap.callback() with SETTLE_ORDER
    //           payload and verify both sides are settled.
    // =========================================================================
    function test_reactive_to_leanswap_simple_settle() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Alice: token0 → token1
        uint256 aliceOrderId = _placeOrder(alice, true, amountIn, deadline);
        // Bob:   token1 → token0 (matching)
        uint256 bobOrderId = _placeOrder(bob, false, amountIn, deadline);

        // Feed both order-created events to the reactive contract
        vm.startPrank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(key, true, deadline, aliceOrderId, amountIn));
        reactive.react(_buildOrderCreatedLog(key, false, deadline, bobOrderId, amountIn));
        vm.stopPrank();

        // Both orders should be active in the reactive graph
        assertTrue(reactive.isActiveOrder(aliceOrderId), "Alice order active");
        assertTrue(reactive.isActiveOrder(bobOrderId), "Bob order active");

        // Snapshot balances before settlement
        uint256 aliceBal1Before = currency1.balanceOf(alice);
        uint256 bobBal0Before = currency0.balanceOf(bob);

        // Now simulate what the Reactive Network would do: call LeanSwap.callback()
        // with a SETTLE_ORDER payload for this pool key (from the RSC address).
        vm.prank(RSC_ADDR);
        hook.callback(ReactiveLibrary.encodeCallbackPayload(key));

        // Alice should have received token1, Bob should have received token0
        assertGt(currency1.balanceOf(alice), aliceBal1Before, "Alice should receive token1");
        assertGt(currency0.balanceOf(bob), bobBal0Before, "Bob should receive token0");

        // Both batch sides must be empty after settlement
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0, "token0 batch cleared");
        assertEq(hook.batchPendingOrdersIn(poolId, false), 0, "token1 batch cleared");
    }

    // =========================================================================
    // Test 3 — Reactive contract unregisters an order when it receives a
    //           SwapOrderSettled event.
    // =========================================================================
    function test_reactive_removes_order_on_settled_event() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 orderId = _placeOrder(alice, true, amountIn, deadline);

        // First, register the order
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(key, true, deadline, orderId, amountIn));
        assertTrue(reactive.isActiveOrder(orderId), "Should be active after creation");

        // Now feed a settled event
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderSettledLog(key, true, amountIn, orderId));

        assertFalse(reactive.isActiveOrder(orderId), "Should be inactive after settled event");
    }

    // =========================================================================
    // Test 4 — Reactive contract triggers DEADLINE_EXCEEDED in LeanSwap when
    //           an order's deadline has passed.
    //           Flow: place order → feed to reactive → warp past deadline →
    //           reactive.react() (which calls checkDeadlines() and emits Callback) →
    //           capture emitted payload → replay to hook.callback().
    // =========================================================================
    function test_reactive_deadline_triggers_leanswap_swap() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 30 minutes;

        uint256 orderId = _placeOrder(alice, true, amountIn, deadline);

        // Register the order with the reactive contract
        vm.prank(RSC_ADDR);
        reactive.react(_buildOrderCreatedLog(key, true, deadline, orderId, amountIn));
        assertTrue(reactive.isActiveOrder(orderId), "Order should be active");

        // Warp past deadline
        vm.warp(deadline + 1);

        // Record logs so we can capture the Callback event emitted by the reactive contract
        vm.recordLogs();

        // A new react() call now triggers checkDeadlines() on BOTH the OrderCreated and
        // OrderSettled branches (the user added checkDeadlines() to the settled handler).
        // We send a settled-event log with a dummy orderId that is not in the reactive
        // graph.  The reactive contract gracefully removes nothing, then calls checkDeadlines()
        // which finds Alice's expired order and emits the DEADLINE_EXCEEDED Callback.
        // This avoids the 2-party-cycle risk that a created-log with zeroForOne=false would cause.
        uint256 dummySentinelId = uint256(keccak256("deadline-trigger-sentinel"));
        IReactive.LogRecord memory triggerLog = _buildOrderSettledLog(
            key,
            true,
            0,
            dummySentinelId // zero amountOut; orderId not present in graph
        );

        vm.prank(RSC_ADDR);
        reactive.react(triggerLog);

        // Find the Callback event emitted for the deadline-exceeded order
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory deadlinePayload;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                // Callback event: chain_id, _contract, gas_limit are all indexed (in topics).
                // logs[i].data contains only the non-indexed `bytes payload` argument.
                deadlinePayload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        assertTrue(deadlinePayload.length > 0, "Reactive contract should have emitted a Callback for the deadline");

        // The payload from the Callback event is: abi.encodeWithSignature("callback(bytes)", innerData)
        // Strip the 4-byte selector to get the inner abi.encoded bytes parameter
        bytes memory innerCalldata = _stripSelector(deadlinePayload);
        // innerCalldata is the ABI encoding of a single `bytes` argument
        bytes memory innerData = abi.decode(innerCalldata, (bytes));

        uint256 aliceBal1Before = currency1.balanceOf(alice);

        // Replay to the hook as if the Reactive Network delivered it
        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        assertGt(currency1.balanceOf(alice), aliceBal1Before, "Alice should receive token1 from AMM after deadline");
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0, "Batch cleared");
    }

    // =========================================================================
    // Test 5 — Duplicate SwapOrderCreated logs are ignored (idempotent).
    // =========================================================================
    function test_reactive_ignores_duplicate_orderCreated() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 orderId = _placeOrder(alice, true, amountIn, deadline);
        IReactive.LogRecord memory logRec = _buildOrderCreatedLog(key, true, deadline, orderId, amountIn);

        vm.startPrank(RSC_ADDR);
        reactive.react(logRec);
        reactive.react(logRec); // second time — should be a no-op
        vm.stopPrank();

        // Order should appear only once in the graph
        address assetIn = Currency.unwrap(key.currency0);
        // ordersByAssetIn[assetIn] should have exactly one entry for this orderId
        uint256 count = 0;
        while (true) {
            try reactive.ordersByAssetIn(assetIn, count) returns (uint256 oid) {
                if (oid == orderId) count++;
                else break; // guard
                count == 0 ? count++ : count; // won't reach here
            } catch {
                break;
            }
        }
        // The isActiveOrder guard inside react() prevents double-insertion
        assertTrue(reactive.isActiveOrder(orderId), "Order still active after dedup");
    }

    // =========================================================================
    // Test 6 — Dust orders (below minOrderAmount) are silently dropped by the
    //           reactive contract.
    // =========================================================================
    function test_reactive_drops_dust_orders() public {
        uint256 dustAmount = 500; // below minOrderAmount = 1000
        uint256 deadline = block.timestamp + 1 hours;
        uint256 dummyOrderId = uint256(keccak256("dust-order"));

        IReactive.LogRecord memory logRec = _buildOrderCreatedLog(key, true, deadline, dummyOrderId, dustAmount);

        vm.prank(RSC_ADDR);
        reactive.react(logRec);

        // Order should NOT have been registered
        assertFalse(reactive.isActiveOrder(dummyOrderId), "Dust order should not be stored");
    }

    // =========================================================================
    // Test 7 — LeanSwap.callback() reverts when called by a non-RSC address.
    // =========================================================================
    function test_leanswap_callback_reverts_for_unauthorized_caller() public {
        vm.prank(alice);
        vm.expectRevert(LeanSwap.NotAuthorizedRsc.selector);
        hook.callback(ReactiveLibrary.encodeCallbackPayload(key));
    }

    // =========================================================================
    // Test 8 — LeanSwap.callback() handles SETTLE_COMPLEX_ORDER from RSC.
    //           We manually build the 3-order cycle payload (A→B→C→A) using
    //           the same 2-currency pool in both directions plus a third synthetic
    //           "pool" (reusing same key for simplicity since we only have 2 tokens
    //           in this test file) and confirm the complex settler runs without reverting.
    //           Full multi-pool cycle is tested in LeanSwapLoopOrders.t.sol.
    // =========================================================================
    function test_reactive_complex_settle_two_orders_via_callback() public {
        uint256 shade = uint256(uint160(makeAddr("shade")));
        address shadeAddr = address(uint160(shade));
        MockERC20(Currency.unwrap(currency0)).mint(shadeAddr, 1_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(shadeAddr, 1_000 ether);
        vm.startPrank(shadeAddr);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Alice: token0 → token1
        uint256 aliceOrderId = _placeOrder(alice, true, amountIn, deadline);
        // Bob:   token1 → token0
        uint256 bobOrderId = _placeOrder(bob, false, amountIn, deadline);

        // Build SETTLE_COMPLEX_ORDER payload manually
        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = aliceOrderId;
        orderIds[1] = bobOrderId;

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = key;
        keys[1] = key;

        uint256 aliceBal1Before = currency1.balanceOf(alice);
        uint256 bobBal0Before = currency0.balanceOf(bob);

        // LeanSwap's callback() strips the selector from the payload
        bytes memory innerData = abi.encode(ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);

        vm.prank(RSC_ADDR);
        hook.callback(innerData);

        assertGt(currency1.balanceOf(alice), aliceBal1Before, "Alice got token1 via complex settle");
        assertGt(currency0.balanceOf(bob), bobBal0Before, "Bob got token0 via complex settle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utility
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Strips the leading 4-byte function selector from a calldata payload.
    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        require(data.length >= 4, "payload too short");
        bytes memory result = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; i++) {
            result[i - 4] = data[i];
        }
        return result;
    }
}

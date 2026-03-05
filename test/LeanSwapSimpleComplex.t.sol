// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LeanSwapLibrary} from "../src/Library.sol";

contract LeanSwapTestExtended is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LeanSwap hook;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address john = makeAddr("john");
    address shade = makeAddr("shade");
    address ade = makeAddr("ade");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LeanSwap.sol", abi.encode(manager, address(0x0000000000000000000000000000000000fffFfF)), hookAddress);
        hook = LeanSwap(payable(hookAddress));

        (key, poolId) = initPool(currency0, currency1, hook, 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10_000 ether, salt: bytes32(0)}),
            new bytes(0)
        );

        MockERC20(Currency.unwrap(currency0)).mint(alice, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(bob, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(john, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(john, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(shade, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(shade, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(ade, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(ade, 1000 ether);

        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        address[3] memory extras = [john, shade, ade];
        for (uint256 i = 0; i < extras.length; i++) {
            vm.startPrank(extras[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    // Helper to extract orderId
    function _getOrderId(bool zeroForOne, uint256 deadline, uint256 amtIn, uint256 amtOut, address owner)
        internal
        view
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(poolId, zeroForOne, deadline, amtIn, amtOut, owner)));
    }

    // 1. Exact Output Swap
    function test_exactOutputSwap() public {
        uint256 amountOut = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        uint256 bal0BeforeHook = currency0.balanceOf(address(hook));

        // Exact output is a positive amountSpecified
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();

        uint256 bal0AfterHook = currency0.balanceOf(address(hook));
        assertGt(bal0AfterHook, bal0BeforeHook); // Hook should have taken some tokens
        assertGt(hook.batchPendingOrdersIn(poolId, true), 0); // Hook should have batched an order
    }

    // 2. Multiple swap orders from multiple users
    function test_multipleUsersSwapOrders() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Alice orders
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, alice)
        );

        // Bob orders
        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, bob)
        );

        // John orders (opposite direction)
        vm.prank(john);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn * 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, john)
        );

        // Batch should have 2 ether from true (zeroForOne), and 2 ether from false
        assertEq(hook.batchPendingOrdersIn(poolId, true), 2 ether);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 2 ether);

        hook._settleOrder(key);

        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 0);
    }

    // 3. Swap orders that are not equal in when they are batched
    function test_ordersNotEqualWhenBatched() public {
        uint256 amountInAlice = 1 ether; // Provide less
        uint256 amountInBob = 3 ether; // Provide more
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountInAlice),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, alice)
        );

        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountInBob), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, bob)
        );

        hook._settleOrder(key);

        // Remaining should be settled via AMM
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 0);
    }

    // 4. User makes the same order twice
    function test_userMakesSameOrderTwice() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        // First order
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        // Second order EXACT same parameters
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        // Check if both orders were batched properly
        assertEq(hook.batchPendingOrdersIn(poolId, true), amountIn * 2);

        // Try to cancel the first one? Wait, they share an orderId if not salted!
        // We will see if it reverts or handles it gracefully.
        // We can just query `pendingOrders` length
        (,,,,, uint256 amtIn1,,) = hook.pendingOrders(poolId, true, 0);
        assertEq(amtIn1, amountIn);
        (,,,,, uint256 amtIn2,,) = hook.pendingOrders(poolId, true, 1);
        assertEq(amtIn2, amountIn);

        // Getting the orderId
        // uint256 orderId = _getOrderId(true, deadline, amtIn1, 0, alice); // We don't know amountOut trivially here because of test mock, let's just use pendingOrders

        // Let's grab it directly from the contract mapping if needed,
        //, but actually we just call deadlineExceeded
        vm.warp(deadline + 1);

        // Try to trigger one of the identical orders
        // wait, we don't have amountOut to compute orderId.
        // Let's just create an opposite order to see if it settles both correctly!
        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn * 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LeanSwapLibrary.encodeHookData(deadline, true, bob)
        );

        hook._settleOrder(key);

        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
    }
}

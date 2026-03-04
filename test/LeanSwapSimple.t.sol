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

contract LeanSwapTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LeanSwap hook;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LeanSwap.sol", abi.encode(manager), hookAddress);
        hook = LeanSwap(hookAddress);

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
    }

    function test_skipCoW_if_flag_false() public {
        uint256 amountIn = 1 ether;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(0, false, alice);

        vm.startPrank(alice);
        uint256 bal0Before = currency0.balanceOf(alice);
        uint256 bal1Before = currency1.balanceOf(alice);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();

        assertEq(bal0Before - currency0.balanceOf(alice), amountIn);
        assertGt(currency1.balanceOf(alice), bal1Before);
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
    }

    function test_placeOrder() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        uint256 bal0BeforeHook = currency0.balanceOf(address(hook));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();

        uint256 bal0AfterHook = currency0.balanceOf(address(hook));
        assertEq(hook.batchPendingOrdersIn(poolId, true), amountIn);
        assertEq(bal0AfterHook - bal0BeforeHook, amountIn);

        (address owner,, bool zeroForOne, bool fulfilled, bool canceled, uint256 amtIn,, uint256 dl) =
            hook.pendingOrders(poolId, true, 0);
        assertEq(owner, alice);
        assertEq(zeroForOne, true);
        assertEq(fulfilled, false);
        assertEq(canceled, false);
        assertEq(amtIn, amountIn);
        assertEq(dl, deadline);
    }

    // Helper to extract orderId
    function _getOrderId(bool zeroForOne) internal view returns (uint256) {
        (,,,,, uint256 amtIn, uint256 amtOut, uint256 dl) = hook.pendingOrders(poolId, zeroForOne, 0);
        return uint256(keccak256(abi.encode(poolId, zeroForOne, dl, amtIn, amtOut, alice)));
    }

    function test_cancelOrder() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        uint256 orderId = _getOrderId(true);
        uint256 bal0Before = currency0.balanceOf(alice);
        hook.cancelOrder(key, orderId);

        uint256 bal0After = currency0.balanceOf(alice);

        assertEq(bal0After - bal0Before, amountIn); // Refunded
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0); // Batch removed

        vm.expectRevert();
        hook.pendingOrders(poolId, true, 0); // Should revert due to out-of-bounds array access

        vm.stopPrank();
    }

    function test_cancelOrder_NotOwner() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();

        uint256 orderId = _getOrderId(true);

        vm.startPrank(bob);
        vm.expectRevert(LeanSwap.NotOnwerOfOrder.selector);
        hook.cancelOrder(key, orderId);
        vm.stopPrank();
    }

    function test_deadlineExceeded_revertsIfEarly() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        uint256 orderId = _getOrderId(true);

        vm.expectRevert(LeanSwap.DeadlineNotMatured.selector);
        hook.deadlineExceeded(key, orderId);
        vm.stopPrank();
    }

    function test_deadlineExceeded_executesSwap() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();

        uint256 orderId = _getOrderId(true);

        vm.warp(deadline + 1); // Pass the deadline

        uint256 bal1Before = currency1.balanceOf(alice);

        // Anyone can call deadlineExceeded since it just processes the swap for the original owner
        hook.deadlineExceeded(key, orderId);

        uint256 bal1After = currency1.balanceOf(alice);

        assertGt(bal1After, bal1Before); // Alice received token1 from AMM swap
        assertEq(hook.batchPendingOrdersIn(poolId, true), 0); // Batch removed
    }

    function test_settleOrder_matchEqual() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory aliceHookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);
        bytes memory bobHookData = LeanSwapLibrary.encodeHookData(deadline, true, bob);

        // Alice wants token1 by giving token0
        vm.startPrank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            aliceHookData
        );
        vm.stopPrank();

        // Bob wants token0 by giving token1
        vm.startPrank(bob);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bobHookData
        );
        vm.stopPrank();

        uint256 aliceBal1Before = currency1.balanceOf(alice);
        uint256 bobBal0Before = currency0.balanceOf(bob);

        hook.settleOrder(key);

        assertEq(currency1.balanceOf(alice) - aliceBal1Before, amountIn); // 1:1 match
        assertEq(currency0.balanceOf(bob) - bobBal0Before, amountIn); // 1:1 match

        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 0);
    }
}

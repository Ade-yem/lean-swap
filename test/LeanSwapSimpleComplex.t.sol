// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
// import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LeanSwapLibrary, ReactiveLibrary} from "../src/Library.sol";
import {LeanSwapRouter} from "../src/LeanSwapRouter.sol";

contract LeanSwapTestExtended is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LeanSwap hook;
    PoolId poolId;
    LeanSwapRouter router;

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
        deployCodeTo(
            "LeanSwap.sol", abi.encode(manager, address(0x0000000000000000000000000000000000fffFfF), address(this)), hookAddress
        );
        hook = LeanSwap(payable(hookAddress));
        router = new LeanSwapRouter(manager);

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
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        address[3] memory extras = [john, shade, ade];
        for (uint256 i = 0; i < extras.length; i++) {
            vm.startPrank(extras[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    // Helper to extract orderId — mirrors LeanSwap.getOrderId (includes nonce)
    // Order struct layout: owner, zeroForOne, fulfilled, canceled, deadline(uint64), poolId, amountIn, amountOut, nonce
    function _getOrderId(bool zeroForOne, uint256 index) internal view returns (uint256) {
        (,,,, uint64 dl,, uint256 amtIn, uint256 amtOut, uint256 nonce,) = hook.pendingOrders(poolId, zeroForOne, index);
        // Recover the owner by reading it from the order struct
        (address owner,,,,,,,,,) = hook.pendingOrders(poolId, zeroForOne, index);
        return uint256(keccak256(abi.encode(poolId, zeroForOne, dl, amtIn, amtOut, owner, nonce)));
    }

    // 1. Exact Output Swap
    // function test_exactOutputSwap() public {
    //     uint256 amountOut = 1 ether;
    //     uint256 deadline = block.timestamp + 1 hours;
    //     bytes memory hookData = LeanSwapLibrary.encodeHookData(deadline, true, alice);

    //     vm.startPrank(alice);
    //     uint256 bal0BeforeHook = currency0.balanceOf(address(hook));

    //     // Exact output is a positive amountSpecified
    //     router.swap(
    //         key,
    //         SwapParams({
    //             zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),

    //         hookData,
    // amountIn
    //     );
    //     vm.stopPrank();

    //     uint256 bal0AfterHook = currency0.balanceOf(address(hook));
    //     assertGt(bal0AfterHook, bal0BeforeHook); // Hook should have taken some tokens
    //     assertGt(hook.batchPendingOrdersIn(poolId, true), 0); // Hook should have batched an order
    // }

    // 2. Multiple swap orders from multiple users
    function test_multipleUsersSwapOrders() public {
        uint256 amountIn = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Alice orders
        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            LeanSwapLibrary.encodeHookData(deadline, true, alice),
            amountIn
        );

        // Bob orders
        vm.prank(bob);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            LeanSwapLibrary.encodeHookData(deadline, true, bob),
            amountIn
        );

        // John orders (opposite direction)
        vm.prank(john);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn * 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            LeanSwapLibrary.encodeHookData(deadline, true, john),
            amountIn * 2
        );

        // Batch should have 2 ether from true (zeroForOne), and 2 ether from false
        assertEq(hook.batchPendingOrdersIn(poolId, true), 2 ether);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 2 ether);

        vm.startPrank(address(0x0000000000000000000000000000000000fffFfF));
        hook.callback(ReactiveLibrary.encodeCallbackPayload(key));
        vm.stopPrank();

        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
        assertEq(hook.batchPendingOrdersIn(poolId, false), 0);
    }

    // 3. Swap orders that are not equal when they are batched
    function test_ordersNotEqualWhenBatched() public {
        uint256 amountInAlice = 1 ether; // Provide less
        uint256 amountInBob = 3 ether; // Provide more
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountInAlice),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            LeanSwapLibrary.encodeHookData(deadline, true, alice),
            amountInAlice
        );

        vm.prank(bob);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountInBob), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            LeanSwapLibrary.encodeHookData(deadline, true, bob),
            amountInBob
        );

        vm.startPrank(address(0x0000000000000000000000000000000000fffFfF));
        hook.callback(ReactiveLibrary.encodeCallbackPayload(key));
        vm.stopPrank();

        // Both sides should be fully settled (remainder goes through AMM)
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
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // casting to 'int256' is safe because amountIn < type(int256).max
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookData,
            amountIn
        );

        // Second order EXACT same parameters — nonce increments so it gets a unique orderId
        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // casting to 'int256' is safe because amountIn < type(int256).max
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            hookData,
            amountIn
        );

        // Check if both orders were batched properly
        assertEq(hook.batchPendingOrdersIn(poolId, true), amountIn * 2);

        // Verify both orders exist in the pending array with the correct amountIn
        // Order struct layout: owner, zeroForOne, fulfilled, canceled, deadline(uint64), poolId, amountIn, amountOut, nonce
        (,,,,,, uint256 amtIn1,,,) = hook.pendingOrders(poolId, true, 0);
        assertEq(amtIn1, amountIn);
        (,,,,,, uint256 amtIn2,,,) = hook.pendingOrders(poolId, true, 1);
        assertEq(amtIn2, amountIn);

        // vm.warp(deadline + 1);

        // Bob places an opposite order to trigger batch settlement of both alice orders.
        // Use a fresh deadline AFTER the warp so Bob's own swap doesn't revert with DeadlineExpired.
        uint256 bobDeadline = block.timestamp + 1 hours;
        vm.prank(bob);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                // casting to 'int256' is safe because amountIn * 2 < type(int256).max
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn * 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            LeanSwapLibrary.encodeHookData(bobDeadline, true, bob),
            amountIn * 2
        );

        vm.startPrank(address(0x0000000000000000000000000000000000fffFfF));
        hook.callback(ReactiveLibrary.encodeCallbackPayload(key));
        vm.stopPrank();

        assertEq(hook.batchPendingOrdersIn(poolId, true), 0);
    }
}

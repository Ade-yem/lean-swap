// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {LeanSwapLibrary} from "./Library.sol";

contract LeanSwap is BaseHook {
    using LeanSwapLibrary for bytes;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    // Enum
    enum REASON {
        DEADLINE_EXCEEDED,
        SETTLE_ORDER
    }

    // Struct for the order
    struct Order {
        address owner;
        PoolId poolId;
        bool zeroForOne;
        bool fulfilled;
        bool canceled;
        uint256 amountIn;
        uint256 amountOut;
        uint256 deadline;
    }

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        bytes hookData;
        REASON reason;
    }

    // Errors
    error ExactInputRequired();
    error NotOnwerOfOrder();
    error SwapOrderNotFound();
    error DeadlineNotMatured();
    error CallerNotPoolManager();

    // Events
    event SwapOrderCancelled(address owner, PoolKey poolKey, uint256 amount);
    event SwapOrderDeadlineExceeded(address owner, PoolKey poolKey, uint256 amount);
    event SwapOrderCreated(PoolKey pookKey, bool zeroForOne, uint256 deadline);

    // Mappings
    // Basically, we can have multiple orders for thesame deadline, for that deadline, we can have multiple zeroForOne orders or non zeroForOne orders
    // pendingOrders[poolId][zeroForOne] = order
    mapping(PoolId poolId => mapping(bool zeroForOne => Order[] order)) public pendingOrders;
    // Aggregation of all orders for thesame pool
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 totalAmount)) public batchPendingOrdersIn;
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 totalAmount)) public batchPendingOrdersOut;
    // Indexes of the order so it can be removed
    mapping(uint256 orderId => Order order) public orders;
    mapping(uint256 orderId => uint256 index) public orderIndex;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// Hook permission selector
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook functionality
    /// @inheritdoc BaseHook
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 deadline, bool useCoW, address owner) = hookData.decodeHookData();
        if (!useCoW) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        } else {
            // We want to place an order for the user.
            // We want to give ownership of the token to the smart contract
            // We want to return a no op to the pool manager
            PoolId poolId = key.toId();
            bool zeroForOne = params.zeroForOne;
            // The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
            int256 inputAmount = params.amountSpecified;
            // We want to simulate the swapping to determine the amount of token1 that the user is going to get or the amount of token0 the user is going to pay
            (uint256 tokenIn, uint256 tokenOut, BeforeSwapDelta beforeSwapDelta_) = simulateSwap(poolId, params);

            uint128 amountToTake = inputAmount < 0 ? uint128(uint256(-inputAmount)) : uint128(tokenIn);
            takeAndSettle(key, zeroForOne, amountToTake);

            placeOrder(poolId, owner, zeroForOne, tokenIn, tokenOut, deadline);
            emit SwapOrderCreated(key, zeroForOne, deadline);
            return (this.beforeSwap.selector, beforeSwapDelta_, 0);
        }
    }

    function placeOrder(
        PoolId _poolId,
        address owner,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 deadline
    ) internal returns (uint256 orderId) {
        Order memory order = Order({
            owner: owner,
            poolId: _poolId,
            zeroForOne: zeroForOne,
            fulfilled: false,
            canceled: false,
            amountIn: amountIn,
            amountOut: amountOut,
            deadline: deadline
        });
        pendingOrders[_poolId][zeroForOne].push(order);
        batchPendingOrdersIn[_poolId][zeroForOne] += amountIn;
        batchPendingOrdersOut[_poolId][zeroForOne] += amountOut;
        orderId = getOrderId(_poolId, zeroForOne, deadline, amountIn, amountOut, order.owner);
        orderIndex[orderId] = pendingOrders[_poolId][zeroForOne].length;
        orders[orderId] = order;
    }

    /// It swaps the token in one swap order for the second one
    /// @notice Handles simple pool match and routes the net imbalance to the Uniswap V4 Pool.
    /// @param key Pool key
    function settleOrder(PoolKey calldata key) public {
        PoolId poolId = key.toId();

        uint256 amountOfToken0In = batchPendingOrdersIn[poolId][true];
        uint256 amountOfToken1In = batchPendingOrdersIn[poolId][false];

        if (amountOfToken0In == 0 && amountOfToken1In == 0) return; // Nothing to settle

        // 1. Get current pool state to determine the fair internal matching price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // 2. Determine value of token0 in terms of token1 at current spot price
        uint256 ratioX192 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1);
        uint256 token0ValueInToken1 = FullMath.mulDivRoundingUp(amountOfToken0In, ratioX192, 1 << 192);

        uint256 totalToken1ForToken0Sellers;
        uint256 totalToken0ForToken1Sellers;

        // 3. Match internal liquidity and swap the imbalance
        if (token0ValueInToken1 > amountOfToken1In) {
            // Excess Token0. Match all Token1 internally.
            totalToken0ForToken1Sellers = amountOfToken1In;

            // Calculate the token0 imbalance to swap to the pool
            // Imbalance = total token0 - token0 needed to match token1
            uint256 token0ToSwap =
                amountOfToken0In - ((amountOfToken1In << 192) / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)));

            if (token0ToSwap > 0) {
                BalanceDelta delta = abi.decode(
                    poolManager.unlock(
                        abi.encode(
                            CallbackData({
                                key: key,
                                params: SwapParams({
                                    zeroForOne: true,
                                    amountSpecified: -token0ToSwap.toInt256(), // Exact input
                                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                                }),
                                hookData: LeanSwapLibrary.encodeHookData(0, false, address(0)),
                                reason: REASON.SETTLE_ORDER
                            })
                        )
                    ),
                    (BalanceDelta)
                );
                totalToken1ForToken0Sellers = amountOfToken1In + int256(delta.amount1()).toUint256();
            } else {
                totalToken1ForToken0Sellers = amountOfToken1In;
            }
        } else {
            // Excess Token1. Match all Token0 internally.
            totalToken1ForToken0Sellers = amountOfToken0In;

            // Calculate the token1 imbalance to swap
            uint256 token1ToSwap = amountOfToken1In - token0ValueInToken1;

            if (token1ToSwap > 0) {
                BalanceDelta delta = abi.decode(
                    poolManager.unlock(
                        abi.encode(
                            CallbackData({
                                key: key,
                                params: SwapParams({
                                    zeroForOne: false,
                                    amountSpecified: -token1ToSwap.toInt256(), // Exact input
                                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                                }),
                                hookData: LeanSwapLibrary.encodeHookData(0, false, address(0)),
                                reason: REASON.SETTLE_ORDER
                            })
                        )
                    ),
                    (BalanceDelta)
                );
                totalToken0ForToken1Sellers = amountOfToken0In + int256(delta.amount0()).toUint256();
            } else {
                totalToken0ForToken1Sellers = amountOfToken0In;
            }
        }

        // 4. Distribute fulfilled amounts to orders proportionally
        _distributeSettlement(key, true, amountOfToken0In, totalToken1ForToken0Sellers);
        _distributeSettlement(key, false, amountOfToken1In, totalToken0ForToken1Sellers);

        // 5. Reset the batches
        batchPendingOrdersIn[poolId][true] = 0;
        batchPendingOrdersIn[poolId][false] = 0;
        batchPendingOrdersOut[poolId][true] = 0;
        batchPendingOrdersOut[poolId][false] = 0;
    }

    function cancelOrder(PoolKey calldata key, uint256 orderId) public {
        if (orderIndex[orderId] == 0) revert SwapOrderNotFound();
        Order memory order = orders[orderId];
        // Ensure the caller is the owner of the order
        if (order.owner != msg.sender) revert NotOnwerOfOrder();
        // We want to remove the order from the pending orders listusing swap and pop
        Order[] storage memOrders = pendingOrders[order.poolId][order.zeroForOne];
        uint256 index = orderIndex[orderId] - 1;
        uint256 lastIndex = memOrders.length - 1;
        // Swap and pop
        if (index != lastIndex) {
            Order storage lastOrder = memOrders[lastIndex];
            uint256 lastOrderId = getOrderId(
                lastOrder.poolId,
                lastOrder.zeroForOne,
                lastOrder.deadline,
                lastOrder.amountIn,
                lastOrder.amountOut,
                lastOrder.owner
            );
            memOrders[index] = lastOrder;
            orderIndex[lastOrderId] = index + 1;
        }
        memOrders.pop();
        // Remove from batch
        batchPendingOrdersIn[order.poolId][order.zeroForOne] -= order.amountIn;
        batchPendingOrdersOut[order.poolId][order.zeroForOne] -= order.amountOut;
        // make the order's amount claimable to zero
        orders[orderId].canceled = true;
        orderIndex[orderId] = 0;
        Currency token = order.zeroForOne ? key.currency0 : key.currency1;
        token.transfer(order.owner, order.amountIn);
        emit SwapOrderCancelled(order.owner, key, order.amountIn);
    }

    function deadlineExceeded(PoolKey calldata key, uint256 orderId) public {
        if (orderIndex[orderId] == 0) revert SwapOrderNotFound();
        Order memory order = orders[orderId];
        if (block.timestamp < order.deadline) revert DeadlineNotMatured();
        // We want to remove the order from the pending orders listusing swap and pop
        Order[] storage memOrders = pendingOrders[order.poolId][order.zeroForOne];
        uint256 index = orderIndex[orderId] - 1;
        uint256 lastIndex = memOrders.length - 1;
        // Swap and pop
        if (index != lastIndex) {
            Order storage lastOrder = memOrders[lastIndex];
            uint256 lastOrderId = getOrderId(
                lastOrder.poolId,
                lastOrder.zeroForOne,
                lastOrder.deadline,
                lastOrder.amountIn,
                lastOrder.amountOut,
                lastOrder.owner
            );
            memOrders[index] = lastOrder;
            orderIndex[lastOrderId] = index + 1;
        }
        memOrders.pop();
        // Remove from batch
        batchPendingOrdersIn[order.poolId][order.zeroForOne] -= order.amountIn;
        batchPendingOrdersOut[order.poolId][order.zeroForOne] -= order.amountOut;
        // make the order's amount claimable to zero
        orders[orderId].canceled = true;
        orderIndex[orderId] = 0;
        BalanceDelta delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        key: key,
                        params: SwapParams({
                            zeroForOne: order.zeroForOne,
                            amountSpecified: -order.amountIn.toInt256(), // Exact input
                            sqrtPriceLimitX96: order.zeroForOne
                                ? TickMath.MIN_SQRT_PRICE + 1
                                : TickMath.MAX_SQRT_PRICE - 1
                        }),
                        hookData: LeanSwapLibrary.encodeHookData(0, false, order.owner),
                        reason: REASON.DEADLINE_EXCEEDED
                    })
                )
            ),
            (BalanceDelta)
        );
        Currency token = order.zeroForOne ? key.currency1 : key.currency0;
        uint256 amountToSend =
            order.zeroForOne ? int256(delta.amount1()).toUint256() : int256(delta.amount0()).toUint256();
        token.transfer(order.owner, amountToSend);
        emit SwapOrderDeadlineExceeded(order.owner, key, order.amountIn);
    }

    /// Callback for the pool manager
    function unlockCallback(bytes calldata callbackData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();
        CallbackData memory data = abi.decode(callbackData, (CallbackData));
        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        // 2. Settle the exact Delta dynamically based on signs!

        // Settle token0
        if (delta.amount0() < 0) {
            // Hook owes PoolManager token0
            _settle(data.key.currency0, uint128(uint256(int256(-delta.amount0()))));
        } else if (delta.amount0() > 0) {
            // PoolManager owes Hook token0
            _take(data.key.currency0, uint128(uint256(int256(delta.amount0()))));
        }

        // Settle token1
        if (delta.amount1() < 0) {
            // Hook owes PoolManager token1
            _settle(data.key.currency1, uint128(uint256(int256(-delta.amount1()))));
        } else if (delta.amount1() > 0) {
            // PoolManager owes Hook token1
            _take(data.key.currency1, uint128(uint256(int256(delta.amount1()))));
        }

        return abi.encode(delta);
    }

    // =================== Helper Functions ==================

    /// Calculate what would happen if the swap went through the Uniswap AMM right now, without actually executing it.
    /// @param poolId Id of the pool
    /// @param params Swap params
    /// @return tokenIn amount of eth from the wallet
    /// @return tokenOut amount of token sent back to the user
    /// @return beforeSwapDelta_ BeforeSwapDelta
    function simulateSwap(PoolId poolId, SwapParams memory params)
        internal
        view
        returns (uint256 tokenIn, uint256 tokenOut, BeforeSwapDelta beforeSwapDelta_)
    {
        // Get the current price for the pool to use as a price basis for the swap
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (params.amountSpecified >= 0) {
            // token0 for token1 with exact output for input
            // If the amount specified for token1 is greater than what we have in the pool fees from deposit fees,
            // we use poolFees amount1 otherwise, we use amountSpecified for the swap
            // We want to determine the maximum value
            uint256 amountSpecified = params.amountSpecified.toUint256();

            // We want to determine the amount of ETH token required to get the amount of token1 specified at the current pool state
            (, tokenIn, tokenOut,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: amountSpecified.toInt256(),
                feePips: 0
            });
            // Update our hook delta to reduce the upcoming swap amount to show that we have
            // already spent some of the ETH and received some of the underlying ERC20.
            beforeSwapDelta_ = toBeforeSwapDelta(
                -tokenIn.toInt256().toInt128(), // specified is negative for exactIn
                0 // unspecified is 0 because user receives output upon fulfillment
            );
        } else {
            // token0 for token1 with exact input for output
            // amountSpecified is negative
            // Since we already know the amount of token0 required, we just need to
            // determine the amount we will receive if we convert all of the pool fees.
            (, tokenIn, tokenOut,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: params.amountSpecified,
                feePips: 0
            });

            if (tokenIn > (-params.amountSpecified).toUint256()) {
                uint256 percentage = ((-params.amountSpecified).toUint256() * 1e18) / tokenIn;
                tokenOut = (tokenOut * percentage) / 100;
            }
            beforeSwapDelta_ = toBeforeSwapDelta((-params.amountSpecified).toInt128(), 0);
        }
    }

    /// @notice Simulates a swap to calculate expected output/input amounts and the corresponding BeforeSwapDelta.
    /// @dev This function uses the current pool price and liquidity to estimate the swap outcome without executing it.
    /// It is primarily used to determine the parameters for limit orders or CoW (Coincidence of Wants) matching
    /// by calculating how
    function takeAndSettle(PoolKey calldata key, bool zeroForOne, uint128 amount) internal {
        if (zeroForOne) {
            // take currency zero and settle currency 1
            _take(key.currency0, amount);
        } else {
            _take(key.currency1, amount);
        }
    }

    /// @dev Helper to iterate through orders and assign their proportional output
    function _distributeSettlement(PoolKey calldata key, bool zeroForOne, uint256 totalInput, uint256 totalOutput)
        internal
    {
        PoolId poolId = key.toId();
        uint256 totalOrders = pendingOrders[poolId][zeroForOne].length;
        if (totalOrders == 0 || totalInput == 0) return;

        for (uint256 i = 0; i < totalOrders; i++) {
            Order memory order = pendingOrders[poolId][zeroForOne][i];
            uint256 orderId = getOrderId(
                order.poolId, order.zeroForOne, order.deadline, order.amountIn, order.amountOut, order.owner
            );

            // Calculate proportional share: (order.amountIn / totalInput) * totalOutput
            uint256 actualAmountOut = (order.amountIn * totalOutput) / totalInput;

            // Update order state
            orders[orderId].fulfilled = true;
            // Transfer the actual token to the user
            Currency outCurrency = order.zeroForOne ? key.currency1 : key.currency0;
            outCurrency.transfer(order.owner, actualAmountOut);
        }

        // Clear the array since they are processed
        delete pendingOrders[poolId][zeroForOne];
    }

    /// Settle currency with pool manager
    /// @param currency Currency to settle
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        if (amount > 0) currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// Take the money from the user and add it to the smart contract
    /// @param currency Currency of the swap
    /// @param amount Amount to take
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    /// Deterministic function to get the order id of the swap
    /// @param _poolId Pool Id
    /// @param zeroForOne direction
    /// @param deadline deadline of CoW swap
    /// @param amountIn Amount of token in
    /// @param amountOut Amount of token out
    /// @return orderId order id of the swap
    function getOrderId(
        PoolId _poolId,
        bool zeroForOne,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOut,
        address owner
    ) internal pure returns (uint256 orderId) {
        return uint256(keccak256(abi.encode(_poolId, zeroForOne, deadline, amountIn, amountOut, owner)));
    }
}

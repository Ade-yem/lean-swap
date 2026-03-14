// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;
import {console} from "forge-std/console.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {LeanSwapLibrary, ReactiveLibrary} from "./Library.sol";

contract LeanSwap is BaseHook, AbstractCallback, Ownable, ReentrancyGuard {
    using LeanSwapLibrary for bytes;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // Enum
    enum REASON {
        DEADLINE_EXCEEDED,
        SETTLE_ORDER
    }

    // Struct for the order
    // Storage-packed: booleans + uint64 deadline fit into one slot together with address (20 bytes)
    struct Order {
        address owner; // 20 bytes
        bool zeroForOne; // 1  byte  \
        bool fulfilled; // 1  byte   > pack into one 32-byte slot with owner
        bool canceled; // 1  byte  /
        uint64 deadline; // 8  bytes /
        PoolId poolId; // 32 bytes (separate slot)
        uint256 amountIn; // 32 bytes
        uint256 amountOut; // 32 bytes
        uint256 nonce; // 32 bytes
        uint256 minAmountOut;
    }

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        bytes hookData;
        REASON reason;
    }

    // ── Custom Errors (saves gas vs. require strings) ────────────────────────
    error ExactInputRequired();
    error NotOwnerOfOrder();
    error SwapOrderNotFound();
    error DeadlineNotMatured();
    error DeadlineExpired();
    error CallerNotPoolManager();
    error NotAuthorizedRsc();
    error AmountTooSmall();
    error MaxOrdersReached();
    error ArrayLengthMismatch();
    error MaxCycleDepthExceeded();
    error PoolKeyMismatch();
    error FundInsolvency();

    // Events
    event SwapOrderCancelled(address owner, PoolKey poolKey, uint256 amount);
    event SwapOrderDeadlineExceededSettled(address owner, PoolKey poolKey, uint256 amount, uint256 orderId);
    event SwapOrderCreated(PoolKey poolKey, bool zeroForOne, uint256 deadline, uint256 orderId, uint256 amountIn);
    event SwapOrderSettled(PoolKey poolKey, bool zeroForOne, uint256 amountOut, uint256 orderId);

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant MAX_ORDERS_PER_POOL_SIDE = 100;
    uint256 public constant MAX_CYCLE_DEPTH = 10; // callback validation cap
    uint256 public constant MIN_ORDER_AMOUNT = 1000; // minimum token units to prevent spam

    // Reactive smart contract address
    address rscAddress;
    // Nonce for orders
    uint256 nonce = 1;

    // Mappings
    // pendingOrders[poolId][zeroForOne] = order[]
    mapping(PoolId poolId => mapping(bool zeroForOne => Order[] order)) public pendingOrders;
    // Aggregation of all orders for the same pool
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 totalAmount)) public batchPendingOrdersIn;
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 totalAmount)) public batchPendingOrdersOut;
    // Indexes of the order so it can be removed (stored as real 0-based index + 1, so 0 means "not present")
    mapping(uint256 orderId => Order order) public orders;
    mapping(uint256 orderId => uint256 index) public orderIndex; // stores (realIndex + 1)

    constructor(IPoolManager _poolManager, address _reactiveService)
        BaseHook(_poolManager)
        AbstractCallback(_reactiveService)
        Ownable(msg.sender)
    {
        rscAddress = _reactiveService;
    }

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
        (uint256 deadline, bool useCoW, address owner, uint256 minAmountOut) = hookData.decodeHookData();
        if (!useCoW) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        } else {
            // Validate deadline hasn't already passed
            if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();

            PoolId poolId = key.toId();
            bool zeroForOne = params.zeroForOne;
            (uint256 tokenIn, uint256 tokenOut, BeforeSwapDelta beforeSwapDelta_) = simulateSwap(poolId, params);

            takeAndSettle(key, zeroForOne, tokenIn.toUint128());

            uint256 orderId = placeOrder(poolId, owner, zeroForOne, tokenIn, tokenOut, minAmountOut, uint64(deadline));
            emit SwapOrderCreated(key, zeroForOne, deadline, orderId, tokenIn);
            return (this.beforeSwap.selector, beforeSwapDelta_, 0);
        }
    }

    function placeOrder(
        PoolId _poolId,
        address owner,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 minAmountOut,
        uint64 deadline
    ) internal returns (uint256 orderId) {
        if (amountIn < MIN_ORDER_AMOUNT) revert AmountTooSmall();
        if (pendingOrders[_poolId][zeroForOne].length >= MAX_ORDERS_PER_POOL_SIDE) revert MaxOrdersReached();

        Order memory order = Order({
            owner: owner,
            poolId: _poolId,
            zeroForOne: zeroForOne,
            fulfilled: false,
            canceled: false,
            amountIn: amountIn,
            amountOut: amountOut,
            deadline: deadline,
            nonce: nonce,
            minAmountOut: minAmountOut
        });

        // Store real 0-based index + 1 so that 0 can serve as "not present" sentinel
        uint256 realIndex = pendingOrders[_poolId][zeroForOne].length;
        pendingOrders[_poolId][zeroForOne].push(order);
        batchPendingOrdersIn[_poolId][zeroForOne] += amountIn;
        batchPendingOrdersOut[_poolId][zeroForOne] += amountOut;

        orderId = getOrderId(_poolId, zeroForOne, deadline, amountIn, amountOut, owner, nonce);
        orderIndex[orderId] = realIndex + 1; // +1 so 0 means "absent"
        orders[orderId] = order;
        nonce++;
    }

    /// It swaps the token in one swap order for the second one
    /// @notice Handles simple pool match and routes the net imbalance to the Uniswap V4 Pool.
    /// @param key Pool key
    function _settleOrder(PoolKey memory key) internal nonReentrant {
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
            totalToken0ForToken1Sellers = FullMath.mulDiv(amountOfToken1In, 1 << 192, ratioX192);

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
            totalToken1ForToken0Sellers = token0ValueInToken1;

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

        // 4. Reset the batches BEFORE distributing (CEI pattern)
        batchPendingOrdersIn[poolId][true] = 0;
        batchPendingOrdersIn[poolId][false] = 0;
        batchPendingOrdersOut[poolId][true] = 0;
        batchPendingOrdersOut[poolId][false] = 0;

        // 5. Distribute fulfilled amounts to orders proportionally
        _distributeSettlement(key, true, amountOfToken0In, totalToken1ForToken0Sellers);
        _distributeSettlement(key, false, amountOfToken1In, totalToken0ForToken1Sellers);
    }

    /// @notice Settles a complex CoW cycle (e.g., A -> B -> C -> A) using Exact Input AMM routing
    /// @param keys Array of PoolKeys corresponding to each order's intended swap
    /// @param orderIds Array of order IDs that form the closed loop
    function _settleComplexOrder(PoolKey[] memory keys, uint256[] memory orderIds) internal nonReentrant {
        uint256 cycleLength = orderIds.length;
        if (cycleLength < 2) return;
        if (keys.length != cycleLength) revert ArrayLengthMismatch();
        if (cycleLength > MAX_CYCLE_DEPTH) revert MaxCycleDepthExceeded();

        Order[] memory cycleOrders = new Order[](cycleLength);

        // 1. Verify and Load
        for (uint256 i = 0; i < cycleLength;) {
            uint256 oId = orderIds[i];
            if (orderIndex[oId] == 0) revert SwapOrderNotFound();
            Order memory o = orders[oId];
            if (o.fulfilled || o.canceled) revert SwapOrderNotFound();
            if (PoolId.unwrap(o.poolId) != PoolId.unwrap(keys[i].toId())) revert PoolKeyMismatch();

            cycleOrders[i] = o;
            unchecked {
                ++i;
            }
        }

        // 2. PASS 1: Calculate internal matches to break the forward loop dependency
        // internalMatches[i] = amount of TokenOut that order `i` receives directly from order `i+1`
        uint256[] memory internalMatches = new uint256[](cycleLength);
        for (uint256 i = 0; i < cycleLength;) {
            uint256 nextIdx = (i + 1) % cycleLength;

            uint256 amountDemanded = cycleOrders[i].amountOut;
            uint256 amountProvidedByNext = cycleOrders[nextIdx].amountIn;

            // Match is the minimum of what `i` wants and what `i+1` provides
            internalMatches[i] = amountDemanded < amountProvidedByNext ? amountDemanded : amountProvidedByNext;

            unchecked {
                ++i;
            }
        }

        // Setup arrays to defer transfers until all state/AMM calls are finished
        address[] memory recipients = new address[](cycleLength);
        Currency[] memory outCurrencies = new Currency[](cycleLength);
        uint256[] memory outAmounts = new uint256[](cycleLength);

        // 3. PASS 2: AMM Routing and Slippage Checks
        for (uint256 i = 0; i < cycleLength;) {
            Order memory currentOrder = cycleOrders[i];
            PoolKey memory currentKey = keys[i];

            // The previous order in the ring determines how much of our input was spent internally
            uint256 prevIdx = (i + cycleLength - 1) % cycleLength;

            recipients[i] = currentOrder.owner;
            outCurrencies[i] = currentOrder.zeroForOne ? currentKey.currency1 : currentKey.currency0;

            // What currentOrder receives from the internal ring
            uint256 internalOutputReceived = internalMatches[i];

            // What currentOrder spent internally (given to the previous order)
            uint256 internalInputSpent = internalMatches[prevIdx];

            // The unspent input is routed to the AMM (Exact Input)
            uint256 inputForAmm = currentOrder.amountIn - internalInputSpent;
            uint256 ammOutputReceived = 0;

            if (inputForAmm > 0) {
                BalanceDelta delta = abi.decode(
                    poolManager.unlock(
                        abi.encode(
                            CallbackData({
                                key: currentKey,
                                params: SwapParams({
                                    zeroForOne: currentOrder.zeroForOne,
                                    amountSpecified: -inputForAmm.toInt256(), // Exact input (negative)
                                    sqrtPriceLimitX96: currentOrder.zeroForOne
                                        ? TickMath.MIN_SQRT_PRICE + 1
                                        : TickMath.MAX_SQRT_PRICE - 1
                                }),
                                hookData: LeanSwapLibrary.encodeHookData(0, false, address(0)),
                                reason: REASON.SETTLE_ORDER
                            })
                        )
                    ),
                    (BalanceDelta)
                );

                int256 outputDelta = currentOrder.zeroForOne ? delta.amount1() : delta.amount0();
                ammOutputReceived = outputDelta < 0 ? uint256(-outputDelta) : uint256(outputDelta);
            }

            uint256 totalOutput = internalOutputReceived + ammOutputReceived;

            // Slippage check: Did the combined output meet the user's limit?
            if (totalOutput < currentOrder.amountOut && totalOutput < currentOrder.minAmountOut) {
                revert FundInsolvency();
            }

            outAmounts[i] = totalOutput;

            // CEI: Mark fulfilled and remove from pending BEFORE external token transfers
            orders[orderIds[i]].fulfilled = true;
            _removeOrderFromPending(currentOrder, orderIds[i]);

            emit SwapOrderSettled(currentKey, currentOrder.zeroForOne, totalOutput, orderIds[i]);

            unchecked {
                ++i;
            }
        }

        // 4. PASS 3: Safe Transfers (Interactions)
        // Grouped at the very end to enforce strict Checks-Effects-Interactions
        for (uint256 i = 0; i < cycleLength;) {
            _safeTransferCurrency(outCurrencies[i], recipients[i], outAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function cancelOrder(PoolKey calldata key, uint256 orderId) public nonReentrant {
        if (orderIndex[orderId] == 0) revert SwapOrderNotFound();
        Order memory order = orders[orderId];
        // Ensure the caller is the owner of the order
        if (order.owner != msg.sender) revert NotOwnerOfOrder();

        // CEI: update state first, then transfer
        _removeOrderFromPendingArray(order, orderId);
        // Remove from batch
        batchPendingOrdersIn[order.poolId][order.zeroForOne] -= order.amountIn;
        batchPendingOrdersOut[order.poolId][order.zeroForOne] -= order.amountOut;
        orders[orderId].canceled = true;
        orderIndex[orderId] = 0;

        emit SwapOrderCancelled(order.owner, key, order.amountIn);

        // Interactions last
        Currency token = order.zeroForOne ? key.currency0 : key.currency1;
        _safeTransferCurrency(token, order.owner, order.amountIn);
    }

    function _deadlineExceeded(PoolKey memory key, uint256 orderId) internal nonReentrant {
        if (orderIndex[orderId] == 0) revert SwapOrderNotFound();
        Order memory order = orders[orderId];
        if (block.timestamp < uint256(order.deadline)) revert DeadlineNotMatured();

        // Issue 12: validate the supplied PoolKey matches this order
        if (PoolId.unwrap(order.poolId) != PoolId.unwrap(key.toId())) revert PoolKeyMismatch();

        // CEI: update state before any external call / token transfer
        _removeOrderFromPendingArray(order, orderId);
        batchPendingOrdersIn[order.poolId][order.zeroForOne] -= order.amountIn;
        batchPendingOrdersOut[order.poolId][order.zeroForOne] -= order.amountOut;
        orders[orderId].canceled = true;
        orderIndex[orderId] = 0;

        emit SwapOrderDeadlineExceededSettled(order.owner, key, order.amountIn, orderId);

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
        uint256 amountToSend = order.zeroForOne
            ? int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()).toUint256()
            : int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()).toUint256();

        // Interactions last
        _safeTransferCurrency(token, order.owner, amountToSend);
    }

    /// Callback for the pool manager
    function unlockCallback(bytes calldata callbackData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotPoolManager();
        CallbackData memory data = abi.decode(callbackData, (CallbackData));
        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        // Settle token0
        if (delta.amount0() < 0) {
            _settle(data.key.currency0, uint128(uint256(int256(-delta.amount0()))));
        } else if (delta.amount0() > 0) {
            _take(data.key.currency0, uint128(uint256(int256(delta.amount0()))));
        }

        // Settle token1
        if (delta.amount1() < 0) {
            _settle(data.key.currency1, uint128(uint256(int256(-delta.amount1()))));
        } else if (delta.amount1() > 0) {
            _take(data.key.currency1, uint128(uint256(int256(delta.amount1()))));
        }

        return abi.encode(delta);
    }

    /// Callback for the reactive network
    function callback(bytes calldata data) external {
        if (msg.sender != rscAddress) revert NotAuthorizedRsc();

        // Issue 6: validate data is at minimum length before decoding
        if (data.length < 32) revert ArrayLengthMismatch();

        (ReactiveLibrary.CallbackType action) = abi.decode(data, (ReactiveLibrary.CallbackType));

        if (action == ReactiveLibrary.CallbackType.SETTLE_ORDER) {
            (, PoolKey memory key) = abi.decode(data, (ReactiveLibrary.CallbackType, PoolKey));
            _settleOrder(key);
        } else if (action == ReactiveLibrary.CallbackType.DEADLINE_EXCEEDED) {
            (, uint256 orderId, PoolKey memory key) = abi.decode(data, (ReactiveLibrary.CallbackType, uint256, PoolKey));
            _deadlineExceeded(key, orderId);
        } else if (action == ReactiveLibrary.CallbackType.SETTLE_COMPLEX_ORDER) {
            (, uint256[] memory orderIds, PoolKey[] memory keys) =
                abi.decode(data, (ReactiveLibrary.CallbackType, uint256[], PoolKey[]));

            // Issue 6: validate array lengths and cycle depth cap
            if (orderIds.length != keys.length) revert ArrayLengthMismatch();
            if (orderIds.length > MAX_CYCLE_DEPTH) revert MaxCycleDepthExceeded();

            _settleComplexOrder(keys, orderIds);
        }
    }

    /// Sets the address of the reactive smart contract
    function setRscAddress(address _address) external onlyOwner {
        addAuthorizedSender(_address);
        rscAddress = _address;
        vendor = IPayable(payable(_address));
        rvm_id = _address;
    }

    // =================== Helper Functions ==================

    /// Calculate what would happen if the swap went through the Uniswap AMM right now, without actually executing it.
    /// @param poolId Id of the pool
    /// @param params Swap params
    /// @return tokenIn amount from the wallet
    /// @return tokenOut amount sent back to the user
    /// @return beforeSwapDelta_ BeforeSwapDelta
    function simulateSwap(PoolId poolId, SwapParams memory params)
        internal
        view
        returns (uint256 tokenIn, uint256 tokenOut, BeforeSwapDelta beforeSwapDelta_)
    {
        // Cache the slot0 call
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        bool zeroForOne = params.zeroForOne;

        if (params.amountSpecified >= 0) {
            uint256 amountSpecified = params.amountSpecified.toUint256();

            (, tokenIn, tokenOut,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: amountSpecified.toInt256(),
                feePips: 0
            });

            int128 amountToSpecified = zeroForOne ? int128(uint128(tokenOut)) : int128(uint128(tokenIn));
            int128 amountUnspecified = zeroForOne ? int128(uint128(tokenIn)) : int128(uint128(tokenOut));
            beforeSwapDelta_ = toBeforeSwapDelta(amountToSpecified, amountUnspecified);
        } else {
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

    /// @notice Takes tokens from the pool manager and holds them in this contract for the CoW order.
    function takeAndSettle(PoolKey calldata key, bool zeroForOne, uint128 amount) internal {
        if (zeroForOne) {
            _take(key.currency0, amount);
        } else {
            _take(key.currency1, amount);
        }
    }

    /// @dev Helper to iterate through orders and assign their proportional output (CEI-safe: state first, transfers last)
    function _distributeSettlement(PoolKey memory key, bool zeroForOne, uint256 totalInput, uint256 totalOutput)
        internal
    {
        PoolId poolId = key.toId();
        Order[] storage ordersArr = pendingOrders[poolId][zeroForOne];
        uint256 totalOrders = ordersArr.length;
        if (totalOrders == 0 || totalInput == 0) return;

        // Collect all transfer data before modifying state
        address[] memory recipients = new address[](totalOrders);
        Currency[] memory outCurrencies = new Currency[](totalOrders);
        uint256[] memory outAmounts = new uint256[](totalOrders);

        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;

        for (uint256 i = 0; i < totalOrders;) {
            Order memory order = ordersArr[i];
            uint256 orderId = getOrderId(
                order.poolId,
                order.zeroForOne,
                order.deadline,
                order.amountIn,
                order.amountOut,
                order.owner,
                order.nonce
            );

            uint256 actualAmountOut = (order.amountIn * totalOutput) / totalInput;

            if (actualAmountOut < order.amountOut && actualAmountOut < order.minAmountOut) {
                continue;
            }

            // Accumulate transfer info
            recipients[i] = order.owner;
            outCurrencies[i] = outCurrency;
            outAmounts[i] = actualAmountOut;

            // CEI: mark fulfilled before any transfer
            orders[orderId].fulfilled = true;
            orderIndex[orderId] = 0;

            emit SwapOrderSettled(key, order.zeroForOne, actualAmountOut, orderId);

            unchecked {
                ++i;
            }
        }

        // Clear the array (state update) before transfers
        delete pendingOrders[poolId][zeroForOne];

        // Perform transfers after all state is updated
        for (uint256 i = 0; i < totalOrders;) {
            _safeTransferCurrency(outCurrencies[i], recipients[i], outAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Shared swap-and-pop removal used by cancelOrder and _deadlineExceeded
    function _removeOrderFromPendingArray(Order memory order, uint256 orderId) internal {
        Order[] storage memOrders = pendingOrders[order.poolId][order.zeroForOne];
        uint256 index = orderIndex[orderId] - 1; // convert stored (realIndex+1) back to realIndex
        uint256 lastIndex = memOrders.length - 1;

        if (index != lastIndex) {
            Order storage lastOrder = memOrders[lastIndex];
            uint256 lastOrderId = getOrderId(
                lastOrder.poolId,
                lastOrder.zeroForOne,
                lastOrder.deadline,
                lastOrder.amountIn,
                lastOrder.amountOut,
                lastOrder.owner,
                lastOrder.nonce
            );
            memOrders[index] = lastOrder;
            orderIndex[lastOrderId] = index + 1;
        }
        memOrders.pop();
    }

    /// @dev Helper to cleanly pop orders from the pending list (used by complex settlement)
    function _removeOrderFromPending(Order memory order, uint256 orderId) internal {
        _removeOrderFromPendingArray(order, orderId);
        orderIndex[orderId] = 0;
        // Remove remaining balances from the batch aggregators
        batchPendingOrdersOut[order.poolId][order.zeroForOne] -= order.amountOut;
        batchPendingOrdersIn[order.poolId][order.zeroForOne] -= order.amountIn;
    }

    /// @dev Safe transfer wrapper — uses SafeERC20 for ERC20 tokens; handles native ETH via CurrencyLibrary
    function _safeTransferCurrency(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            // Native ETH — CurrencyLibrary.transfer handles this
            currency.transfer(to, amount);
        } else {
            // ERC20 — use SafeERC20 to handle non-standard tokens safely
            SafeERC20.safeTransfer(IERC20(Currency.unwrap(currency)), to, amount);
        }
    }

    /// Settle currency with pool manager
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        if (amount > 0) currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// Take the money from the user and add it to the smart contract
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    /// Deterministic function to get the order id of the swap
    function getOrderId(
        PoolId _poolId,
        bool zeroForOne,
        uint64 deadline,
        uint256 amountIn,
        uint256 amountOut,
        address owner,
        uint256 orderNonce
    ) internal pure returns (uint256 orderId) {
        return uint256(keccak256(abi.encode(_poolId, zeroForOne, deadline, amountIn, amountOut, owner, orderNonce)));
    }
}

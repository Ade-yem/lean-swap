// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ReactiveLibrary} from "./Library.sol";

contract LeanSwapReactive is IReactive, AbstractReactive {
    uint256 public originChainId;
    uint256 public destinationChainId;
    uint64 private constant GAS_LIMIT = 500000;

    address private callbackAddr;
    uint256 orderCreatedTopic0;
    uint256 orderSettledTopic0;
    uint256 orderDeadlineTopic0;

    // ── Graph Data Structures ─────────────────────────────────────────────────
    struct SwapOrder {
        uint256 orderId;
        address assetIn;
        address assetOut;
        PoolKey poolKey;
        bool zeroForOne;
    }

    // Mapping of Asset In -> List of Order IDs
    mapping(address => uint256[]) public ordersByAssetIn;
    mapping(uint256 => SwapOrder) public orderDetails;

    // ── Issue 7 fix: O(1) active-order tracking via head-pointer queue ────────
    // Instead of a plain array that grows unbounded with linear scans, we use a
    // mapping-based queue with a monotonically increasing head pointer so that:
    //   • enqueueing is O(1)
    //   • dequeuing (expiry / settlement) is O(1)
    //   • the "array" never actually shrinks in storage but head advances past
    //     stale entries, bounding the per-call scan to at most `maxChecks` live slots.
    mapping(uint256 qIndex => uint256 orderId) private orderQueue;
    uint256 private queueHead; // next index to inspect during deadline scan
    uint256 private queueTail; // next index to write

    // O(1) lookup: orderId -> queue index (+1 sentinel, 0 = not present)
    mapping(uint256 orderId => uint256 queueIndexPlusOne) private orderQueueIndex;

    // Deadline / poolKey per order
    mapping(uint256 orderId => uint256 deadline) public deadlines;
    mapping(uint256 orderId => PoolKey poolKey) public poolKeyStore;

    // Issue 8: O(1) active-order membership check
    mapping(uint256 orderId => bool) public isActiveOrder;

    uint256 constant MAX_CYCLE_DEPTH = 4;
    uint256 constant MAX_BRANCHES = 5;
    uint256 constant DEADLINE_CHECKS = 20; // how many queue slots to inspect per react() call

    // ── Minimum order size to prevent order-flooding (issue 7 / economic) ─────
    uint256 public minOrderAmount;

    constructor(
        address _service,
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _contract,
        uint256 _orderCreatedTopic0,
        uint256 _orderSettledTopic0,
        uint256 _orderDeadlineTopic0,
        address _callback,
        uint256 _minOrderAmount
    ) payable {
        service = ISystemContract(payable(_service));

        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        callbackAddr = _callback;
        orderCreatedTopic0 = _orderCreatedTopic0;
        orderSettledTopic0 = _orderSettledTopic0;
        orderDeadlineTopic0 = _orderDeadlineTopic0;
        minOrderAmount = _minOrderAmount;

        if (!vm) {
            service.subscribe(
                originChainId, _contract, _orderCreatedTopic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId, _contract, _orderSettledTopic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId, _contract, _orderDeadlineTopic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == orderCreatedTopic0) {
            ReactiveLibrary.OrderMetadata memory eventData = ReactiveLibrary.decodeOrderData(log.data);

            // Issue 7 / economic: ignore dust orders to prevent graph explosion
            if (eventData.amountIn < minOrderAmount) return;

            address assetIn = eventData.zeroForOne
                ? Currency.unwrap(eventData.poolKey.currency0)
                : Currency.unwrap(eventData.poolKey.currency1);
            address assetOut = !eventData.zeroForOne
                ? Currency.unwrap(eventData.poolKey.currency0)
                : Currency.unwrap(eventData.poolKey.currency1);

            uint256 oid = eventData.orderId;

            // Guard against duplicate events
            if (isActiveOrder[oid]) return;

            deadlines[oid] = eventData.deadline;
            poolKeyStore[oid] = eventData.poolKey;

            // Issue 7 fix: enqueue into O(1) queue instead of plain push
            _enqueueOrder(oid);
            isActiveOrder[oid] = true;

            // 1. Add order to our graph
            orderDetails[oid] = SwapOrder({
                orderId: oid,
                assetIn: assetIn,
                assetOut: assetOut,
                poolKey: eventData.poolKey,
                zeroForOne: eventData.zeroForOne
            });
            ordersByAssetIn[assetIn].push(oid);

            // 2. Cycle Detection (DFS)
            uint256[] memory path = new uint256[](MAX_CYCLE_DEPTH);
            path[0] = oid;

            // Look for a path from assetOut back to assetIn
            (bool cycleFound, uint256 cycleLength) = findCyclePath(assetOut, assetIn, path, 1);

            if (cycleFound) {
                uint256[] memory matchedOrderIds = new uint256[](cycleLength);
                PoolKey[] memory matchedPoolKeys = new PoolKey[](cycleLength);

                for (uint256 j = 0; j < cycleLength;) {
                    matchedOrderIds[j] = path[j];
                    matchedPoolKeys[j] = orderDetails[path[j]].poolKey;
                    unchecked {
                        ++j;
                    }
                }

                bytes memory payload = ReactiveLibrary.encodeComplexCallbackData(matchedOrderIds, matchedPoolKeys);
                emit Callback(destinationChainId, callbackAddr, GAS_LIMIT, payload);
            }

            checkDeadlines();
        } else if (log.topic_0 == orderSettledTopic0 || log.topic_0 == orderDeadlineTopic0) {
            uint256 orderId;
            if (log.topic_0 == orderSettledTopic0) {
                ReactiveLibrary.SettledOrderMetadata memory eventData = ReactiveLibrary.decodeSettledOrderData(log.data);
                orderId = eventData.orderId;
            } else {
                ReactiveLibrary.DeadlineSettledData memory eventData =
                    ReactiveLibrary.decodeDeadlineSettledData(log.data);
                orderId = eventData.orderId;
                deadlines[orderId] = 0;
            }
            _removeOrderFromGraph(orderId);
            _deactivateOrder(orderId);
        }
    }

    /// @dev DFS to find a path back to the starting asset.
    ///      Issue 8: skips stale / already-removed orders.
    function findCyclePath(address currentAsset, address targetAsset, uint256[] memory path, uint256 depth)
        internal
        view
        returns (bool, uint256)
    {
        if (currentAsset == targetAsset) {
            return (true, depth);
        }
        if (depth >= MAX_CYCLE_DEPTH) {
            return (false, 0);
        }

        uint256[] storage edges = ordersByAssetIn[currentAsset];
        uint256 edgeCount = edges.length;
        uint256 checkLimit = edgeCount > MAX_BRANCHES ? MAX_BRANCHES : edgeCount;

        for (uint256 i = 0; i < checkLimit;) {
            uint256 nextOrderId = edges[edgeCount - 1 - i];

            // Issue 8: skip orders that have been settled/cancelled (no longer in graph)
            if (!isActiveOrder[nextOrderId]) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Prevent self-loops/revisiting nodes in the current path
            bool visited = false;
            for (uint256 j = 0; j < depth;) {
                if (path[j] == nextOrderId) {
                    visited = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (visited) {
                unchecked {
                    ++i;
                }
                continue;
            }

            path[depth] = nextOrderId;
            SwapOrder memory nextOrder = orderDetails[nextOrderId];

            (bool found, uint256 finalDepth) = findCyclePath(nextOrder.assetOut, targetAsset, path, depth + 1);
            if (found) {
                return (true, finalDepth);
            }
            unchecked {
                ++i;
            }
        }

        return (false, 0);
    }

    function _removeOrderFromGraph(uint256 orderId) internal {
        address assetIn = orderDetails[orderId].assetIn;
        uint256[] storage edges = ordersByAssetIn[assetIn];
        uint256 edgeLen = edges.length;
        for (uint256 i = 0; i < edgeLen;) {
            if (edges[i] == orderId) {
                edges[i] = edges[edgeLen - 1];
                edges.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        delete orderDetails[orderId];
    }

    /// @dev Issue 7 fix: check up to DEADLINE_CHECKS queue slots per call.
    ///      Uses head-pointer approach so already-processed slots are never revisited.
    function checkDeadlines() internal {
        uint256 head = queueHead;
        uint256 tail = queueTail;
        uint256 checks = 0;

        while (head < tail && checks < DEADLINE_CHECKS) {
            uint256 currentOrderId = orderQueue[head];

            // Skip slots that were logically removed (cancelled/settled before deadline)
            if (!isActiveOrder[currentOrderId]) {
                unchecked {
                    ++head;
                    ++checks;
                }
                continue;
            }

            uint256 dl = deadlines[currentOrderId];
            if (dl != 0 && block.timestamp >= dl) {
                PoolKey memory key = poolKeyStore[currentOrderId];
                bytes memory payload = ReactiveLibrary.encodeDeadlineCallbackData(currentOrderId, key);
                emit Callback(destinationChainId, callbackAddr, GAS_LIMIT, payload);

                // Deactivate so we don't double-trigger
                isActiveOrder[currentOrderId] = false;
            }

            unchecked {
                ++head;
                ++checks;
            }
        }

        queueHead = head;
    }

    // ── Internal queue helpers ────────────────────────────────────────────────

    function _enqueueOrder(uint256 orderId) internal {
        uint256 tail = queueTail;
        orderQueue[tail] = orderId;
        orderQueueIndex[orderId] = tail + 1; // +1 sentinel
        queueTail = tail + 1;
    }

    /// @dev Mark an order as inactive (O(1)). The queue slot will be skipped during checkDeadlines.
    function _deactivateOrder(uint256 orderId) internal {
        isActiveOrder[orderId] = false;
        deadlines[orderId] = 0;
        orderQueueIndex[orderId] = 0;
    }
}

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ReactiveLibrary} from "./Library.sol";

// struct LogRecord {
//    uint256 chain_id;
//    address _contract;
//    uint256 topic_0;
//    uint256 topic_1;
//    uint256 topic_2;
//    uint256 topic_3;
//    bytes data;
//    uint256 block_number;
//    uint256 op_code;
//    uint256 block_hash;
//    uint256 tx_hash;
//    uint256 log_index;
// }

contract LeanSwapReactive is IReactive, AbstractReactive {
    uint256 public originChainId;
    uint256 public destinationChainId;
    uint64 private constant GAS_LIMIT = 500000;

    address private callback;
    uint256 orderCreatedTopic0;
    uint256 orderSettledTopic0;
    uint256 orderDeadlineTopic0;

    // --- Graph Data Structures ---
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

    // Deadline tracking
    mapping(uint256 orderId => uint256 deadline) public deadlines;
    mapping(uint256 orderId => PoolKey poolKey) public poolKeyStore;
    uint256[] public activeOrderIds;

    uint256 constant MAX_CYCLE_DEPTH = 4;
    uint256 constant MAX_BRANCHES = 5;

    constructor(
        address _service,
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _contract,
        uint256 _order_created_topic_0,
        uint256 _order_settled_topic_0,
        uint256 _order_deadline_topic_0,
        address _callback
    ) payable {
        service = ISystemContract(payable(_service));

        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        callback = _callback;
        orderCreatedTopic0 = _order_created_topic_0;
        orderSettledTopic0 = _order_settled_topic_0;
        orderDeadlineTopic0 = _order_deadline_topic_0;

        if (!vm) {
            service.subscribe(
                originChainId, _contract, _order_created_topic_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId, _contract, _order_settled_topic_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId, _contract, _order_deadline_topic_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == orderCreatedTopic0) {
            ReactiveLibrary.OrderMetadata memory eventData = ReactiveLibrary.decodeOrderData(log.data);

            address assetIn = eventData.zeroForOne
                ? Currency.unwrap(eventData.poolKey.currency0)
                : Currency.unwrap(eventData.poolKey.currency1);
            address assetOut = !eventData.zeroForOne
                ? Currency.unwrap(eventData.poolKey.currency0)
                : Currency.unwrap(eventData.poolKey.currency1);

            deadlines[eventData.orderId] = eventData.deadline;
            poolKeyStore[eventData.orderId] = eventData.poolKey;
            activeOrderIds.push(eventData.orderId);

            // 1. Add order to our Graph
            orderDetails[eventData.orderId] = SwapOrder({
                orderId: eventData.orderId,
                assetIn: assetIn,
                assetOut: assetOut,
                poolKey: eventData.poolKey,
                zeroForOne: eventData.zeroForOne
            });
            ordersByAssetIn[assetIn].push(eventData.orderId);

            // 2. Cycle Detection (DFS)
            uint256[] memory path = new uint256[](MAX_CYCLE_DEPTH);
            path[0] = eventData.orderId;

            // We just added A -> B. Look for a path from B back to A.
            (bool cycleFound, uint256 cycleLength) = findCyclePath(assetOut, assetIn, path, 1);

            if (cycleFound) {
                // We found a complex CoW match!
                uint256[] memory matchedOrderIds = new uint256[](cycleLength);
                PoolKey[] memory matchedPoolKeys = new PoolKey[](cycleLength);

                for (uint256 j = 0; j < cycleLength; j++) {
                    matchedOrderIds[j] = path[j];
                    matchedPoolKeys[j] = orderDetails[path[j]].poolKey;
                }

                // Note: You'll need to update ReactiveLibrary to handle encoding complex mult-hop callbacks
                bytes memory payload = ReactiveLibrary.encodeComplexCallbackData(matchedOrderIds, matchedPoolKeys);
                emit Callback(destinationChainId, callback, GAS_LIMIT, payload);
            }

            checkDeadlines();
        } else if (log.topic_0 == orderSettledTopic0 || log.topic_0 == orderDeadlineTopic0) {
            uint256 orderId;
            if (log.topic_0 == orderSettledTopic0) {
                ReactiveLibrary.SettledOrderMetadata memory eventData = ReactiveLibrary.decodeSettledOrderData(log.data);
                // In a full implementation, you'd decode the exact orderId from the event
                orderId = eventData.orderId;
            } else {
                ReactiveLibrary.DeadlineSettledData memory eventData =
                    ReactiveLibrary.decodeDeadlineSettledData(log.data);
                orderId = eventData.orderId;
                deadlines[orderId] = 0;
            }
            _removeOrderFromGraph(orderId);
            _removeFromActiveOrdersByOrderId(orderId);
        }
    }

    /// @dev DFS to find a path back to the starting asset
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

        uint256[] memory edges = ordersByAssetIn[currentAsset];
        // Determine how many branches to check to prevent gas exhaustion.
        // We check from the end of the array (most recent orders first) to prioritize fresh liquidity.
        uint256 edgeCount = edges.length;
        uint256 checkLimit = edgeCount > MAX_BRANCHES ? MAX_BRANCHES : edgeCount;

        for (uint256 i = 0; i < checkLimit; i++) {
            // Read from the back of the array (newest orders)
            uint256 nextOrderId = edges[edgeCount - 1 - i];

            // Prevent self-loops/revisiting nodes in the current path
            bool visited = false;
            for (uint256 j = 0; j < depth; j++) {
                if (path[j] == nextOrderId) {
                    visited = true;
                    break;
                }
            }
            if (visited) continue;

            path[depth] = nextOrderId;
            SwapOrder memory nextOrder = orderDetails[nextOrderId];

            (bool found, uint256 finalDepth) = findCyclePath(nextOrder.assetOut, targetAsset, path, depth + 1);
            if (found) {
                return (true, finalDepth);
            }
        }

        return (false, 0);
    }

    function _removeOrderFromGraph(uint256 orderId) internal {
        address assetIn = orderDetails[orderId].assetIn;
        uint256[] storage edges = ordersByAssetIn[assetIn];
        for (uint256 i = 0; i < edges.length; i++) {
            if (edges[i] == orderId) {
                edges[i] = edges[edges.length - 1];
                edges.pop();
                break;
            }
        }
        delete orderDetails[orderId];
    }

    function checkDeadlines() internal {
        // We only check a few at a time to stay under gas limits
        uint256 maxChecks = 5;
        uint256 i = 0;

        while (i < activeOrderIds.length && i < maxChecks) {
            uint256 currentOrderId = activeOrderIds[i];

            if (block.timestamp >= deadlines[currentOrderId]) {
                // DEADLINE HIT!
                PoolKey memory key = poolKeyStore[currentOrderId];

                // Encode the call for deadlineExceeded(key, orderId)
                bytes memory payload = ReactiveLibrary.encodeDeadlineCallbackData(currentOrderId, key);
                emit Callback(destinationChainId, callback, GAS_LIMIT, payload);

                // Remove from tracking to avoid double-processing
                _removeActiveOrder(i);
                // Don't increment 'i' because the last element moved into this spot
            } else {
                i++;
            }
        }
    }

    function _removeActiveOrder(uint256 index) internal {
        require(index < activeOrderIds.length, "Index out of bounds");

        // Move the last element into the place of the one we want to delete
        activeOrderIds[index] = activeOrderIds[activeOrderIds.length - 1];

        // Remove the last element (which is now a duplicate)
        activeOrderIds.pop();
    }

    /// @dev Removes an order ID from the active array using swap-and-pop
    function _removeFromActiveOrdersByOrderId(uint256 orderId) internal {
        uint256 length = activeOrderIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeOrderIds[i] == orderId) {
                // Move the last element into the place of the one we want to delete
                activeOrderIds[i] = activeOrderIds[length - 1];
                // Remove the last element
                activeOrderIds.pop();
                break;
            }
        }
    }
}

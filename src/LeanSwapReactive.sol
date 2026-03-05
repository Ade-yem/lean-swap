// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
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
    uint64 private constant GAS_LIMIT = 100000;

    address private callback;
    uint256 orderCreatedTopic0;
    uint256 orderSettledTopic0;
    uint256 orderDeadlineTopic0;

    // Mapping
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 amount)) public pendingOrders;
    mapping(uint256 orderId => uint256 deadline) public deadlines;
    mapping(uint256 orderId => PoolKey poolKey) public poolKeyStore;
    uint256[] public activeOrderIds;

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
            PoolId poolId = eventData.poolKey.toId();
            deadlines[eventData.orderId] = eventData.deadline;
            poolKeyStore[eventData.orderId] = eventData.poolKey; // Save the struct
            activeOrderIds.push(eventData.orderId); // Add to the list to be checked
            // 1. Update the RSC's mirror state
            pendingOrders[poolId][eventData.zeroForOne] += eventData.amountIn;
            // 2. Logic: Only hit the blockchain if a CoW match is now possible
            if (pendingOrders[poolId][!eventData.zeroForOne] > 0) {
                bytes memory payload = ReactiveLibrary.encodeCallbackData(eventData.poolKey);
                emit Callback(destinationChainId, callback, GAS_LIMIT, payload);
            }
            checkDeadlines();
        } else if (log.topic_0 == orderSettledTopic0) {
            ReactiveLibrary.SettledOrderMetadata memory eventData = ReactiveLibrary.decodeSettledOrderData(log.data);
            // Remove orders to the mapping
            pendingOrders[eventData.poolKey.toId()][eventData.zeroForOne] = 0;
        } else if (log.topic_0 == orderDeadlineTopic0) {
            ReactiveLibrary.DeadlineSettledData memory eventData = ReactiveLibrary.decodeDeadlineSettledData(log.data);
            deadlines[eventData.orderId] = 0;
        }
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
}

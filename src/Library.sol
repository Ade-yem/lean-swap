// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

library LeanSwapLibrary {
    function decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (uint256 deadline, bool useCoW, address owner, uint256 minAmountOut)
    {
        if (hookData.length < 32) return (0, false, address(0), 0);
        if (hookData.length == 96) {
            (deadline, useCoW, owner) = abi.decode(hookData, (uint256, bool, address));
            minAmountOut = 0;
        } else {
            return abi.decode(hookData, (uint256, bool, address, uint256));
        }
    }

    function encodeHookData(uint256 deadline, bool useCoW, address owner)
        internal
        pure
        returns (bytes memory hookData)
    {
        hookData = abi.encode(deadline, useCoW, owner, uint256(0));
    }

    function encodeHookData(uint256 deadline, bool useCoW, address owner, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory hookData)
    {
        hookData = abi.encode(deadline, useCoW, owner, minAmountOut);
    }
}

library ReactiveLibrary {
    struct OrderMetadata {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 deadline;
        uint256 orderId;
        uint256 amountIn;
    }

    struct SettledOrderMetadata {
        PoolKey poolKey;
        bool zeroForOne;
        uint256 amountOut;
        uint256 orderId;
    }

    struct DeadlineSettledData {
        address owner;
        PoolKey poolKey;
        uint256 amount;
        uint256 orderId;
    }

    enum CallbackType {
        SETTLE_ORDER,
        DEADLINE_EXCEEDED,
        SETTLE_COMPLEX_ORDER
    }

    function encodeCallbackPayload(PoolKey memory key) internal pure returns (bytes memory) {
        return abi.encode(CallbackType.SETTLE_ORDER, key);
    }

    function encodeDeadlineCallbackPayload(uint256 orderId, PoolKey memory key) internal pure returns (bytes memory) {
        return abi.encode(CallbackType.DEADLINE_EXCEEDED, orderId, key);
    }

    function encodeComplexCallbackPayload(uint256[] memory orderIds, PoolKey[] memory keys)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(CallbackType.SETTLE_COMPLEX_ORDER, orderIds, keys);
    }

    // Update these to return the full payload including the "callback(bytes)" selector
    function encodeCallbackData(PoolKey memory key) internal pure returns (bytes memory) {
        bytes memory data = encodeCallbackPayload(key);
        return abi.encodeWithSignature("callback(bytes)", data);
    }

    function encodeDeadlineCallbackData(uint256 orderId, PoolKey memory key) internal pure returns (bytes memory) {
        bytes memory data = encodeDeadlineCallbackPayload(orderId, key);
        return abi.encodeWithSignature("callback(bytes)", data);
    }

    function encodeComplexCallbackData(uint256[] memory orderIds, PoolKey[] memory keys)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory data = encodeComplexCallbackPayload(orderIds, keys);
        return abi.encodeWithSignature("callback(bytes)", data);
    }

    function decodeOrderData(bytes calldata orderData) internal pure returns (OrderMetadata memory data) {
        data = abi.decode(orderData, (OrderMetadata));
    }

    function decodeSettledOrderData(bytes calldata orderData) internal pure returns (SettledOrderMetadata memory data) {
        data = abi.decode(orderData, (SettledOrderMetadata));
    }

    function decodeDeadlineSettledData(bytes calldata orderData)
        internal
        pure
        returns (DeadlineSettledData memory data)
    {
        data = abi.decode(orderData, (DeadlineSettledData));
    }
}

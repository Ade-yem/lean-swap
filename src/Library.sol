// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

library LeanSwapLibrary {
    function decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (uint256 deadline, bool useCoW, address owner)
    {
        if (hookData.length < 32) return (0, false, address(0));
        return abi.decode(hookData, (uint256, bool, address));
    }

    function encodeHookData(uint256 deadline, bool useCoW, address owner)
        internal
        pure
        returns (bytes memory hookData)
    {
        hookData = abi.encode(deadline, useCoW, owner);
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
    }

    struct DeadlineSettledData {
        address owner;
        PoolKey poolKey;
        uint256 amount;
        uint256 orderId;
    }

    enum CallbackType {
        SETTLE_ORDER,
        DEADLINE_EXCEEDED
    }

    // Update these to return the full payload including the "callback(bytes)" selector
    function encodeCallbackData(PoolKey memory key) internal pure returns (bytes memory) {
        bytes memory data = abi.encode(CallbackType.SETTLE_ORDER, key);
        return abi.encodeWithSignature("callback(bytes)", data);
    }

    function encodeDeadlineCallbackData(uint256 orderId, PoolKey memory key) internal pure returns (bytes memory) {
        bytes memory data = abi.encode(CallbackType.DEADLINE_EXCEEDED, orderId, key);
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

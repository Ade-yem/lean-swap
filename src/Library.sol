// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

library LeanSwapLibrary {
    function decodeHookData (bytes calldata hookData) internal pure returns(uint256 deadline, bool useCoW, address owner) {
        if (hookData.length < 32) return (0, false, address(0));
        return abi.decode(hookData, (uint256, bool, address));
    }
    function encodeHookData (uint256 deadline, bool useCoW, address owner) internal pure returns(bytes memory hookData) {
        hookData = abi.encode(deadline, useCoW, owner);
    }
}
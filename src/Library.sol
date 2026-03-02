// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

library LeanSwapLibrary {
    function decodeHookData (bytes calldata hookData) internal pure returns(uint256 deadline, uint256 minOutput) {
        if (hookData.length < 32) return (0, 0);
        return abi.decode(hookData, (uint256, uint256));
    }
    function encodeHookData (uint256 deadline, uint256 minOutput) internal pure returns(bytes memory hokData) {
        return abi.encode(deadline, minOutput);
    }
}
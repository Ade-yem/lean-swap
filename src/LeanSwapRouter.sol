// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LeanSwapRouter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error ExactInputOnly();
    error AmountMismatch();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /*//////////////////////////////////////////////////////////////
                                SWAP
    //////////////////////////////////////////////////////////////*/

    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData,
        uint256 amountIn
    ) external {
        // Enforce exact input swaps only
        if (params.amountSpecified >= 0) revert ExactInputOnly();

        if (uint256(-params.amountSpecified) != amountIn) {
            revert AmountMismatch();
        }

        bool zeroForOne = params.zeroForOne;

        Currency tokenIn = zeroForOne ? key.currency0 : key.currency1;

        // Pull tokens from user
        if (!tokenIn.isAddressZero()) {
            IERC20(Currency.unwrap(tokenIn)).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
        }

        // Enter PoolManager execution context
        poolManager.unlock(
            abi.encode(
                msg.sender,
                key,
                params,
                hookData,
                amountIn
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        UNLOCK CALLBACK (CORE)
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (
            address sender,
            PoolKey memory key,
            SwapParams memory params,
            bytes memory hookData,
            uint256 amountIn
        ) = abi.decode(data, (address, PoolKey, SwapParams, bytes, uint256));

        // Approve tokens to PoolManager if ERC20
        Currency tokenIn = params.zeroForOne ? key.currency0 : key.currency1;

        if (!tokenIn.isAddressZero()) {
            IERC20(Currency.unwrap(tokenIn)).approve(
                address(poolManager),
                amountIn
            );
        }

        // Execute swap
        BalanceDelta delta = poolManager.swap(
            key,
            params,
            hookData
        );

        // --- Settlement logic (CRITICAL) ---

        // token0
        if (delta.amount0() < 0) {
            _settle(key.currency0, uint128(int128(-delta.amount0())));
        } else if (delta.amount0() > 0) {
            _take(key.currency0, uint128(int128(delta.amount0())), sender);
        }

        // token1
        if (delta.amount1() < 0) {
            _settle(key.currency1, uint128(int128(-delta.amount1())));
        } else if (delta.amount1() > 0) {
            _take(key.currency1, uint128(int128(delta.amount1())), sender);
        }

        return abi.encode(delta);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        if (amount > 0) {
            currency.transfer(address(poolManager), amount);
        }
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount, address to) internal {
        poolManager.take(currency, to, amount);
    }
}
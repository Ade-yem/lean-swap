// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;


import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract LeanSwapRouter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    IPoolManager public immutable POOL_MANAGER;

    error NotPoolManager();
    error ExactInputOnly();
    error AmountMismatch();

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
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
        POOL_MANAGER.unlock(
            abi.encode(
                msg.sender,
                key,
                params,
                hookData,
                amountIn
            )
        );
    }

    /// Quote swap 
    function quoteSwap(PoolKey calldata key, SwapParams memory params) external view returns (uint256 tokenIn, uint256 tokenOut) {
        (tokenIn, tokenOut) = _simulateSwap(key.toId(), params);
    }

    /*//////////////////////////////////////////////////////////////
                        UNLOCK CALLBACK (CORE)
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

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
                address(POOL_MANAGER),
                amountIn
            );
        }

        // Execute swap
        BalanceDelta delta = POOL_MANAGER.swap(
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
        POOL_MANAGER.sync(currency);
        if (amount > 0) {
            currency.transfer(address(POOL_MANAGER), amount);
        }
        POOL_MANAGER.settle();
    }

    function _take(Currency currency, uint128 amount, address to) internal {
        POOL_MANAGER.take(currency, to, amount);
    }

    function _simulateSwap(PoolId poolId, SwapParams memory params)
        internal
        view
        returns (uint256 tokenIn, uint256 tokenOut)
    {
        // Cache the slot0 call
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (params.amountSpecified >= 0) {
            uint256 amountSpecified = params.amountSpecified.toUint256();

            (, tokenIn, tokenOut,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: POOL_MANAGER.getLiquidity(poolId),
                amountRemaining: amountSpecified.toInt256(),
                feePips: 0
            });
        } else {
            (, tokenIn, tokenOut,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: POOL_MANAGER.getLiquidity(poolId),
                amountRemaining: params.amountSpecified,
                feePips: 0
            });

            if (tokenIn > (-params.amountSpecified).toUint256()) {
                uint256 percentage = ((-params.amountSpecified).toUint256() * 1e18) / tokenIn;
                tokenOut = (tokenOut * percentage) / 1e18;
            }
        }
    }
}
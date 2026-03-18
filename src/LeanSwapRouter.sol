// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LeanSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
        uint256 amountToPull;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Executes a LeanSwap CoW swap (Supports Exact Input & Exact Output)
    /// @param amountInMaximum The max input tokens to pull (For Exact Input, this should equal the input amount)
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData,
        uint256 amountInMaximum
    ) external returns (BalanceDelta delta) {
        
        Currency tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        
        // 1. Determine how much to pull from the user upfront
        // Exact Input: -params.amountSpecified
        // Exact Output: amountInMaximum
        uint256 amountToPull = params.amountSpecified < 0 
            ? uint256(-params.amountSpecified) 
            : amountInMaximum;

        require(amountToPull > 0, "Invalid pull amount");

        // 2. Pull tokens from the user into this router
        if (!tokenIn.isAddressZero()) {
            IERC20(Currency.unwrap(tokenIn)).safeTransferFrom(msg.sender, address(this), amountToPull);
        }

        // 3. Unlock the PoolManager to start the transaction lifecycle
        bytes memory result = poolManager.unlock(
            abi.encode(CallbackData(msg.sender, key, params, hookData, amountToPull))
        );

        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice The callback required by the PoolManager's unlock function
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not authorized");

        CallbackData memory decoded = abi.decode(data, (CallbackData));
        Currency tokenIn = decoded.params.zeroForOne ? decoded.key.currency0 : decoded.key.currency1;

        // 4. PRE-SETTLE: Give the PoolManager the maximum potential tokens BEFORE calling swap.
        tokenIn.transfer(address(poolManager), decoded.amountToPull);
        poolManager.sync(tokenIn);
        poolManager.settle();

        // 5. SWAP: The hook will intercept and take what it actually needs.
        BalanceDelta delta = poolManager.swap(decoded.key, decoded.params, decoded.hookData);

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // 6. TAKE OUTPUTS & REFUND UNSPENT INPUT
        // In v4, a positive delta means the PM consumed tokens. A negative delta means the PM owes you tokens.
        if (decoded.params.zeroForOne) {
            // token0 is Input, token1 is Output
            uint256 amountInConsumed = uint256(int256(delta0));
            uint256 refund = decoded.amountToPull - amountInConsumed;
            
            if (refund > 0) {
                poolManager.take(decoded.key.currency0, decoded.sender, refund); // Refund unspent input
            }
            if (delta1 < 0) {
                poolManager.take(decoded.key.currency1, decoded.sender, uint256(int256(-delta1))); // Take output
            }
        } else {
            // token1 is Input, token0 is Output
            uint256 amountInConsumed = uint256(int256(delta1));
            uint256 refund = decoded.amountToPull - amountInConsumed;
            
            if (refund > 0) {
                poolManager.take(decoded.key.currency1, decoded.sender, refund); // Refund unspent input
            }
            if (delta0 < 0) {
                poolManager.take(decoded.key.currency0, decoded.sender, uint256(int256(-delta0))); // Take output
            }
        }

        return abi.encode(delta);
    }
}
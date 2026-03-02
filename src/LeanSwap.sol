// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {LeanSwapLibrary} from "./Library.sol";

contract LeanSwap is BaseHook, ERC1155 {
    using LeanSwapLibrary for bytes;
    using StateLibrary for IPoolManager;

    // Struct for the order
    struct Order {
        address owner;
        PoolId poolId;
        bool zeroForOne;
        bool fulfilled;
        uint256 amountIn;
        uint256 amountOut;
        uint256 deadline;
    }

    // Errors
    error ExactInputRequired();
    error NotOnwerOfOrder();

    // Mappings
    // Basically, we can have multiple orders for thesame deadline, for that deadline, we can have multiple zeroForOne orders or non zeroForOne orders
    // pendingOrders[poolId][zeroForOne] = order
    mapping(PoolId poolId => mapping(bool zeroForOne => Order[] order)) public pendingOrders;
    // Aggregation of all orders for thesame pool
    mapping(PoolId poolId => mapping(bool zeroForOne => uint256 totalAmount)) public batchPendingOrders;
    // Amount of claim tokens for the order
    mapping(uint256 orderId => uint256 amountClaimable) public tokenClaims;
    mapping(uint256 orderId => uint256 claimableFulfilled) public tokensClaimsFulfilled;
    // Indexes of the order so it can be removed
    mapping(uint256 orderId => Order order) public orders;
    mapping(uint256 orderId => uint256 index) public orderIndex;
    
    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    /// Hook permission selector
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook functionality
    /// @inheritdoc BaseHook
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 deadline, bool useCoW) = hookData.decodeHookData();
        if (!useCoW) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        } else {
            // We want to place an order for the user.
            // We want to give ownership of the token to the smart contract
            // We want to return a no op to the pool manager
            PoolId poolId = key.toId();
            bool zeroForOne = params.zeroForOne;
            // The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
            int256 inputAmount = params.amountSpecified;

            // For now, we want to skip exact output. TODO - include functionality for exact output
            if (inputAmount >= 0) return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
            // We want to simulate the swapping to determine the amount of token1 that the user is going to get or the amount of token0 the user is going to pay
            (uint256 ethOut, uint256 tokenIn, BeforeSwapDelta beforeSwapDelta_) = simulateSwap(poolId, params);
            takeAndSettle(key, zeroForOne, uint128(int128(-inputAmount)));
            Order memory order = Order({
                owner: sender,
                poolId: poolId,
                zeroForOne: zeroForOne,
                fulfilled: false,
                amountIn: ethOut,
                amountOut: tokenIn,
                deadline: deadline
            });
            placeOrder(poolId, order);
            return (this.beforeSwap.selector, beforeSwapDelta_, 0);
        }
    }

    function placeOrder(PoolId _poolId, Order memory order) public returns (uint256 orderId) {
        bool zeroForOne = order.zeroForOne;
        uint256 deadline = order.deadline;
        uint256 amountIn = order.amountIn;
        uint256 amountOut = order.amountOut;
        pendingOrders[_poolId][zeroForOne].push(order);
        batchPendingOrders[_poolId][zeroForOne] += amountIn;
        orderId = getOrderId(_poolId, zeroForOne, deadline, amountIn, amountOut);
        _mint(order.owner, orderId, amountOut, "");
        tokenClaims[orderId] += amountOut;
        tokensClaimsFulfilled[orderId] += 0;
        orderIndex[orderId] = pendingOrders[_poolId][zeroForOne].length;
    }

    function settleOrder(PoolKey calldata key) public {

    }

    function cancelOrder(uint256 orderId) public {
        Order memory order = orders[orderId];
        // Ensure the caller is the owner of the order
        if (order.owner != msg.sender) revert NotOnwerOfOrder();
        // We want to remove the order from the pending orders listusing swap and pop
        pendingOrders[order.PoolId][order.zeroForOne]
        // burn the user's claim tokens
        // make the order's amount claimable to zero
        // make the order's claimFulfilled to zero
    }

    // =================== Helper Functions ==================

    /// Calculate what would happen if the swap went through the Uniswap AMM right now, without actually executing it.
    /// @param poolId Id of the pool
    /// @param params Swap params
    /// @return ethOut amount of eth from the wallet
    /// @return tokenIn amount of token sent back to the user
    /// @return beforeSwapDelta_ BeforeSwapDelta
    function simulateSwap(PoolId poolId, SwapParams calldata params)
        internal
        view
        returns (uint256 ethOut, uint256 tokenIn, BeforeSwapDelta beforeSwapDelta_)
    {
        // Get the current price for the pool to use as a price basis for the swap
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (params.amountSpecified >= 0) {
            // token0 for token1 with exact output for input
            // If the amount specified for token1 is greater than what we have in the pool fees from deposit fees,
            // we use poolFees amount1 otherwise, we use amountSpecified for the swap
            // We want to determine the maximum value
            uint256 amountSpecified = uint256(params.amountSpecified);

            // We want to determine the amount of ETH token required to get the amount of token1 specified at the current pool state
            (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: int256(amountSpecified),
                feePips: 0
            });
            // Update our hook delta to reduce the upcoming swap amount to show that we have
            // already spent some of the ETH and received some of the underlying ERC20.
            beforeSwapDelta_ = toBeforeSwapDelta(-int128(int256(tokenIn)), int128(int256(ethOut)));
        } else {
            // token0 for token1 with exact input for output
            // amountSpecified is negative
            // Since we already know the amount of token0 required, we just need to
            // determine the amount we will receive if we convert all of the pool fees.
            (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: int256(int256(-params.amountSpecified)),
                feePips: 0
            });

            if (ethOut > uint256(-params.amountSpecified)) {
                uint256 percentage = (uint256(-params.amountSpecified) * 1e18) / ethOut;
                tokenIn = (tokenIn * percentage) / 100;
            }
            beforeSwapDelta_ = toBeforeSwapDelta(int128(int256(ethOut)), -int128(int256(tokenIn)));
        }
    }

    /// @notice Simulates a swap to calculate expected output/input amounts and the corresponding BeforeSwapDelta.
    /// @dev This function uses the current pool price and liquidity to estimate the swap outcome without executing it.
    /// It is primarily used to determine the parameters for limit orders or CoW (Coincidence of Wants) matching
    /// by calculating how
    function takeAndSettle(PoolKey calldata key, bool zeroForOne, uint128 amount) internal {
        if (zeroForOne) {
            // take currency zero and settle currency 1
            _take(key.currency1, amount);
            _settle(key.currency1);
        } else {
            _take(key.currency1, amount);
            _settle(key.currency0);
        }
    }

    /// Settle currency with pool manager
    /// @param currency Currency to settle
    function _settle(Currency currency) internal {
        poolManager.sync(currency);
        poolManager.settle();
    }

    /// Take the money from the user and add it to the smart contract
    /// @param currency Currency of the swap
    /// @param amount Amount to take
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    /// Deterministic function to get the order id of the swap
    /// @param _poolId Pool Id
    /// @param zeroForOne direction
    /// @param deadline deadline of CoW swap
    /// @param amountIn Amount of token in
    /// @param amountOut Amount of token out
    /// @return orderId order id of the swap
    function getOrderId(PoolId _poolId, bool zeroForOne, uint256 deadline, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (uint256 orderId)
    {
        return uint256(keccak256(abi.encode(_poolId, zeroForOne, deadline, amountIn, amountOut)));
    }
}

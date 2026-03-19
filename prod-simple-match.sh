#!/bin/bash
# Requirements: Set RPC_URL, USER_A_PK, USER_B_PK in your environment variables

tETH="0x568933d38886b2aA8A2165dAfDcE7D017388637C"
tUSDC="0x69421BB202C3514384DCb5053DCDc3FD591e4507"

# Extract public addresses from private keys using cast
USER_A=$(cast wallet address --private-key $PRIVATE_KEY)
USER_B=$(cast wallet address --private-key $PRIVATE_KEY1)

echo "--- BEFORE SWAP BALANCES ---"
echo "User A ($USER_A) tUSDC balance: $(cast call $tUSDC "balanceOf(address)(uint256)" $USER_A --rpc-url $RPC_URL)"
echo "User B ($USER_B) tETH balance: $(cast call $tETH "balanceOf(address)(uint256)" $USER_B --rpc-url $RPC_URL)"
echo "----------------------------"

echo "Executing Swap Orders..."
forge script script/DemoSimpleMatch.s.sol:DemoSimpleMatch --rpc-url $RPC_URL --broadcast

echo "Orders submitted. Waiting 30 seconds for the Reactive Smart Contract to settle..."
sleep 30

echo "--- AFTER SETTLEMENT BALANCES ---"
echo "User A tUSDC balance: $(cast call $tUSDC "balanceOf(address)(uint256)" $USER_A --rpc-url $RPC_URL)"
echo "User B tETH balance: $(cast call $tETH "balanceOf(address)(uint256)" $USER_B --rpc-url $RPC_URL)"
echo "If balances have increased, the CoW match was successful!"
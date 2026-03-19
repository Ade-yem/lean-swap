#!/bin/bash
# Requirements: Set RPC_URL, USER_A_PK, USER_B_PK, USER_C_PK

tETH="0x568933d38886b2aA8A2165dAfDcE7D017388637C"
tUSDC="0x69421BB202C3514384DCb5053DCDc3FD591e4507"
tDAI="0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec"

USER_A=$(cast wallet address --private-key $USER_A_PK)
USER_B=$(cast wallet address --private-key $USER_B_PK)
USER_C=$(cast wallet address --private-key $USER_C_PK)

echo "--- BEFORE SWAP BALANCES ---"
echo "User A Target (tUSDC): $(cast call $tUSDC "balanceOf(address)(uint256)" $USER_A --rpc-url $RPC_URL)"
echo "User B Target (tDAI): $(cast call $tDAI "balanceOf(address)(uint256)" $USER_B --rpc-url $RPC_URL)"
echo "User C Target (tETH): $(cast call $tETH "balanceOf(address)(uint256)" $USER_C --rpc-url $RPC_URL)"
echo "----------------------------"

echo "Executing 3-Party Loop Swap Orders..."
forge script script/DemoLoopMatch.s.sol:DemoLoopMatch --rpc-url $RPC_URL --broadcast

echo "Orders submitted. Waiting 30-40 seconds for the DFS cycle detection and settlement via callback..."
sleep 40

echo "--- AFTER SETTLEMENT BALANCES ---"
echo "User A Target (tUSDC): $(cast call $tUSDC "balanceOf(address)(uint256)" $USER_A --rpc-url $RPC_URL)"
echo "User B Target (tDAI): $(cast call $tDAI "balanceOf(address)(uint256)" $USER_B --rpc-url $RPC_URL)"
echo "User C Target (tETH): $(cast call $tETH "balanceOf(address)(uint256)" $USER_C --rpc-url $RPC_URL)"
echo "If target balances increased, the Reactive contract successfully detected and settled the closed loop!"
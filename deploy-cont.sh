#!/bin/bash

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | xargs)
else
  echo "Please provide a .env file based on .env.example below"
  cat .env.example
  exit 1
fi
# Configuration
REACTIVE_FAUCET="0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"

# Step 2: Deploy Reactive Smart Contract to Reactive Network
echo "⏳ [2/4] Deploying Reactive Smart Contract to Reactive Network..."
# Ensure the RSC deployment knows about the Unichain Hook
export HOOK_ADDRESS="0xDEd4eA65Fa4BeD481c0c2Ab041c8030aFC308088"
export ORIGIN_CHAIN_ID=$UNICHAIN_SEPOLIA_CHAIN_ID
export DEST_CHAIN_ID=$UNICHAIN_SEPOLIA_CHAIN_ID

RSC_OUTPUT=$(forge script script/deployReactive.s.sol --rpc-url $REACTIVE_TESTNET_RPC --broadcast)
echo "$RSC_OUTPUT"

# Extract RSC Address
REACTIVE_CONTRACT_ADDR=$(echo "$RSC_OUTPUT" | grep "LeanSwapReactive deployed at:" | grep -oE "0x[a-fA-F0-9]{40}")
if [ -z "$REACTIVE_CONTRACT_ADDR" ]; then
    echo "Failed to extract Reactive Contract Address!"
    exit 1
fi
echo ">>> Reactive Contract Address: $REACTIVE_CONTRACT_ADDR"

# Step 3: Update the Hook with the actual RSC address on Unichain
echo "⏳ [3/4] Updating Hook on Unichain with the RSC address..."
cast send $HOOK_ADDRESS "setRscAddress(address)" $REACTIVE_CONTRACT_ADDR \
    --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY

# Step 6: Fund the RSC with REACT tokens via Ethereum Sepolia Faucet
echo "⏳ [4/4] Funding Reactive Smart Contract via Ethereum Sepolia Faucet..."
cast send $REACTIVE_FAUCET "request(address)" $REACTIVE_CONTRACT_ADDR --value 0.2ether \
    --rpc-url $ETHEREUM_SEPOLIA_RPC \
    --private-key $PRIVATE_KEY

echo "⏳ [5/5] Initializing the reactive smart contract subscription"
cast send $REACTIVE_CONTRACT_ADDR "initializeSubscription()"  --rpc-url $REACTIVE_TESTNET_RPC --private-key $PRIVATE_KEY

echo "----------------------------------------------------------------"
echo "Deployment Complete!"
echo "Hook Address: $HOOK_ADDRESS"
echo "RSC Address: $REACTIVE_CONTRACT_ADDR"
echo "----------------------------------------------------------------"

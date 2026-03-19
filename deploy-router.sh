#!/bin/bash

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | xargs)
else
  echo "Please provide a .env file based on .env.example below"
  cat .env.example
  exit 1
fi

# Check arguments
if [ "$1" == "test" ]; then
    SCRIPT="script/deployTestRouter.s.sol"
    MODE_NAME="Test Router"
    OUTPUT="./deployment/test-router-output.txt"
elif [ "$1" == "live" ]; then
    SCRIPT="script/deployRouter.s.sol"
    MODE_NAME="LeanSwap Router"
    OUTPUT="./deployment/live-router-output.txt"
else
    echo "Usage: $0 [test|live]"
    exit 1
fi

# Configuration
UNICHAIN_SEPOLIA_CHAIN_ID=${UNICHAIN_SEPOLIA_CHAIN_ID:-1301}

echo "----------------------------------------------------------------"
echo "Starting Deployment for $MODE_NAME --- LFG 🚀"
echo "----------------------------------------------------------------"

# Step 1, 4, 5: Deploy Tokens, Faucet, Router and Initialize Pools on Unichain
echo "⏳ [1/5] Deploying $MODE_NAME to Unichain Sepolia..."
DEPLOY_OUTPUT=$(forge script $SCRIPT --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast \
        --slow --verify --verifier "blockscout" --verifier-url "https://unichain-sepolia.blockscout.com/api" \
        --verifier-api-key $UNICHAIN_EXPLORER_API_KEY --with-gas-price 1gwei
        )
echo "$DEPLOY_OUTPUT" > $OUTPUT
echo "$DEPLOY_OUTPUT"

# Extract Router Address
ROUTER_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "Router deployed at:" | tail -1 | grep -oE "0x[a-fA-F0-9]{40}")
if [ -z "$ROUTER_ADDRESS" ]; then
    echo "Failed to extract Router Address!"
    exit 1
fi
echo ">>> Router Address: $ROUTER_ADDRESS"

echo "----------------------------------------------------------------"
echo "Deployment Complete!"
echo "Router Address: $ROUTER_ADDRESS"
echo "----------------------------------------------------------------"

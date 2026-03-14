# These are all examples of commands I will use


# For sending token to the reactive smart contract
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 --rpc-url $ETHEREUM_SEPOLIA_RPC --private-key $PRIVATE_KEY "request(address)" $REACTIVE_CONTRACT_ADDR --value 0.1ether

# to update the hook's smart contract rsc address
cast send $HOOK_ADDRESS --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY "setRscAddress(address)" $REACTIVE_CONTRACT_ADDR --value 0.1ether

# Get the ETH balance of an address
cast balance 0xE265a72c0F8af149492c4d509807b97dE5E6b53B --rpc-url $ETHEREUM_SEPOLIA_RPC

# Deploy to testnet
forge script script/DeployHook.s.sol --rpc-url $MAINNET_RPC_URL --chain-id 1 --broadcast
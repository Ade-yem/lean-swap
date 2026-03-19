# LeanSwap Deployment & Interaction Guide

LeanSwap is a Uniswap v4 Hook-based protocol featuring cross-chain reactive automation. This guide provides instructions on how to deploy, test, and interact with the LeanSwap ecosystem.

## 🌐 Targeted Networks

The protocol is deployed across multiple networks to facilitate trading and reactive automation.

| Network              | Chain ID   | Role                                  | Explorer                                             |
| :------------------- | :--------- | :------------------------------------ | :--------------------------------------------------- |
| **Unichain Sepolia** | `1301`     | Primary (Hook, Pools, Tokens, Router) | [Explorer](https://unichain-sepolia.blockscout.com/) |
| **Reactive Testnet** | `5318007`  | Automation (Reactive Smart Contracts) | [Explorer](https://lasna.reactscan.net//)           |
| **Ethereum Sepolia** | `11155111` | Funding for Reactive Smart contract                  | [Explorer](https://sepolia.etherscan.io/)            |
| **Base Sepolia**     | `84532`    | Funding for Reactive Smart contract                      | [Explorer](https://base-sepolia.blockscout.com/)     |

---

## 📂 Project Structure

### Deployment Scripts

- **Bash Scripts** (Root):
  - `deploy.sh`: Orchestrates the full deployment of the Hook, Tokens, Faucet, and Reactive Smart Contract.
  - `deploy-router.sh`: Deploys the `LeanSwapRouter` (supports `test` and `live` modes).
  - `cmd.sh`: Collection of useful `cast` commands for contract management.
  - `getReact.sh`: Quick script to request funds from the Reactive faucet.
- **Foundry Scripts** (`script/`):
  - `deployHookTokensAndFaucet.s.sol`: Deploys core infrastructure on Unichain.
  - `deployReactive.s.sol`: Deploys automation logic on the Reactive Network.
  - `deployRouter.s.sol`: Deploys the main LeanSwap Router.
  - `TestDeployment.s.sol`: Verifies deployment by performing multi-pool quotes and swaps.

### Testing

- **Test Suite** (`test/`):
  - `LeanSwapLoopOrders.t.sol`: Comprehensive tests for loop order logic.
  - `LeanSwapReactiveInteraction.t.sol`: Tests the bridge between Unichain and Reactive Network.
  - `LeanSwapSimple.t.sol` & `LeanSwapSimpleComplex.t.sol`: Basic and advanced hook functionality tests.

---

## 🚀 Deployment Workflow

### 1. Prerequisites

Ensure you have a `.env` file configured with the following variables:

```bash
PRIVATE_KEY=your_private_key
UNICHAIN_EXPLORER_API_KEY=your_key
UNICHAIN_SEPOLIA_RPC_URL=your_rpc_url
REACTIVE_TESTNET_RPC=https://lasna-rpc.rnk.dev/
```

### 2. Full System Deployment

To deploy the entire stack (Hook, Tokens, RSC):

```bash
chmod +x deploy.sh
./deploy.sh
```

This script will:

1. Deploy Tokens and Hook to Unichain Sepolia.
2. Deploy the Reactive Smart Contract (RSC) to the Reactive Network.
3. Link the Hook and RSC.
4. Fund the RSC for gas fees.

### 3. Router Deployment

To deploy the Swap Router:

```bash
# For the live router
./deploy-router.sh live

# For the test router (internal testing)
./deploy-router.sh test
```

---

## 🔧 Interaction & Management

### Updating Hook Configuration

If you need to update the Reactive Smart Contract address in the Hook:

```bash
cast send $HOOK_ADDRESS "setRscAddress(address)" $REACTIVE_CONTRACT_ADDR \
    --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

### Performing a Swap

Interactions are handled through the `LeanSwapRouter`. You must first approve the router for the input token.

**Example: Swapping ETH for USDC**

```bash
# 1. Approve
cast send $tUSDC_ADDRESS "approve(address,uint256)" $ROUTER_ADDRESS $AMOUNT
...

# 2. Swap (using the Router)
# See TestDeployment.s.sol for specific encoding of hook data
```

### Funding Reactive Contracts

Funding the RSC with `REACT` tokens via the Ethereum Sepolia faucet:

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
    --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    "request(address)" $REACTIVE_CONTRACT_ADDR \
    --value 0.04ether
```

---

## 🧪 Running Tests

Validate the protocol logic locally using Foundry:

```bash
# Run all tests
forge test

# Run a specific test file
forge test --match-path test/LeanSwapLoopOrders.t.sol -vv

# Run with gas reporting
forge test --gas-report
```

---

## 📝 Deployments

| Contract                       | Address                                      |
| :----------------------------- | :------------------------------------------- |
| **tUSDC token**                     | `0x69421BB202C3514384DCb5053DCDc3FD591e4507` |
| **tDAI token**                      | `0x98ED3c67CCD6c07A09aa643944a926d251ae29Ec` |
| **tLEAN token**                     | `0x18754e7c697A6DB8afC0BF963692f53c2719453f` |
| **tETH token**                      | `0x568933d38886b2aA8A2165dAfDcE7D017388637C` |
| **tCOW token**                      | `0xFF02F80E373317b778a1335808ddEFD1FC448227` |
| **Faucet**        | `0xC454a89fc5FD364bE7A5f3E22BF9bD66f55634b0` |
| **Live Router**        | `0x305D52a7EB149f153fa7268061656B17f8b008af` |
| **Test Router**        | `0x305D52a7EB149f153fa7268061656B17f8b008af` |
| **LeanSwap Hook** | `0x2E297061451a5B83748Cdf14025dcf86553b9f38` |
| **LeanSwap RSC** | `0x824fD4070869F4cC5530fd6371d75a3f4A6C0E4C` |

> [!NOTE]
> Deployment details in [./deployment/](./deployment/) directory after running deployment scripts.

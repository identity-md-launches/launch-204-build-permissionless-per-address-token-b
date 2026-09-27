# Deployment — RateLimiter on Sepolia

Deployment target: **Sepolia only** (chain id `11155111`). The script refuses chain id 1, and
nothing in this repository is meant for mainnet. No token is created or deployed.

## Parameters

| Item | Value |
| --- | --- |
| Contract | `src/RateLimiter.sol:RateLimiter` |
| Compiler | solc 0.8.24, optimizer on, 200 runs, `evm_version = cancun`, `bytecode_hash = none`, no via-IR |
| Constructor | `constructor(uint256 capacity, uint256 refillInterval)` |
| Constructor arguments (demo) | `capacity = 10`, `refillInterval = 60` |
| ABI-encoded constructor arguments | `0x000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000003c` |
| Privileged roles | none (no owner, no `$owner` argument, no admin functions) |
| ETH handling | none (no `receive`/`fallback`, nonpayable constructor) |
| Forbidden opcodes | none used (no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`; no proxy) |

The constructor is nonpayable, takes only `uint256` arguments and performs no external calls, so
the contract can be deployed either directly with the script below or through a factory that
supports `uint256` constructor arguments (for a manifest: arguments `[10, 60]`, no address
references, no owner).

## Procedure (operator with a funded Sepolia test account)

1. Preconditions, offline:

   ```bash
   forge build --offline
   forge test --offline
   forge fmt --check
   forge script script/DeployRateLimiter.s.sol:DeployRateLimiter --offline   # local dry run
   ```

2. Simulate against Sepolia (no broadcast):

   ```bash
   forge script script/DeployRateLimiter.s.sol:DeployRateLimiter \
       --rpc-url "$SEPOLIA_RPC_URL" --sender "$DEPLOYER_ADDRESS"
   ```

3. Broadcast with a **test account only** (a keystore or hardware wallet holding Sepolia ETH; never a
   key with mainnet funds). Optional overrides `RATE_LIMITER_CAPACITY` / `RATE_LIMITER_REFILL_INTERVAL`
   default to the demo values `10` / `60`:

   ```bash
   forge script script/DeployRateLimiter.s.sol:DeployRateLimiter \
       --rpc-url "$SEPOLIA_RPC_URL" --account "$KEYSTORE_ACCOUNT" --broadcast
   ```

   `forge` writes `broadcast/DeployRateLimiter.s.sol/11155111/run-latest.json` with the contract
   address and transaction hash. Commit that file as the deployment record.

4. Verify the source on the explorer (optional, needs an Etherscan API key):

   ```bash
   forge verify-contract --chain sepolia --compiler-version 0.8.24 \
       --constructor-args 0x000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000003c \
       "$CONTRACT_ADDRESS" src/RateLimiter.sol:RateLimiter
   ```

5. Smoke test the live contract:

   ```bash
   cast call "$CONTRACT_ADDRESS" "capacity()(uint256)"          --rpc-url "$SEPOLIA_RPC_URL"   # 10
   cast call "$CONTRACT_ADDRESS" "refillInterval()(uint256)"    --rpc-url "$SEPOLIA_RPC_URL"   # 60
   cast call "$CONTRACT_ADDRESS" "available(address)(uint256)" "$DEPLOYER_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL"  # 10
   cast send "$CONTRACT_ADDRESS" "consume(uint256)" 3 --rpc-url "$SEPOLIA_RPC_URL" --account "$KEYSTORE_ACCOUNT"
   cast call "$CONTRACT_ADDRESS" "available(address)(uint256)" "$DEPLOYER_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL"  # 7
   ```

## Deployment record

| Field | Value |
| --- | --- |
| Network | Sepolia, chain id 11155111 |
| Contract address | **not deployed from this environment** |
| Deployment transaction hash | **not deployed from this environment** |
| Explorer link | `https://sepolia.etherscan.io/address/<CONTRACT_ADDRESS>` once deployed |
| Constructor arguments | `10`, `60` (encoded above) |
| Deployer account | to be a documented Sepolia test account; none was available here |

**Why the on-chain step is not done.** This working environment has no funded Sepolia account, no
RPC credential and no keystore, and the contributor rules for this network forbid a build task from
accessing a wallet key or broadcasting transactions. Rather than fabricate a record, the script,
parameters and exact commands above are delivered so the operator (or the factory-based launch
step) can complete the deployment and fill in the three empty fields. The local dry run
(`forge script ... --offline`) executes the constructor successfully with the demo parameters
(reported gas used 600,694 in the simulation).

## Operational notes

* Parameters are immutable. Changing them means deploying a new instance.
* The contract has no privileged functions, so there is nothing to hand over, rotate or pause.
* Do not deploy to Ethereum mainnet; the script's `run()` rejects chain id 1 as a guard.

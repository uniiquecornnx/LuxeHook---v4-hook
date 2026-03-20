# 💎 LuxeBridge

> **A Uniswap V4 hook that brings certified diamonds on-chain.**
> Oracle-gated, compliance-aware liquidity pools for real-world luxury assets.

---

## What is LuxeBridge?

LuxeBridge is a custom Uniswap V4 hook that enables vault-backed, GIA-certified diamonds to trade in on-chain AMM pools. By representing physical diamonds as ERC-20 tokens and enforcing compliance at the hook layer, LuxeBridge transforms a standard liquidity pool into a **programmable, compliance-aware trading engine** built for real-world assets.

The $80B+ global diamond market is illiquid, opaque, and gated behind closed dealer networks. LuxeBridge changes that — enabling **24/7 price discovery**, **fractional ownership**, and **institutional-grade controls** for an asset class that has never had them.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      LuxeBridge System                       │
│                                                              │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────┐  │
│  │  DiamondToken   │  │   LuxeOracle     │  │ LuxeBridge │  │
│  │   (ERC-20)      │◄─┤  (price + cert)  ├─►│    Hook    │  │
│  └─────────────────┘  └──────────────────┘  └─────┬──────┘  │
│                                                    │         │
│                                          ┌─────────▼──────┐  │
│                                          │  Uniswap V4    │  │
│                                          │  PoolManager   │  │
│                                          └────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Contracts

| Contract | Description |
|---|---|
| `LuxeBridgeHook.sol` | Core hook — oracle checks, price deviation guard, circuit breaker |
| `DiamondToken.sol` | ERC-20 representing a vault-backed GIA-certified diamond |
| `MockLuxeOracle.sol` | Test oracle (swap for Chainlink Functions in production) |

---

## How It Works

The hook intercepts two Uniswap V4 pool actions:

### `beforeSwap`
Before any trade executes, the hook enforces four checks in sequence:

1. **Pool registration** — is this pool registered with LuxeBridge?
2. **Circuit breaker** — has the pool been halted due to a price anomaly?
3. **Certification** — is the diamond token currently GIA-certified?
4. **Oracle freshness + price deviation** — is the oracle price recent, and is the pool price within the allowed deviation?

### `beforeAddLiquidity`
Before any liquidity is added:

1. Certification check — uncertified tokens cannot enter the pool
2. Oracle freshness check — stale price data blocks liquidity additions

### Circuit Breaker
If the pool price drifts more than `maxDeviationBps` (default: **5%**) from the oracle price, the pool is **automatically halted**:

```
deviation = |pool_price - oracle_price| / oracle_price * 10,000
if deviation > maxDeviationBps → poolActive[poolId] = false
```

A `CircuitBreakerTriggered` event is emitted and an admin must review and manually reset the pool. This is the institutional-grade control that standard AMMs don't provide.

---

## Quickstart

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify
forge --version
```

### Setup

```bash
# Clone the correct base repo
git clone --branch main --recurse-submodules https://github.com/Uniswap/v4-periphery.git
cd v4-periphery

# Copy LuxeBridge contracts into place
cp LuxeBridgeHook.sol src/
cp DiamondToken.sol src/
cp MockLuxeOracle.sol src/
cp LuxeBridgeHook.t.sol test/
cp DeployLuxeBridge.s.sol script/

# Create remappings
cat > remappings.txt << 'EOF'
v4-core/=lib/v4-core/
v4-periphery/src/=src/
@uniswap/v4-core/=lib/v4-core/
forge-std/=lib/v4-core/lib/forge-std/src/
@openzeppelin/contracts/=lib/v4-core/lib/openzeppelin-contracts/contracts/
openzeppelin-contracts/=lib/v4-core/lib/openzeppelin-contracts/
permit2/=lib/permit2/
solmate/=lib/v4-core/lib/solmate/
ds-test/=lib/v4-core/lib/forge-std/lib/ds-test/src/
EOF

forge build
```

### Run Tests

```bash
# Full test suite
forge test -vvv

# Single test
forge test --match-test test_Swap_Success -vvv

# Gas report
forge test --gas-report
```

### Deploy Locally (Anvil)

```bash
# Terminal 1 — start local node
anvil

# Terminal 2 — deploy
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/DeployLuxeBridge.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  -vvvv
```

---

## Test Coverage

| Test | What it covers |
|---|---|
| `test_PoolRegistered` | Pool correctly registered and active |
| `test_AddLiquidity_Success` | Happy path liquidity addition |
| `test_Swap_Success` | Happy path swap |
| `test_Revert_TokenNotCertified_OnSwap` | Reverts when certification revoked |
| `test_Revert_TokenNotCertified_OnAddLiquidity` | Reverts on uncertified liquidity add |
| `test_Revert_StaleOracle_OnSwap` | Reverts when oracle price is stale |
| `test_Revert_UnregisteredPool` | Reverts on unregistered pool |
| `test_CircuitBreaker_TriggeredOnLargeDeviation` | Circuit breaker fires on large price gap |
| `test_CircuitBreaker_Reset` | Owner can reset a halted pool |
| `test_DiamondToken_Metadata` | Token decimals, certificate ID, carat weight |
| `test_DiamondToken_MintBurn` | Mint and burn mechanics |

---

## Interacting via Cast

```bash
# Check if a pool is active
cast call <HOOK_ADDRESS> "isPoolActive((address,address,uint24,int24,address))" \
  "(<C0>,<C1>,3000,60,<HOOK_ADDRESS>)" --rpc-url http://localhost:8545

# Get current oracle price
cast call <ORACLE_ADDRESS> "getPrice(address)" <DIAMOND_TOKEN> \
  --rpc-url http://localhost:8545

# Check certification
cast call <ORACLE_ADDRESS> "isCertified(address)" <DIAMOND_TOKEN> \
  --rpc-url http://localhost:8545

# Reset circuit breaker (owner only)
cast send <HOOK_ADDRESS> "resetCircuitBreaker((address,address,uint24,int24,address))" \
  "(<C0>,<C1>,3000,60,<HOOK_ADDRESS>)" --private-key $PRIVATE_KEY \
  --rpc-url http://localhost:8545

# Update max deviation to 10%
cast send <HOOK_ADDRESS> "setMaxDeviationBps(uint256)" 1000 \
  --private-key $PRIVATE_KEY --rpc-url http://localhost:8545
```

---

## Hook Flags

LuxeBridge only uses two hook flags, keeping gas overhead minimal:

```solidity
Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
```

All other pool actions (remove liquidity, donate, etc.) pass through without interception.

---

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `maxDeviationBps` | `500` | Max allowed pool/oracle price deviation (5%) |
| `oracleStaleThreshold` | `3600` | Oracle price max age in seconds (1 hour) |
| Pool fee | `3000` | 0.3% swap fee |
| Pool tick spacing | `60` | Standard for 0.3% pools |

---

## Production Roadmap

To deploy this with real value:

- **Replace `MockLuxeOracle`** with a Chainlink Functions feed sourcing from [Rappaport price sheets](https://www.rappaport.com) or [IDEX](https://www.idexonline.com)
- **Add KYC/AML gating** in `beforeSwap` against a verified wallet whitelist
- **Gate `DiamondToken` minting** behind on-chain vault proof / proof-of-reserve
- **Add a TimelockController** to admin functions (`setOracle`, `setMaxDeviationBps`)
- **Full security audit** before any real-value deployment

---

## Built With

- [Uniswap V4](https://github.com/Uniswap/v4-core) — Hook infrastructure
- [Foundry](https://github.com/foundry-rs/foundry) — Testing and deployment
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC-20, Ownable, ReentrancyGuard
- [Unichain](https://unichain.org) — Target deployment chain

---

## License

MIT

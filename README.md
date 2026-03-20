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


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Oracle interface for diamond/luxury asset valuation
interface ILuxeOracle {
    /// @notice Returns the current USD price (18 decimals) of a diamond token
    /// @param token The ERC-20 token representing the diamond
    /// @return price USD price per token (18 decimals)
    /// @return updatedAt Timestamp of the last price update
    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Returns whether a specific diamond token is certified/verified
    function isCertified(address token) external view returns (bool);
}

/// @title LuxeBridge Hook
/// @notice A Uniswap V4 hook that enables compliant, oracle-gated trading of
///         tokenized luxury assets (diamonds) in on-chain liquidity pools.
/// @dev Implements beforeSwap and beforeModifyLiquidity hooks to enforce:
///      1. Oracle-based valuation checks
///      2. Price deviation limits (circuit breaker)
///      3. Certification gating — only verified diamond tokens may enter the pool
contract LuxeBridgeHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    // ────────────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────────────

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DeviationLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event OracleStaleThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PoolRegistered(PoolId indexed poolId, address indexed luxuryToken);
    event SwapBlocked(PoolId indexed poolId, string reason);
    event LiquidityBlocked(PoolId indexed poolId, string reason);
    event CircuitBreakerTriggered(PoolId indexed poolId, uint256 oraclePrice, uint256 poolPrice);

    // ────────────────────────────────────────────────────────────────────────
    // Errors
    // ────────────────────────────────────────────────────────────────────────

    error TokenNotCertified(address token);
    error OraclePriceStale(uint256 lastUpdate, uint256 threshold);
    error PriceDeviationTooHigh(uint256 poolPrice, uint256 oraclePrice, uint256 deviation);
    error PoolNotRegistered(PoolId poolId);
    error ZeroAddress();
    error InvalidDeviationLimit();
    error OracleCallFailed();

    // ────────────────────────────────────────────────────────────────────────
    // State
    // ────────────────────────────────────────────────────────────────────────

    /// @notice The oracle used for luxury asset valuation
    ILuxeOracle public oracle;

    /// @notice Maximum allowed deviation between oracle price and pool price (basis points)
    /// @dev 500 = 5%, 1000 = 10%, etc.
    uint256 public maxDeviationBps;

    /// @notice Maximum age (seconds) for oracle price to be considered fresh
    uint256 public oracleStaleThreshold;

    /// @notice Mapping from PoolId → luxury ERC-20 token address
    /// @dev Only pools registered here have hook logic enforced
    mapping(PoolId => address) public poolLuxuryToken;

    /// @notice Mapping from PoolId → whether the pool is active (not circuit-broken)
    mapping(PoolId => bool) public poolActive;

    /// @notice Constant: 10_000 basis points = 100%
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice ETH/USD price feed address (Chainlink-compatible) for ETH-denominated pools
    address public ethPriceFeed;

    // ────────────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────────────

    /// @param _poolManager Uniswap V4 PoolManager
    /// @param _oracle Initial oracle address
    /// @param _maxDeviationBps Initial max price deviation in basis points (e.g. 500 = 5%)
    /// @param _oracleStaleThreshold Seconds before an oracle price is considered stale
    constructor(
        IPoolManager _poolManager,
        address _oracle,
        uint256 _maxDeviationBps,
        uint256 _oracleStaleThreshold
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        if (_oracle == address(0)) revert ZeroAddress();
        if (_maxDeviationBps == 0 || _maxDeviationBps > BPS_DENOMINATOR) revert InvalidDeviationLimit();

        oracle = ILuxeOracle(_oracle);
        maxDeviationBps = _maxDeviationBps;
        oracleStaleThreshold = _oracleStaleThreshold;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Hook Permissions
    // ────────────────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,      // Gate liquidity additions
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,              // Gate swaps
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ────────────────────────────────────────────────────────────────────────
    // Hook Callbacks
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Called before any swap. Enforces oracle checks and price deviation limits.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // 1. Pool must be registered
        address luxuryToken = poolLuxuryToken[poolId];
        if (luxuryToken == address(0)) revert PoolNotRegistered(poolId);

        // 2. Pool must not be circuit-broken
        if (!poolActive[poolId]) {
            emit SwapBlocked(poolId, "circuit breaker active");
            revert("LuxeBridge: circuit breaker active");
        }

        // 3. Run compliance checks
        _runComplianceChecks(poolId, key, luxuryToken);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Called before liquidity is added. Enforces certification and oracle checks.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        address luxuryToken = poolLuxuryToken[poolId];
        if (luxuryToken == address(0)) revert PoolNotRegistered(poolId);

        if (!poolActive[poolId]) {
            emit LiquidityBlocked(poolId, "circuit breaker active");
            revert("LuxeBridge: circuit breaker active");
        }

        // Certification check: only allow liquidity from verified tokens
        if (!oracle.isCertified(luxuryToken)) {
            emit LiquidityBlocked(poolId, "token not certified");
            revert TokenNotCertified(luxuryToken);
        }

        // Oracle freshness check
        (, uint256 updatedAt) = _safeGetOraclePrice(luxuryToken);
        _checkOracleFreshness(updatedAt);

        return BaseHook.beforeAddLiquidity.selector;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Internal Logic
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Runs all compliance checks for a given pool
    function _runComplianceChecks(
        PoolId poolId,
        PoolKey calldata key,
        address luxuryToken
    ) internal {
        // Check certification
        if (!oracle.isCertified(luxuryToken)) {
            emit SwapBlocked(poolId, "token not certified");
            revert TokenNotCertified(luxuryToken);
        }

        // Get oracle price
        (uint256 oraclePrice, uint256 updatedAt) = _safeGetOraclePrice(luxuryToken);

        // Check freshness
        _checkOracleFreshness(updatedAt);

        // Check price deviation against pool's current sqrt price
        uint256 poolPrice = _derivePoolPrice(key);
        if (poolPrice > 0 && oraclePrice > 0) {
            _checkPriceDeviation(poolId, poolPrice, oraclePrice);
        }
    }

    /// @dev Derives an approximate pool price from the current sqrtPriceX96
    ///      Returns price of token0 in terms of token1, scaled to 18 decimals
    function _derivePoolPrice(PoolKey calldata key) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return 0;

        // price = (sqrtPriceX96 / 2^96)^2
        // To avoid overflow, compute in two steps
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        // price18 = sqrtPrice^2 * 1e18 / (2^192)
        // 2^192 = 2^96 * 2^96
        uint256 price = (sqrtPrice * sqrtPrice * 1e18) >> 192;
        return price;
    }

    /// @dev Checks that the deviation between pool price and oracle price is within limits
    function _checkPriceDeviation(
        PoolId poolId,
        uint256 poolPrice,
        uint256 oraclePrice
    ) internal {
        uint256 deviation;
        if (poolPrice > oraclePrice) {
            deviation = ((poolPrice - oraclePrice) * BPS_DENOMINATOR) / oraclePrice;
        } else {
            deviation = ((oraclePrice - poolPrice) * BPS_DENOMINATOR) / oraclePrice;
        }

        if (deviation > maxDeviationBps) {
            // Trigger circuit breaker
            poolActive[poolId] = false;
            emit CircuitBreakerTriggered(poolId, oraclePrice, poolPrice);
            revert PriceDeviationTooHigh(poolPrice, oraclePrice, deviation);
        }
    }

    /// @dev Safely calls oracle.getPrice, reverts on failure
    function _safeGetOraclePrice(address token) internal view returns (uint256 price, uint256 updatedAt) {
        try oracle.getPrice(token) returns (uint256 p, uint256 u) {
            return (p, u);
        } catch {
            revert OracleCallFailed();
        }
    }

    /// @dev Checks oracle price freshness
    function _checkOracleFreshness(uint256 updatedAt) internal view {
        if (block.timestamp - updatedAt > oracleStaleThreshold) {
            revert OraclePriceStale(updatedAt, oracleStaleThreshold);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Register a pool as a LuxeBridge pool, associating it with a luxury token
    /// @param key The Uniswap V4 pool key
    /// @param luxuryToken The ERC-20 diamond/luxury token in the pool
    function registerPool(PoolKey calldata key, address luxuryToken) external onlyOwner {
        if (luxuryToken == address(0)) revert ZeroAddress();
        PoolId poolId = key.toId();
        poolLuxuryToken[poolId] = luxuryToken;
        poolActive[poolId] = true;
        emit PoolRegistered(poolId, luxuryToken);
    }

    /// @notice Reset a circuit-broken pool back to active (after manual review)
    /// @param key The pool key to reset
    function resetCircuitBreaker(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        poolActive[poolId] = true;
    }

    /// @notice Update the oracle address
    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        emit OracleUpdated(address(oracle), newOracle);
        oracle = ILuxeOracle(newOracle);
    }

    /// @notice Update the maximum allowed price deviation in basis points
    function setMaxDeviationBps(uint256 newDeviationBps) external onlyOwner {
        if (newDeviationBps == 0 || newDeviationBps > BPS_DENOMINATOR) revert InvalidDeviationLimit();
        emit DeviationLimitUpdated(maxDeviationBps, newDeviationBps);
        maxDeviationBps = newDeviationBps;
    }

    /// @notice Update the oracle staleness threshold
    function setOracleStaleThreshold(uint256 newThreshold) external onlyOwner {
        emit OracleStaleThresholdUpdated(oracleStaleThreshold, newThreshold);
        oracleStaleThreshold = newThreshold;
    }

    // ────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Returns whether a pool is registered and active
    function isPoolActive(PoolKey calldata key) external view returns (bool registered, bool active) {
        PoolId poolId = key.toId();
        registered = poolLuxuryToken[poolId] != address(0);
        active = poolActive[poolId];
    }

    /// @notice Returns the current oracle price for a pool's luxury token
    function getPoolOraclePrice(PoolKey calldata key) external view returns (uint256 price, uint256 updatedAt) {
        PoolId poolId = key.toId();
        address luxuryToken = poolLuxuryToken[poolId];
        if (luxuryToken == address(0)) revert PoolNotRegistered(poolId);
        return oracle.getPrice(luxuryToken);
    }
}

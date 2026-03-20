// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LuxeBridgeHook} from "../src/LuxeBridgeHook.sol";
import {DiamondToken} from "../src/DiamondToken.sol";
import {MockLuxeOracle} from "../src/MockLuxeOracle.sol";

/// @title DeployLuxeBridge
/// @notice Deployment script for local Anvil testing
/// @dev Run with: forge script script/DeployLuxeBridge.s.sol --rpc-url http://localhost:8545 --broadcast
contract DeployLuxeBridge is Script {
    // ─── Config ──────────────────────────────────────────────────────────────

    // Uniswap V4 PoolManager address on Unichain Sepolia
    // For local Anvil: deployed by Deployers.sol in tests
    // Update this to the correct address for your target network
    address constant POOL_MANAGER_UNICHAIN_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POOL_MANAGER_ETH_SEPOLIA = 0xe8E23e97Fa135823143d6b9Cba9c699040D51F70;

    uint256 constant MAX_DEVIATION_BPS = 500; // 5%
    uint256 constant ORACLE_STALE_THRESHOLD = 1 hours;
    uint256 constant DIAMOND_INITIAL_PRICE_USD = 10_000e18; // $10,000

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== LuxeBridge Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Deploy Oracle ────────────────────────────────────────────
        MockLuxeOracle oracle = new MockLuxeOracle();
        console2.log("Oracle deployed:", address(oracle));

        // ── Step 2: Deploy Diamond Token ─────────────────────────────────────
        DiamondToken diamond = new DiamondToken(
            "GIA Diamond Round 1ct",
            "DIAM",
            "GIA-2465783910",
            10000,   // 1.0000 carats
            deployer // certifier = deployer for testing
        );
        console2.log("DiamondToken deployed:", address(diamond));

        // Certify the diamond
        diamond.certify();
        console2.log("Diamond certified");

        // Mint initial supply
        diamond.mint(deployer, 10_000_000e6); // 10M tokens
        console2.log("Minted 10M diamond tokens to deployer");

        // Set oracle price
        oracle.setPrice(address(diamond), DIAMOND_INITIAL_PRICE_USD, true);
        console2.log("Oracle price set: $10,000 per DIAM token");

        // ── Step 3: Mine Hook Address ─────────────────────────────────────────
        address poolManager = POOL_MANAGER_UNICHAIN_SEPOLIA;
        if (block.chainid == 11155111) {
            poolManager = POOL_MANAGER_ETH_SEPOLIA;
        }

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        console2.log("Mining hook address (this may take a moment)...");

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer, // deployer is the CREATE2 factory in script context
            flags,
            type(LuxeBridgeHook).creationCode,
            abi.encode(
                poolManager,
                address(oracle),
                MAX_DEVIATION_BPS,
                ORACLE_STALE_THRESHOLD
            )
        );

        console2.log("Hook address mined:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // ── Step 4: Deploy Hook ───────────────────────────────────────────────
        LuxeBridgeHook hook = new LuxeBridgeHook{salt: salt}(
            IPoolManager(poolManager),
            address(oracle),
            MAX_DEVIATION_BPS,
            ORACLE_STALE_THRESHOLD
        );

        require(address(hook) == hookAddress, "Hook address mismatch — re-run HookMiner");
        console2.log("LuxeBridgeHook deployed:", address(hook));

        // ── Step 5: Create Pool Key & Register ───────────────────────────────
        // ETH / DIAM pool (ETH = Currency.wrap(address(0)))
        bool diamondIsToken0 = address(diamond) < address(0);
        PoolKey memory poolKey = PoolKey({
            currency0: diamondIsToken0
                ? Currency.wrap(address(diamond))
                : CurrencyLibrary.ADDRESS_ZERO,
            currency1: diamondIsToken0
                ? CurrencyLibrary.ADDRESS_ZERO
                : Currency.wrap(address(diamond)),
            fee: 3000,     // 0.3%
            tickSpacing: 60,
            hooks: hook
        });

        hook.registerPool(poolKey, address(diamond));
        console2.log("Pool registered with hook");

        // ── Step 6: Initialize Pool ───────────────────────────────────────────
        // Diamond $10,000 / ETH $3,000 = 3.333 ETH per DIAM
        // sqrtPrice = sqrt(3.333) * 2^96
        uint160 sqrtPriceX96 = 144563940740534073360;
        IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);
        console2.log("Pool initialized");

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("\n=== Deployment Summary ===");
        console2.log("Oracle:           ", address(oracle));
        console2.log("DiamondToken:     ", address(diamond));
        console2.log("LuxeBridgeHook:   ", address(hook));
        console2.log("PoolManager:      ", poolManager);
        console2.log("Pool fee:          0.3%");
        console2.log("Max deviation:     5%");
        console2.log("Oracle freshness:  1 hour");
        console2.log("\nNext steps:");
        console2.log("1. Add liquidity via the Uniswap V4 position manager");
        console2.log("2. Interact with the pool at the above hook address");
        console2.log("3. Monitor oracle prices and circuit breaker status");
    }
}

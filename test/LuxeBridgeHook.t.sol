// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LuxeBridgeHook} from "../src/LuxeBridgeHook.sol";
import {DiamondToken} from "../src/DiamondToken.sol";
import {MockLuxeOracle} from "../src/MockLuxeOracle.sol";


contract LuxeBridgeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;


    LuxeBridgeHook hook;
    MockLuxeOracle oracle;
    DiamondToken diamond;


    uint256 constant DIAMOND_PRICE_USD = 10_000e18;

    uint256 constant MAX_DEVIATION_BPS = 500;

    uint256 constant ORACLE_STALE_THRESHOLD = 1 hours;

    uint256 constant ETH_PRICE_USD = 3000;

  
    PoolKey poolKey;

   
    function setUp() public {
        deployFreshManagerAndRouters();

        oracle = new MockLuxeOracle();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LuxeBridgeHook).creationCode,
            abi.encode(
                address(manager),
                address(oracle),
                MAX_DEVIATION_BPS,
                ORACLE_STALE_THRESHOLD
            )
        );

        hook = new LuxeBridgeHook{salt: salt}(
            IPoolManager(address(manager)),
            address(oracle),
            MAX_DEVIATION_BPS,
            ORACLE_STALE_THRESHOLD
        );

        require(address(hook) == hookAddress, "Hook address mismatch");

        diamond = new DiamondToken(
            "GIA Diamond Round 1ct",
            "DIAM",
            "GIA-2465783910",
            10000, // 1.0000 carats (scaled by 1e4)
            address(this)
        );

        diamond.certify();

        oracle.setPrice(address(diamond), DIAMOND_PRICE_USD, true);

        diamond.mint(address(this), 1_000_000e6); // 1M diamond tokens

        (Currency currency0, Currency currency1) = address(diamond) < address(0)
            ? (Currency.wrap(address(diamond)), CurrencyLibrary.ADDRESS_ZERO)
            : (CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(diamond)));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: hook
        });

        hook.registerPool(poolKey, address(diamond));

             uint160 sqrtPriceX96 = 144563940740534073360;
        manager.initialize(poolKey, sqrtPriceX96);

        diamond.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

  
    function test_PoolRegistered() public view {
        (bool registered, bool active) = hook.isPoolActive(poolKey);
        assertTrue(registered, "Pool should be registered");
        assertTrue(active, "Pool should be active");
    }

    function test_AddLiquidity_Success() public {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_Swap_Success() public {
        // Add liquidity first
        test_AddLiquidity_Success();

        // Perform swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6, // exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function test_OraclePrice() public view {
        (uint256 price, uint256 updatedAt) = hook.getPoolOraclePrice(poolKey);
        assertEq(price, DIAMOND_PRICE_USD, "Oracle price mismatch");
        assertGt(updatedAt, 0, "Oracle timestamp should be set");
    }

       function test_Revert_TokenNotCertified_OnSwap() public {
        oracle.setCertified(address(diamond), false);

      
        vm.expectRevert(
            abi.encodeWithSelector(
                LuxeBridgeHook.TokenNotCertified.selector,
                address(diamond)
            )
        );
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_Revert_TokenNotCertified_OnAddLiquidity() public {
        oracle.setCertified(address(diamond), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                LuxeBridgeHook.TokenNotCertified.selector,
                address(diamond)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_Revert_StaleOracle_OnSwap() public {
        // Warp time forward past stale threshold
        vm.warp(block.timestamp + ORACLE_STALE_THRESHOLD + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LuxeBridgeHook.OraclePriceStale.selector,
                block.timestamp - ORACLE_STALE_THRESHOLD - 1,
                ORACLE_STALE_THRESHOLD
            )
        );
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_Revert_UnregisteredPool() public {
        PoolKey memory unregisteredKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(diamond)),
            fee: 10000,
            tickSpacing: 200,
            hooks: hook
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                LuxeBridgeHook.PoolNotRegistered.selector,
                unregisteredKey.toId()
            )
        );
        swapRouter.swap(
            unregisteredKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

  
    function test_CircuitBreaker_TriggeredOnLargeDeviation() public {
           oracle.setPrice(address(diamond), DIAMOND_PRICE_USD * 100, true);

        vm.expectRevert(); // PriceDeviationTooHigh
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, bool active) = hook.isPoolActive(poolKey);
        assertFalse(active, "Pool should be circuit-broken");
    }

    function test_CircuitBreaker_Reset() public {
        oracle.setPrice(address(diamond), DIAMOND_PRICE_USD * 100, true);
        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}

        (, bool active) = hook.isPoolActive(poolKey);
        assertFalse(active, "Should be broken");

        // Reset by owner
        hook.resetCircuitBreaker(poolKey);
        (, active) = hook.isPoolActive(poolKey);
        assertTrue(active, "Should be active again");
    }

 
    function test_SetMaxDeviation() public {
        hook.setMaxDeviationBps(1000); // 10%
        assertEq(hook.maxDeviationBps(), 1000);
    }

    function test_SetOracle() public {
        MockLuxeOracle newOracle = new MockLuxeOracle();
        hook.setOracle(address(newOracle));
        assertEq(address(hook.oracle()), address(newOracle));
    }

    function test_Revert_SetOracle_ZeroAddress() public {
        vm.expectRevert(LuxeBridgeHook.ZeroAddress.selector);
        hook.setOracle(address(0));
    }

    function test_Revert_NonOwner_RegisterPool() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.registerPool(poolKey, address(diamond));
    }

    function test_Revert_InvalidDeviation() public {
        vm.expectRevert(LuxeBridgeHook.InvalidDeviationLimit.selector);
        hook.setMaxDeviationBps(0);

        vm.expectRevert(LuxeBridgeHook.InvalidDeviationLimit.selector);
        hook.setMaxDeviationBps(10_001);
    }

    function test_DiamondToken_Metadata() public view {
        assertEq(diamond.decimals(), 6);
        assertEq(diamond.certificateId(), "GIA-2465783910");
        assertEq(diamond.caratWeight(), 10000);
        assertTrue(diamond.certified());
    }

    function test_DiamondToken_MintBurn() public {
        uint256 initialBalance = diamond.balanceOf(address(this));
        diamond.mint(address(this), 1000e6);
        assertEq(diamond.balanceOf(address(this)), initialBalance + 1000e6);

        diamond.burn(address(this), 1000e6);
        assertEq(diamond.balanceOf(address(this)), initialBalance);
    }

    function test_DiamondToken_CertificationRevoke() public {
        assertTrue(diamond.certified());
        diamond.revokeCertification();
        assertFalse(diamond.certified());
    }
}

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LeanSwap} from "../src/LeanSwap.sol";
import {LeanSwapRouter} from "../src/LeanSwapRouter.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-hooks-public/src/utils/HookMiner.sol";
import {TestnetToken} from "../src/TestnetToken.sol";
import {Faucet} from "../src/Faucet.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPermit2} from "v4-hooks-public/lib/briefcase/src/protocols/permit2/interfaces/IPermit2.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta);
}

contract DeployTestnet is Script {
    IPoolManager manager;
    IPermit2 permit2;
    IPoolModifyLiquidityTest modifyLiquidityRouter;

    function encodePriceSqrt(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        require(amount0 > 0 && amount1 > 0, "amounts must be > 0");

        // Compute ratio in Q96 fixed point: (amount1 << 96) / amount0
        uint256 ratioX96 = (amount1 << 96) / amount0;

        // Integer square root of ratioX96, then shift left 48 to reach Q96
        sqrtPriceX96 = uint160(sqrt(ratioX96) << 48);

        // Clamp to Uniswap V4 valid range
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        }
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        }
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function setupPool(
        address tokenA,
        uint256 reserveA,
        address tokenB,
        uint256 reserveB,
        address hookAddress,
        int256 liquidityDelta
    ) internal returns (PoolKey memory key) {
        (address token0, address token1, uint256 reserve0, uint256 reserve1) = tokenA < tokenB
            ? (tokenA, tokenB, reserveA, reserveB)
            : (tokenB, tokenA, reserveB, reserveA);

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        uint160 sqrtPriceX96 = encodePriceSqrt(reserve1, reserve0);
        manager.initialize(key, sqrtPriceX96);

        // Mint lots of tokens to deployer to provide liquidity easily
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        TestnetToken(token0).mint(deployer, reserve0 * 1000);
        TestnetToken(token1).mint(deployer, reserve1 * 1000);

        TestnetToken(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestnetToken(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60000,
                tickUpper: 60000, // Very wide range for testnet
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        console.log("Pool initialized for", TestnetToken(token0).symbol(), "/", TestnetToken(token1).symbol());
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        address poolModifyLiquidityTest = address(0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB);
        address create2Deployer = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        address permit2Address = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        manager = IPoolManager(poolManager);
        modifyLiquidityRouter = IPoolModifyLiquidityTest(poolModifyLiquidityTest);
        permit2 = IPermit2(permit2Address);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Tokens
        TestnetToken tUSDC = new TestnetToken("Test USDC", "tUSDC", 6);
        TestnetToken tDAI = new TestnetToken("Test DAI", "tDAI", 18);
        TestnetToken tLEAN = new TestnetToken("Test LEAN", "tLEAN", 18);
        TestnetToken tETH = new TestnetToken("Test ETH", "tETH", 18);
        TestnetToken tCOW = new TestnetToken("Test COW", "tCOW", 18);

        console.log("--- Tokens Deployed ---");
        console.log("tUSDC:", address(tUSDC));
        console.log("tDAI:", address(tDAI));
        console.log("tLEAN:", address(tLEAN));
        console.log("tETH:", address(tETH));
        console.log("tCOW:", address(tCOW));

        // 2. Deploy Faucet
        Faucet faucet = new Faucet(address(tUSDC), address(tDAI), address(tLEAN), address(tETH), address(tCOW));
        console.log("Faucet deployed at:", address(faucet));

        tUSDC.setFaucet(address(faucet));
        tDAI.setFaucet(address(faucet));
        tLEAN.setFaucet(address(faucet));
        tETH.setFaucet(address(faucet));
        tCOW.setFaucet(address(faucet));

        faucet.initializeMints();

        LeanSwapRouter router = new LeanSwapRouter(manager, permit2);
        console.log("Router deployed at:", address(router));
        // 3. Deploy LeanSwap Hook
        // Note: For actual react network it expects an address, using reactiveSystemContract if available
        address reactiveSystemContract = address(0x0000000000000000000000000000000000fffFfF);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, reactiveSystemContract, vm.addr(deployerPrivateKey)); // Pass deployer as owner

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(LeanSwap).creationCode, constructorArgs);

        LeanSwap leanSwap = new LeanSwap{salt: salt}(IPoolManager(poolManager), reactiveSystemContract, vm.addr(deployerPrivateKey));
        require(address(leanSwap) == hookAddress, "Hook address mismatch");
        console.log("LeanSwap Hook deployed at:", hookAddress);
        // 4. Initialize Pools
        // Ratios:
        // 1 tETH = 2000 tUSDC => (1e18, 2000e6)
        setupPool(address(tETH), 1e18, address(tUSDC), 2000e6, hookAddress, 1e14);

        // 1 tETH = 2000 tDAI => (1e18, 2000e18)
        setupPool(address(tETH), 1e18, address(tDAI), 2000e18, hookAddress, 4e19);

        // 1 tUSDC = 1 tDAI => (1e6, 1e18)
        setupPool(address(tUSDC), 1e6, address(tDAI), 1e18, hookAddress, 1e12);

        // 1 tCOW = 100 tLEAN => (1e18, 100e18)
        setupPool(address(tCOW), 1e18, address(tLEAN), 100e18, hookAddress, 1e19);

        // 1 tUSDC = 20 tCOW => (1e6, 20e18)
        setupPool(address(tUSDC), 1e6, address(tCOW), 20e18, hookAddress, 4e12);

        vm.stopBroadcast();
    }
}

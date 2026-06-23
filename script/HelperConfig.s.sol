// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

/**
 * @title HelperConfig
 * @notice Supplies network-specific addresses (collateral tokens + their price feeds) so the
 *         deploy script is identical across local anvil and the Sepolia testnet.
 * @dev On a chain we don't recognise (i.e. anvil), it deploys fresh mocks so everything works
 *      out of the box with no external dependencies. On Sepolia it returns the real Chainlink
 *      feed addresses. No private keys live here — signing is handled by Foundry's keystore
 *      (`--account`) at the CLI, which keeps secrets out of the repo.
 */
contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
    }

    /// @dev Mock feed config: Chainlink USD feeds use 8 decimals.
    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8; // $2,000 per ETH
    int256 public constant BTC_USD_PRICE = 1000e8; // $1,000 per BTC
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    /**
     * @notice Real Chainlink feeds on Sepolia. The wETH/wBTC token addresses are existing
     *         Sepolia test tokens; swap in your own if these ever change (see README).
     */
    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH/USD
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, // BTC/USD
            weth: 0xDd13e55209FD76Afceb3Ec76A0C8c40dc15f1C9b,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063
        });
    }

    /**
     * @notice Deploy mocks the first time we're asked for an anvil config, then cache them.
     * @dev Wrapped in a broadcast so the mocks are actually sent as transactions when this runs
     *      against a live anvil node. The cache check makes repeat calls within one run free.
     */
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // Already initialised? Return the cached config (a real feed address is our sentinel).
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, 1000e8);

        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wbtcMock = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, 1000e8);
        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock)
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

/**
 * @title InvariantsTest
 * @notice Stateful (invariant) tests. The runner fires long random sequences of Handler actions
 *         and, after each, asserts our core safety property still holds.
 *
 * THE invariant: the protocol must always custody more USD value of collateral than the total
 * supply of DSC. If this ever breaks, DSC is no longer fully backed.
 */
contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc) = config.activeNetworkConfig();

        // Route fuzzing through the bounded Handler rather than calling the engine directly.
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    /// @notice Collateral USD value held by the engine >= total DSC minted, always.
    function invariant_protocolMustHaveMoreCollateralValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assertGe(wethValue + wbtcValue, totalSupply);
    }

    /// @notice Pure/view getters must never revert — a cheap sanity invariant.
    function invariant_gettersCantRevert() public view {
        engine.getLiquidationBonus();
        engine.getLiquidationThreshold();
        engine.getLiquidationPrecision();
        engine.getMinHealthFactor();
        engine.getPrecision();
        engine.getAdditionalFeedPrecision();
        engine.getCollateralTokens();
    }
}

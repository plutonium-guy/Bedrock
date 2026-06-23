// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/**
 * @title DSCEngineFuzz
 * @notice Stateless (property) fuzz tests over deposit / mint / redeem amounts. Each runs many
 *         random inputs (foundry.toml fuzz.runs) to flush out edge cases the example-based unit
 *         tests might miss.
 */
contract DSCEngineFuzz is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;

    address USER = makeAddr("fuzzUser");
    uint256 constant MAX_DEPOSIT = type(uint96).max;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth,) = config.activeNetworkConfig();
    }

    /// @notice Any positive deposit is recorded exactly and reflected in USD value.
    function testFuzz_DepositCollateralRecordsBalance(uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT);
        ERC20Mock(weth).mint(USER, amountCollateral);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        assertEq(engine.getCollateralBalanceOfUser(USER, weth), amountCollateral);
        // USD value round-trips back to the deposited token amount.
        uint256 usdValue = engine.getUsdValue(weth, amountCollateral);
        assertEq(engine.getTokenAmountFromUsd(weth, usdValue), amountCollateral);
    }

    /// @notice Minting at or below the 50% cap always succeeds and keeps HF >= 1.
    function testFuzz_MintWithinCapStaysHealthy(uint256 amountCollateral, uint256 amountToMint) public {
        amountCollateral = bound(amountCollateral, 1 ether, 1000 ether);
        ERC20Mock(weth).mint(USER, amountCollateral);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);

        uint256 collateralValueUsd = engine.getUsdValue(weth, amountCollateral);
        uint256 maxMint = collateralValueUsd / 2; // 50% LTV
        amountToMint = bound(amountToMint, 1, maxMint);
        engine.mintDsc(amountToMint);
        vm.stopPrank();

        assertEq(dsc.balanceOf(USER), amountToMint);
        assertGe(engine.getHealthFactor(USER), engine.getMinHealthFactor());
    }

    /// @notice Minting strictly above the 50% cap always reverts (never under-collateralized).
    function testFuzz_MintAboveCapReverts(uint256 amountToMint) public {
        uint256 amountCollateral = 10 ether; // $20,000
        ERC20Mock(weth).mint(USER, amountCollateral);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);

        uint256 maxMint = engine.getUsdValue(weth, amountCollateral) / 2; // $10,000
        amountToMint = bound(amountToMint, maxMint + 1, maxMint * 100);
        vm.expectRevert(); // DSCEngine__BreaksHealthFactor with the resulting HF
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    /// @notice Depositing then redeeming the same amount (no debt) returns the collateral fully.
    function testFuzz_DepositThenRedeemIsNeutral(uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT);
        ERC20Mock(weth).mint(USER, amountCollateral);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();

        assertEq(engine.getCollateralBalanceOfUser(USER, weth), 0);
        assertEq(ERC20Mock(weth).balanceOf(USER), amountCollateral);
    }
}

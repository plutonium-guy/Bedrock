// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @title DSCEngineTest
 * @notice Full unit coverage for the engine: deposit, mint, redeem, burn, pricing, health
 *         factor, every revert path, the price-crash liquidation scenario, and stale oracles.
 *
 * Baseline prices come from HelperConfig's mocks: ETH = $2,000, BTC = $1,000 (8-decimal feeds).
 */
contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // $20,000 at $2,000/ETH
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100 ether; // well within the cap

    // Used to construct an engine with mismatched arrays in the constructor test.
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc) = config.activeNetworkConfig();

        // Fund USER with some wETH to deposit.
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed); // one extra -> mismatch

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function test_CollateralTokensRegistered() public view {
        address[] memory tokens = engine.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(engine.getCollateralTokenPriceFeed(weth), ethUsdPriceFeed);
        assertEq(engine.getDsc(), address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                                PRICING
    //////////////////////////////////////////////////////////////*/

    function test_GetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15 ETH * $2,000 = $30,000
        uint256 expectedUsd = 30_000e18;
        assertEq(engine.getUsdValue(weth, ethAmount), expectedUsd);
    }

    function test_GetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether; // $100
        // $100 / $2,000 per ETH = 0.05 ETH
        uint256 expectedWeth = 0.05 ether;
        assertEq(engine.getTokenAmountFromUsd(weth, usdAmount), expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_RevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_RevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("Random", "RAN", USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), 100e18);
        vm.stopPrank();
    }

    function test_CanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
        assertEq(engine.getCollateralBalanceOfUser(USER, weth), AMOUNT_COLLATERAL);
    }

    function test_CanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        // collateralValueInUsd should convert back to exactly the deposited amount.
        assertEq(engine.getTokenAmountFromUsd(weth, collateralValueInUsd), AMOUNT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                                MINT DSC
    //////////////////////////////////////////////////////////////*/

    function test_RevertsIfMintAmountIsZero() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
    }

    function test_CanMintDsc() public depositedCollateral {
        vm.prank(USER);
        engine.mintDsc(AMOUNT_DSC_TO_MINT);
        assertEq(dsc.balanceOf(USER), AMOUNT_DSC_TO_MINT);
    }

    function test_RevertsIfMintBreaksHealthFactor() public depositedCollateral {
        // $20,000 collateral, try to mint $20,000 DSC -> HF = (20000*0.5)/20000 = 0.5
        uint256 amountToMint = 20_000 ether;
        uint256 expectedHealthFactor = 0.5 ether; // 5e17
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
    }

    function test_CanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), AMOUNT_DSC_TO_MINT);
        assertEq(engine.getCollateralBalanceOfUser(USER, weth), AMOUNT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                                BURN DSC
    //////////////////////////////////////////////////////////////*/

    modifier depositedAndMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function test_RevertsIfBurnAmountIsZero() public depositedAndMinted {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
    }

    function test_CantBurnMoreThanUserHas() public {
        // USER has no DSC; the debt-decrement underflows (arithmetic panic).
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function test_CanBurnDsc() public depositedAndMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.burnDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), 0);
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            REDEEM COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_RevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
    }

    function test_CanRedeemCollateral() public depositedCollateral {
        vm.prank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_USER_BALANCE);
        assertEq(engine.getCollateralBalanceOfUser(USER, weth), 0);
    }

    function test_RevertsIfRedeemBreaksHealthFactor() public depositedAndMinted {
        // Pulling ALL collateral while debt remains => HF collapses to 0.
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    function test_CanRedeemCollateralForDsc() public depositedAndMinted {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), 0);
        assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                             HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    function test_ProperlyReportsHealthFactor() public depositedAndMinted {
        // $20,000 collateral, $100 debt => HF = (20000 * 0.5) / 100 = 100
        uint256 expectedHealthFactor = 100 ether;
        assertEq(engine.getHealthFactor(USER), expectedHealthFactor);
    }

    function test_HealthFactorIsMaxWithNoDebt() public depositedCollateral {
        assertEq(engine.getHealthFactor(USER), type(uint256).max);
    }

    function test_HealthFactorCanGoBelowOne() public depositedAndMinted {
        // Crash ETH to $1 so $10 of collateral backs $100 of debt.
        int256 ethUsdUpdatedPrice = 1e8; // $1
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        assertLt(engine.getHealthFactor(USER), engine.getMinHealthFactor());
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertsLiquidationIfHealthFactorOk() public depositedAndMinted {
        // Give the liquidator some DSC to attempt with.
        ERC20Mock(weth).mint(LIQUIDATOR, 100 ether);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), 100 ether);
        engine.depositCollateralAndMintDsc(weth, 100 ether, AMOUNT_DSC_TO_MINT);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    /**
     * @notice The headline scenario: a healthy position becomes unsafe after a price drop,
     *         a liquidator repays its debt for a discounted chunk of collateral, profits,
     *         and the protocol stays fully backed throughout.
     */
    function test_CrashScenario_LiquidationProfitsAndKeepsSolvency() public {
        // 1. USER opens a safe position at $2,000/ETH: $20,000 collateral, $8,000 debt (HF 1.25).
        uint256 userCollateral = 10 ether;
        uint256 userDebt = 8_000 ether;
        ERC20Mock(weth).mint(USER, userCollateral);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), userCollateral);
        engine.depositCollateralAndMintDsc(weth, userCollateral, userDebt);
        vm.stopPrank();
        assertGe(engine.getHealthFactor(USER), engine.getMinHealthFactor());

        // 2. Market crash: ETH $2,000 -> $1,400. Collateral now $14,000, HF = 7,000/8,000 = 0.875.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1_400e8);
        assertLt(engine.getHealthFactor(USER), engine.getMinHealthFactor());

        // 3. LIQUIDATOR opens a safe position and repays USER's full debt.
        uint256 liqCollateral = 20 ether; // $28,000 at $1,400 -> HF 1.75 after minting userDebt
        ERC20Mock(weth).mint(LIQUIDATOR, liqCollateral);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), liqCollateral);
        engine.depositCollateralAndMintDsc(weth, liqCollateral, userDebt);
        dsc.approve(address(engine), userDebt);
        engine.liquidate(weth, USER, userDebt);
        vm.stopPrank();

        // 4. USER's debt is wiped and the position is healthy again.
        (uint256 userDscAfter,) = engine.getAccountInformation(USER);
        assertEq(userDscAfter, 0);
        assertEq(engine.getHealthFactor(USER), type(uint256).max);

        // 5. Liquidator received the debt-equivalent collateral PLUS the 10% bonus.
        uint256 expectedSeized = engine.getTokenAmountFromUsd(weth, userDebt);
        expectedSeized += (expectedSeized * engine.getLiquidationBonus()) / engine.getLiquidationPrecision();
        assertEq(ERC20Mock(weth).balanceOf(LIQUIDATOR), expectedSeized);

        // 6. ...and that collateral is worth strictly more than the debt repaid: real profit.
        assertGt(engine.getUsdValue(weth, expectedSeized), userDebt);

        // 7. Protocol solvency: USD value of collateral held by the engine >= total DSC supply.
        assertGe(_engineCollateralUsd(), dsc.totalSupply());
    }

    /*//////////////////////////////////////////////////////////////
                              STALE ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_GetUsdValueRevertsOnStalePrice() public {
        // No feed update for longer than OracleLib.TIMEOUT (3h) => stale => revert.
        vm.warp(block.timestamp + 3 hours + 1);
        vm.roll(block.number + 1);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        engine.getUsdValue(weth, 1 ether);
    }

    function test_StalePriceWhenRoundIncomplete() public {
        // An incomplete round reports updatedAt == 0, which OracleLib treats as stale.
        MockV3Aggregator(ethUsdPriceFeed).updateRoundData(1, 2_000e8, 0, 0);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        engine.getUsdValue(weth, 1 ether);
    }

    function test_OracleTimeoutIsThreeHours() public pure {
        assertEq(OracleLib.getTimeout(), 3 hours);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW GETTERS / PURE MATH
    //////////////////////////////////////////////////////////////*/

    function test_Getters() public view {
        assertEq(engine.getLiquidationThreshold(), 50);
        assertEq(engine.getLiquidationBonus(), 10);
        assertEq(engine.getLiquidationPrecision(), 100);
        assertEq(engine.getMinHealthFactor(), 1e18);
        assertEq(engine.getPrecision(), 1e18);
        assertEq(engine.getAdditionalFeedPrecision(), 1e10);
    }

    function test_CalculateHealthFactor() public view {
        // No debt => infinitely safe.
        assertEq(engine.calculateHealthFactor(0, 1_000e18), type(uint256).max);
        // $20,000 collateral, $100 debt => HF = (20000 * 0.5) / 100 = 100.
        assertEq(engine.calculateHealthFactor(100e18, 20_000e18), 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Total USD value of all collateral the engine custodies (its token balances).
    function _engineCollateralUsd() internal view returns (uint256 total) {
        address[] memory tokens = engine.getCollateralTokens();
        for (uint256 i; i < tokens.length; i++) {
            total += engine.getUsdValue(tokens[i], ERC20Mock(tokens[i]).balanceOf(address(engine)));
        }
    }
}

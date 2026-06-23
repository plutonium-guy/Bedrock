// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @title Handler
 * @notice Bounded action driver for the invariant campaign. Instead of letting the fuzzer call
 *         the engine with totally random (and mostly-reverting) inputs, the invariant runner
 *         calls THIS contract, which constrains each action to sensible ranges. That makes the
 *         random call sequences actually exercise the protocol (deposit -> mint -> redeem) rather
 *         than bouncing off input validation.
 *
 * @dev Prices are held constant here; the invariant we protect (collateral value >= DSC supply)
 *      should hold purely from the 50% mint cap, independent of price moves.
 */
contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    // Cap a single deposit so cumulative balances can never overflow the USD-value math.
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    // Users who currently hold collateral — mintDsc only targets these so it isn't a guaranteed revert.
    address[] public usersWithCollateralDeposited;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    /// @notice Deposit a bounded amount of one of the two collateral tokens as `msg.sender`.
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral); // free mint on a test token
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender); // duplicates are harmless
    }

    /// @notice Redeem up to the caller's current balance of a collateral token.
    /// @dev If they have outstanding debt this may revert (health factor); with
    ///      fail_on_revert=false the runner simply skips those, which is fine.
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) return;
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    /// @notice Mint DSC for a depositor, bounded by their remaining mintable headroom (50% LTV).
    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) return;
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        // Max additional DSC = half the collateral USD value minus what's already minted.
        // Casts are safe: deposits are bounded by uint96 in this handler, so these values are
        // far below int256.max, and the uint256 cast below is reached only when maxDscToMint > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = bound(amount, 1, uint256(maxDscToMint));

        vm.prank(sender);
        engine.mintDsc(amount);
    }

    function _getCollateralFromSeed(uint256 seed) private view returns (ERC20Mock) {
        return seed % 2 == 0 ? weth : wbtc;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author my_coin
 * @notice The heart of the system. A minimal CDP / Vault engine, loosely modelled on MakerDAO's
 *         DAI but stripped to its essence (no governance, no stability fee, no DSR).
 *
 * The system is designed so 1 DSC == $1 and is always **overcollateralized**: at no point should
 * the USD value of all collateral be less than the USD value of all minted DSC.
 *
 * Mechanism summary:
 *  - Users deposit approved collateral (wETH / wBTC) and mint DSC against it.
 *  - A Chainlink feed prices collateral in USD.
 *  - A "health factor" (HF) measures position safety. HF >= 1 is safe; HF < 1 is liquidatable.
 *  - The 50% liquidation threshold means you can mint at most $1 of DSC per $2 of collateral
 *    (i.e. 200% collateralization).
 *  - If a position falls below HF 1, anyone may liquidate it: repay its DSC debt and seize its
 *    collateral plus a 10% bonus — the incentive that keeps the system solvent.
 *
 * @dev Security posture: ReentrancyGuard on state-changing external calls, checks-effects-
 *      interactions ordering, SafeERC20 for transfers, and OracleLib for stale-price protection.
 */
contract DSCEngine is ReentrancyGuard {
    using OracleLib for AggregatorV3Interface;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                            STATE / CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Chainlink USD feeds return 8 decimals; multiply by 1e10 to reach our 18-decimal math.
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    /// @dev Standard 18-decimal fixed-point unit used throughout.
    uint256 private constant PRECISION = 1e18;
    /// @dev 50 => only 50% of collateral USD value counts toward backing debt (200% collateral).
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    /// @dev Denominator for the threshold/bonus percentages.
    uint256 private constant LIQUIDATION_PRECISION = 100;
    /// @dev 10 => liquidators receive a 10% bonus on seized collateral.
    uint256 private constant LIQUIDATION_BONUS = 10;
    /// @dev HF below this (1e18 == "1.0") is liquidatable.
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    /// @dev token => its Chainlink USD price feed. A non-zero entry also marks a token as "allowed".
    mapping(address token => address priceFeed) private s_priceFeeds;
    /// @dev user => token => amount of that collateral they have deposited.
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    /// @dev user => amount of DSC they have minted (their debt).
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    /// @dev List of every allowed collateral token, so we can iterate when valuing an account.
    address[] private s_collateralTokens;

    /// @dev The DSC token. Immutable — the engine is its owner and sole minter/burner.
    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        // A token is allowed iff we registered a price feed for it in the constructor.
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param tokenAddresses     Allowed collateral tokens (e.g. [wETH, wBTC]).
     * @param priceFeedAddresses Chainlink USD feeds, index-aligned with `tokenAddresses`.
     * @param dscAddress         The deployed DSC token this engine controls.
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // Each collateral token must have exactly one matching price feed.
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL — DEPOSIT / MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit collateral and mint DSC in a single transaction (the common path).
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Deposit `amountCollateral` of an approved token as backing.
     * @dev CEI: we update internal accounting (effect) before pulling tokens (interaction).
     *      The pull uses SafeERC20 and requires the caller to have approved this engine.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
    }

    /**
     * @notice Mint `amountDscToMint` DSC against already-deposited collateral.
     * @dev We record the new debt first, then assert the resulting health factor is still safe,
     *      then actually mint. If the HF check reverts, the whole tx (including the debt write)
     *      is rolled back, so we can never leave the user under-collateralized.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL — REDEEM / BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burn DSC and redeem collateral in one transaction (unwind a position).
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        // Burn first so the redeem's health-factor check sees the reduced debt.
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice Withdraw `amountCollateral`, provided the position stays healthy afterward.
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Repay/burn `amount` of your own DSC debt.
     * @dev The trailing HF check can essentially never revert (burning debt only improves HF),
     *      but it is cheap insurance and keeps every debt-changing path uniform.
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Liquidate an unsafe position: repay some/all of `user`'s DSC debt and seize the
     *         equivalent collateral plus a 10% bonus.
     * @param collateral  The collateral token to seize.
     * @param user        The under-collateralized borrower (HF < 1).
     * @param debtToCover Amount of the user's DSC debt to repay (in DSC, 1e18).
     *
     * @dev Flow:
     *      1. Confirm the user is actually liquidatable.
     *      2. Convert the DSC debt to a collateral amount, add the 10% bonus.
     *      3. Move that collateral from the user to the liquidator (msg.sender).
     *      4. Burn `debtToCover` DSC pulled from the liquidator, reducing the user's debt.
     *      5. Require the user's HF improved (else the liquidation was pointless/harmful).
     *      6. Make sure the liquidator didn't wreck their own HF in the process.
     *      The bonus is what makes liquidating profitable, which is what keeps the protocol solvent.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // How much collateral is `debtToCover` worth, plus the liquidation bonus.
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        // A liquidator must not push themselves underwater to liquidate someone else.
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                      PRIVATE / INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Low-level collateral move used by both `redeemCollateral` and `liquidate`.
     *      Decrements `from`'s balance (reverts on underflow if they lack it) then transfers
     *      out to `to`. The caller is responsible for any health-factor check afterward.
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    /**
     * @dev Low-level debt burn. Reduces `onBehalfOf`'s recorded debt, pulls the DSC from
     *      `dscFrom` into the engine, then burns it. In a self-burn both are the caller; in a
     *      liquidation `onBehalfOf` is the borrower and `dscFrom` is the liquidator.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        IERC20(address(i_dsc)).safeTransferFrom(dscFrom, address(this), amountDscToBurn);
        i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @dev Health factor for `user`. See {_calculateHealthFactor} for the formula.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev Pure health-factor math.
     *      collateralAdjusted = collateralUsd * 50 / 100  (only half the collateral "counts")
     *      HF = collateralAdjusted * 1e18 / debt
     *      No debt => infinitely safe (return max uint).
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /// @dev Revert if `user` would be left under-collateralized (HF < 1).
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PUBLIC / EXTERNAL VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sum the USD value of every collateral token `user` holds.
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    /// @notice USD value (18 decimals) of `amount` of `token`, priced via Chainlink.
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // price is 8-decimal USD; scale to 18 then multiply by the (18-decimal) token amount.
        // Cast is safe: Chainlink USD feeds return a non-negative answer, and OracleLib has
        // already rejected stale/incomplete rounds before we reach this line.
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /// @notice How many `token` units equal `usdAmountInWei` USD (18 decimals). Inverse of getUsdValue.
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Cast is safe: see getUsdValue — Chainlink USD price is non-negative and freshness-checked.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /// @notice Public health factor (1e18 == 1.0).
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}

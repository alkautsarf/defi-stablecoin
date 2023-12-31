// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "forge-std/console.sol";

/**
 * @title DSCEngine
 * @author elpabl0.eth / Alkautsar.F
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1:1 ratio with USD.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC System should always be "overcollateralized". At no point, should the value of all collateral <= the $backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    error DSCEngine__AmountMustBeGreaterThanZero();
    error DSCEngine__TokenAddressNotSuitWithPriceFeedAddress();
    error DSCEngine__NotRegisteredToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BelowHealthFactorThreshold();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__WarningExceededLiquidationThreshold();
    error DSCEngine__BurnMoreThanUserHas(uint256 amountToBurn, uint256 actualUserBalance);

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus for liquidators

    DecentralizedStableCoin private immutable i_dsc;

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotRegisteredToken();
        }
        _;
    }

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) revert DSCEngine__AmountMustBeGreaterThanZero();
        _;
    }

    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressNotSuitWithPriceFeedAddress();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    /**
     * @param _tokenCollateralAddress The address of the collateral token.
     * @param _amountCollateral The amount of collateral to deposit.
     * @param _amountDscToMint The amount of DSC to mint.
     * @notice This function will deposit your collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /**
     * @notice Follows CEI.
     * @param _tokenCollateralAddress The address of the collateral token.
     * @param _amountCollateral The amount of collateral to deposit.
     * @param _amountDscToBurn The amount of DSC to burn.
     * @notice This function will burn your DSC and redeem your underlying collateral in one transaction.
     */
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // Redeem collateral already checks health factor.
    }

    /**
     * @notice Follows CEI.
     * @param _collateral The address of the collateral token to liquidate from the user.
     * @param _user The address of the user who will be liquidated.
     * @param _debtToCover The amount of DSC to burn to improve the users health factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice This function working assumes the protocol is overcollateralized by roughly 200%.
     * @notice A known bug would be if the protocol were 100% collateralized or less, then there will be no incentive for liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * @notice This function will revert with a warning if the collateral price drops more than 40% from the initial collateral price of liquidated user.
     * @notice It's because the protocol cannot pay the incentive of 10% to liquidator.
     */
    function liquidate(address _collateral, address _user, uint256 _debtToCover)
        external
        moreThanZero(_debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_collateral, totalCollateralToRedeem, _user, msg.sender);
        _burnDsc(_debtToCover, _user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _updateLiquidatorBalances(msg.sender, _collateral, tokenAmountFromDebtCovered, _debtToCover);
        _revertIfHealthFactorIsBelowThreshold(msg.sender);
    }

    function _updateLiquidatorBalances(
        address _liquidator,
        address _collateral,
        uint256 _redeemedCollateral,
        uint256 _debtToCover
    ) private {
        s_dscMinted[_liquidator] -= _debtToCover;
        s_collateralDeposited[_liquidator][_collateral] -= _redeemedCollateral;
    }

    function getHealthFactor(address _user) external view returns (uint256) {
        return _healthFactor(_user);
    }

    function getTotalCollateralAndDscValue(address _user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getTotalCollateralAndDscValue(_user);
    }

    function getUsdValue(
        address _token,
        uint256 _amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(_token, _amount);
    }

    function calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(_totalDscMinted, _collateralValueInUsd);
    }

    /**
     * @notice Follows CEI.
     * @param _tokenCollateralAddress The address of the collateral token.
     * @param _amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        // This conditional is hypothetically unreachable since it always return true if succeed and revert early if failed.
        bool ok = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!ok) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Follows CEI.
     * @notice Health Factor must be above the minimum threshold which is 1.
     * @param _tokenCollateralAddress The address of the collateral token.
     * @param _amountCollateral The amount of collateral to withdraw.
     */
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        nonReentrant
    {
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBelowThreshold(msg.sender);
    }

    /**
     * @notice Follows CEI.
     * @param _amountDscToMint The amount of DSC to mint.
     * @notice They must have collateral value than the minimum threshold.
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBelowThreshold(msg.sender); // This is not necessary and probably will never hit.
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function _getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }

    /**
     * @notice Follows CEI.
     * @dev Health Factor is term used by AAVE.
     * @param _user The address of the user.
     */
    function _revertIfHealthFactorIsBelowThreshold(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BelowHealthFactorThreshold();
        }
    }

    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (_totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (_collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / _totalDscMinted;
    }

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
    {
        if(_amountCollateral > s_collateralDeposited[_from][_tokenCollateralAddress]) {
            revert DSCEngine__WarningExceededLiquidationThreshold();
        }
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
        bool ok = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!ok) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for Health Factor being broken.
     */
    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        if (_amountDscToBurn > s_dscMinted[_onBehalfOf]) {
            revert DSCEngine__BurnMoreThanUserHas(_amountDscToBurn, s_dscMinted[_onBehalfOf]);
        }
        s_dscMinted[_onBehalfOf] -= _amountDscToBurn;
        bool ok = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        // This conditional is hypothetically unreachable since it always return true if succeed and revert early if failed.
        if (!ok) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn);
    }

    /**
     * Returns how close to liquidation a user is.
     * If a user goes below 1, they are liquidated.
     */
    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getTotalCollateralAndDscValue(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getTotalCollateralAndDscValue(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
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

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address _token) external view returns (address) {
        return s_priceFeeds[_token];
    }

    function getCollateralAmount(address _user, address _token) external view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }
}

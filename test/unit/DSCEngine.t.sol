// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/mocks/token/ERC20Mock.sol";
import {IERC20Errors} from "@openzeppelin/interfaces/draft-IERC6093.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;
    uint256 public constant ERC20_MINTED = 10 ether;
    uint256 public constant DSC_MINTED = 15000 ether;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 10;

    DeployDSC public deployer;
    HelperConfig public config;
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;

    address public ethUsdPriceFeed;
    address public weth;
    address public btcUsdPriceFeed;
    address public wbtc;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");

    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_MINTED);
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_MINTED);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 1650e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, DSC_MINTED);
        dsc.approve(address(dsce), DSC_MINTED);
        dsce.liquidate(weth, USER, DSC_MINTED); // We are covering their whole debt
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getTotalCollateralAndDscValue(LIQUIDATOR);
        uint256 collateralAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        dsce.redeemCollateral(weth, collateralAmount);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, ERC20_MINTED);
    }

    //* ERC20 Mock

    function testERC20MockTokenMintedToUser() public {
        uint256 balances = ERC20Mock(weth).balanceOf(USER);
        assertEq(balances, ERC20_MINTED);
    }

    //* Constructor DSCEngine

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressNotSuitWithPriceFeedAddress.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //* Function mintDsc()

    function testRevert_MintDscWithZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        dsce.mintDsc(0);
    }

    function testRevert_MintDscWithHealthFactorBelowThreshold(uint256 _amount) public {
        vm.assume(_amount != 0);
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BelowHealthFactorThreshold.selector);
        dsce.mintDsc(_amount);
    }

    function testMintDscSucceed() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(AMOUNT_COLLATERAL);
        uint256 mintedDsc = dsc.balanceOf(USER);
        assertEq(AMOUNT_COLLATERAL, mintedDsc);
    }

    //* Function depositCollateral()

    function testRevert_DepositCollateralIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevert_DepositCollateralIfTokenIsNotRegistered(address _address, uint256 _amount) public {
        vm.assume(_address != weth && _address != wbtc);
        vm.assume(_amount != 0);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotRegisteredToken.selector);
        dsce.depositCollateral(_address, _amount);
        vm.stopPrank();
    }

    function testRevert_DepositCollateralIfTransferFromFailed() public {
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, dsce, 0, AMOUNT_COLLATERAL)
        );
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //* Function depositCollateralAndMintDsc()

    function testDepositCollateralAndMintDscSucceed() public depositedCollateralAndMintedDsc {
        uint256 mintedDsc = dsc.balanceOf(USER);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getTotalCollateralAndDscValue(USER);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(mintedDsc, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    //* Function redeemCollateral()

    function testRevert_RedeemCollateralFailedIfDscNotBurned() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BelowHealthFactorThreshold.selector);
        dsce.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralSucceed() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        uint256 beforeBalance = ERC20Mock(weth).balanceOf(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        dsce.burnDsc(DSC_MINTED);
        dsce.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 updatedBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(beforeBalance, 0);
        assertEq(updatedBalance, AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralEmit() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        dsce.burnDsc(DSC_MINTED);
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //* Function burnDsc()

    function testRevert_BurnDscIfZeroTokenBeingBurned() public depositedCollateralAndMintedDsc {
        vm.prank(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        dsce.burnDsc(0);
    }

    function testRevert_BurnDscIfBurnMoreThanUserHas() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BurnMoreThanUserHas.selector, DSC_MINTED + 1, DSC_MINTED)
        );
        dsce.burnDsc(DSC_MINTED + 1);
        vm.stopPrank();
    }

    function testRevert_BurnDscIfUserNotApprovedAllowance() public depositedCollateralAndMintedDsc {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, dsce, 0, DSC_MINTED));
        dsce.burnDsc(DSC_MINTED);
    }

    function testBurnDscSucceed() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        dsce.burnDsc(DSC_MINTED);
        vm.stopPrank();
        uint256 expectedBalance = dsc.balanceOf(USER);
        assertEq(expectedBalance, 0);
    }

    //* Function redeemCollateralForDsc()

    function testRedeemCollateralForDscSucceed() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        uint256 beforeWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 beforeDscBalance = dsc.balanceOf(USER);
        dsc.approve(address(dsce), DSC_MINTED);
        dsce.redeemCollateralForDsc(address(weth), AMOUNT_COLLATERAL, DSC_MINTED);
        uint256 updatedWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 updatedDscBalance = dsc.balanceOf(USER);
        vm.stopPrank();
        assertEq(beforeWethBalance, 0);
        assertEq(updatedWethBalance, AMOUNT_COLLATERAL);
        assertEq(beforeDscBalance, DSC_MINTED);
        assertEq(updatedDscBalance, 0);
    }

    //* Function liquidate()

    function testRevert_LiquidateWithZeroInputInDebtToCover() public depositedCollateralAndMintedDsc {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testRevert_LiquidateWithTargetedUserHealthFactorOk(uint256 _amount)
        public
        depositedCollateralAndMintedDsc
    {
        vm.assume(_amount != 0);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, _amount);
    }

    function testRevert_LiquidateExceededLiquidationThreshold() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_MINTED);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 1600e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, DSC_MINTED);
        dsc.approve(address(dsce), DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__WarningExceededLiquidationThreshold.selector);
        dsce.liquidate(weth, USER, DSC_MINTED); // We are covering their whole debt
        vm.stopPrank();
    }

    function testLiquidateSucceedAndLiquidatorGetBonus() public liquidated {
        uint256 liquidatorBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 tokenAmount = dsce.getTokenAmountFromUsd(weth, DSC_MINTED);
        uint256 expectedLiquidatorBalance = COLLATERAL_TO_COVER + (tokenAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        assertEq(liquidatorBalance, expectedLiquidatorBalance);
    }

    //* Function getUsdValue()

    function testGetUsdValue(uint256 _amount) public {
        _amount = bound(_amount, 1, 100);
        uint256 ethAmount = _amount * 10 ** 18;
        uint256 expectedUsd = ethAmount * 3000;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    //* Function getTokenAmountFromUsd()

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 300 ether;
        uint256 expectedWeth = 0.1 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        console.log(actualWeth);
        assertEq(expectedWeth, actualWeth);
    }

    //* Function getTotalCollateralAndDscValue() & getTokenAmountFromUsd()

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getTotalCollateralAndDscValue(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    //* Function calculateHealthFactor()

    function testCalculateHealthFactorAboveMinHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        uint256 actualHealthFactor = dsce.getHealthFactor(USER);
        console.log(actualHealthFactor);
        assert(actualHealthFactor >= minHealthFactor);
    }

    function testCalculateHealthFactorBelowMinHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        int256 ethUsdUpdatedPrice = 1500e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 afterHealthFactor = dsce.getHealthFactor(USER);
        assert(afterHealthFactor < minHealthFactor);
    }

    function testOnlyCalculateHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = MIN_HEALTH_FACTOR;
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getTotalCollateralAndDscValue(USER);
        uint256 actualHealthFactor = dsce.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    //* External Getter Functions

    function testGetPrecision() public {
        assertEq(dsce.getPrecision(), PRECISION);
    }

    function testgetAdditionalFeedPrecision() public {
        assertEq(dsce.getAdditionalFeedPrecision(), ADDITIONAL_FEED_PRECISION);
    }

    function testgetLiquidationThreshold() public {
        assertEq(dsce.getLiquidationThreshold(), LIQUIDATION_THRESHOLD);
    }

    function testgetLiquidationBonus() public {
        assertEq(dsce.getLiquidationBonus(), LIQUIDATION_BONUS);
    }

    function testgetLiquidationPrecision() public {
        assertEq(dsce.getLiquidationPrecision(), LIQUIDATION_PRECISION);
    }

    function testgetCollateralTokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }

    function testgetDsc() public {
        assertEq(dsce.getDsc(), address(dsc));
    }

    function testGetCollateralTokenPriceFeed() public {
        address expectedEthPriceFeedAddress = dsce.getCollateralTokenPriceFeed(weth);
        address expectedBtcPriceFeedAddress = dsce.getCollateralTokenPriceFeed(wbtc);
        assertEq(expectedEthPriceFeedAddress, ethUsdPriceFeed);
        assertEq(expectedBtcPriceFeedAddress, btcUsdPriceFeed);
    }

    function testGetCollateralAmount() public depositedCollateral {
        assertEq(dsce.getCollateralAmount(USER, weth), AMOUNT_COLLATERAL);
    }
}

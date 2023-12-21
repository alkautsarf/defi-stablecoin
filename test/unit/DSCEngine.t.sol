// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/mocks/token/ERC20Mock.sol";
import {IERC20Errors} from "@openzeppelin/interfaces/draft-IERC6093.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    HelperConfig public config;
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    address public ethUsdPriceFeed;
    address public weth;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant ERC20_MINTED = 10 ether;
    address USER = makeAddr("user");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, ERC20_MINTED);
    }

    function testERC20MockTokenMintedToUser() public {
        uint256 balances = ERC20Mock(weth).balanceOf(USER);
        assertEq(balances, ERC20_MINTED);
    }

    function testGetUsdValue(uint256 _amount) public {
        _amount = bound(_amount, 1, 100);
        uint256 ethAmount = _amount * 10 ** 18;
        uint256 expectedUsd = ethAmount * 3000;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testRevertDepositCollateralIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertDepositCollateralIfTokenIsNotRegistered(address _address, uint256 _amount) public {
        vm.assume(_address != weth);
        vm.assume(_amount != 0);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotRegisteredToken.selector);
        dsce.depositCollateral(_address, _amount);
        vm.stopPrank();
    }

    function testRevertDepositCollateralIfTransferFromFailed() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, dsce, 0, AMOUNT_COLLATERAL));
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
}

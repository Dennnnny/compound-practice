// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";

import "compound-protocol/contracts/CErc20.sol";
import "compound-protocol/contracts/Comptroller.sol";
import "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import "compound-protocol/contracts/CErc20Delegator.sol";
import "compound-protocol/contracts/CErc20Delegate.sol";
import "compound-protocol/contracts/Unitroller.sol";
import "compound-protocol/contracts/SimplePriceOracle.sol";
import "compound-protocol/contracts/CToken.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UnderlyingToken} from "../script/Compound.s.sol";

// import {Compound} from "../script/Compound.s.sol";

contract CompoundTest is Test {
    //
    ERC20 public underlyingToken;
    CErc20Delegator public cToken;
    CErc20Delegate public cErc20Delegate;
    WhitePaperInterestRateModel public whitePaperInterestRateModel;
    Unitroller public unitroller;
    Comptroller public comptroller;
    Comptroller public unitrollerProxy;
    SimplePriceOracle public simplePriceOracle;

    address ADMIN = makeAddr("admin");
    address userA = makeAddr("userA");

    function setUp() public {
        // vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // make a underlying erc20 token
        underlyingToken = new UnderlyingToken();

        // a unitroller
        unitroller = new Unitroller();

        // a comptroller
        comptroller = new Comptroller();

        // a simple price oracle
        simplePriceOracle = new SimplePriceOracle();

        // setup unitroller
        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);

        // setup comptroller proxy
        Comptroller comptrollerProxy = Comptroller(address(unitroller));
        comptrollerProxy._setPriceOracle(simplePriceOracle);
        // comptrollerProxy

        // 借貸利率設定為 0%
        whitePaperInterestRateModel = new WhitePaperInterestRateModel(0, 0);

        cErc20Delegate = new CErc20Delegate();

        cToken = new CErc20Delegator(
            address(underlyingToken),
            comptrollerProxy,
            whitePaperInterestRateModel,
            1e18, //exchange rate, which scaled by 1e18
            "Compound Token",
            "cToken",
            18, //decimal
            payable(ADMIN),
            address(cErc20Delegate),
            bytes("0")
        );

        deal(address(underlyingToken), userA, 100 ether);

        comptrollerProxy._supportMarket(CToken(address(cToken)));
    }

    function testMintAndRedeem() public {
        vm.startPrank(userA);

        assertEq(underlyingToken.balanceOf(userA), 100 ether);
        assertEq(cToken.balanceOf(userA), 0 ether);

        underlyingToken.approve(address(cToken), type(uint256).max);
        uint mint_success = cToken.mint(100 ether);

        require(mint_success == 0, "ctoken mint fail");
        assertEq(cToken.balanceOf(userA), 100 ether);
        assertEq(underlyingToken.balanceOf(userA), 0 ether);

        uint redeem_success = cToken.redeem(100 ether);
        require(redeem_success == 0, "ctoken redeem fail");
        assertEq(cToken.balanceOf(userA), 0 ether);
        assertEq(underlyingToken.balanceOf(userA), 100 ether);

        vm.stopPrank();
    }
}

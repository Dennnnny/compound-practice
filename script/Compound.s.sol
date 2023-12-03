// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {Script} from "forge-std/Script.sol";

import "compound-protocol/contracts/CErc20.sol";
import "compound-protocol/contracts/Comptroller.sol";
import "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import "compound-protocol/contracts/CErc20Delegator.sol";
import "compound-protocol/contracts/CErc20Delegate.sol";
import "compound-protocol/contracts/Unitroller.sol";
import "compound-protocol/contracts/SimplePriceOracle.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract UnderlyingToken is ERC20 {
    constructor() ERC20("Underlying Token", "ULTK") {}
}

contract Compound is Script {
    ERC20 public underlyingToken;
    CErc20Delegator public cToken;
    CErc20Delegate public cErc20Delegate;
    WhitePaperInterestRateModel public whitePaperInterestRateModel;
    Unitroller public unitroller;
    Comptroller public comptroller;
    Comptroller public unitrollerProxy;
    SimplePriceOracle public simplePriceOracle;

    address public ADMIN = makeAddr("admin");

    function setUp() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

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
    }
}

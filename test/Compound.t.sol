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

contract anotherErc20 is ERC20 {
    constructor() ERC20("Another Underlying Token", "AULTK") {}
}

contract CompoundTest is Test {
    //
    ERC20 public tokenA;
    ERC20 public tokenB;
    CErc20Delegator public cToken_A;
    CErc20Delegator public cToken_B;
    CErc20Delegate public cErc20Delegate;
    WhitePaperInterestRateModel public whitePaperInterestRateModel;
    Unitroller public unitroller;
    Comptroller public comptroller;
    Comptroller public unitrollerProxy;
    SimplePriceOracle public simplePriceOracle;
    Comptroller public comptrollerProxy;

    address ADMIN = makeAddr("admin");
    address user1 = makeAddr("user1");
    address supplier = makeAddr("supplier");
    address[] tokens = new address[](2);

    function setUp() public {
        vm.startPrank(ADMIN);
        // make a underlying erc20 token
        tokenA = new UnderlyingToken();

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
        comptrollerProxy = Comptroller(address(unitroller));
        comptrollerProxy._setPriceOracle(simplePriceOracle);
        // comptrollerProxy

        // 借貸利率設定為 0%
        whitePaperInterestRateModel = new WhitePaperInterestRateModel(0, 0);

        cErc20Delegate = new CErc20Delegate();

        cToken_A = new CErc20Delegator(
            address(tokenA),
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

        comptrollerProxy._supportMarket(CToken(address(cToken_A)));
    }

    /// this is prepare for question 3,
    /// make another erc20, and making the setup part
    /// 部署第二份 cERC20 合約，以下稱它們的 underlying tokens 為 token A 與 token B。
    function prepare() public {
        vm.startPrank(ADMIN);
        // this is tokenB
        tokenB = new anotherErc20();

        // cToken_B
        cToken_B = new CErc20Delegator(
            address(tokenB),
            comptrollerProxy,
            whitePaperInterestRateModel,
            1e18, //exchange rate, which scaled by 1e18
            "Compound Token B",
            "cTokenB",
            18, //decimal
            payable(ADMIN),
            address(cErc20Delegate),
            bytes("0")
        );

        comptrollerProxy._supportMarket(CToken(address(cToken_B)));

        // 在 Oracle 中設定一顆 token A 的價格為 $1，一顆 token B 的價格為 $100
        simplePriceOracle.setUnderlyingPrice(CToken(address(cToken_A)), 1e18);
        simplePriceOracle.setUnderlyingPrice(CToken(address(cToken_B)), 100e18);

        // Token B 的 collateral factor 為 50%
        comptrollerProxy._setCollateralFactor(
            CToken(address(cToken_B)),
            0.5e18
        );

        vm.stopPrank();
    }

    function testMintAndRedeem() public {
        deal(address(tokenA), user1, 100e18);
        vm.startPrank(user1);

        assertEq(tokenA.balanceOf(user1), 100e18);
        assertEq(cToken_A.balanceOf(user1), 0e18);

        tokenA.approve(address(cToken_A), type(uint256).max);
        {
            uint success = cToken_A.mint(100e18);
            require(success == 0, "cToken_A mint fail");
            assertEq(cToken_A.balanceOf(user1), 100e18);
            assertEq(tokenA.balanceOf(user1), 0e18);
        }
        {
            uint success = cToken_A.redeem(100e18);
            require(success == 0, "cToken_A redeem fail");
            assertEq(cToken_A.balanceOf(user1), 0e18);
            assertEq(tokenA.balanceOf(user1), 100e18);
        }
        vm.stopPrank();
    }

    function testBorrowAndRepay() public {
        prepare();

        // make someone mint in tokenA first
        deal(address(tokenA), supplier, 100e18);
        vm.startPrank(supplier);
        tokenA.approve(address(cToken_A), type(uint256).max);
        {
            uint success = cToken_A.mint(100e18);
            require(success == 0, "cToken_A mint fail");
        }
        vm.stopPrank();

        // give user1 1 tokenB
        deal(address(tokenB), user1, 1 ether);
        // * User1 使用 1 顆 token B 來 mint cToken => user1 把 1顆 tokenB 轉進去 並且 enabled tokenB
        // -> 會得到 1顆 cToken_B, 少1顆 tokenB

        // * User1 使用 token B 作為抵押品來借出 50 顆 token A => 需要有一個人先把 tokenA 放個100顆
        // -> mint 得到 50 顆 tokenA，

        vm.startPrank(user1);

        tokenB.approve(address(cToken_B), type(uint256).max);
        {
            uint success = cToken_B.mint(1e18);
            require(success == 0, "ctoken_B mint fail");

            tokens[0] = address(cToken_A);
            tokens[1] = address(cToken_B);
            comptrollerProxy.enterMarkets(tokens);
        }

        {
            uint success = cToken_A.borrow(50e18);
            require(success == 0, "cToken_A borrow fail");
        }

        assertEq(tokenA.balanceOf(user1), 50e18);
        assertEq(tokenB.balanceOf(user1), 0);

        vm.stopPrank();
    }

    function testLiquidation_collateral_factor() public {
        // 延續 (3.) 的借貸場景，調整 token B 的 collateral factor，讓 User1 被 User2 清算
        // => 調降collateral -> 能借出的就該變少 -> 30% 能借30顆 但身上有50顆 -> 清算
    }

    function testLiquidation_oracle_price() public {
        // 5. 延續 (3.) 的借貸場景，調整 oracle 中 token B 的價格，讓 User1 被 User2 清算
        // => 把tokenB 價格調低 -> token B 價值變低： 原本50% factor 可以接50顆 -> 現在25顆 ， 但身上還有50顆 = 清算
    }
}

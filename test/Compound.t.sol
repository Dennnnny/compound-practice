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
    address liquidator = makeAddr("liquidator");
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
        {
            uint success = comptrollerProxy._setCloseFactor(0.5e18);
            require(success == 0, "set close factor fail");
        }
        {
            uint success = comptrollerProxy._setLiquidationIncentive(1.1e18);
            require(success == 0, "set incentive fail");
        }
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

        // user1 持有 tokenA 50顆
        // 延續#3
        testBorrowAndRepay();

        // 調低 collateral factor 0.5 -> 0.3
        vm.startPrank(ADMIN);
        {
            uint success = comptrollerProxy._setCollateralFactor(
                CToken(address(cToken_B)),
                0.3e18
            );
            require(success == 0, "set collateral factor fail");
        }

        vm.stopPrank();
        uint borrowAmount = cToken_A.borrowBalanceCurrent(user1);

        // give money to liquidator to liquidate
        deal(address(tokenA), liquidator, 25e18);

        vm.startPrank(liquidator);

        tokenA.approve(address(cToken_A), type(uint256).max);
        {
            (uint code, uint liquidity, uint shortfall) = comptrollerProxy
                .getAccountLiquidity(user1);
            require(
                shortfall > 0,
                "shortfall must greater than 0 to do the liquidation"
            );
        }
        {
            uint success = cToken_A.liquidateBorrow(
                user1,
                borrowAmount / 2,
                cToken_B
            );
            require(success == 0, "liquidateBorrow fail");
        }

        // 計算清算獎勵 (包含協議的獎勵)
        (uint success, uint seizeTokens) = comptrollerProxy
            .liquidateCalculateSeizeTokens(
                address(cToken_A),
                address(cToken_B),
                borrowAmount / 2
            );

        // user1 會剩下的抵押品量為扣除獎勵與清算價值後：
        assertEq(cToken_B.balanceOf(user1), (1e18 - seizeTokens));

        // liquidator 得到的則是 獎勵扣除 分給協議的：
        assertEq(
            cToken_B.balanceOf(liquidator),
            (seizeTokens * (1e18 - cToken_A.protocolSeizeShareMantissa())) /
                1e18
        );
        vm.stopPrank();
    }

    function testLiquidation_oracle_price() public {
        // 5. 延續 (3.) 的借貸場景，調整 oracle 中 token B 的價格，讓 User1 被 User2 清算
        // => 把tokenB 價格調低 -> token B 價值變低： 原本100$/50% factor 可以接50顆 -> 現在50$/50% : 25顆 ， 但身上還有50顆 = 清算
        testBorrowAndRepay();
        vm.startPrank(ADMIN);
        {
            simplePriceOracle.setUnderlyingPrice(
                CToken(address(cToken_B)),
                50e18
            );
        }
        vm.stopPrank();
        uint borrowAmount = cToken_A.borrowBalanceStored(user1);
        // give money to liquidator to liquidate
        deal(address(tokenA), liquidator, 25e18);

        vm.startPrank(liquidator);
        {
            (uint code, uint liquidity, uint shortfall) = comptrollerProxy
                .getAccountLiquidity(user1);

            require(
                shortfall > 0,
                "shortfall must greater than 0 to do the liquidation"
            );
        }

        tokenA.approve(address(cToken_A), type(uint256).max);
        {
            uint success = cToken_A.liquidateBorrow(
                user1,
                borrowAmount / 2,
                cToken_B
            );
            require(success == 0, "liquidateBorrow fail");
        }
        // 獎勵
        (uint success, uint seizeTokens) = comptrollerProxy
            .liquidateCalculateSeizeTokens(
                address(cToken_A),
                address(cToken_B),
                borrowAmount / 2
            );

        // user1 會剩下的抵押品量為扣除獎勵與清算價值後：
        assertEq(cToken_B.balanceOf(user1), (1e18 - seizeTokens));

        // liquidator 得到的則是 獎勵扣除 分給協議的：
        assertEq(
            cToken_B.balanceOf(liquidator),
            ((seizeTokens) * (1e18 - cToken_A.protocolSeizeShareMantissa())) /
                1e18
        );

        // 發現在某些價格之下 例如 70$ , 用『balanceOf算出來的數量』與 用『seizeToken減去協議獎勵算出來的數量』
        // 會有誤差，感覺是 rounddown 造成的 但我沒有找出不會有誤差的計算公式Ｑ＿Ｑ

        vm.stopPrank();
    }
}

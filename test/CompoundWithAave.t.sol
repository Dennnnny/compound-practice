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
import "compound-protocol/contracts/CTokenInterfaces.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CompoundWithAave is Test {
    // [x] Fork Ethereum mainnet at block  17465000([Reference](https://book.getfoundry.sh/forge/fork-testing#examples))
    // [x] cERC20 的 decimals 皆為 18，初始 exchangeRate 為 1:1
    // [x] Close factor 設定為 50%
    // [x] Liquidation incentive 設為 8% (1.08 * 1e18)
    // [x] 使用 USDC 以及 UNI 代幣來作為 token A 以及 Token B
    // [x] 在 Oracle 中設定 USDC 的價格為 $1，UNI 的價格為 $5
    // [x] 設定 UNI 的 collateral factor 為 50%
    // [x] User1 使用 1000 顆 UNI 作為抵押品借出 2500 顆 USDC
    // [x] 將 UNI 價格改為 $4 使 User1 產生 Shortfall，並讓 User2 透過 AAVE 的 Flash loan 來借錢清算 User1
    // [x] 可以自行檢查清算 50% 後是不是大約可以賺 63 USDC
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1"); // borrower
    address user2 = makeAddr("user2"); // liquidator
    address user3 = makeAddr("user3"); // supplier
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    CErc20Delegator public cUSDC; // cToken_A;
    CErc20Delegator public cUNI; //cToken_B;
    ERC20 public token_USDC = ERC20(USDC);
    ERC20 public token_UNI = ERC20(UNI);
    uint256 USDCDecimal = 6;
    uint256 UNIDecimal = 18;
    CErc20Delegate public cErc20Delegate;
    WhitePaperInterestRateModel public whitePaperInterestRateModel;
    Unitroller public unitroller;
    Comptroller public comptroller;
    Comptroller public unitrollerProxy;
    SimplePriceOracle public simplePriceOracle;
    Comptroller public comptrollerProxy;

    struct CallbackData {
        address borrower;
        address liquidator;
        address borrowToken;
        address collateralToken;
    }

    function setUp() public {
        // for mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 17465000);
        // vm.rollFork(17465000);
        vm.startPrank(owner);
        // setup contracts
        unitroller = new Unitroller();
        comptroller = new Comptroller();
        simplePriceOracle = new SimplePriceOracle();
        // setup unitroller
        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);
        // setup comptroller proxy
        comptrollerProxy = Comptroller(address(unitroller));
        comptrollerProxy._setPriceOracle(simplePriceOracle);
        CErc20Delegate cUSDCDelegate = new CErc20Delegate();
        CErc20Delegate cUNIDelegate = new CErc20Delegate();
        WhitePaperInterestRateModel interestRateModel = new WhitePaperInterestRateModel(
                0,
                0
            );
        // tokenA = USDC
        cUSDC = new CErc20Delegator(
            USDC,
            comptrollerProxy,
            interestRateModel,
            10 ** USDCDecimal,
            "Compound TokenA",
            "cUSDC",
            18, //decimal
            payable(owner),
            address(cUSDCDelegate),
            bytes("0")
        );
        // tokenB = UNI
        cUNI = new CErc20Delegator(
            UNI,
            comptrollerProxy,
            interestRateModel,
            10 ** UNIDecimal,
            "Compound TokenB",
            "cUNI",
            18, //decimal
            payable(owner),
            address(cUNIDelegate),
            bytes("0")
        );
        // list cTokens
        comptrollerProxy._supportMarket(CToken(address(cUSDC)));
        comptrollerProxy._supportMarket(CToken(address(cUNI)));

        // set price usdc $1 and uni $5
        simplePriceOracle.setDirectPrice(USDC, 1 * 10 ** (36 - USDCDecimal));
        simplePriceOracle.setDirectPrice(UNI, 5 * 10 ** (36 - UNIDecimal));
        // set close Factory 50%
        comptrollerProxy._setCloseFactor(0.5e18);
        // uni collacteral 50%
        uint se = comptrollerProxy._setCollateralFactor(
            CToken(address(cUNI)),
            0.5e18
        );
        comptrollerProxy._setCollateralFactor(CToken(address(cUSDC)), 0.5e18);
        // incentive% 1.08
        comptrollerProxy._setLiquidationIncentive(1.08e18);

        // let owner put some money in the pool
        //
        uint256 initialUSDCAmount = 10000 * 10 ** USDCDecimal;
        uint256 initialUNIAmount = 10000 * 10 ** UNIDecimal;
        vm.startPrank(owner);
        deal(address(token_USDC), owner, initialUSDCAmount);
        deal(address(token_UNI), owner, initialUNIAmount);
        token_USDC.approve(address(cUSDC), type(uint256).max);
        token_UNI.approve(address(cUNI), type(uint256).max);
        cUSDC.mint(initialUSDCAmount);
        cUNI.mint(initialUNIAmount);
        address[] memory paths = new address[](2);
        paths[0] = address(cUNI);
        paths[1] = address(cUSDC);
        comptrollerProxy.enterMarkets(paths);
        vm.stopPrank();
    }

    function testLiquidation() public {
        // user1 go to borrow usdc
        vm.startPrank(user1);
        uint256 collacteralAmount = 1000 * 10 ** UNIDecimal;
        uint256 borrowAmount = 2500 * 10 ** USDCDecimal;
        // deal 1000 UNI to user1 as collacteral
        deal(address(token_UNI), user1, collacteralAmount);
        assertEq(token_UNI.balanceOf(user1), collacteralAmount);
        token_UNI.approve(address(cUNI), type(uint256).max);
        cUNI.mint(collacteralAmount);
        // let UNI enter market
        address[] memory tokens = new address[](1);
        tokens[0] = address(cUNI);
        uint[] memory re = comptrollerProxy.enterMarkets(tokens);

        // borrow 2500 USDC
        cUSDC.borrow(borrowAmount);
        vm.stopPrank();
        assertEq(token_USDC.balanceOf(user1), borrowAmount);

        //////////

        // change the price of uni 5 -> 4
        simplePriceOracle.setDirectPrice(
            address(UNI),
            4 * 10 ** (36 - UNIDecimal)
        );

        // prank user2 to liquidate user1
        vm.startPrank(user2);

        // check user1's liquidity
        (, , uint shortfall) = comptrollerProxy.getAccountLiquidity(user1);

        // console2.log("shortfall here:", shortfall);
        require(shortfall > 0, "shotfall need to greater than 0");

        CallbackData memory data = CallbackData(
            user1,
            user2,
            address(cUSDC),
            address(cUNI)
        );

        Liquidator liquidator = new Liquidator();

        uint256 repayAmount = cUSDC.borrowBalanceStored(user1) / 2;

        liquidator.liquidateWithSimpleFlashLoan(
            USDC,
            repayAmount,
            abi.encode(data)
        );

        // check user2 has benefit after liquidation around 63 usdc
        console2.log(token_USDC.balanceOf(user2)); // = 63638693 約 63.63
        assertGt(token_USDC.balanceOf(user2), 63 * 10 ** USDCDecimal);
        vm.stopPrank();
    }
}

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ISwapRouter.ExactInputSingleParams memory params
    ) external returns (uint256 amountOut);
}

contract Liquidator {
    ERC20 UNI = ERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IPool pool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    ISwapRouter swapRouter =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function liquidateWithSimpleFlashLoan(
        address token,
        uint256 amount,
        bytes calldata data
    ) public {
        pool.flashLoanSimple(address(this), token, amount, data, 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(
            msg.sender == address(pool),
            "FlashLoanLiquidate: invalid sender"
        );
        require(
            initiator == address(this),
            "FlashLoanLiquidate: invalid initiator"
        );

        (
            address borrower,
            address liquidator,
            address cUSDC,
            address cUNI
        ) = abi.decode(params, (address, address, address, address));

        // 要先用erc20 approve 讓ctoken 可以transferFrom
        ERC20(asset).approve(address(cUSDC), type(uint256).max);

        CErc20Interface(cUSDC).liquidateBorrow(
            borrower,
            amount,
            CTokenInterface(cUNI)
        );
        CErc20Interface(cUNI).redeem(
            CTokenInterface(cUNI).balanceOf(address(this))
        );

        // UNI Swap to USDC
        UNI.approve(address(swapRouter), type(uint256).max);
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(UNI),
                tokenOut: asset,
                fee: 3000, // 0.3%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: UNI.balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        uint256 amountOut = swapRouter.exactInputSingle(swapParams);

        // amount that need to pay back to aave plus fee
        uint256 totalPayback = amount + premium;

        // transfer to liquidator
        ERC20(asset).transfer(address(liquidator), amountOut - totalPayback);

        ERC20(asset).approve(address(pool), totalPayback);

        return true;
    }
}

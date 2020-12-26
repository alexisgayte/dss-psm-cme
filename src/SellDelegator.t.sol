pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";
import "ds-token/token.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Dai}              from "dss/dai.sol";
import {Vow}              from "dss/vow.sol";

import "./SellDelegator.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestToken is DSToken {

    constructor(bytes32 symbol_, uint256 decimals_) public DSToken(symbol_) {
        decimals = decimals_;
    }

}

contract TestRoute {

    uint public amountOut;
    bool public hasBeenCalled = false;

    function swapTokensForExactTokens(uint _amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts){
        hasBeenCalled = true;
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = _amountOut;
        amountOut = _amountOut;

    }
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = amountIn;
    }

    function reset() external {
        hasBeenCalled = false;
        amountOut = 0;
    }

}


contract TestPSM {

    bool public hasBeenCalled = false;
    DSToken usdc;
    constructor(DSToken usdx) public {
        usdc = usdx;
    }

    function sellGem(address usr, uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        hasBeenCalled = true;
    }

    function reset() external {
        hasBeenCalled = false;
    }
}

contract TestVow is Vow {
    constructor(address vat, address flapper, address flopper)
    public Vow(vat, flapper, flopper) {}
}

contract TestVat is Vat {
}

contract SellDelegotorTest is DSTest {
    
    Hevm hevm;

    address me;

    TestToken usdx;
    Dai dai;

    DSToken bonusToken;
    TestVow vow;
    TestVat vat;
    TestPSM testPsm;
    TestRoute testRoute;
    SellDelegator sellDelegator;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));


    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        usdx = new TestToken("USDX", 18);
        usdx.mint(1000);

        dai = new Dai(0);
        bonusToken = new TestToken("XOMP", 8);
        bonusToken.mint(1000);

        /////
        testPsm = new TestPSM(usdx);
        usdx.setOwner(address(testPsm));
        testRoute = new TestRoute();
        vat = new TestVat();
        vow = new TestVow(address(vat), address(0), address(0));

        sellDelegator = new SellDelegator(address(vow), address(dai), address(usdx), address(bonusToken));
        sellDelegator.file("psm", address(testPsm));
        sellDelegator.file("route", address(testRoute));
    }


    function test_processUsdc_without_usdc() public {
        sellDelegator.processUsdc();

        assertTrue(!testPsm.hasBeenCalled());
    }

    function test_processComp_without_comp() public {
        sellDelegator.processComp();

        assertTrue(!testRoute.hasBeenCalled());
    }

    function test_processUsdc_with_usdc() public {
        usdx.transfer(address(sellDelegator), 100);
        assertEq(usdx.balanceOf(address(sellDelegator)), 100);
        assertEq(usdx.balanceOf(address(vow)), 0);
        sellDelegator.processUsdc();

        assertTrue(testPsm.hasBeenCalled());

        assertEq(usdx.balanceOf(address(sellDelegator)), 0);
    }

    function test_processDai_with_dai() public {
        dai.mint(address(sellDelegator), 100);

        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(vow)), 100);
    }

    function test_processComp_with_bonus() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);

        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
    }

    function test_processComp_with_bonus_and_auction_time() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);

        sellDelegator.processComp();

        assertTrue(!testPsm.hasBeenCalled());
        assertTrue(testRoute.hasBeenCalled());
        hevm.warp(4 hours + 30 minutes);
        testRoute.reset();
        sellDelegator.processComp();
        assertTrue(!testRoute.hasBeenCalled());

    }

    function test_processComp_with_bonus_under_max_auction_amount() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);
        sellDelegator.file("max_auction_amount", 200);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processComp_with_bonus_over_max_auction_amount() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);
        sellDelegator.file("max_auction_amount", 50);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processComp_with_a_different_auction_duration() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);

        sellDelegator.file("max_auction_amount", 200);
        sellDelegator.file("auction_duration", 30*60);
        hevm.warp(45 minutes);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);

    }

}

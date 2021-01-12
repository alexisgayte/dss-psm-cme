pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";
import {Dai} from "dss/dai.sol";

import "./stub/TestRoute.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import "./SellDelegator.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestReserve {
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


contract SellDelegatorTest is DSTest {
    
    Hevm hevm;

    address me;

    TestToken usdx;
    Dai dai;

    TestReserve reserve;
    DSToken bonusToken;
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
        TokenAuthority usdxAuthority = new TokenAuthority();
        usdx.setAuthority(DSAuthority(address(usdxAuthority)));
        usdx.mint(1000);

        dai = new Dai(0);
        dai.mint(address(this), 1000);

        bonusToken = new TestToken("XOMP", 8);
        TokenAuthority bonusAuthority = new TokenAuthority();
        bonusToken.setAuthority(DSAuthority(address(bonusAuthority)));
        bonusToken.mint(1000);

        /////
        testPsm = new TestPSM(usdx);

        testRoute = new TestRoute();
        dai.rely(address(testRoute));

        reserve = new TestReserve();

        sellDelegator = new SellDelegator(address(reserve), address(dai), address(usdx), address(bonusToken));
        sellDelegator.file("psm", address(testPsm));
        sellDelegator.file("route", address(testRoute));
    }

    // processUsdc

    function test_processUsdc_without_usdc() public {
        sellDelegator.processUsdc();

        assertTrue(!testPsm.hasBeenCalled());
    }

    function test_processUsdc_with_usdc() public {
        usdx.transfer(address(sellDelegator), 100);
        assertEq(usdx.balanceOf(address(sellDelegator)), 100);
        assertEq(usdx.balanceOf(address(reserve)), 0);
        sellDelegator.processUsdc();

        assertTrue(testPsm.hasBeenCalled());

        assertEq(usdx.balanceOf(address(sellDelegator)), 0);
    }

    // processDai

    function test_processDai_without_dai() public {
        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        hevm.warp(4 hours);

        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(reserve)), 0);
    }

    function test_processDai_with_dai_under_duration() public {
        dai.mint(address(sellDelegator), 100);

        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        hevm.warp(1 hours);

        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        assertEq(dai.balanceOf(address(reserve)), 0);
    }

    function test_processDai_with_dai() public {
        dai.mint(address(sellDelegator), 100);

        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);

        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(reserve)), 100);
    }

    function test_processDai_with_dai_and_auction_time() public {
        dai.mint(address(sellDelegator), 100);
        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);

        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(reserve)), 100);

        // second round

        dai.mint(address(sellDelegator), 100);
        assertEq(dai.balanceOf(address(sellDelegator)), 100);

        hevm.warp(4 hours + 30 minutes);

        sellDelegator.processDai();
        assertEq(dai.balanceOf(address(sellDelegator)), 100);
        assertEq(dai.balanceOf(address(reserve)), 100 + 0);

    }

    function test_processDai_with_dai_under_max_dai_auction_amount() public {
        dai.transfer(address(sellDelegator), 100);
        assertEq(dai.balanceOf(address(sellDelegator)), 100);

        hevm.warp(4 hours);
        sellDelegator.file("dai_auction_max_amount", 200);
        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(reserve)), 100);
    }

    function test_processDai_with_dai_over_max_dai_auction_amount() public {
        dai.transfer(address(sellDelegator), 200);
        assertEq(dai.balanceOf(address(sellDelegator)), 200);

        hevm.warp(4 hours);
        sellDelegator.file("dai_auction_max_amount", 50);
        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 150);
        assertEq(dai.balanceOf(address(reserve)), 50);

    }

    function test_processDai_with_a_different_dai_auction_duration() public {
        dai.transfer(address(sellDelegator), 100);
        assertEq(dai.balanceOf(address(sellDelegator)), 100);

        sellDelegator.file("dai_auction_max_amount", 200);
        sellDelegator.file("dai_auction_duration", 30*60);
        hevm.warp(45 minutes);
        sellDelegator.processDai();

        assertEq(dai.balanceOf(address(sellDelegator)), 0);
        assertEq(dai.balanceOf(address(reserve)), 100);

    }

    // processComp

    function test_processComp_without_comp() public {
        sellDelegator.processComp();

        assertTrue(!testRoute.hasBeenCalled());
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

    function test_processComp_with_bonus_under_bonus_auction_max_amount() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);
        sellDelegator.file("bonus_auction_max_amount", 200);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processComp_with_bonus_over_bonus_auction_max_amount() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);
        hevm.warp(4 hours);
        sellDelegator.file("bonus_auction_max_amount", 50);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processComp_with_a_different_bonus_auction_duration() public {
        bonusToken.transfer(address(sellDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sellDelegator)), 100);

        sellDelegator.file("bonus_auction_max_amount", 200);
        sellDelegator.file("bonus_auction_duration", 30*60);
        hevm.warp(45 minutes);
        sellDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);

    }

}

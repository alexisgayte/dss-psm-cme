pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";
import {Dai} from "dss/dai.sol";

import "./stub/TestRoute.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import "./BurnDelegator.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
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

    TestToken mkr;
    TestToken bonusToken;
    TestPSM testPsm;
    TestRoute testRoute;
    BurnDelegator burnDelegator;

    bytes32 constant ilk = "usdx";

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));


    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }

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

        mkr = new TestToken("MKR", 8);
        TokenAuthority mkrAuthority = new TokenAuthority();
        mkr.setAuthority(DSAuthority(address(mkrAuthority)));
        mkr.mint(1000);

        /////
        testPsm = new TestPSM(usdx);

        testRoute = new TestRoute();
        dai.rely(address(testRoute));
        mkrAuthority.rely(address(testRoute));

        burnDelegator = new BurnDelegator(address(mkr), address(dai), address(usdx), address(bonusToken));
        burnDelegator.file("psm", address(testPsm));
        burnDelegator.file("route", address(testRoute));

    }


    function test_processUsdc_without_usdc() public {
        burnDelegator.processUsdc();

        assertTrue(!testPsm.hasBeenCalled());
    }

    function test_processComp_without_comp() public {
        burnDelegator.processComp();

        assertTrue(!testRoute.hasBeenCalled());
    }

    function test_processUsdc_with_usdc() public {
        usdx.transfer(address(burnDelegator), 100);
        assertEq(usdx.balanceOf(address(burnDelegator)), 100);
        burnDelegator.processUsdc();

        assertTrue(testPsm.hasBeenCalled());

        assertEq(usdx.balanceOf(address(burnDelegator)), 0);
    }

    function test_processDai_with_dai() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);

        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(mkr.balanceOf(address(burnDelegator)), 0);
    }

    function test_processDai_with_dai_and_auction_time() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);

        burnDelegator.processDai();

        assertTrue(!testPsm.hasBeenCalled());
        assertTrue(testRoute.hasBeenCalled());
        hevm.warp(4 hours + 30 minutes);
        testRoute.reset();
        burnDelegator.processDai();
        assertTrue(!testRoute.hasBeenCalled());

    }

    function test_processDai_with_dai_under_max_dai_auction_amount() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("dai_auction_max_amount", 200);
        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processDai_with_dai_over_max_dai_auction_amount() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("dai_auction_max_amount", 50);
        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processDai_with_a_different_dai_auction_duration() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);

        burnDelegator.file("dai_auction_max_amount", 200);
        burnDelegator.file("dai_auction_duration", 30*60);
        hevm.warp(45 minutes);
        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);

    }
    ///
    function test_processComp_with_bonus() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);

        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
    }

    function test_processComp_with_bonus_and_auction_time() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);

        burnDelegator.processComp();

        assertTrue(!testPsm.hasBeenCalled());
        assertTrue(testRoute.hasBeenCalled());
        hevm.warp(4 hours + 30 minutes);
        testRoute.reset();
        burnDelegator.processComp();
        assertTrue(!testRoute.hasBeenCalled());

    }

    function test_processComp_with_bonus_under_max_bonus_auction_amount() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("bonus_auction_max_amount", 200);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processComp_with_bonus_over_max_bonus_auction_amount() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("bonus_auction_max_amount", 50);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processComp_with_a_different_auction_duration() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);

        burnDelegator.file("bonus_auction_max_amount", 200);
        burnDelegator.file("bonus_auction_duration", 30*60);
        hevm.warp(45 minutes);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);

    }

}

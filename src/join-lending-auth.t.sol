pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";
import "ds-token/token.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Dai}              from "dss/dai.sol";

import "./join-lending-auth.sol";
import "./stub/TestCToken.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestDelegator {
    bool public hasBeenCalled = false;

    function call() external {
        hasBeenCalled = true;
    }

    function reset() external {
        hasBeenCalled = false;
    }
}

contract JoinLendingAuthTest is DSTest {
    
    Hevm hevm;

    address me;

    Vat vat;
    Spotter spotGemA;
    DSValue pipGemA;
    TestToken usdx;
    Dai dai;

    TestCToken ctoken;
    DSToken bonusToken;
    TestDelegator excessDelegator;

    LendingAuthGemJoin gemA;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "usdx";

    uint256 constant TOLL_ONE_PCT = 10 ** 16;
    uint256 USDX_WAD;
    uint256 USDX_TO_18;

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }


    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        vat = new Vat();
        vat = vat;

        spotGemA = new Spotter(address(vat));
        vat.rely(address(spotGemA));

        usdx = new TestToken("USDX", 6);
        TokenAuthority usdxAuthority = new TokenAuthority();
        usdx.setAuthority(DSAuthority(address(usdxAuthority)));
        USDX_WAD = 10 ** usdx.decimals();
        USDX_TO_18 = 10 ** (18 - usdx.decimals());
        usdx.mint(1000 * USDX_WAD);
        vat.init(ilkA);

        dai = new Dai(0);
        bonusToken = new TestToken("XOMP", 8);
        TokenAuthority bonusAuthority = new TokenAuthority();
        bonusToken.setAuthority(DSAuthority(address(bonusAuthority)));

        excessDelegator = new TestDelegator();
        ctoken = new TestCToken("CUSDC", 8, usdx, bonusToken);

        bonusAuthority.rely(address(ctoken));
        usdxAuthority.rely(address(ctoken));

        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(usdx), address(ctoken), address(bonusToken));
        gemA.rely(me);
        vat.rely(address(gemA));

        pipGemA = new DSValue();
        pipGemA.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemA.file(ilkA, bytes32("pip"), address(pipGemA));
        spotGemA.file(ilkA, bytes32("mat"), ray(1 ether));
        spotGemA.poke(ilkA);

        vat.file(ilkA, "line", rad(1000 ether));
        vat.file("Line",       rad(1000 ether));
    }

    function test_join() public {

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_WAD, me);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 100 * USDX_WAD * USDX_TO_18);

    }

    function test_exit_after_join() public {

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_WAD, me);

        gemA.exit(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
    }

    function testFail_exit_without_found() public {

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        gemA.exit(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 100 * USDX_WAD * USDX_TO_18);
    }

    function testFail_direct_deposit() public {

        gemA.deny(me);
        usdx.approve(address(gemA), uint(-1));
        gemA.join(me, 10 * USDX_WAD, me);
    }

    function testFail_direct_join_exit() public {

        gemA.deny(me);
        usdx.approve(address(gemA), uint(-1));
        gemA.exit(me, 10 * USDX_WAD);
    }

    function test_harvest_with_bonus() public {
        usdx.approve(address(gemA));//token

        gemA.file("excessDelegator", address(excessDelegator));
        ctoken.setReward(1);

        gemA.join(me, 100 * USDX_WAD, me);
        gemA.exit(me, 100 * USDX_WAD);
        gemA.join(me, 100 * USDX_WAD, me);
        gemA.harvest();

        assertTrue(excessDelegator.hasBeenCalled());
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 3);
        assertEq(usdx.balanceOf(address(excessDelegator)) , 0);
    }

    function test_harvest_with_no_monies() public {
        usdx.approve(address(gemA));//token

        gemA.file("excessDelegator", address(excessDelegator));
        ctoken.setReward(0);

        gemA.join(me, 100 * USDX_WAD, me);
        gemA.exit(me, 100 * USDX_WAD);
        gemA.harvest();

        assertTrue(!excessDelegator.hasBeenCalled());
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 0);
    }

    function test_harvest_with_fees() public {
        usdx.approve(address(gemA));//token
        gemA.file("excessDelegator", address(excessDelegator));
        ctoken.setReward(0);
        ctoken.addFeeIncome(address(gemA), 4 * USDX_WAD);

        gemA.join(me, 100 * USDX_WAD, me);
        vat.frob(ilkA, me, me, me, 100, 100);
        gemA.harvest();
        assertTrue(excessDelegator.hasBeenCalled());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_WAD);
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 0);
    }

    function test_harvest_with_fees_and_bonus() public {
        usdx.approve(address(gemA));//token
        gemA.file("excessDelegator", address(excessDelegator));
        ctoken.setReward(1);
        ctoken.addFeeIncome(address(gemA), 4 * USDX_WAD);

        gemA.join(me, 100 * USDX_WAD, me);
        vat.frob(ilkA, me, me, me, 100, 100);
        gemA.harvest();
        assertTrue(excessDelegator.hasBeenCalled());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_WAD);
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 1);
    }

    function test_harvest_with_fees_and_two_auths() public {
        usdx.approve(address(gemA));//token
        gemA.file("excessDelegator", address(excessDelegator));
        gemA.rely(address(spotGemA));
        ctoken.setReward(0);
        ctoken.addFeeIncome(address(gemA), 4 * USDX_WAD);
        assertEq(gemA.wards(address(me)), 1);
        assertEq(gemA.wards(address(spotGemA)), 1);

        gemA.join(me, 100 * USDX_WAD, me);
        vat.frob(ilkA, me, me, me, 100, 100);
        gemA.harvest();
        assertTrue(excessDelegator.hasBeenCalled());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_WAD);
    }
}

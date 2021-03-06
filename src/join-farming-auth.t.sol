pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";
import "ds-value/value.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Dai}              from "dss/dai.sol";

import "./stub/TestComptroller.stub.sol";
import "./stub/TestCToken.stub.sol";
import "./stub/TestRoute.stub.sol";

import "./mock/Delegator.mock.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import "./join-farming-auth.sol";


interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract DssPsmCmeTest is DSTest , DSMath {
    
    Hevm hevm;

    address me;

    Vat vat;
    Spotter spotGemA;
    DSValue pipGemA;
    TestToken usdx;

    TestCToken ctoken;
    DSToken bonusToken;
    DelegatorMock excessDelegator;
    TestRoute testRoute;
    TestComptroller comptroller;

    FarmingAuthGemJoin gemA;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "usdx";

    uint256 USDX_DEC;
    uint256 CUSDC_DEC;
    uint256 XOMP_DEC;
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

        Dai dai = new Dai(0);

        usdx = new TestToken("USDX", 6);
        TokenAuthority usdxAuthority = new TokenAuthority();
        usdx.setAuthority(DSAuthority(address(usdxAuthority)));
        USDX_DEC = 10 ** usdx.decimals();
        USDX_TO_18 = 10 ** (18 - usdx.decimals());
        usdx.mint(10000 * USDX_DEC);
        vat.init(ilkA);

        bonusToken = new TestToken("XOMP", 8);
        TokenAuthority bonusAuthority = new TokenAuthority();
        bonusToken.setAuthority(DSAuthority(address(bonusAuthority)));
        XOMP_DEC = 10 ** bonusToken.decimals();

        excessDelegator = new DelegatorMock(address(dai), address(usdx), address(bonusToken));
        ctoken = new TestCToken("CUSDC", 8, usdx, bonusToken);
        CUSDC_DEC = 10 ** ctoken.decimals();

        bonusAuthority.rely(address(ctoken));
        usdxAuthority.rely(address(ctoken));

        testRoute = new TestRoute();
        usdxAuthority.rely(address(testRoute));

        comptroller = new TestComptroller(ctoken , bonusToken);
        bonusAuthority.rely(address(comptroller));

        gemA = new FarmingAuthGemJoin(address(vat), ilkA, address(usdx), address(ctoken), address(bonusToken), address(comptroller));
        gemA.rely(me);
        vat.rely(address(gemA));
        gemA.file("cf_target", 70 * WAD / 100);
        gemA.file("excess_delegator", address(excessDelegator));
        gemA.file("route", address(testRoute));
        gemA.file("cf_max", 75*WAD/100);

        pipGemA = new DSValue();
        pipGemA.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemA.file(ilkA, bytes32("pip"), address(pipGemA));
        spotGemA.file(ilkA, bytes32("mat"), ray(1 ether));
        spotGemA.poke(ilkA);

        vat.file(ilkA, "line", rad(1000 ether));
        vat.file("Line",       rad(1000 ether));
    }

    // test file()
    function test_excessDelegator() public {
        gemA.file("excess_delegator", address(0));
        assertEq(address(gemA.excessDelegator()), address(0));
    }

    function test_route() public {
        gemA.file("route",  address(0));
        assertEq(address(gemA.route()), address(0));
    }

    function test_cfTarget() public {
        gemA.file("cf_target", 80 * WAD / 100);
        assertEq(gemA.cfTarget(), 80 * WAD / 100);
    }

    function testFail_cfTarget_over_100_percent() public {
        gemA.file("cf_target", 101 * WAD / 100);
    }
    function testFail_cfTarget_100_percent() public {
        gemA.file("cf_target", 100 * WAD / 100);
    }

    function test_cfMax() public {
        gemA.file("cf_max", 80 * WAD / 100);
        assertEq(gemA.cfMax(), 80 * WAD / 100);
    }

    function testFail_cfMax_100_percent() public {
        gemA.file("cf_max", 100 * WAD / 100);
    }

    function testFail_cfMax_over_100_percent() public {
        gemA.file("cf_max", 101 * WAD / 100);
    }

    function test_maxBonusAuctionAmount() public {
        gemA.file("bonus_auction_max_amount", 80 * WAD);
        assertEq(gemA.bonusAuctionMaxAmount(), 80 * WAD);
    }

    function test_bonusAuctionDuration() public {
        gemA.file("bonus_auction_duration", 10000);
        assertEq(gemA.bonusAuctionDuration(), 10000);
    }


    // test coefficientTarget()
    function test_coefficient_target_zero() public {
        gemA.file("cf_max", 0);
        assertEq(gemA.cfMax(), 0);

        assertEq(gemA.maxCollateralFactor(), 0);
    }

    function test_coefficient_target_under_max_market() public {
        gemA.file("cf_max", 70 * WAD / 100);
        assertEq(gemA.cfMax(), 70 * WAD / 100);

        assertEq(gemA.maxCollateralFactor(), 70 * WAD / 100);
    }

    function test_coefficient_target_over_max_market() public {
        gemA.file("cf_max", 80 * WAD / 100);
        assertEq(gemA.cfMax(), 80 * WAD / 100);

        assertEq(gemA.maxCollateralFactor(), 75 * WAD / 100);
    }

    // test maxCollateralFactor()
    function test_max_collateral_factor_zero() public {
        gemA.file("cf_target", 0);
        assertEq(gemA.cfTarget(), 0);

        assertEq(gemA.coefficientTarget(), 0);
    }

    function test_coefficient_target_under_max_collateral_factor() public {
        gemA.file("cf_target", 70 * WAD / 100);
        assertEq(gemA.cfTarget(), 70 * WAD / 100);

        assertEq(gemA.coefficientTarget(), 70 * WAD / 100);
    }

    function test_coefficient_target_over_max_collateral_factor() public {
        gemA.file("cf_target", 80 * WAD / 100);
        assertEq(gemA.cfTarget(), 80 * WAD / 100);

        assertEq(gemA.coefficientTarget(), 75 * WAD * 98 / 10000); // 98%
    }

    // normal suit test
    function test_join() public {

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 9900 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 100 * USDX_DEC * USDX_TO_18);

    }

    function test_exit_after_join() public {

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_DEC);

        gemA.exit(me, 100 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
    }

    function testFail_exit_without_found() public {

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        gemA.exit(me, 100 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 9900 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 100 * USDX_DEC * USDX_TO_18);
    }

    function testFail_direct_deposit() public {

        gemA.deny(me);
        usdx.approve(address(gemA), uint(-1));
        gemA.join(me, 10 * USDX_DEC);
    }

    function testFail_direct_join_exit() public {

        gemA.deny(me);
        usdx.approve(address(gemA), uint(-1));
        gemA.exit(me, 10 * USDX_DEC);
    }


    // test harvest over collateralized
    function test_harvest_over_collateralized_with_bonus() public {
        usdx.approve(address(gemA));//token

        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(1);
        comptroller.setReward(100);
        ctoken.addFeeIncome(address(gemA), 1 * USDX_DEC);

        gemA.join(me, 10000 * USDX_DEC);
        gemA.exit(me, 10000 * USDX_DEC);
        gemA.harvest();

        assertTrue(excessDelegator.hasMoneyBeenSent());
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 115); // more then 100 and 1 each mint
        assertEq(usdx.balanceOf(address(excessDelegator)) , 1 * USDX_DEC - 500); // 500 Margin
    }

    function test_harvest_over_collateralized_with_no_monies_no_reward() public {
        usdx.approve(address(gemA));//token

        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(0);
        ctoken.addFeeIncome(address(gemA), 10 * USDX_DEC);
        comptroller.setReward(0);

        gemA.join(me, 10000 * USDX_DEC);
        gemA.harvest();

        assertTrue(!excessDelegator.hasMoneyBeenSent());
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 0);
        assertEq(usdx.balanceOf(address(excessDelegator)) , 0);
    }

    function test_harvest_over_collateralized_with_fees() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(0);
        ctoken.addFeeIncome(address(gemA), 14 * USDX_DEC);

        gemA.join(me, 10000 * USDX_DEC);
        vat.frob(ilkA, me, me, me, 10000, 10000);
        gemA.harvest();
        assertTrue(excessDelegator.hasMoneyBeenSent());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_DEC - 500); // 500 Margin
    }

    function test_harvest_over_collateralized_with_fees_and_bonus() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(1);
        ctoken.addFeeIncome(address(gemA), 14 * USDX_DEC);

        gemA.join(me, 10000 * USDX_DEC);
        vat.frob(ilkA, me, me, me, 10000, 10000);
        gemA.harvest();
        assertTrue(excessDelegator.hasMoneyBeenSent());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_DEC - 500); // 500 Margin
        assertEq(bonusToken.balanceOf(address(excessDelegator)) , 7);
    }

    function test_harvest_over_collateralized_with_fees_and_two_auths() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        gemA.rely(address(spotGemA));
        ctoken.setReward(0);
        ctoken.addFeeIncome(address(gemA), 14 * USDX_DEC);
        assertEq(gemA.wards(address(me)), 1);
        assertEq(gemA.wards(address(spotGemA)), 1);

        gemA.join(me, 10000 * USDX_DEC);
        vat.frob(ilkA, me, me, me, 10000, 10000);

        gemA.harvest();
        assertTrue(excessDelegator.hasMoneyBeenSent());
        assertEq(usdx.balanceOf(address(excessDelegator)) , 4 * USDX_DEC - 500); // 500 Margin
    }

    // test harvest under collateralized

    function test_harvest_under_collateralized_without_bonus() public {
        usdx.approve(address(gemA));
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(0);

        gemA.join(me, 10000 * USDX_DEC);
        gemA.harvest();
        assertTrue(!testRoute.hasBeenCalled());
    }

    function test_harvest_under_collateralized_with_bonus() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(100);

        gemA.join(me, 10000 * USDX_DEC);

        hevm.warp(4 hours);
        assertEq(bonusToken.balanceOf(address(gemA)), 700);

        gemA.harvest();

        assertTrue(testRoute.hasBeenCalled());
    }

    function test_harvest_under_collateralized_with_bonus_and_auction_time() public {
        usdx.approve(address(gemA));//token
        usdx.mint(10000 * USDX_DEC); // mint an extra 10000
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(100);

        gemA.join(me, 10000 * USDX_DEC);

        hevm.warp(4 hours);
        assertEq(bonusToken.balanceOf(address(gemA)), 700);

        gemA.harvest();

        assertTrue(testRoute.hasBeenCalled());
        hevm.warp(4 hours + 30 minutes);

        gemA.join(me, 10000 * USDX_DEC);
        testRoute.reset();
        gemA.harvest();

        assertTrue(!testRoute.hasBeenCalled());

    }

    function test_harvest_under_collateralized_with_bonus_under_bonus_auction_max_amount() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(10);

        hevm.warp(4 hours);
        gemA.file("bonus_auction_max_amount", 200);
        gemA.join(me, 10000 * USDX_DEC);

        gemA.harvest();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 70);
    }

    function test_harvest_under_collateralized_with_bonus_over_bonus_auction_max_amount() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(100);

        hevm.warp(4 hours);
        gemA.file("bonus_auction_max_amount", 50);
        gemA.join(me, 10000 * USDX_DEC);

        gemA.harvest();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_harvest_under_collateralized_with_a_different_bonus_auction_duration() public {
        usdx.approve(address(gemA));//token
        gemA.file("excess_delegator", address(excessDelegator));
        ctoken.setReward(10);

        gemA.file("bonus_auction_max_amount", 200);
        gemA.file("bonus_auction_duration", 30*60);
        hevm.warp(45 minutes);
        gemA.join(me, 10000 * USDX_DEC);

        gemA.harvest();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 70);

    }


    // Test winding and unwinding

    function test_winding() public {

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 9900 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 100 * USDX_DEC * USDX_TO_18);

        // test Join
        // gemA.file("cf_target", 70 * WAD / 100);
        assertEq(ctoken.balanceOf(address(gemA)), 100 * USDX_DEC * 100 / 30);

    }

    function test_unwinding() public {

        assertEq(usdx.balanceOf(me), 10000 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));
        gemA.join(me, 100 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 9900 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 100 * USDX_DEC * USDX_TO_18);

        // test Join
        // gemA.file("cf_target", 70 * WAD / 100);
        assertEq(ctoken.balanceOf(address(gemA)), 100 * USDX_DEC * 100 / 30);
        gemA.exit(me, 70 * USDX_DEC);

        assertEq(usdx.balanceOf(me), 9970 * USDX_DEC);
        assertEq(vat.gem(ilkA, me), 30 * USDX_DEC * USDX_TO_18);

        // test Join
        // gemA.file("cf_target", 70 * WAD / 100);
        assertEq(usdx.balanceOf(address(gemA)), 0);
        assertEq(ctoken.balanceOf(address(gemA)), 30 * USDX_DEC * 100 / 30);


    }

}

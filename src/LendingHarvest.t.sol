pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";

import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {GemJoin, DaiJoin} from "dss/join.sol";
import {Dai}              from "dss/dai.sol";

import "./stub/TestCToken.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import {LendingAuthGemJoin, LTKLike} from "./join-lending-auth.sol";
import "./DssPsmCme.sol";
import "./LendingHarvest.sol";

contract TestDelegator {
    bool public hasBeenCalled = false;

    function call() external {
        hasBeenCalled = true;
    }

    function reset() external {
        hasBeenCalled = false;
    }
}


contract DssPsmCmeTest is DSTest {

    address me;

    Vat vat;
    Spotter spotGemA;
    DSValue pipGemA;

    Dai dai;
    TestToken usdx;
    TestCToken cusdx;
    TestToken bonusToken;

    TestDelegator excessDelegator;

    LendingAuthGemJoin gemA;
    LendingHarvest lendingHarvest;

    bytes32 constant ilkA = "usdx";

    uint256 constant USDX_WAD = 10 ** 6;
    uint256 constant WAD = 10 ** 18;

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }

    function setUp() public {
        me = address(this);

        usdx = new TestToken("USDX", 6);
        TokenAuthority usdxAuthority = new TokenAuthority();
        usdx.setAuthority(DSAuthority(address(usdxAuthority)));
        usdx.mint(1000 * USDX_WAD);

        dai = new Dai(0);

        bonusToken = new TestToken("XOMP", 8);
        TokenAuthority bonusAuthority = new TokenAuthority();
        bonusToken.setAuthority(DSAuthority(address(bonusAuthority)));

        cusdx = new TestCToken("CUSDC", 8, usdx, bonusToken);
        TokenAuthority cusdxAuthority = new TokenAuthority();
        cusdx.setAuthority(DSAuthority(address(cusdxAuthority)));
        usdxAuthority.rely(address(cusdx));
        bonusAuthority.rely(address(cusdx));

        excessDelegator = new TestDelegator();

        vat = new Vat();

        spotGemA = new Spotter(address(vat));
        vat.rely(address(spotGemA));

        vat.init(ilkA);

        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(usdx), address(cusdx), address(bonusToken));
        gemA.file("excess_delegator", address(excessDelegator));

        vat.rely(address(gemA));

        pipGemA = new DSValue();
        pipGemA.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemA.file(ilkA, bytes32("pip"), address(pipGemA));
        spotGemA.file(ilkA, bytes32("mat"), ray(1 ether));
        spotGemA.poke(ilkA);


        vat.file(ilkA, "line", rad(1000 ether));
        vat.file("Line",       rad(1000 ether));

        lendingHarvest = new LendingHarvest(address(gemA));
        gemA.rely(address(lendingHarvest));

        gemA.deny(me);
    }


    function test_harvest_delegator_has_been_call() public {
        bonusToken.mint(address(gemA), 1 ether);
        lendingHarvest.harvest();

        assertTrue(excessDelegator.hasBeenCalled());
    }

}

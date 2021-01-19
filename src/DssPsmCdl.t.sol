pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";

import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Vow}              from "dss/vow.sol";
import {DaiJoin}          from "dss/join.sol";
import {Dai}              from "dss/dai.sol";

import "./stub/TestCToken.stub.sol";
import "./stub/TestRoute.stub.sol";
import "./stub/TestComptroller.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import {FarmingAuthGemJoin} from "./join-farming-auth.sol";
import "./DssPsmCdl.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
    function roll(uint256) external;
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

contract TestVow is Vow {
    constructor(address vat, address flapper, address flopper)
    public Vow(vat, flapper, flopper) {}
    // Total surplus
    function Joy() public view returns (uint256) {
        return vat.dai(address(this));
    }
}

contract DssPsmCdlTest is DSTest {
    
    Hevm hevm;

    address me;

    Vat vat;
    Spotter spotGemA;
    TestVow vow;
    DSValue pipGemA;

    DaiJoin daiJoin;

    Dai dai;
    TestCToken cdai;
    TestToken bonusToken;

    TestRoute testRoute;
    TestComptroller comptroller;

    TestDelegator excessDelegator;

    FarmingAuthGemJoin gemA;

    DssPsmCdl psmC;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "dai-comp-leverage";

    uint256 constant WAD = 10 ** 18;

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }


    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        dai = new Dai(0);

        bonusToken = new TestToken("XOMP", 8);
        TokenAuthority bonusAuthority = new TokenAuthority();
        bonusToken.setAuthority(DSAuthority(address(bonusAuthority)));

        cdai = new TestCToken("CDAI", 8, TestToken(address(dai)), bonusToken);
        TokenAuthority cdaiAuthority = new TokenAuthority();
        cdai.setAuthority(DSAuthority(address(cdaiAuthority)));
        dai.rely(address(cdai));
        bonusAuthority.rely(address(cdai));

        excessDelegator = new TestDelegator();

        vat = new Vat();

        spotGemA = new Spotter(address(vat));
        vat.rely(address(spotGemA));

        vow = new TestVow(address(vat), address(0), address(0));

        vat.init(ilkA);

        testRoute = new TestRoute();
        dai.rely(address(testRoute));

        comptroller = new TestComptroller(cdai , bonusToken);
        bonusAuthority.rely(address(comptroller));

        gemA = new FarmingAuthGemJoin(address(vat), ilkA, address(dai), address(cdai), address(bonusToken), address(comptroller));
        gemA.file("cf_target", 70 * WAD / 100);
        gemA.file("route", address(testRoute));
        gemA.file("cf_max", 75 * WAD / 100);
        gemA.file("excess_delegator", address(excessDelegator));

        vat.rely(address(gemA));

        daiJoin = new DaiJoin(address(vat), address(dai));
        dai.rely(address(daiJoin));

        vat.rely(address(daiJoin));

        psmC = new DssPsmCdl(address(gemA), address(daiJoin));
        vat.rely(address(psmC));

        gemA.rely(address(psmC));
        daiJoin.rely(address(psmC));

        pipGemA = new DSValue();
        pipGemA.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemA.file(ilkA, bytes32("pip"), address(pipGemA));
        spotGemA.file(ilkA, bytes32("mat"), ray(1 ether));
        spotGemA.poke(ilkA);


        vat.file(ilkA, "line", rad(100000000 ether));
        vat.file("Line",       rad(100000000 ether));

        gemA.deny(me);
        daiJoin.deny(me);
    }

    //
    function test_leverage() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverage(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 100000 ether);
        assertEq(artpsm, 100000 ether);
    }

    function test_deleverage() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverage(100000 * WAD);
        psmC.deleverage(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 0 ether);
        assertEq(artpsm, 0 ether);

    }

}

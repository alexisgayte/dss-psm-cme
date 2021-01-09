pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";

import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Vow}              from "dss/vow.sol";
import {GemJoin, DaiJoin} from "dss/join.sol";
import {Dai}              from "dss/dai.sol";

import "./stub/TestCToken.stub.sol";
import "./stub/TestRoute.stub.sol";
import "./stub/TestComptroller.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import {LendingAuthGemJoin, LTKLike} from "./join-lending-auth.sol";
import {LendingLeverageAuthGemJoin} from "./join-lending-leverage-auth.sol";
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
    Spotter spotGemB;
    TestVow vow;
    DSValue pipGemA;
    DSValue pipGemB;

    DaiJoin daiJoinGem;

    Dai dai;
    TestCToken cdai;
    TestToken bonusToken;

    TestRoute testRoute;
    TestComptroller comptroller;

    TestDelegator excessDelegator;

    LendingAuthGemJoin gemA;
    LendingLeverageAuthGemJoin gemB;
    DssPsmCdl psmC;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "dai-comp-leverage";
    bytes32 constant ilkB = "dai-comp";

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

        spotGemB = new Spotter(address(vat));
        vat.rely(address(spotGemB));

        vow = new TestVow(address(vat), address(0), address(0));

        vat.init(ilkA);
        vat.init(ilkB);


        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(dai), address(cdai), address(bonusToken));
        gemA.file("excessDelegator", address(excessDelegator));

        vat.rely(address(gemA));

        testRoute = new TestRoute();
        dai.rely(address(testRoute));

        comptroller = new TestComptroller(cdai , bonusToken);
        bonusAuthority.rely(address(comptroller));

        gemB = new LendingLeverageAuthGemJoin(address(vat), ilkB, address(dai), address(cdai), address(bonusToken), address(comptroller), address(dai));
        gemB.file("cfTarget", 70 * WAD / 100);
        gemB.file("route", address(testRoute));
        gemB.file("cfMax", 75 * WAD / 100);
        gemB.file("excessDelegator", address(excessDelegator));

        vat.rely(address(gemB));

        daiJoinGem = new DaiJoin(address(vat), address(dai));
        dai.rely(address(daiJoinGem));

        vat.rely(address(daiJoinGem));

        psmC = new DssPsmCdl(address(gemA), address(gemB), address(daiJoinGem));
        dai.rely(address(psmC));

        gemA.rely(address(psmC));
        gemB.rely(address(psmC));
        daiJoinGem.rely(address(psmC));

        pipGemA = new DSValue();
        pipGemA.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemA.file(ilkA, bytes32("pip"), address(pipGemA));
        spotGemA.file(ilkA, bytes32("mat"), ray(1 ether));
        spotGemA.poke(ilkA);

        pipGemB = new DSValue();
        pipGemB.poke(bytes32(uint256(1 ether))); // Spot = $1

        spotGemB.file(ilkB, bytes32("pip"), address(pipGemB));
        spotGemB.file(ilkB, bytes32("mat"), ray(1 ether));
        spotGemB.poke(ilkB);

        vat.file(ilkA, "line", rad(100000 ether));
        vat.file(ilkB, "line", rad(100000 ether));
        vat.file("Line",       rad(200000 ether));

        gemA.deny(me);
        gemB.deny(me);
        daiJoinGem.deny(me);
    }

    //
    function test_leverageLendingVault() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverageLendingVault(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 100000 ether);
        assertEq(artpsm, 100000 ether);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmC));
        assertEq(inkpsm, 0 ether);
        assertEq(artpsm, 0 ether);
    }

    function test_leverageLendingLeverageVault() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverageLendingLeverageVault(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 0);
        assertEq(artpsm, 0);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmC));
        assertEq(inkpsm, 100000 ether);
        assertEq(artpsm, 100000 ether);
    }


    function test_deleverageLendingVault() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverageLendingVault(100000 * WAD);
        psmC.deleverageLendingVault(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 0 ether);
        assertEq(artpsm, 0 ether);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmC));
        assertEq(inkpsm, 0 ether);
        assertEq(artpsm, 0 ether);
    }


    function test_deleverageLendingLeverageVault() public {
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        psmC.leverageLendingLeverageVault(100000 * WAD);
        psmC.deleverageLendingLeverageVault(100000 * WAD);

        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);
        assertEq(dai.balanceOf(address(psmC)), 0);
        assertEq(vat.gem(ilkA, address(psmC)), 0);
        assertEq(vat.gem(ilkB, address(psmC)), 0);
        assertEq(vat.dai(address(psmC)), 0);

        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmC));
        assertEq(inkpsm, 0);
        assertEq(artpsm, 0);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmC));
        assertEq(inkpsm, 0);
        assertEq(artpsm, 0);
    }

}

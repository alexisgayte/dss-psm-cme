pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";

import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Vow}              from "dss/vow.sol";
import {GemJoin, DaiJoin} from "dss/join.sol";
import {Dai}              from "dss/dai.sol";

import "./stub/TestCToken.stub.sol";

import "./testhelper/TestToken.sol";
import "./testhelper/MkrTokenAuthority.sol";

import {LendingAuthGemJoin, LTKLike} from "./join-lending-auth.sol";
import "./DssPsmCme.sol";

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
    // Total deficit
    function Awe() public view returns (uint256) {
        return vat.sin(address(this));
    }
    // Total surplus
    function Joy() public view returns (uint256) {
        return vat.dai(address(this));
    }
    // Unqueued, pre-auction debt
    function Woe() public view returns (uint256) {
        return sub(sub(Awe(), Sin), Ash);
    }
}

contract User {

    Dai public dai;
    DssPsmCme public psm;

    constructor(Dai dai_, DssPsmCme psm_) public {
        dai = dai_;
        psm = psm_;
    }

    function sell(uint256 wad) public {
        DSToken(address(psm.token())).approve(address(psm), uint256(-1));
        psm.sell(address(this), wad);
    }

    function buy(uint256 wad) public {
        dai.approve(address(psm), uint256(-1));
        psm.buy(address(this), wad);
    }


}

contract DssPsmCmeTest is DSTest {
    
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
    TestToken usdx;
    TestCToken cusdx;
    TestCToken cdai;
    TestToken bonusToken;


    TestDelegator excessDelegator;

    LendingAuthGemJoin gemA;
    LendingAuthGemJoin gemB;
    DssPsmCme psmA;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "usdx";
    bytes32 constant ilkB = "dai";

    uint256 constant TOLL_ONE_PCT = 10 ** 16;
    uint256 constant USDX_WAD = 10 ** 6;

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }


    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

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


        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(usdx), address(cusdx), address(bonusToken));
        gemA.file("excess_delegator", address(excessDelegator));

        vat.rely(address(gemA));

        gemB = new LendingAuthGemJoin(address(vat), ilkB, address(dai), address(cdai), address(bonusToken));
        gemB.file("excess_delegator", address(excessDelegator));

        vat.rely(address(gemB));

        daiJoinGem = new DaiJoin(address(vat), address(dai));
        dai.rely(address(daiJoinGem));

        vat.rely(address(daiJoinGem));

        psmA = new DssPsmCme(address(gemA), address(gemB), address(daiJoinGem), address(vow));

        gemA.rely(address(psmA));
        gemB.rely(address(psmA));
        daiJoinGem.rely(address(psmA));

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

        vat.file(ilkA, "line", rad(1000 ether));
        vat.file(ilkB, "line", rad(1000 ether));
        vat.file("Line",       rad(2000 ether));

        gemA.deny(me);
        gemB.deny(me);
        daiJoinGem.deny(me);
    }

    // sanity check & Param check
    function testFail_direct_deposit() public {
        usdx.approve(address(gemA), uint(-1));
        gemA.join(me, 10 * USDX_WAD);
    }

    uint256 constant WAD = 10 ** 18;
    function testFail_tin_over_100_percent() public {
        usdx.approve(address(psmA));
        psmA.file("tin", 1 * WAD);
        psmA.sell(me, 100 * USDX_WAD);
    }

    function testFail_tout_over_100_percent() public {
        usdx.approve(address(psmA));
        psmA.file("tout", 1 * WAD);
        psmA.sell(me, 100 * USDX_WAD);
    }

    function testFail_deny_gov_file() public {
        usdx.approve(address(psmA));
        psmA.deny(me);
        psmA.file("tout", 1 * WAD);
        psmA.sell(me, 100 * USDX_WAD);
    }

    function testFail_deny_following_rely_gov_file() public {
        usdx.approve(address(psmA));
        psmA.deny(me);
        psmA.rely(me);// no right
        psmA.file("tout", 1 * WAD);
        psmA.sell(me, 100 * USDX_WAD);
    }

    //
    function test_sell_no_fee() public {
        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), 0);
        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmA));
        assertEq(inkpsm, 100 ether);
        assertEq(artpsm, 100 ether);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmA));
        assertEq(inkpsm, 100 ether);
        assertEq(artpsm, 100 ether);
    }

    function test_sell_fee() public {
        psmA.file("tin", TOLL_ONE_PCT);

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 99 ether);
        assertEq(vow.Joy(), rad(1 ether));

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 99 ether);
        assertEq(vow.Joy(), rad(1 ether));

        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inkpsm, uint256 artpsm) = vat.urns(ilkA, address(psmA));
        assertEq(inkpsm, 100 ether);
        assertEq(artpsm, 100 ether);

        (inkpsm, artpsm) = vat.urns(ilkB, address(psmA));
        assertEq(inkpsm, 100 ether);
        assertEq(artpsm, 100 ether);
    }

    function test_swap_both_no_fee() public {
        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);
        dai.approve(address(psmA), 40 ether);
        psmA.buy(me, 40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 940 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 60 ether);
        assertEq(vow.Joy(), 0);
        (uint256 ink, uint256 art) = vat.urns(ilkA, address(psmA));
        assertEq(ink, 60 ether);
        assertEq(art, 60 ether);

        (ink, art) = vat.urns(ilkB, address(psmA));
        assertEq(ink, 60 ether);
        assertEq(art, 60 ether);
    }

    function test_swap_both_fees() public {
        psmA.file("tin", 5 * TOLL_ONE_PCT);
        psmA.file("tout", 10 * TOLL_ONE_PCT);

        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(dai.balanceOf(me), 95 ether);
        assertEq(vow.Joy(), rad(5 ether));
        (uint256 ink1, uint256 art1) = vat.urns(ilkA, address(psmA));
        assertEq(ink1, 100 ether);
        assertEq(art1, 100 ether);
        (ink1, art1) = vat.urns(ilkB, address(psmA));
        assertEq(ink1, 100 ether);
        assertEq(art1, 100 ether);

        dai.approve(address(psmA), 44 ether);
        psmA.buy(me, 40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 940 * USDX_WAD);
        assertEq(dai.balanceOf(me), 51 ether);
        assertEq(vow.Joy(), rad(9 ether));
        (uint256 ink2, uint256 art2) = vat.urns(ilkA, address(psmA));
        assertEq(ink2, 60 ether);
        assertEq(art2, 60 ether);
        (ink2, art2) = vat.urns(ilkB, address(psmA));
        assertEq(ink2, 60 ether);
        assertEq(art2, 60 ether);
    }

    function test_swap_twice_both_fees() public {
        psmA.file("tin", 5 * TOLL_ONE_PCT);
        psmA.file("tout", 10 * TOLL_ONE_PCT);

        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(dai.balanceOf(me), 95 ether);
        assertEq(vow.Joy(), rad(5 ether));
        (uint256 inkA, uint256 artA) = vat.urns(ilkA, address(psmA));
        assertEq(inkA, 100 ether);
        assertEq(artA, 100 ether);

        (uint256 inkB, uint256 artB) = vat.urns(ilkB, address(psmA));
        assertEq(inkB, 100 ether);
        assertEq(artB, 100 ether);

        dai.approve(address(psmA), 44 ether);
        psmA.buy(me, 40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 940 * USDX_WAD);
        assertEq(dai.balanceOf(me), 51 ether);
        assertEq(vow.Joy(), rad(9 ether));
        (inkA, artA) = vat.urns(ilkA, address(psmA));
        assertEq(inkA, 60 ether);
        assertEq(artA, 60 ether);

        (inkB, artB) = vat.urns(ilkB, address(psmA));
        assertEq(inkB, 60 ether);
        assertEq(artB, 60 ether);

        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 840 * USDX_WAD);
        assertEq(dai.balanceOf(me), 146 ether);
        assertEq(vow.Joy(), rad(14 ether));
        (inkA, artA) = vat.urns(ilkA, address(psmA));
        assertEq(inkA, 160 ether);
        assertEq(artA, 160 ether);

        (inkB, artB) = vat.urns(ilkB, address(psmA));
        assertEq(inkB, 160 ether);
        assertEq(artB, 160 ether);


        dai.approve(address(psmA), 44 ether);
        psmA.buy(me, 40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 880 * USDX_WAD);
        assertEq(dai.balanceOf(me), 102 ether);
        assertEq(vow.Joy(), rad(18 ether));
        (inkA, artA) = vat.urns(ilkA, address(psmA));
        assertEq(inkA, 120 ether);
        assertEq(artA, 120 ether);

        (inkB, artB) = vat.urns(ilkB, address(psmA));
        assertEq(inkB, 120 ether);
        assertEq(artB, 120 ether);
    }

    function test_swap_both_other() public {
        usdx.approve(address(psmA));
        psmA.sell(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), rad(0 ether));

        User someUser = new User(dai, psmA);
        dai.mint(address(someUser), 45 ether);
        someUser.buy(40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(usdx.balanceOf(address(someUser)), 40 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0 ether);
        assertEq(vat.gem(ilkA, address(someUser)), 0 ether);
        assertEq(vat.dai(me), 0);
        assertEq(vat.dai(address(someUser)), 0);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(dai.balanceOf(address(someUser)), 5 ether);
        assertEq(vow.Joy(), rad(0 ether));
        (uint256 ink, uint256 art) = vat.urns(ilkA, address(psmA));
        assertEq(ink, 60 ether);
        assertEq(art, 60 ether);
    }

    function test_swap_both_other_small_fee() public {
        psmA.file("tin", 1);

        User user1 = new User(dai, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sell(40 * USDX_WAD);

        assertEq(usdx.balanceOf(address(user1)), 0 * USDX_WAD);
        assertEq(dai.balanceOf(address(user1)), 40 ether - 40);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink1, uint256 art1) = vat.urns(ilkA, address(psmA));
        assertEq(ink1, 40 ether);
        assertEq(art1, 40 ether);

        user1.buy(40 * USDX_WAD - 1);

        assertEq(usdx.balanceOf(address(user1)), 40 * USDX_WAD - 1);
        assertEq(dai.balanceOf(address(user1)), 999999999960);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink2, uint256 art2) = vat.urns(ilkA, address(psmA));
        assertEq(ink2, 1 * 10 ** 12);
        assertEq(art2, 1 * 10 ** 12);
    }

    function testFail_sell_insufficient_gem() public {
        User user1 = new User(dai, psmA);
        user1.sell(40 * USDX_WAD);
    }

    function testFail_swap_both_small_fee_insufficient_dai() public {
        psmA.file("tin", 1);        // Very small fee pushes you over the edge

        User user1 = new User(dai, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sell(40 * USDX_WAD);
        user1.buy(40 * USDX_WAD);
    }

    function testFail_sell_over_line() public {
        usdx.mint(1000 * USDX_WAD);
        usdx.approve(address(psmA));
        psmA.buy(me, 2000 * USDX_WAD);
    }

    function testFail_two_users_insufficient_dai() public {
        User user1 = new User(dai, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sell(40 * USDX_WAD);

        User user2 = new User(dai, psmA);
        dai.mint(address(user2), 39 ether);
        user2.buy(40 * USDX_WAD);
    }

    function test_swap_both_zero() public {
        usdx.approve(address(psmA), uint(-1));
        psmA.sell(me, 0);
        dai.approve(address(psmA), uint(-1));
        psmA.buy(me, 0);
    }
}

pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";
import "ds-token/token.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Vow}              from "dss/vow.sol";
import {GemJoin, DaiJoin} from "dss/join.sol";
import {Dai}              from "dss/dai.sol";

import {LendingAuthGemJoin, LTKLike} from "./join-lending-auth.sol";
import "./DssPsmCme.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestToken is DSToken {

    constructor(bytes32 symbol_, uint256 decimals_) public DSToken(symbol_) {
        decimals = decimals_;
    }

}

contract TestCToken is DSMath {

    DSToken underlyingToken;

    constructor(bytes32 symbol_, uint256 decimals_, DSToken underlyingToken_) public {
        decimals = decimals_;
        underlyingToken = underlyingToken_;
        symbol = symbol_;
    }

    function mint(uint256 mintAmount) external returns (uint256){
        mint(msg.sender, mintAmount);
        underlyingToken.burn(msg.sender, mintAmount);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256){
        burn(msg.sender, redeemAmount);
        underlyingToken.mint(msg.sender, redeemAmount);
        return 0;
    }

    //// TokenDS

    bool                                              public  stopped;
    uint256                                           public  totalSupply;
    mapping (address => uint256)                      public  balanceOf;
    mapping (address => mapping (address => uint256)) public  allowance;
    bytes32                                           public  symbol;
    uint256                                           public  decimals = 18; // standard token precision. override to customize
    bytes32                                           public  name = "";     // Optional token name

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);
    event Mint(address indexed guy, uint wad);
    event Burn(address indexed guy, uint wad);

    function approve(address guy) external returns (bool) {
        return approve(guy, uint(-1));
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;

        emit Approval(msg.sender, guy, wad);

        return true;
    }

    function transfer(address dst, uint wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad) public returns (bool){
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad, "ds-token-insufficient-approval");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }

        require(balanceOf[src] >= wad, "ds-token-insufficient-balance");
        balanceOf[src] = sub(balanceOf[src], wad);
        balanceOf[dst] = add(balanceOf[dst], wad);

        emit Transfer(src, dst, wad);

        return true;
    }

    function mint(address guy, uint wad) public {
        balanceOf[guy] = add(balanceOf[guy], wad);
        totalSupply = add(totalSupply, wad);
        emit Mint(guy, wad);
    }

    function burn(address guy, uint wad) public {
        if (guy != msg.sender && allowance[guy][msg.sender] != uint(-1)) {
            require(allowance[guy][msg.sender] >= wad, "ds-token-insufficient-approval");
            allowance[guy][msg.sender] = sub(allowance[guy][msg.sender], wad);
        }

        require(balanceOf[guy] >= wad, "ds-token-insufficient-balance");
        balanceOf[guy] = sub(balanceOf[guy], wad);
        totalSupply = sub(totalSupply, wad);
        emit Burn(guy, wad);
    }

}

contract TestVat is Vat {
    function mint(address usr, uint256 rad) public {
        dai[usr] += rad;
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
    LendingAuthGemJoin public gemJoin;
    DssPsmCme public psm;

    constructor(Dai dai_, LendingAuthGemJoin gemJoin_, DssPsmCme psm_) public {
        dai = dai_;
        gemJoin = gemJoin_;
        psm = psm_;
    }

    function sellGem(uint256 wad) public {
        DSToken(address(gemJoin.gem())).approve(address(gemJoin));
        psm.sellGem(address(this), wad);
    }

    function buyGem(uint256 wad) public {
        dai.approve(address(psm), uint256(-1));
        psm.buyGem(address(this), wad);
    }

}

contract DssPsmCmeTest is DSTest {
    
    Hevm hevm;

    address me;

    TestVat vat;
    Spotter spotGemA;
    Spotter spotGemB;
    TestVow vow;
    DSValue pipGemA;
    DSValue pipGemB;
    TestToken usdx;
    DaiJoin daiJoinGemA;
    DaiJoin daiJoinGemB;
    Dai dai;

    TestCToken ctoken;
    TestCToken cdai;

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

        vat = new TestVat();
        vat = vat;

        spotGemA = new Spotter(address(vat));
        vat.rely(address(spotGemA));

        spotGemB = new Spotter(address(vat));
        vat.rely(address(spotGemB));

        vow = new TestVow(address(vat), address(0), address(0));

        usdx = new TestToken("USDX", 6);
        usdx.mint(1000 * USDX_WAD);

        vat.init(ilkA);
        vat.init(ilkB);

        dai = new Dai(0);

        ctoken = new TestCToken("CUSDC", 8, usdx);
        usdx.setOwner(address(ctoken));

        cdai = new TestCToken("CDAI", 8, DSToken(address(dai)));
        dai.rely(address(cdai));

        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(usdx), address(ctoken), address(0));
        vat.rely(address(gemA));

        gemB = new LendingAuthGemJoin(address(vat), ilkB, address(dai), address(cdai), address(0));
        vat.rely(address(gemB));


        daiJoinGemA = new DaiJoin(address(vat), address(dai));
        vat.rely(address(daiJoinGemA));
        dai.rely(address(daiJoinGemA));

        daiJoinGemB = new DaiJoin(address(vat), address(dai));
        vat.rely(address(daiJoinGemB));
        dai.rely(address(daiJoinGemB));

        psmA = new DssPsmCme(address(gemA), address(daiJoinGemA), address(gemB), address(daiJoinGemB), address(vow));
        gemA.rely(address(psmA));
        gemA.deny(me);

        gemB.rely(address(psmA));
        gemB.deny(me);

        daiJoinGemA.rely(address(psmA));
        daiJoinGemA.deny(me);

        daiJoinGemB.rely(address(psmA));
        daiJoinGemB.deny(me);

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
        vat.file("Line",       rad(1000 ether));

        vat.file(ilkB, "line", rad(1000 ether));
        vat.file("Line",       rad(1000 ether));
    }

    function test_sellGem_no_fee() public {
        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.gem(ilkB, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);

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

    function test_sellGem_fee() public {
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

        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);

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
        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);
        dai.approve(address(psmA), 40 ether);
        psmA.buyGem(me, 40 * USDX_WAD);

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

        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);

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
        psmA.buyGem(me, 40 * USDX_WAD);

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

        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);

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
        psmA.buyGem(me, 40 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 940 * USDX_WAD);
        assertEq(dai.balanceOf(me), 51 ether);
        assertEq(vow.Joy(), rad(9 ether));
        (inkA, artA) = vat.urns(ilkA, address(psmA));
        assertEq(inkA, 60 ether);
        assertEq(artA, 60 ether);

        (inkB, artB) = vat.urns(ilkB, address(psmA));
        assertEq(inkB, 60 ether);
        assertEq(artB, 60 ether);

        psmA.sellGem(me, 100 * USDX_WAD);

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
        psmA.buyGem(me, 40 * USDX_WAD);

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
        usdx.approve(address(gemA));
        psmA.sellGem(me, 100 * USDX_WAD);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), rad(0 ether));

        User someUser = new User(dai, gemA, psmA);
        dai.mint(address(someUser), 45 ether);
        someUser.buyGem(40 * USDX_WAD);

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

        User user1 = new User(dai, gemA, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sellGem(40 * USDX_WAD);

        assertEq(usdx.balanceOf(address(user1)), 0 * USDX_WAD);
        assertEq(dai.balanceOf(address(user1)), 40 ether - 40);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink1, uint256 art1) = vat.urns(ilkA, address(psmA));
        assertEq(ink1, 40 ether);
        assertEq(art1, 40 ether);

        user1.buyGem(40 * USDX_WAD - 1);

        assertEq(usdx.balanceOf(address(user1)), 40 * USDX_WAD - 1);
        assertEq(dai.balanceOf(address(user1)), 999999999960);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink2, uint256 art2) = vat.urns(ilkA, address(psmA));
        assertEq(ink2, 1 * 10 ** 12);
        assertEq(art2, 1 * 10 ** 12);
    }

    function testFail_sellGem_insufficient_gem() public {
        User user1 = new User(dai, gemA, psmA);
        user1.sellGem(40 * USDX_WAD);
    }

    function testFail_swap_both_small_fee_insufficient_dai() public {
        psmA.file("tin", 1);        // Very small fee pushes you over the edge

        User user1 = new User(dai, gemA, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sellGem(40 * USDX_WAD);
        user1.buyGem(40 * USDX_WAD);
    }

    function testFail_sellGem_over_line() public {
        usdx.mint(1000 * USDX_WAD);
        usdx.approve(address(gemA));
        psmA.buyGem(me, 2000 * USDX_WAD);
    }

    function testFail_two_users_insufficient_dai() public {
        User user1 = new User(dai, gemA, psmA);
        usdx.transfer(address(user1), 40 * USDX_WAD);
        user1.sellGem(40 * USDX_WAD);

        User user2 = new User(dai, gemA, psmA);
        dai.mint(address(user2), 39 ether);
        user2.buyGem(40 * USDX_WAD);
    }

    function test_swap_both_zero() public {
        usdx.approve(address(gemA), uint(-1));
        psmA.sellGem(me, 0);
        dai.approve(address(psmA), uint(-1));
        psmA.buyGem(me, 0);
    }

    function testFail_direct_deposit() public {
        usdx.approve(address(gemA), uint(-1));
        gemA.join(me, 10 * USDX_WAD, me);
    }

}

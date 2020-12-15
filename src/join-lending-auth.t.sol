pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";
import "ds-token/token.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Dai}              from "dss/dai.sol";

import "./join-lending-auth.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestToken is DSToken {

    constructor(bytes32 symbol_, uint256 decimals_) public DSToken(symbol_) {
        decimals = decimals_;
    }

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


contract TestCToken is DSMath {

    DSToken underlyingToken;
    uint reward;
    DSToken bonusToken;

    constructor(bytes32 symbol_, uint256 decimals_, DSToken underlyingToken_, DSToken bonusToken_) public {
        decimals = decimals_;
        underlyingToken = underlyingToken_;
        bonusToken = bonusToken_;
        symbol = symbol_;
    }

    function mint(uint256 mintAmount) external returns (uint256){
        mint(msg.sender, mintAmount);
        underlyingToken.burn(msg.sender, mintAmount);
        bonusToken.mint(msg.sender, reward);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256){
        burn(msg.sender, redeemAmount);
        underlyingToken.mint(msg.sender, redeemAmount);
        bonusToken.mint(msg.sender, reward);
        return 0;
    }

    function setReward(uint256 reward_) external {
        reward = reward_;
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

contract DssPsmCmeTest is DSTest {
    
    Hevm hevm;

    address me;

    TestVat vat;
    Spotter spotGemA;
    DSValue pipGemA;
    TestToken usdx;
    Dai dai;

    TestCToken ctoken;
    DSToken bonusToken;
    TestDelegator bonusDelegator;

    LendingAuthGemJoin gemA;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "usdx";

    uint256 constant TOLL_ONE_PCT = 10 ** 16;
    uint256 constant USDX_WAD = 10 ** 6;
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

        vat = new TestVat();
        vat = vat;

        spotGemA = new Spotter(address(vat));
        vat.rely(address(spotGemA));

        usdx = new TestToken("USDX", 6);
        usdx.mint(1000 * USDX_WAD);
        USDX_TO_18 = 10 ** (18 - usdx.decimals());
        vat.init(ilkA);

        dai = new Dai(0);
        bonusToken = new TestToken("XOMP", 8);
        bonusDelegator = new TestDelegator();
        ctoken = new TestCToken("CUSDC", 8, usdx, bonusToken);
        usdx.setOwner(address(ctoken));

        bonusToken.setOwner(address(ctoken));

        gemA = new LendingAuthGemJoin(address(vat), ilkA, address(usdx), address(ctoken));
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

    function test_join_with_delegator_call_only() public {
        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));//token
        gemA.file("bonusDelegator", address(me));
        gemA.join(me, 100 * USDX_WAD, me);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 100 * USDX_WAD * USDX_TO_18);
    }

    function test_join_with_bonus_token_call_only() public {
        assertEq(usdx.balanceOf(me), 1000 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);

        usdx.approve(address(gemA));//token
        gemA.file("bonusToken", address(bonusToken));
        gemA.join(me, 100 * USDX_WAD, me);

        assertEq(usdx.balanceOf(me), 900 * USDX_WAD);
        assertEq(vat.gem(ilkA, me), 100 * USDX_WAD * USDX_TO_18);
    }

    function test_join_with_bonus_delegator_setup() public {
        usdx.approve(address(gemA));//token

        gemA.file("bonusToken", address(bonusToken));
        gemA.file("bonusDelegator", address(bonusDelegator));
        ctoken.setReward(1);

        gemA.join(me, 100 * USDX_WAD, me);
        assertTrue(!bonusDelegator.hasBeenCalled());
        gemA.exit(me, 100 * USDX_WAD);
        assertTrue(!bonusDelegator.hasBeenCalled());
        hevm.warp(1 days);
        gemA.join(me, 100 * USDX_WAD, me);
        assertTrue(bonusDelegator.hasBeenCalled());
        bonusDelegator.reset();
        gemA.exit(me, 100 * USDX_WAD);
        assertTrue(!bonusDelegator.hasBeenCalled());

        assertEq(bonusToken.balanceOf(address(bonusDelegator)) , 3);
    }

    function test_join_with_bonus_delegator_and_duration() public {
        usdx.approve(address(gemA));//token

        gemA.file("bonusToken", address(bonusToken));
        gemA.file("bonusDelegator", address(bonusDelegator));
        gemA.file("duration", 14400); //4 hours
        ctoken.setReward(1);

        gemA.join(me, 100 * USDX_WAD, me);
        assertTrue(!bonusDelegator.hasBeenCalled());
        gemA.exit(me, 100 * USDX_WAD);
        assertTrue(!bonusDelegator.hasBeenCalled());
        hevm.warp(2 hours);
        gemA.join(me, 100 * USDX_WAD, me);
        assertTrue(!bonusDelegator.hasBeenCalled());
        bonusDelegator.reset();
        gemA.exit(me, 100 * USDX_WAD);
        assertTrue(!bonusDelegator.hasBeenCalled());

        assertEq(bonusToken.balanceOf(address(bonusDelegator)) , 0);

        hevm.warp(4 hours + 1 seconds);

        gemA.join(me, 100 * USDX_WAD, me);
        assertTrue(bonusDelegator.hasBeenCalled());

        assertEq(bonusToken.balanceOf(address(bonusDelegator)) , 5);
    }
}

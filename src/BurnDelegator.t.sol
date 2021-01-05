pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-value/value.sol";
import "ds-token/token.sol";
import {Vat}              from "dss/vat.sol";
import {Spotter}          from "dss/spot.sol";
import {Dai}              from "dss/dai.sol";
import {Vow}              from "dss/vow.sol";
import {DaiJoin}          from "dss/join.sol";

import "./BurnDelegator.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestToken is DSToken {

    constructor(bytes32 symbol_, uint256 decimals_) public DSToken(symbol_) {
        decimals = decimals_;
    }

}

contract TestRoute {

    uint public amountOut;
    bool public hasBeenCalled = false;

    function swapTokensForExactTokens(uint _amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts){
        hasBeenCalled = true;
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = _amountOut;
        amountOut = _amountOut;

    }
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = amountIn;
    }

    function reset() external {
        hasBeenCalled = false;
        amountOut = 0;
    }

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

contract TestVow is Vow {
    constructor(address vat, address flapper, address flopper)
    public Vow(vat, flapper, flopper) {}
}

contract TestVat is Vat {
}

contract MkrAuthority {
    address public root;
    modifier sudo { require(msg.sender == root); _; }
    event LogSetRoot(address indexed newRoot);
    function setRoot(address usr) public sudo {
        root = usr;
        emit LogSetRoot(usr);
    }

    mapping (address => uint) public wards;
    event LogRely(address indexed usr);
    function rely(address usr) public sudo { wards[usr] = 1; emit LogRely(usr); }
    event LogDeny(address indexed usr);
    function deny(address usr) public sudo { wards[usr] = 0; emit LogDeny(usr); }

    constructor() public {
        root = msg.sender;
    }

    // bytes4(keccak256(abi.encodePacked('burn(uint256)')))
    bytes4 constant burn = bytes4(0x42966c68);
    // bytes4(keccak256(abi.encodePacked('burn(address,uint256)')))
    bytes4 constant burnFrom = bytes4(0x9dc29fac);
    // bytes4(keccak256(abi.encodePacked('mint(address,uint256)')))
    bytes4 constant mint = bytes4(0x40c10f19);

    function canCall(address src, address, bytes4 sig)
    public view returns (bool)
    {
        if (sig == burn || sig == burnFrom || src == root) {
            return true;
        } else if (sig == mint) {
            return (wards[src] == 1);
        } else {
            return false;
        }
    }
}

contract SellDelegotorTest is DSTest {
    
    Hevm hevm;

    address me;

    TestToken usdx;
    Dai dai;

    DSToken mkr;
    DSToken bonusToken;
    TestVow vow;
    TestVat vat;
    TestPSM testPsm;
    TestRoute testRoute;
    BurnDelegator burnDelegator;
    DaiJoin daiJoin;

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
        usdx.mint(1000);

        dai = new Dai(0);
        dai.mint(address(this), 1000);
        bonusToken = new TestToken("XOMP", 8);
        bonusToken.mint(1000);

        mkr = new TestToken("MKR", 8);
        MkrAuthority mkrAuthority = new MkrAuthority();
        mkr.setAuthority(DSAuthority(address(mkrAuthority)));
        mkr.mint(1000);
        /////
        testPsm = new TestPSM(usdx);
        usdx.setOwner(address(testPsm));
        testRoute = new TestRoute();
        vat = new TestVat();
        vow = new TestVow(address(vat), address(0), address(0));

        daiJoin = new DaiJoin(address(vat), address(dai));
        vat.rely(address(daiJoin));
        dai.rely(address(daiJoin));

        vat.init(ilk);
        vat.file(ilk, "line", rad(1000 ether));
        vat.file("Line",       rad(1000 ether));

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
        assertEq(usdx.balanceOf(address(vow)), 0);
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
        burnDelegator.file("max_dai_auction_amount", 200);
        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processDai_with_dai_over_max_dai_auction_amount() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("max_dai_auction_amount", 50);
        burnDelegator.processDai();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processDai_with_a_different_dai_auction_duration() public {
        dai.transfer(address(burnDelegator), 100);
        mkr.transfer(address(burnDelegator), 200);
        assertEq(dai.balanceOf(address(burnDelegator)), 100);

        burnDelegator.file("max_dai_auction_amount", 200);
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
        burnDelegator.file("max_bonus_auction_amount", 200);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);
    }

    function test_processComp_with_bonus_over_max_bonus_auction_amount() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);
        hevm.warp(4 hours);
        burnDelegator.file("max_bonus_auction_amount", 50);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 50);

    }

    function test_processComp_with_a_different_auction_duration() public {
        bonusToken.transfer(address(burnDelegator), 100);
        assertEq(bonusToken.balanceOf(address(burnDelegator)), 100);

        burnDelegator.file("max_bonus_auction_amount", 200);
        burnDelegator.file("bonus_auction_duration", 30*60);
        hevm.warp(45 minutes);
        burnDelegator.processComp();

        assertTrue(testRoute.hasBeenCalled());
        assertEq(testRoute.amountOut(), 100);

    }

}

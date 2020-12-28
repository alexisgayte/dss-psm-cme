pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";
import {Dai}              from "dss/dai.sol";

import "./SendDelegator.sol";

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

contract TestReserve {
}

contract SendDelegotorTest is DSTest {
    
    Hevm hevm;

    address me;

    TestToken usdx;
    Dai dai;
    TestReserve dai_reserve;
    TestReserve bonus_reserve;
    DSToken bonusToken;

    TestPSM testPsm;
    TestRoute testRoute;
    SendDelegator sendDelegator;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));


    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        usdx = new TestToken("USDX", 18);
        usdx.mint(1000);

        dai = new Dai(0);
        dai.mint(address(this), 1000);
        bonusToken = new TestToken("XOMP", 8);
        bonusToken.mint(1000);

        /////
        testPsm = new TestPSM(usdx);
        usdx.setOwner(address(testPsm));
        testRoute = new TestRoute();

        dai_reserve = new TestReserve();
        bonus_reserve = new TestReserve();

        sendDelegator = new SendDelegator(address(dai_reserve), address(bonus_reserve), address(dai), address(usdx), address(bonusToken));
        sendDelegator.file("psm", address(testPsm));
        sendDelegator.file("route", address(testRoute));
    }

    // processUsdc
    function test_processUsdc_without_usdc() public {
        sendDelegator.processUsdc();

        assertTrue(!testPsm.hasBeenCalled());
    }

    function test_processUsdc_with_usdc() public {
        usdx.transfer(address(sendDelegator), 100);
        assertEq(usdx.balanceOf(address(sendDelegator)), 100);
        assertEq(usdx.balanceOf(address(dai_reserve)), 0);
        sendDelegator.processUsdc();

        assertTrue(testPsm.hasBeenCalled());

        assertEq(usdx.balanceOf(address(sendDelegator)), 0);
    }

    // processDai


    function test_processDai_with_dai_under_duration() public {
        dai.mint(address(sendDelegator), 100);

        assertEq(dai.balanceOf(address(sendDelegator)), 100);
        hevm.warp(1 hours);

        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 100);
        assertEq(dai.balanceOf(address(dai_reserve)), 0);
    }

    function test_processDai_with_dai() public {
        dai.mint(address(sendDelegator), 100);

        assertEq(dai.balanceOf(address(sendDelegator)), 100);
        hevm.warp(4 hours);

        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 0);
        assertEq(dai.balanceOf(address(dai_reserve)), 100);
    }

    function test_processDai_with_dai_and_auction_time() public {
        dai.mint(address(sendDelegator), 100);
        assertEq(dai.balanceOf(address(sendDelegator)), 100);
        hevm.warp(4 hours);

        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 0);
        assertEq(dai.balanceOf(address(dai_reserve)), 100);

        // second round

        dai.mint(address(sendDelegator), 100);
        assertEq(dai.balanceOf(address(sendDelegator)), 100);

        hevm.warp(4 hours + 30 minutes);

        sendDelegator.processDai();
        assertEq(dai.balanceOf(address(sendDelegator)), 100);
        assertEq(dai.balanceOf(address(dai_reserve)), 100 + 0);

    }

    function test_processDai_with_dai_under_max_dai_auction_amount() public {
        dai.transfer(address(sendDelegator), 100);
        assertEq(dai.balanceOf(address(sendDelegator)), 100);

        hevm.warp(4 hours);
        sendDelegator.file("max_dai_auction_amount", 200);
        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 0);
        assertEq(dai.balanceOf(address(dai_reserve)), 100);
    }

    function test_processDai_with_dai_over_max_dai_auction_amount() public {
        dai.transfer(address(sendDelegator), 200);
        assertEq(dai.balanceOf(address(sendDelegator)), 200);

        hevm.warp(4 hours);
        sendDelegator.file("max_dai_auction_amount", 50);
        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 150);
        assertEq(dai.balanceOf(address(dai_reserve)), 50);

    }

    function test_processDai_with_a_different_dai_auction_duration() public {
        dai.transfer(address(sendDelegator), 100);
        assertEq(dai.balanceOf(address(sendDelegator)), 100);

        sendDelegator.file("max_dai_auction_amount", 200);
        sendDelegator.file("dai_auction_duration", 30*60);
        hevm.warp(45 minutes);
        sendDelegator.processDai();

        assertEq(dai.balanceOf(address(sendDelegator)), 0);
        assertEq(dai.balanceOf(address(dai_reserve)), 100);

    }

    // processComp
    function test_processComp_without_comp() public {
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        hevm.warp(4 hours);

        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 0);
    }

    function test_processComp_with_comp_under_duration() public {
        bonusToken.mint(address(sendDelegator), 100);

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);
        hevm.warp(1 hours);

        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 0);
    }

    function test_processComp_with_comp() public {
        bonusToken.mint(address(sendDelegator), 100);

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);
        hevm.warp(4 hours);

        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 100);
    }

    function test_processComp_with_comp_and_auction_time() public {
        bonusToken.mint(address(sendDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);
        hevm.warp(4 hours);

        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 100);

        // second round

        bonusToken.mint(address(sendDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);

        hevm.warp(4 hours + 30 minutes);

        sendDelegator.processComp();
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 100 + 0);

    }

    function test_processComp_with_comp_under_max_bonus_auction_amount() public {
        bonusToken.transfer(address(sendDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);

        hevm.warp(4 hours);
        sendDelegator.file("max_bonus_auction_amount", 200);
        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 100);
    }

    function test_processComp_with_comp_over_max_bonus_auction_amount() public {
        bonusToken.transfer(address(sendDelegator), 200);
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 200);

        hevm.warp(4 hours);
        sendDelegator.file("max_bonus_auction_amount", 50);
        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 150);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 50);

    }

    function test_processComp_with_a_different_bonus_auction_duration() public {
        bonusToken.transfer(address(sendDelegator), 100);
        assertEq(bonusToken.balanceOf(address(sendDelegator)), 100);

        sendDelegator.file("max_bonus_auction_amount", 200);
        sendDelegator.file("bonus_auction_duration", 30*60);
        hevm.warp(45 minutes);
        sendDelegator.processComp();

        assertEq(bonusToken.balanceOf(address(sendDelegator)), 0);
        assertEq(bonusToken.balanceOf(address(bonus_reserve)), 100);

    }

}

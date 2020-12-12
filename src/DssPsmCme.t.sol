pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./DssPsmCme.sol";

contract DssPsmCmeTest is DSTest {
    DssPsmCme cme;

    function setUp() public {
        cme = new DssPsmCme();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}

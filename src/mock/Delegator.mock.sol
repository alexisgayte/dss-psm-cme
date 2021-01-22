pragma solidity 0.6.7;

import { GemAbstract } from "dss-interfaces/ERC/GemAbstract.sol";

contract DelegatorMock {

    // primary variable
    GemAbstract public  dai;
    GemAbstract public  usdc;
    GemAbstract public  bonusToken;

    // constructor
    constructor(address dai_, address usdc_, address bonusToken_) public {

        dai        = GemAbstract(dai_);
        usdc       = GemAbstract(usdc_);
        bonusToken = GemAbstract(bonusToken_);

    }

    function hasMoneyBeenSent() external returns (bool) {
        uint256 _balance = dai.balanceOf(address(this));
        _balance += usdc.balanceOf(address(this));
        _balance += bonusToken.balanceOf(address(this));
        return (_balance > 0);
    }

    // --- Primary Functions ---

    function processDai() external {

    }

    function processComp() external {

    }

    function processUsdc() external {

    }
}